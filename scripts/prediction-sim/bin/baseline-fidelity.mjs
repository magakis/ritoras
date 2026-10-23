#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { adaptClientTelemetry, recordedEmissionMap } from '../lib/client-telemetry.mjs';
import { compareEmissionMaps } from './vad-never-onset-study.mjs';
import { compareTelemetry, replaySession } from './replay-vad.mjs';

const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
const DEFAULT_REPORT_PATH = path.join(DEFAULT_CORPUS_PATH, 'BASELINE-2026-10-23.md');
const TELEMETRY_FRAME_CAP = 2000;
const EMISSION_TOLERANCE_SECONDS = 0.6;
const SPLIT_RESUME_LIMIT_SECONDS = 1;
const EVENING_START_HOUR = 18;
const PHASE3_TRANSCRIPT_FILES = ['chunks.jsonl', 'transcription.txt', 'partial.txt'];

function parseArgs(argv) {
  const options = { corpusPath: DEFAULT_CORPUS_PATH, reportPath: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--corpus' || argument === '--report') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${argument} requires a path`);
      if (argument === '--corpus') options.corpusPath = path.resolve(value);
      else options.reportPath = path.resolve(value);
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }
  options.reportPath ??= path.join(options.corpusPath, path.basename(DEFAULT_REPORT_PATH));
  return options;
}

function positiveCount(value) {
  const count = Number(value);
  return Number.isFinite(count) && count > 0 ? count : null;
}

function sourceFrameCount(payload) {
  const candidates = [
    payload.summary?.frame_count,
    payload.summary?.frameCount,
    payload.summary?.total_frames,
    payload.summary?.totalFrames,
    payload.frame_count,
    payload.frameCount,
    payload.total_frames,
    payload.totalFrames,
  ];
  return candidates.map(positiveCount).find(count => count !== null) ?? null;
}

function inspectTelemetryRetention(payload) {
  const frames = Array.isArray(payload.frames) ? payload.frames : [];
  const retention = payload.summary?.retention ?? {};
  const reasons = [];
  const qValues = frames.map(frame => frame.q === undefined || frame.q === null
    ? Number.NaN
    : Number(frame.q));
  let qGapCount = 0;
  let missingSequenceCount = 0;
  let firstGap = null;

  if (frames.length === 0) {
    reasons.push('telemetry contains no frames');
  } else if (qValues.some(value => !Number.isInteger(value))) {
    reasons.push('frame sequence q is missing or non-integer; retention continuity cannot be verified');
  } else {
    if (qValues[0] !== 0) {
      missingSequenceCount += Math.max(0, qValues[0]);
      qGapCount += 1;
      firstGap = { expected: 0, actual: qValues[0] };
    }
    for (let index = 1; index < qValues.length; index += 1) {
      const delta = qValues[index] - qValues[index - 1];
      if (delta !== 1) {
        qGapCount += 1;
        if (delta > 1) missingSequenceCount += delta - 1;
        firstGap ??= { expected: qValues[index - 1] + 1, actual: qValues[index] };
      }
    }
    if (qGapCount > 0) {
      reasons.push(`telemetry frame sequence has ${qGapCount} q gap(s), omitting at least ${missingSequenceCount} frame(s)`);
    }
  }

  const recordedFrameCount = sourceFrameCount(payload);
  if (recordedFrameCount !== null && recordedFrameCount > frames.length) {
    reasons.push(`telemetry retained ${frames.length} of ${recordedFrameCount} recorded frames`);
  }
  for (const field of ['historical_dropped', 'tail_dropped']) {
    const dropped = Number(retention[field] ?? 0);
    if (Number.isFinite(dropped) && dropped > 0) {
      reasons.push(`telemetry retention reports ${dropped} ${field.replace('_', ' ')} frame(s)`);
    }
  }
  const eventsDropped = Number(retention.events_dropped ?? 0);
  if (Number.isFinite(eventsDropped) && eventsDropped > 0) {
    reasons.push(`telemetry retention reports ${eventsDropped} dropped event(s)`);
  }
  if (retention.policy === 'stratified_tail'
    && frames.length >= TELEMETRY_FRAME_CAP
    && recordedFrameCount === null
    && qGapCount === 0) {
    reasons.push(`telemetry reached the ${TELEMETRY_FRAME_CAP}-frame stratified history/tail cap; total source-frame count is unavailable`);
  }

  return {
    frameCount: frames.length,
    recordedFrameCount,
    qGapCount,
    missingSequenceCount,
    firstGap,
    retentionPolicy: retention.policy ?? null,
    historicalDropped: Number(retention.historical_dropped ?? 0),
    tailDropped: Number(retention.tail_dropped ?? 0),
    eventsDropped: Number(retention.events_dropped ?? 0),
    reasons: [...new Set(reasons)],
  };
}

function emissionMap(events) {
  return events.filter(event => event.k === 'emit').map(event => ({
    start: Number.isFinite(event.s0) ? event.s0 / 1000 : null,
    end: Number.isFinite(event.s1) ? event.s1 / 1000 : null,
    duration: Number.isFinite(event.tm) ? event.tm / 1000 : null,
    id: event.id ?? null,
    reason: event.r ?? null,
    finalizeTime: Number.isFinite(event.time) ? event.time : null,
  }));
}

function recordedFinalizeDecisions(payload) {
  let time = 0;
  const decisions = [];
  for (const [index, frame] of (payload.frames ?? []).entries()) {
    const duration = Number(frame.dt);
    if (!Number.isFinite(duration) || duration <= 0) continue;
    time += duration;
    if (typeof frame.d === 'string' && frame.d.startsWith('finalize_')) {
      decisions.push({ time, frame: frame.q ?? index, decision: frame.d });
    }
  }
  return decisions;
}

function recordedEmissionDetails(payload) {
  const emissions = recordedEmissionMap({ events: payload.events });
  const emitEvents = payload.events.filter(event => event.k === 'emit');
  const finalizeDecisions = recordedFinalizeDecisions(payload);
  let lastMatchedDecisionTime = -Infinity;
  return emissions.map((emission, index) => {
    const reason = emitEvents[index]?.r ?? null;
    const expectedDecision = reason ? `finalize_${reason}` : null;
    const decision = expectedDecision
      ? finalizeDecisions.find(candidate => candidate.decision === expectedDecision
        && candidate.time > lastMatchedDecisionTime
        && candidate.time >= (emission.start ?? 0)
        && candidate.time >= (emission.end ?? 0))
      : null;
    if (decision) lastMatchedDecisionTime = decision.time;
    return {
      ...emission,
      reason,
      finalizeTime: decision?.time ?? null,
      finalizeFrame: decision?.frame ?? null,
      closeTimeSource: decision ? 'finalize-frame' : null,
    };
  });
}

function recordedStartTimes(payload) {
  let time = 0;
  const starts = [];
  for (const [index, frame] of (payload.frames ?? []).entries()) {
    const duration = Number(frame.dt);
    if (!Number.isFinite(duration) || duration <= 0) continue;
    time += duration;
    if (frame.d === 'start_utterance') starts.push({ time, frame: frame.q ?? index });
  }
  return starts;
}

function detectSplitSignatures(sessionResult) {
  if (!sessionResult.payload || !sessionResult.recorded.length) return [];
  const starts = recordedStartTimes(sessionResult.payload);
  return sessionResult.recorded.flatMap(emission => {
    if (!Number.isFinite(emission.end) || emission.reason !== 'endpoint') return [];
    const closeAt = emission.finalizeTime ?? emission.end;
    const resume = starts.find(start => start.time > closeAt);
    if (!resume) return [];
    const delay = resume.time - closeAt;
    if (delay < 0 || delay >= SPLIT_RESUME_LIMIT_SECONDS) return [];
    return [{
      id: sessionResult.id,
      emissionId: emission.id,
      closeAt,
      resumedAt: resume.time,
      resumeFrame: resume.frame,
      resumeAfterSeconds: delay,
      emissionReason: emission.reason,
      closeTimeSource: emission.closeTimeSource ?? 'emission-boundary-fallback',
      evidenceQuality: sessionResult.status === 'fidelity-ok'
        ? 'fidelity-validated'
        : `provisional-${sessionResult.status}`,
      usableForPhase3: sessionResult.status === 'fidelity-ok'
        && emission.closeTimeSource === 'finalize-frame',
    }];
  });
}

function isEveningSession(sessionId) {
  const match = sessionId.match(/^20261023-(\d{2})\d{4}$/);
  return Boolean(match && Number(match[1]) >= EVENING_START_HOUR);
}

function formatSeconds(value) {
  return Number.isFinite(value) ? `${value.toFixed(3)}s` : 'n/a';
}

function formatEmissionMap(map) {
  if (map.length === 0) return 'none';
  return map.map(emission => {
    const id = emission.id === null ? '?' : emission.id;
    const range = Number.isFinite(emission.start) && Number.isFinite(emission.end)
      ? `${formatSeconds(emission.start)}–${formatSeconds(emission.end)}`
      : 'boundary unavailable';
    const reason = emission.reason ? `/${emission.reason}` : '';
    return `#${id}${reason} ${range}`;
  }).join('; ');
}

function formatSplitSignature(item) {
  return `close ${formatSeconds(item.closeAt)} → resume ${formatSeconds(item.resumedAt)} (${(item.resumeAfterSeconds * 1000).toFixed(0)} ms, emit #${item.emissionId ?? '?'}, ${item.evidenceQuality})`;
}

function mirrorRevision() {
  const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
  const result = spawnSync('git', ['rev-parse', '--short', 'HEAD'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
  });
  return result.status === 0 ? result.stdout.trim() : 'unknown';
}

function loadSessionResult(corpusPath, entry) {
  const telemetryPath = path.join(corpusPath, entry.path, 'client_telemetry.json');
  const missingPhase3Files = PHASE3_TRANSCRIPT_FILES.filter(file => (
    !fs.existsSync(path.join(corpusPath, entry.path, file))
  ));
  const result = {
    id: entry.id,
    path: entry.path,
    sources: entry.sources ?? [],
    payload: null,
    recorded: [],
    replayed: [],
    comparison: null,
    frameDivergence: null,
    status: 'excluded',
    exclusionReason: null,
    retention: null,
    frameCount: 0,
    config: null,
    missingPhase3Files,
  };
  if (!fs.existsSync(telemetryPath)) {
    const artifactNote = missingPhase3Files.length > 0
      ? `; phase-3 transcript artifact(s) also missing: ${missingPhase3Files.join(', ')}`
      : '';
    result.exclusionReason = `client_telemetry.json is missing${artifactNote}`;
    return result;
  }

  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(telemetryPath, 'utf8'));
  } catch (error) {
    result.exclusionReason = `client_telemetry.json is invalid: ${error.message}`;
    return result;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    result.exclusionReason = 'client_telemetry.json root is not an object';
    return result;
  }
  result.payload = payload;
  result.retention = inspectTelemetryRetention(payload);
  result.frameCount = result.retention.frameCount;
  result.recorded = Array.isArray(payload.events)
    ? recordedEmissionDetails(payload)
    : [];
  if (!Array.isArray(payload.events)) {
    result.exclusionReason = 'telemetry events array is missing; recorded emission map is unavailable';
    return result;
  }
  if (result.retention.reasons.length > 0) {
    result.exclusionReason = result.retention.reasons.join('; ');
    return result;
  }

  try {
    const session = adaptClientTelemetry(payload, entry.id);
    const replay = replaySession(session, session.config, { compare: false });
    result.config = replay.config;
    result.replayed = emissionMap(replay.events);
    result.comparison = compareEmissionMaps(result.recorded, result.replayed);
    if (result.comparison.pass) {
      result.status = 'fidelity-ok';
    } else {
      const mismatch = result.comparison.rows.find(row => !row.matched);
      result.frameDivergence = compareTelemetry(session.recordedFrames, replay.frames).firstDivergence;
      const frameDetail = result.frameDivergence
        ? `first frame divergence ${result.frameDivergence.frame} (q${result.frameDivergence.seq}; ${result.frameDivergence.fields.join('/')})`
        : 'no per-frame divergence was identified';
      result.exclusionReason = `unresolved current-mirror emission divergence: ${result.comparison.rows.filter(row => !row.matched).length} unmatched emission row(s); ${frameDetail}; first mismatch ${JSON.stringify(mismatch)}`;
    }
  } catch (error) {
    result.exclusionReason = `current-mirror replay failed: ${error.message}`;
  }
  return result;
}

function maxBoundaryDelta(comparison) {
  const deltas = comparison?.rows.flatMap(row => [row.startDelta, row.endDelta])
    .filter(Number.isFinite) ?? [];
  return deltas.length > 0 ? Math.max(...deltas) : null;
}

function markdownReport({ corpusPath, reportPath, inventory, results, signatures }) {
  const validated = results.filter(result => result.status === 'fidelity-ok');
  const excluded = results.filter(result => result.status !== 'fidelity-ok');
  const validatedSignatures = signatures.filter(item => item.usableForPhase3);
  const provisionalSignatures = signatures.filter(item => !item.usableForPhase3);
  const incidentCandidates = signatures.filter(item => isEveningSession(item.id));
  const incidentCandidateSessions = [...new Set(incidentCandidates.map(item => item.id))].sort();
  const healthyControls = validated.filter(result => result.recorded.length > 0
    && !signatures.some(item => item.id === result.id));
  const unresolved = excluded.filter(result => result.exclusionReason?.startsWith('unresolved current-mirror'));
  const lines = [
    '# Ritoras VAD baseline fidelity · 2026-10-23',
    '',
    `- Generated: ${new Date().toISOString()}`,
    `- Corpus: ${corpusPath}`,
    `- Current JS mirror revision: ${mirrorRevision()}`,
    `- Sessions: ${results.length} total; ${validated.length} fidelity-validated; ${excluded.length} excluded; ${unresolved.length} unresolved replay divergence(s).`,
    `- Split signature: recorded endpoint finalize frame followed by the next recorded start_utterance decision in less than ${SPLIT_RESUME_LIMIT_SECONDS.toFixed(1)} second.`,
    `- Evening incident candidates: session IDs at or after ${String(EVENING_START_HOUR).padStart(2, '0')}:00; no exact incident timestamp was supplied, so this is a candidate set, not attribution.`,
    '',
    '## Fidelity-validated sessions',
    '',
    validated.map(result => `- ${result.id} (${result.frameCount} frames; ${result.recorded.length} emissions)`).join('\n') || '- None',
    '',
    '## Excluded sessions and reasons',
    '',
    '| Session | Sources | Frames | Reason |',
    '|---|---|---:|---|',
  ];
  for (const result of excluded) {
    lines.push(`| ${result.id} | ${(result.sources ?? []).join(', ') || 'unknown'} | ${result.frameCount} | ${result.exclusionReason ?? 'unclassified exclusion'} |`);
  }
  if (excluded.length === 0) lines.push('| none | — | — | — |');

  const transcriptArtifactWarnings = results.filter(result => result.missingPhase3Files.length > 0);
  lines.push('', '## Phase 3 transcript-artifact gaps', '');
  if (transcriptArtifactWarnings.length === 0) {
    lines.push('- None');
  } else {
    for (const result of transcriptArtifactWarnings) {
      lines.push(`- ${result.id}: missing ${result.missingPhase3Files.join(', ')}; not all Phase 3 transcript/merger analyses can use this session.`);
    }
  }

  lines.push(
    '',
    '## Emission-map fidelity by session',
    '',
    `Pass requires equal emission counts and both start/end boundaries within ${EMISSION_TOLERANCE_SECONDS.toFixed(3)} s. Excluded sessions are not replay-qualified; their recorded map is shown where telemetry remains available.`,
    '',
    '| Session | Frames | Recorded emission map | Replayed emission map | Result | Max boundary delta |',
    '|---|---:|---|---|---|---:|',
  );
  for (const result of results) {
    const resultName = result.status === 'fidelity-ok'
      ? 'MATCH'
      : result.exclusionReason?.startsWith('unresolved current-mirror') ? 'DIVERGENCE' : 'EXCLUDED';
    const recordedMap = formatEmissionMap(result.recorded);
    const replayedMap = result.replayed.length > 0 || result.status === 'fidelity-ok'
      ? formatEmissionMap(result.replayed)
      : 'not replayed';
    const delta = maxBoundaryDelta(result.comparison);
    lines.push(`| ${result.id} | ${result.frameCount} | ${recordedMap} | ${replayedMap} | ${resultName} | ${formatSeconds(delta)} |`);
  }

  lines.push(
    '',
    '## Split-signature sessions',
    '',
    `Validated split-signature cases: ${validatedSignatures.length} across ${new Set(validatedSignatures.map(item => item.id)).size} fidelity-validated session(s).`,
    '',
  );
  if (validatedSignatures.length === 0) lines.push('- None');
  for (const item of validatedSignatures) lines.push(`- ${item.id}: ${formatSplitSignature(item)}; close from ${item.closeTimeSource}, resume decision frame ${item.resumeFrame}.`);
  if (provisionalSignatures.length > 0) {
    lines.push('', '### Provisional signatures in excluded sessions', '');
    for (const item of provisionalSignatures) {
      lines.push(`- ${item.id}: ${formatSplitSignature(item)}; close from ${item.closeTimeSource}; not phase-3 eligible.`);
    }
  }

  lines.push(
    '',
    '## Evening live-incident candidates',
    '',
    `Candidate sessions: ${incidentCandidateSessions.length}; cases: ${incidentCandidates.length}. Candidates are all observed evening split signatures; review their preserved transcripts/chunks before attributing the reported incident.`,
    '',
  );
  if (incidentCandidates.length === 0) lines.push('- None');
  for (const item of incidentCandidates) {
    lines.push(`- ${item.id}: ${formatSplitSignature(item)}; close from ${item.closeTimeSource}; phase-3 usable: ${item.usableForPhase3 ? 'yes' : 'no'}.`);
  }

  lines.push(
    '',
    '## Healthy-control sessions',
    '',
    `Definition: fidelity-validated session with at least one recorded emission and no recorded start within ${SPLIT_RESUME_LIMIT_SECONDS.toFixed(1)} s of an endpoint finalize frame.`,
    '',
  );
  if (healthyControls.length === 0) lines.push('- None');
  for (const result of healthyControls) {
    const lastEmission = result.recorded.at(-1);
    const silenceMs = result.config?.endpointSilenceMs ?? result.config?.silenceMs ?? null;
    lines.push(`- ${result.id}: ${result.recorded.length} emission(s); last boundary ${formatSeconds(lastEmission.end)}; recorded endpoint silence setting ${silenceMs ?? 'unknown'} ms.`);
  }

  lines.push(
    '',
    '## Retention notes',
    '',
    `- Pi capture retention prunes older sessions; this run includes the fetched ${inventory.sources.pi.sessionCount} Pi sessions and ${inventory.sources.localMorning.sessionCount} local morning sessions.`,
    `- Telemetry exclusions are retained in INVENTORY.json with q-gap, cap, dropped-frame, dropped-event, or missing-file reasons.`,
    `- Phase 3 transcript-artifact gaps are listed separately; missing transcript files do not change VAD emission-fidelity status.`,
    `- Transcript contents are preserved in the corpus session directories and intentionally omitted from this summary report.`,
    `- Full report path: ${reportPath}`,
    '',
  );
  return {
    markdown: `${lines.join('\n')}\n`,
    counts: {
      total: results.length,
      fidelityValidated: validated.length,
      excluded: excluded.length,
      unresolvedDivergence: unresolved.length,
      splitSignatureCases: signatures.length,
      splitSignatureSessions: new Set(signatures.map(item => item.id)).size,
      liveIncidentCandidateCases: incidentCandidates.length,
      liveIncidentCandidateSessions: incidentCandidateSessions.length,
      healthyControls: healthyControls.length,
    },
    validated,
    excluded,
    unresolved,
    validatedSignatures,
    incidentCandidateSessions,
    healthyControls,
  };
}

export function runBaseline({
  corpusPath = DEFAULT_CORPUS_PATH,
  reportPath = DEFAULT_REPORT_PATH,
} = {}) {
  const inventoryPath = path.join(corpusPath, 'INVENTORY.json');
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, 'utf8'));
  if (!Array.isArray(inventory.sessions)) throw new Error('INVENTORY.json has no sessions array');
  const results = inventory.sessions
    .map(entry => loadSessionResult(corpusPath, entry))
    .sort((left, right) => left.id.localeCompare(right.id));
  const signatures = results.flatMap(detectSplitSignatures);
  const report = markdownReport({ corpusPath, reportPath, inventory, results, signatures });

  const resultById = new Map(results.map(result => [result.id, result]));
  inventory.sessions = inventory.sessions.map(entry => {
    const result = resultById.get(entry.id);
    return {
      ...entry,
      status: result.status,
      exclusionReason: result.exclusionReason,
      telemetry: {
        ...entry.telemetry,
        ...(result.retention ?? {}),
      },
      phase3Artifacts: {
        ready: result.missingPhase3Files.length === 0,
        missingFiles: result.missingPhase3Files,
      },
      fidelity: {
        pass: result.status === 'fidelity-ok',
        recordedEmissionCount: result.recorded.length,
        replayedEmissionCount: result.replayed.length,
        maxBoundaryDeltaSeconds: maxBoundaryDelta(result.comparison),
        classification: result.status === 'fidelity-ok'
          ? 'matched'
          : result.exclusionReason?.startsWith('unresolved current-mirror')
            ? 'unresolved-divergence'
            : 'excluded',
        firstFrameDivergence: result.frameDivergence,
      },
      splitSignatures: signatures.filter(item => item.id === entry.id),
    };
  });
  inventory.generatedAt = new Date().toISOString();
  inventory.baseline = {
    reportPath,
    mirrorRevision: mirrorRevision(),
    emissionBoundaryToleranceSeconds: EMISSION_TOLERANCE_SECONDS,
    splitResumeLimitSeconds: SPLIT_RESUME_LIMIT_SECONDS,
  };
  inventory.totals = {
    ...inventory.totals,
    sessionCount: results.length,
    fidelityValidated: report.counts.fidelityValidated,
    excludedSessionCount: report.counts.excluded,
    unresolvedDivergenceCount: report.counts.unresolvedDivergence,
    telemetryMissing: results.filter(result => result.exclusionReason?.startsWith('client_telemetry.json is missing'))
      .map(result => ({ id: result.id, reason: result.exclusionReason })),
    telemetryRetentionWarnings: results.filter(result => result.retention?.reasons.length > 0)
      .map(result => ({
        id: result.id,
        retainedFrames: result.frameCount,
        summaryFrameCount: result.retention.recordedFrameCount,
        qGapCount: result.retention.qGapCount,
        missingSequenceCount: result.retention.missingSequenceCount,
        reason: result.retention.reasons.join('; '),
      })),
    phase3ArtifactWarnings: results.filter(result => result.missingPhase3Files.length > 0)
      .map(result => ({
        id: result.id,
        missingFiles: result.missingPhase3Files,
        reason: `missing transcript artifact(s): ${result.missingPhase3Files.join(', ')}`,
      })),
    phase3ArtifactWarningCount: results.filter(result => result.missingPhase3Files.length > 0).length,
    splitSignatureCount: report.counts.splitSignatureCases,
    splitSignatureSessionCount: report.counts.splitSignatureSessions,
    liveIncidentCandidateCount: report.counts.liveIncidentCandidateSessions,
    healthyControlCount: report.counts.healthyControls,
  };
  fs.writeFileSync(inventoryPath, `${JSON.stringify(inventory, null, 2)}\n`);
  fs.writeFileSync(reportPath, report.markdown);
  return report.counts;
}

function usage() {
  return 'Usage: node scripts/prediction-sim/bin/baseline-fidelity.mjs [--corpus PATH] [--report PATH]';
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const counts = runBaseline(options);
  process.stdout.write(`Baseline: ${counts.total} sessions; ${counts.fidelityValidated} fidelity-ok; ${counts.excluded} excluded (${counts.unresolvedDivergence} unresolved); ${counts.splitSignatureCases} split cases across ${counts.splitSignatureSessions} sessions; ${counts.liveIncidentCandidateSessions} evening candidate sessions; ${counts.healthyControls} healthy controls\n`);
  process.stdout.write(`Inventory: ${path.join(options.corpusPath, 'INVENTORY.json')}\n`);
  process.stdout.write(`Report: ${options.reportPath}\n`);
  if (counts.unresolvedDivergence > 0) process.exitCode = 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
    process.exitCode = 1;
  }
}
