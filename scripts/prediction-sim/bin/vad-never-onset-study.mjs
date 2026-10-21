#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { adaptClientTelemetry, discoverClientTelemetry, recordedEmissionMap } from '../lib/client-telemetry.mjs';
import { findIdleGapTriggers } from '../lib/vad-idle-gap.mjs';
import { replaySession } from './replay-vad.mjs';

export const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
export const DEFAULT_STUDY_PATH = '/home/michael/vad-corpus/STUDY-2026-10-21.md';
export const DEFAULT_VERDICT_PATH = '/home/michael/vad-corpus/STUDY-2026-10-21.verdict.json';
const INCIDENT_ID = '20261021-175330';
// This capture records a sub-minimum tail that the current stop-flush mirror emits.
const KNOWN_LEGACY_FLUSH_SESSION = '20261021-192953';
const LOST_WINDOW = { start: 7.379, end: 8.579 };
const SWEEP = {
  slowOnsetDeltaDb: [3, 4, 5, 6, 7, 8],
  slowOnsetEvidenceMs: [150, 200, 250, 300, 400, 500, 600],
  slowOnsetWindowSeconds: [1, 1.5, 2, 2.5],
};
const EMISSION_MATCH_TOLERANCE_SECONDS = 0.6;

function parseArgs(argv) {
  const options = {
    corpusPath: DEFAULT_CORPUS_PATH,
    outputPath: DEFAULT_STUDY_PATH,
    verdictPath: DEFAULT_VERDICT_PATH,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (key === '--corpus' || key === '--output' || key === '--verdict') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${key} requires a path`);
      if (key === '--corpus') options.corpusPath = path.resolve(value);
      else if (key === '--output') options.outputPath = path.resolve(value);
      else options.verdictPath = path.resolve(value);
      continue;
    }
    if (key === '--help' || key === '-h') {
      options.help = true;
      continue;
    }
    throw new Error(`unknown option: ${key}`);
  }
  return options;
}

function emissionMap(replay) {
  return replay.events.filter(event => event.k === 'emit').map(event => ({
    start: Number.isFinite(event.s0) ? event.s0 / 1000 : null,
    end: Number.isFinite(event.s1) ? event.s1 / 1000 : null,
    duration: Number.isFinite(event.tm) ? event.tm / 1000 : null,
    id: event.id ?? null,
  }));
}

export function compareEmissionMaps(expected, actual) {
  const rows = [];
  const countMatches = expected.length === actual.length;
  let boundariesMatch = countMatches;
  for (let index = 0; index < Math.max(expected.length, actual.length); index += 1) {
    const recorded = expected[index] ?? null;
    const replayed = actual[index] ?? null;
    const boundariesAvailable = recorded && replayed
      && Number.isFinite(recorded.start)
      && Number.isFinite(recorded.end)
      && Number.isFinite(replayed.start)
      && Number.isFinite(replayed.end);
    const startDelta = boundariesAvailable
      ? Math.abs(recorded.start - replayed.start)
      : null;
    const endDelta = boundariesAvailable
      ? Math.abs(recorded.end - replayed.end)
      : null;
    const matched = Boolean(boundariesAvailable
      && startDelta <= EMISSION_MATCH_TOLERANCE_SECONDS
      && endDelta <= EMISSION_MATCH_TOLERANCE_SECONDS);
    boundariesMatch &&= matched;
    rows.push({ index, recorded, replayed, startDelta, endDelta, matched });
  }
  return { pass: countMatches && boundariesMatch, countMatches, boundariesMatch, rows };
}

export function findFirstFrameDivergence(session, replay) {
  const fields = ['e', 'es', 'd'];
  let time = 0;
  for (let index = 0; index < Math.max(session.recordedFrames.length, replay.frames.length); index += 1) {
    const recorded = session.recordedFrames[index];
    const simulated = replay.frames[index];
    time = simulated?.time ?? time + (simulated?.dt ?? 0);
    const differingFields = fields.filter(field => recorded?.[field] !== simulated?.[field]);
    if (differingFields.length > 0) {
      return {
        frameIndex: index,
        timeSeconds: time,
        fields: differingFields,
        recorded: recorded ? Object.fromEntries(differingFields.map(field => [field, recorded[field]])) : null,
        simulated: simulated ? Object.fromEntries(differingFields.map(field => [field, simulated[field]])) : null,
      };
    }
  }
  const lastFrame = replay.frames.at(-1);
  return {
    frameIndex: Math.max(0, replay.frames.length - 1),
    timeSeconds: lastFrame?.time ?? replay.metrics.sessionDurationSeconds,
    fields: ['stop_flush/emission map'],
    recorded: null,
    simulated: null,
  };
}

export function isKnownLegacyStopFlushDivergence(session, recorded, replayed) {
  if (session.id !== KNOWN_LEGACY_FLUSH_SESSION) return null;
  const discardedTail = session.events.find(event => event.k === 'stop_flush'
    && event.r === 'below_minimums'
    && Number(event.sm) > 0
    && Number(event.sm) < Number(session.config.minSpeechMs)
    && Number.isFinite(event.s0)
    && Number.isFinite(event.s1));
  if (!discardedTail) return null;
  const expectedBoundary = { start: discardedTail.s0 / 1000, end: discardedTail.s1 / 1000 };
  const wasRecorded = recorded.some(emission => emission.start !== null
    && emission.end !== null
    && Math.abs(emission.start - expectedBoundary.start) <= EMISSION_MATCH_TOLERANCE_SECONDS
    && Math.abs(emission.end - expectedBoundary.end) <= EMISSION_MATCH_TOLERANCE_SECONDS);
  const wasSimulated = replayed.some(emission => emission.start !== null
    && emission.end !== null
    && Math.abs(emission.start - expectedBoundary.start) <= EMISSION_MATCH_TOLERANCE_SECONDS
    && Math.abs(emission.end - expectedBoundary.end) <= EMISSION_MATCH_TOLERANCE_SECONDS);
  if (wasRecorded || !wasSimulated) return null;
  return {
    classification: 'known-version-divergence',
    excludedFromFidelity: true,
    reason: `recorded stop_flush reason=below_minimums with ${discardedTail.sm} ms speech evidence (<${session.config.minSpeechMs} ms minimum) and no emit; current mirror emits the matching ${expectedBoundary.start.toFixed(3)}–${expectedBoundary.end.toFixed(3)} s tail because stop flush now requires nonzero speech evidence, not the recorded client's configured minimum`,
  };
}

function onsetTimes(replay) {
  return replay.events.filter(event => event.k === 'start_utterance')
    .map(event => event.time);
}

function expandTraceFixture(payload, sessionId) {
  const frames = [];
  for (const segment of payload.trace ?? []) {
    const count = Math.round(segment.durationMs / 10);
    for (let index = 0; index < count; index += 1) {
      frames.push({ dt: 0.01, db: segment.db });
    }
  }
  return adaptClientTelemetry({
    ...payload,
    frames,
    events: payload.events ?? [{ k: 'stop_flush', r: 'flush' }],
  }, sessionId);
}

function hasNewOnset(baseline, candidate) {
  return newOnsetCount(baseline, candidate) > 0;
}

function newOnsetCount(baseline, candidate) {
  const available = onsetTimes(baseline).map(time => ({ time, matched: false }));
  let added = 0;
  for (const onset of onsetTimes(candidate)) {
    const match = available.find(previous => !previous.matched
      && Math.abs(previous.time - onset) <= EMISSION_MATCH_TOLERANCE_SECONDS);
    if (match) match.matched = true;
    else added += 1;
  }
  return added;
}

function newEmissionCount(baseline, candidate) {
  const available = emissionMap(baseline).map(emission => ({ ...emission, matched: false }));
  let added = 0;
  for (const emission of emissionMap(candidate)) {
    const match = available.find(previous => !previous.matched
      && previous.start !== null
      && emission.start !== null
      && Math.abs(previous.start - emission.start) <= EMISSION_MATCH_TOLERANCE_SECONDS);
    if (match) match.matched = true;
    else added += 1;
  }
  return added;
}

function hasIncidentRecall(replay) {
  return onsetTimes(replay).some(onset => onset >= LOST_WINDOW.start && onset <= LOST_WINDOW.end);
}

function candidateConfigs(baselineConfig) {
  const candidates = [];
  for (const delta of SWEEP.slowOnsetDeltaDb) {
    for (const evidenceMs of SWEEP.slowOnsetEvidenceMs) {
      for (const windowSeconds of SWEEP.slowOnsetWindowSeconds) {
        candidates.push({
          ...baselineConfig,
          slowOnsetEnabled: true,
          slowOnsetDeltaDb: delta,
          slowOnsetEvidenceMs: evidenceMs,
          slowOnsetWindowSeconds: windowSeconds,
        });
      }
    }
  }
  return candidates;
}

function candidateLabel(config) {
  return `${config.slowOnsetDeltaDb}dB/${config.slowOnsetEvidenceMs}ms/${config.slowOnsetWindowSeconds}s`;
}

function applySlowOnsetParameters(config, candidate) {
  return {
    ...config,
    slowOnsetEnabled: true,
    slowOnsetDeltaDb: candidate.slowOnsetDeltaDb,
    slowOnsetEvidenceMs: candidate.slowOnsetEvidenceMs,
    slowOnsetWindowSeconds: candidate.slowOnsetWindowSeconds,
  };
}

function parameterDistance(left, right) {
  return Math.sqrt(
    ((left.slowOnsetDeltaDb - right.slowOnsetDeltaDb) / 2) ** 2
    + ((left.slowOnsetEvidenceMs - right.slowOnsetEvidenceMs) / 100) ** 2
    + ((left.slowOnsetWindowSeconds - right.slowOnsetWindowSeconds) / 0.5) ** 2,
  );
}

function findMargins(winner, violating) {
  const nearest = violating
    .map(config => ({ config, distance: parameterDistance(winner, config) }))
    .sort((left, right) => left.distance - right.distance)[0] ?? null;
  if (!nearest) return { nearestViolating: null, deltaDb: null, evidenceMs: null, distance: null };
  return {
    nearestViolating: {
      parameters: {
        slowOnsetDeltaDb: nearest.config.slowOnsetDeltaDb,
        slowOnsetEvidenceMs: nearest.config.slowOnsetEvidenceMs,
        slowOnsetWindowSeconds: nearest.config.slowOnsetWindowSeconds,
      },
      normalizedDistance: nearest.distance,
    },
    deltaDb: Math.abs(winner.slowOnsetDeltaDb - nearest.config.slowOnsetDeltaDb),
    evidenceMs: Math.abs(winner.slowOnsetEvidenceMs - nearest.config.slowOnsetEvidenceMs),
    distance: nearest.distance,
  };
}

function rankCandidates(results) {
  return results.filter(result => result.recall
    && result.addedSafetyOnsets === 0
    && result.addedSafetyEmissions === 0)
    .sort((left, right) => right.config.slowOnsetDeltaDb - left.config.slowOnsetDeltaDb
      || left.config.slowOnsetEvidenceMs - right.config.slowOnsetEvidenceMs
      || left.config.slowOnsetWindowSeconds - right.config.slowOnsetWindowSeconds);
}

function idleTriggerSummary(sessions, baselineById) {
  const perSession = sessions.map(session => {
    const replay = baselineById.get(session.id);
    const config = replay.config;
    const triggers = findIdleGapTriggers(replay.frames, {
      guardDb: config.absoluteSpeechFloorDb,
      deltaDb: 6,
    });
    return { id: session.id, idleStretchesTriggered: triggers.length, triggers };
  });
  return {
    sessionsWithTriggers: perSession.filter(item => item.idleStretchesTriggered > 0).length,
    sessions: perSession.length,
    triggerCount: perSession.reduce((sum, item) => sum + item.idleStretchesTriggered, 0),
    perSession,
  };
}

function formatMap(map) {
  if (map.length === 0) return 'none';
  return map.map(item => item.start === null || item.end === null
    ? `duration ${item.duration?.toFixed(3) ?? 'n/a'}s`
    : `${item.start.toFixed(3)}–${item.end.toFixed(3)}s`).join(', ');
}

function buildMarkdown(study) {
  const lines = [
    '# Never-onset VAD offline study · 2026-10-21',
    '',
    `Verdict: **${study.verdict}**`,
    '',
    '## Gate summary',
    '',
    '| Gate | Result | Details |',
    '|---|---|---|',
    `| Fidelity | ${study.gates.fidelity.pass ? 'PASS' : 'FAIL'} | ${study.gates.fidelity.passCount}/${study.gates.fidelity.sessionCount} matched; ${study.gates.fidelity.excludedCount} documented version-specific exclusion(s); ${study.gates.fidelity.unclassifiedCount} unexplained mismatch(es) |`,
    `| Incident recall | ${study.gates.recall.pass ? 'PASS' : 'FAIL'} | ${study.gates.recall.detail} |`,
    `| Safety | ${study.gates.safety.pass ? 'PASS' : 'FAIL'} | ${study.gates.safety.detail} |`,
    `| Winner/margin | ${study.gates.margin.pass ? 'PASS' : 'FAIL'} | ${study.gates.margin.detail} |`,
    '',
    '## Fidelity by session',
    '',
    '| Session | Frames | Recorded emissions | Replayed emissions | Result | First mismatch |',
    '|---|---:|---|---|---|---|',
  ];
  for (const item of study.fidelity) {
    const result = item.pass ? 'PASS' : item.excludedFromFidelity ? 'EXCLUDED' : 'FAIL';
    const details = item.firstMismatch
      ? `${item.firstMismatch}${item.reason ? `; ${item.reason}` : ''}`
      : 'none';
    lines.push(`| ${item.id} | ${item.frameCount} | ${formatMap(item.recorded)} | ${formatMap(item.replayed)} | ${result} | ${details} |`);
  }
  const exclusions = study.fidelity.filter(item => item.excludedFromFidelity);
  if (exclusions.length > 0) {
    lines.push('', '### Documented fidelity exclusion', '');
    for (const item of exclusions) {
      lines.push(`- ${item.id}: recorded emissions [${formatMap(item.recorded)}]; simulated emissions [${formatMap(item.replayed)}]; first divergence at frame ${item.frameDivergence.frameIndex} (${item.frameDivergence.timeSeconds.toFixed(3)} s). ${item.reason}.`);
    }
  }
  const recallPointLabels = study.frontier.recallPoints.map(candidateLabel);
  const recallSafeLabels = study.frontier.recallAndSafetyPoints.map(point =>
    `${candidateLabel(point)} [margin ${point.margins.deltaDb ?? 'n/a'} dB/${point.margins.evidenceMs ?? 'n/a'} ms]`);
  const allGateLabels = study.frontier.allGatePoints.map(candidateLabel);
  lines.push('', '## Parameter frontier', '',
    `- Recall-passing points (${recallPointLabels.length}): ${recallPointLabels.join(', ') || 'none'}.`,
    `- Recall + zero-addition safety points (${recallSafeLabels.length}): ${recallSafeLabels.join(', ') || 'none'}.`,
    `- Points passing recall, safety, and margin (${allGateLabels.length}): ${allGateLabels.join(', ') || 'none'}.`,
    '', '## Full parameter sweep', '',
    '| Level Δ | Cumulative N | Window W | Recall | Safety | New emissions / utterances | Margin ΔdB / Nms | Margin pass | All gates |',
    '|---:|---:|---:|---|---|---:|---|---|---|');
  for (const result of study.sweep) {
    lines.push(`| ${result.config.slowOnsetDeltaDb} dB | ${result.config.slowOnsetEvidenceMs} ms | ${result.config.slowOnsetWindowSeconds} s | ${result.recall ? 'yes' : 'no'} | ${result.passesSafety ? 'yes' : 'no'} | ${result.addedSafetyEmissions} / ${result.addedSafetyOnsets} | ${result.margins.deltaDb ?? 'n/a'} / ${result.margins.evidenceMs ?? 'n/a'} | ${result.passesMargin ? 'yes' : 'no'} | ${result.passesAll ? 'yes' : 'no'} |`);
  }
  lines.push('', '## Selected configuration and safety margin', '');
  if (study.winner) {
    lines.push(`- Winner: slowLevelDelta=${study.winner.parameters.slowOnsetDeltaDb} dB, N=${study.winner.parameters.slowOnsetEvidenceMs} ms, W=${study.winner.parameters.slowOnsetWindowSeconds} s.`,
      `- Nearest violating grid point: ${study.margins.nearestViolating ? candidateLabel(study.margins.nearestViolating.parameters) : 'none in sweep grid'}.`,
      `- Axis margins: ${study.margins.deltaDb ?? 'n/a'} dB and ${study.margins.evidenceMs ?? 'n/a'} ms (normalized distance ${study.margins.distance?.toFixed(2) ?? 'n/a'}).`);
  } else if (study.bestSafeParameters) {
    lines.push(`- No candidate meets the required margin. Best recall+safe point: ${candidateLabel(study.bestSafeParameters)}.`);
  } else lines.push('- No candidate clears recall and safety.');
  lines.push('', '## Idle-gap trigger scan', '',
    `- ${study.idleGap.triggerCount} qualifying idle windows across ${study.idleGap.sessions} telemetry sessions; ${study.idleGap.sessionsWithTriggers} sessions had at least one trigger.`,
    '- Decision rule: continuous ≥300 ms in the last 10 s of each replayed idle stretch, with dB ≥ max(floor+6 dB, absolute guard).',
    '', `## Baseline-vs-${study.winner ? 'winner' : 'best safe candidate'} emission maps`, '',
    '| Session | Baseline map | Candidate map | New onset |',
    '|---|---|---|---|');
  for (const item of study.winnerMaps) {
    lines.push(`| ${item.id} | ${formatMap(item.baseline)} | ${formatMap(item.winner)} | ${item.newOnset ? 'yes' : 'no'} |`);
  }
  lines.push('', '## Interpretation', '',
    '- The replay consumes only telemetry frame `db` and `dt`; recorded output fields are used only for fidelity comparisons.',
    '- A pass establishes onset/emission behavior only. It does not establish recovered transcript content or device memory behavior.',
    '');
  return lines.join('\n');
}

export function machineVerdict(study) {
  return {
    verdict: {
      verdict: study.verdict,
      winner: study.winner,
      margins: study.margins,
      idleGap: {
        triggerCount: study.idleGap.triggerCount,
        sessionsWithTriggers: study.idleGap.sessionsWithTriggers,
        sessions: study.idleGap.sessions,
      },
    },
    details: {
      bestSafeParameters: study.bestSafeParameters,
      frontier: study.frontier,
      gates: study.gates,
      fidelity: study.fidelity,
      idleGap: study.idleGap,
      sweep: study.sweep,
      winnerMaps: study.winnerMaps,
    },
  };
}

export function runStudy({
  corpusPath = DEFAULT_CORPUS_PATH,
  outputPath = DEFAULT_STUDY_PATH,
  verdictPath = DEFAULT_VERDICT_PATH,
} = {}) {
  const allSessions = discoverClientTelemetry(corpusPath);
  const sessions = allSessions.filter(session => session.frames.length > 0);
  const incident = sessions.find(session => session.id === INCIDENT_ID);
  if (!incident) throw new Error(`required incident session ${INCIDENT_ID} not found in ${corpusPath}`);

  const baselineById = new Map();
  const fidelity = sessions.map(session => {
    const replay = replaySession(session);
    baselineById.set(session.id, replay);
    const recorded = recordedEmissionMap(session);
    const replayed = emissionMap(replay);
    const comparison = compareEmissionMaps(recorded, replayed);
    const firstMismatch = comparison.rows.find(row => !row.matched);
    const frameDivergence = comparison.pass ? null : findFirstFrameDivergence(session, replay);
    const legacyException = comparison.pass
      ? null
      : isKnownLegacyStopFlushDivergence(session, recorded, replayed);
    return {
      id: session.id,
      frameCount: session.frames.length,
      recorded,
      replayed,
      pass: comparison.pass,
      excludedFromFidelity: legacyException?.excludedFromFidelity ?? false,
      classification: legacyException?.classification ?? (comparison.pass ? 'matched' : 'unclassified-divergence'),
      reason: legacyException?.reason ?? null,
      frameDivergence,
      firstMismatch: firstMismatch
        ? `emission ${firstMismatch.index}: recorded ${JSON.stringify(firstMismatch.recorded)}, simulated ${JSON.stringify(firstMismatch.replayed)}; first divergence at frame ${frameDivergence.frameIndex} / ${frameDivergence.timeSeconds.toFixed(3)} s`
        : null,
      mismatch: comparison,
    };
  });
  const fidelityPassCount = fidelity.filter(item => item.pass).length;
  const fidelityExcludedCount = fidelity.filter(item => item.excludedFromFidelity).length;
  const fidelityUnclassifiedCount = fidelity.filter(item => !item.pass && !item.excludedFromFidelity).length;
  const fidelityPass = fidelityPassCount + fidelityExcludedCount === sessions.length
    && sessions.length === 24;

  const baselineIncident = baselineById.get(INCIDENT_ID);
  const safetySessions = sessions.filter(session => session.id !== INCIDENT_ID);
  const whisperFixturePath = new URL('../fixtures/vad-never-onset/quiet-room-whisper.json', import.meta.url);
  const whisperPayload = JSON.parse(fs.readFileSync(whisperFixturePath, 'utf8'));
  const whisper = expandTraceFixture(whisperPayload, 'synthetic-whisper');
  const baselineWhisper = replaySession(whisper);
  const candidateResults = (fidelityPass ? candidateConfigs(baselineIncident.config) : []).map(config => {
    const incidentReplay = replaySession(incident, config, { compare: false });
    let addedSafetyOnsets = 0;
    let addedSafetyEmissions = 0;
    for (const session of safetySessions) {
      const baseline = baselineById.get(session.id);
      const candidate = replaySession(
        session,
        applySlowOnsetParameters(baseline.config, config),
        { compare: false },
      );
      addedSafetyOnsets += newOnsetCount(baseline, candidate);
      addedSafetyEmissions += newEmissionCount(baseline, candidate);
    }
    const candidateWhisper = replaySession(
      whisper,
      applySlowOnsetParameters(baselineWhisper.config, config),
      { compare: false },
    );
    addedSafetyOnsets += newOnsetCount(baselineWhisper, candidateWhisper);
    addedSafetyEmissions += newEmissionCount(baselineWhisper, candidateWhisper);
    return {
      config,
      recall: hasIncidentRecall(incidentReplay),
      incidentReplay,
      addedSafetyOnsets,
      addedSafetyEmissions,
    };
  });
  const violating = candidateResults.filter(result =>
    result.addedSafetyOnsets > 0 || result.addedSafetyEmissions > 0);
  for (const result of candidateResults) {
    result.margins = findMargins(result.config, violating.map(item => item.config));
    result.passesSafety = result.addedSafetyOnsets === 0 && result.addedSafetyEmissions === 0;
    result.passesMargin = Boolean(result.margins
      && result.margins.deltaDb >= 2
      && result.margins.evidenceMs >= 100);
  }
  const rankedSafe = rankCandidates(candidateResults);
  const winner = rankedSafe.find(result => result.passesMargin) ?? null;
  const nearestSafe = rankedSafe[0] ?? null;
  const margins = winner?.margins ?? nearestSafe?.margins ?? null;
  const marginPass = Boolean(winner);
  const safetyPass = Boolean(nearestSafe);
  const recallPass = candidateResults.some(result => result.recall);
  const recallCandidate = candidateResults.find(result => result.recall);
  const winnerParams = winner ? {
    slowOnsetDeltaDb: winner.config.slowOnsetDeltaDb,
    slowOnsetEvidenceMs: winner.config.slowOnsetEvidenceMs,
    slowOnsetWindowSeconds: winner.config.slowOnsetWindowSeconds,
  } : null;
  const reportedCandidate = winner ?? nearestSafe;
  const winnerMaps = reportedCandidate ? sessions.map(session => {
    const baseline = baselineById.get(session.id);
    const candidate = replaySession(
      session,
      applySlowOnsetParameters(baseline.config, reportedCandidate.config),
      { compare: false },
    );
    return {
      id: session.id,
      baseline: emissionMap(baseline),
      winner: emissionMap(candidate),
      newOnset: hasNewOnset(baseline, candidate),
    };
  }) : [];
  if (reportedCandidate) {
    const candidateWhisper = replaySession(
      whisper,
      applySlowOnsetParameters(baselineWhisper.config, reportedCandidate.config),
      { compare: false },
    );
    winnerMaps.push({
      id: 'synthetic-whisper',
      baseline: emissionMap(baselineWhisper),
      winner: emissionMap(candidateWhisper),
      newOnset: hasNewOnset(baselineWhisper, candidateWhisper),
    });
  }
  const idleGap = idleTriggerSummary(sessions, baselineById);
  const sweep = candidateResults.map(result => ({
    config: {
      slowOnsetDeltaDb: result.config.slowOnsetDeltaDb,
      slowOnsetEvidenceMs: result.config.slowOnsetEvidenceMs,
      slowOnsetWindowSeconds: result.config.slowOnsetWindowSeconds,
    },
    recall: result.recall,
    passesSafety: result.passesSafety,
    passesMargin: result.passesMargin,
    passesAll: result.recall && result.passesSafety && result.passesMargin,
    addedSafetyOnsets: result.addedSafetyOnsets,
    addedSafetyEmissions: result.addedSafetyEmissions,
    margins: result.margins,
  }));
  const frontier = {
    recallPoints: sweep.filter(result => result.recall).map(result => result.config),
    recallAndSafetyPoints: sweep.filter(result => result.recall && result.passesSafety)
      .map(result => ({ ...result.config, margins: result.margins, passesMargin: result.passesMargin })),
    allGatePoints: sweep.filter(result => result.passesAll).map(result => result.config),
  };
  const gates = {
    fidelity: {
      pass: fidelityPass,
      passCount: fidelityPassCount,
      excludedCount: fidelityExcludedCount,
      unclassifiedCount: fidelityUnclassifiedCount,
      sessionCount: sessions.length,
      detail: `${fidelityPassCount}/${sessions.length} matched; ${fidelityExcludedCount} documented version-specific exclusion(s); ${fidelityUnclassifiedCount} unexplained mismatch(es)`,
      exceptions: fidelity.filter(item => item.excludedFromFidelity || !item.pass).map(item => ({
        sessionId: item.id,
        classification: item.classification,
        recordedEmissionMap: item.recorded,
        simulatedEmissionMap: item.replayed,
        firstDivergence: item.frameDivergence,
        reason: item.reason,
      })),
    },
    recall: {
      pass: recallPass,
      detail: recallCandidate
        ? `${candidateLabel(recallCandidate.config)} starts at ${onsetTimes(recallCandidate.incidentReplay).find(time => time >= LOST_WINDOW.start && time <= LOST_WINDOW.end)?.toFixed(3)} s`
        : fidelityPass ? 'no candidate starts inside the lost-sentence window' : 'not tuned because fidelity failed',
    },
    safety: {
      pass: safetyPass,
      detail: nearestSafe
        ? `0 new utterances/emissions across ${safetySessions.length} other sessions and synthetic whisper`
        : 'no recall candidate clears the zero-addition check',
    },
    margin: {
      pass: marginPass,
      detail: margins
        ? `${margins.deltaDb} dB / ${margins.evidenceMs} ms to nearest violating grid point (requires ≥2 dB / ≥100 ms)`
        : 'no recall-and-safety candidate or no violating point',
    },
  };
  const study = {
    generatedAt: 'deterministic-from-inputs',
    corpusPath,
    sessionCount: sessions.length,
    verdict: fidelityPass && recallPass && safetyPass && marginPass ? 'GO' : 'NO-GO',
    gates,
    winner: winner ? { parameters: winnerParams } : null,
    bestSafeParameters: nearestSafe ? {
      slowOnsetDeltaDb: nearestSafe.config.slowOnsetDeltaDb,
      slowOnsetEvidenceMs: nearestSafe.config.slowOnsetEvidenceMs,
      slowOnsetWindowSeconds: nearestSafe.config.slowOnsetWindowSeconds,
    } : null,
    margins,
    fidelity,
    sweep,
    frontier,
    idleGap,
    winnerMaps,
  };
  study.markdown = buildMarkdown(study);
  fs.writeFileSync(outputPath, study.markdown);
  fs.writeFileSync(verdictPath, `${JSON.stringify(machineVerdict(study), null, 2)}\n`);
  return study;
}

function usage() {
  return 'Usage: node scripts/prediction-sim/bin/vad-never-onset-study.mjs [--corpus PATH] [--output PATH] [--verdict PATH]';
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const study = runStudy(options);
  for (const [name, gate] of Object.entries(study.gates)) {
    process.stdout.write(`${gate.pass ? 'PASS' : 'FAIL'} ${name}: ${gate.detail}\n`);
  }
  process.stdout.write(`Study report: ${options.outputPath}\n`);
  process.stdout.write(`Machine verdict: ${options.verdictPath}\n`);
  process.stdout.write(`VERDICT_SUMMARY ${JSON.stringify({
    verdict: study.verdict,
    winner: study.winner,
    margins: study.margins,
    gates: Object.fromEntries(Object.entries(study.gates).map(([name, gate]) => [name, gate.pass])),
    idleGap: {
      triggerCount: study.idleGap.triggerCount,
      sessionsWithTriggers: study.idleGap.sessionsWithTriggers,
      sessions: study.idleGap.sessions,
    },
  })}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`);
    process.exitCode = 1;
  }
}
