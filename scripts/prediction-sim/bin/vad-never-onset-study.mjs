#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { adaptClientTelemetry, discoverClientTelemetry, recordedEmissionMap } from '../lib/client-telemetry.mjs';
import { findIdleGapTriggers } from '../lib/vad-idle-gap.mjs';
import { replaySession } from './replay-vad.mjs';

export const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
export const DEFAULT_STUDY_PATH = '/home/michael/vad-corpus/STUDY-2026-10-22-latch.md';
export const DEFAULT_VERDICT_PATH = '/home/michael/vad-corpus/STUDY-2026-10-22-latch.verdict.json';
const TARGET_ID = '20261022-161020';
const TARGET_BASELINE_FIRST_ONSET_SECONDS = 9.983;
// This capture records a sub-minimum tail that the current stop-flush mirror emits.
const KNOWN_LEGACY_FLUSH_SESSION = '20261021-192953';
const LATCH_KNOBS = Object.freeze([
  'latchAmbiguousGraceMs',
  'loudRegimeEnterDb',
  'loudLatchMs',
  'dynamicsWitnessDb',
]);
const CURRENT_LATCH_KNOBS = Object.freeze({
  latchAmbiguousGraceMs: 0,
  loudRegimeEnterDb: -35,
  loudLatchMs: 400,
  dynamicsWitnessDb: 9,
});
const SWEEP = {
  latchAmbiguousGraceMs: [0, 80, 150, 250],
  loudRegimeEnterDb: [-34, -35, -36],
  loudLatchMs: [400, 300, 350],
  dynamicsWitnessDb: [9, 7.5, 8],
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

function firstOnsetTime(replay) {
  return onsetTimes(replay).sort((left, right) => left - right)[0] ?? null;
}

function hasTargetRecall(replay, baselineFirstOnset) {
  if (baselineFirstOnset === null) return false;
  const earlyStarts = onsetTimes(replay).filter(time => time < baselineFirstOnset);
  const emissions = emissionMap(replay);
  return earlyStarts.some(onset => emissions.some(emission => emission.start !== null
    && emission.end !== null
    && emission.start <= onset
    && emission.end >= onset));
}

function candidateConfigs(baselineConfig) {
  const candidates = [];
  for (const latchAmbiguousGraceMs of SWEEP.latchAmbiguousGraceMs) {
    for (const loudRegimeEnterDb of SWEEP.loudRegimeEnterDb) {
      for (const loudLatchMs of SWEEP.loudLatchMs) {
        for (const dynamicsWitnessDb of SWEEP.dynamicsWitnessDb) {
          candidates.push({
            ...baselineConfig,
            slowOnsetEnabled: false,
            latchAmbiguousGraceMs,
            loudRegimeEnterDb,
            loudLatchMs,
            dynamicsWitnessDb,
          });
        }
      }
    }
  }
  return candidates;
}

function candidateLabel(config) {
  return `grace=${config.latchAmbiguousGraceMs}ms/entry=${config.loudRegimeEnterDb}dB/latch=${config.loudLatchMs}ms/witness=${config.dynamicsWitnessDb}dB`;
}

function applyLatchParameters(config, candidate) {
  return {
    ...config,
    slowOnsetEnabled: false,
    ...Object.fromEntries(LATCH_KNOBS.map(key => [key, candidate[key]])),
  };
}

function conservativeDeviation(config) {
  const scale = {
    latchAmbiguousGraceMs: 80,
    loudRegimeEnterDb: 1,
    loudLatchMs: 50,
    dynamicsWitnessDb: 0.5,
  };
  const changes = LATCH_KNOBS.map(key => Math.abs(config[key] - CURRENT_LATCH_KNOBS[key]));
  return {
    changedKnobs: changes.filter(value => value > 0).length,
    normalizedSteps: LATCH_KNOBS.reduce((sum, key) =>
      sum + Math.abs(config[key] - CURRENT_LATCH_KNOBS[key]) / scale[key], 0),
  };
}

function perKnobMargins(candidate, violating) {
  return Object.fromEntries(LATCH_KNOBS.map(key => {
    const neighbors = violating.filter(result => LATCH_KNOBS.every(other =>
      other === key || result.config[other] === candidate.config[other]))
      .sort((left, right) => Math.abs(left.config[key] - candidate.config[key])
        - Math.abs(right.config[key] - candidate.config[key]));
    const nearest = neighbors[0];
    return [key, {
      candidateValue: candidate.config[key],
      nearestViolatingValue: nearest?.config[key] ?? null,
      distance: nearest ? Math.abs(nearest.config[key] - candidate.config[key]) : null,
    }];
  }));
}

function rankCandidates(results) {
  return results.filter(result => result.recall
    && result.addedSafetyOnsets === 0
    && result.addedSafetyEmissions === 0)
    .sort((left, right) => {
      const leftDeviation = conservativeDeviation(left.config);
      const rightDeviation = conservativeDeviation(right.config);
      return leftDeviation.changedKnobs - rightDeviation.changedKnobs
        || leftDeviation.normalizedSteps - rightDeviation.normalizedSteps
        || left.config.latchAmbiguousGraceMs - right.config.latchAmbiguousGraceMs
        || Math.abs(left.config.loudRegimeEnterDb - CURRENT_LATCH_KNOBS.loudRegimeEnterDb)
          - Math.abs(right.config.loudRegimeEnterDb - CURRENT_LATCH_KNOBS.loudRegimeEnterDb)
        || right.config.loudLatchMs - left.config.loudLatchMs
        || right.config.dynamicsWitnessDb - left.config.dynamicsWitnessDb;
    });
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

function readCorpusInventory(corpusPath) {
  const inventoryPath = path.join(corpusPath, 'INVENTORY.json');
  return JSON.parse(fs.readFileSync(inventoryPath, 'utf8'));
}

function recordedOnsetTimes(session) {
  let time = 0;
  const times = [];
  session.recordedFrames.forEach((frame, index) => {
    time += session.frames[index]?.dt ?? 0;
    if (frame.d === 'start_utterance') times.push(time);
  });
  return times;
}

function formatMap(map) {
  if (map.length === 0) return 'none';
  return map.map(item => item.start === null || item.end === null
    ? `duration ${item.duration?.toFixed(3) ?? 'n/a'}s`
    : `${item.start.toFixed(3)}–${item.end.toFixed(3)}s`).join(', ');
}

function buildMarkdown(study) {
  const lines = [
    '# Latch recalibration offline study · 2026-10-22',
    '',
    `Verdict: **${study.verdict}**`,
    '',
    '## Gate summary',
    '',
    '| Gate | Result | Details |',
    '|---|---|---|',
    `| Fidelity | ${study.gates.fidelity.pass ? 'PASS' : 'FAIL'} | ${study.gates.fidelity.passCount}/${study.gates.fidelity.comparedCount} full telemetry replays matched; ${study.gates.fidelity.excludedCount} thinned exclusion(s); ${study.gates.fidelity.skippedCount} missing telemetry session(s); ${study.gates.fidelity.unclassifiedCount} unexplained mismatch(es) |`,
    `| Baseline target | ${study.gates.baselineTarget.pass ? 'PASS' : 'FAIL'} | ${study.gates.baselineTarget.detail} |`,
    `| Latch fidelity anchor | ${study.gates.latchAnchor.pass ? 'PASS' : 'FAIL'} | ${study.gates.latchAnchor.detail} |`,
    `| Target recall | ${study.gates.recall.pass ? 'PASS' : 'FAIL'} | ${study.gates.recall.detail} |`,
    `| Safety | ${study.gates.safety.pass ? 'PASS' : 'FAIL'} | ${study.gates.safety.detail} |`,
    `| Winner/margin | ${study.gates.margin.pass ? 'PASS' : 'FAIL'} | ${study.gates.margin.detail} |`,
    '',
    '## Fidelity by session',
    '',
    '| Session | Frames | Recorded emissions | Replayed emissions | Result | Detail |',
    '|---|---:|---|---|---|---|',
  ];
  for (const item of study.fidelity) {
    const result = item.pass
      ? 'PASS'
      : item.excludedFromFidelity ? 'EXCLUDED' : item.skippedFromFidelity ? 'SKIPPED' : 'FAIL';
    const details = item.firstMismatch ?? item.reason ?? 'none';
    lines.push(`| ${item.id} | ${item.frameCount} | ${formatMap(item.recorded)} | ${formatMap(item.replayed)} | ${result} | ${details} |`);
  }
  lines.push('', '## Mirror latch anchor', '',
    `- Target: ${study.latchAnchor.sessionId}; recorded first onset ${study.latchAnchor.recordedFirstOnsetSeconds?.toFixed(3) ?? 'n/a'} s; baseline mirror first onset ${study.latchAnchor.mirrorFirstOnsetSeconds?.toFixed(3) ?? 'n/a'} s; baseline emissions ${study.latchAnchor.baselineEmissionCount}.`,
    `- Latch promotions in the target session: recorded ${study.latchAnchor.recordedPromotionCount}, mirror ${study.latchAnchor.mirrorPromotionCount}.`,
    `- Across full-history comparable corpus sessions: recorded ll=true ${study.latchAnchor.corpusRecordedPromotionCount}; mirror ll=true ${study.latchAnchor.corpusMirrorPromotionCount}.`,
    `- Corpus exclusions: missing telemetry [${study.missingTelemetryIds.join(', ') || 'none'}]; thinned history [${study.thinnedSessionIds.join(', ') || 'none'}].`,
    '- Ambiguous grace is a per-interruption cap; it requires a floor-converged frame and a dynamics-spread witness within the preceding 500 ms. Accepted grace frames preserve the latch interval and count elapsed time, but do not qualify by themselves as continuing evidence.',
    '- dynamicsWitnessDb sweeps the normal and loud dynamics spread gates; the separate loudLatchWitnessDb remains at its current 3 dB setting.',
    '', '## Sweep frontier', '',
    `- Recall-passing combinations: ${study.frontier.recallPoints.length}.`,
    `- Recall + zero-addition safety combinations: ${study.frontier.recallAndSafetyPoints.length}.`,
    `- Winner combinations (recall + safety): ${study.frontier.winnerPoints.length}.`,
    '', '| Grace ms | Loud entry dB | Loud latch ms | Dynamics witness dB | Recall | Safety | New emissions / utterances | Per-knob margins to nearest violating neighbor |',
    '|---:|---:|---:|---:|---|---|---:|---|');
  for (const result of study.sweep) {
    const margins = LATCH_KNOBS.map(key => `${key}:${result.margins[key].distance ?? 'n/a'}→${result.margins[key].nearestViolatingValue ?? 'none'}`).join(', ');
    lines.push(`| ${result.config.latchAmbiguousGraceMs} | ${result.config.loudRegimeEnterDb} | ${result.config.loudLatchMs} | ${result.config.dynamicsWitnessDb} | ${result.recall ? 'yes' : 'no'} | ${result.passesSafety ? 'yes' : 'no'} | ${result.addedSafetyEmissions} / ${result.addedSafetyOnsets} | ${margins} |`);
  }
  lines.push('', '## Winner and per-knob sensitivity', '');
  if (study.winner) {
    lines.push(`- Winner: ${candidateLabel(study.winner.config)}.`,
      '- Conservative ordering: fewest changed knobs, then smallest normalized grid-step deviation (80 ms grace, 1 dB entry, 50 ms latch, 0.5 dB witness per step).');
  } else lines.push(`- No winner. Verdict: ${study.verdict}.`);
  if (study.sensitivityAnchor) {
    lines.push(`- One-knob sensitivity around ${candidateLabel(study.sensitivityAnchor.config)}:`);
    for (const knob of LATCH_KNOBS) {
      const values = study.sensitivity[knob].map(point =>
        `${point.value}: recall=${point.recall}, safety=${point.passesSafety}, added=${point.addedSafetyEmissions}/${point.addedSafetyOnsets}`);
      lines.push(`  - ${knob}: ${values.join('; ')}`);
    }
  }
  lines.push('', '## Idle-gap trigger scan', '',
    `- Baseline: ${study.idleGap.baseline.triggerCount} triggers across ${study.idleGap.baseline.sessionsWithTriggers}/${study.idleGap.baseline.sessions} eligible telemetry sessions.`,
    study.idleGap.underWinner
      ? `- Under winner: ${study.idleGap.underWinner.triggerCount} triggers across ${study.idleGap.underWinner.sessionsWithTriggers}/${study.idleGap.underWinner.sessions} sessions (${study.idleGap.change} change).`
      : '- No winner; the baseline idle-gap scan is shown for reference.',
    '- Trigger scan decision rule remains continuous ≥300 ms at floor+6 dB in the final 10 s of an idle stretch.',
    '', `## Baseline-vs-${study.winner ? 'winner' : 'reference candidate'} emission maps`, '',
    '| Session | Baseline map | Candidate map | New onset |',
    '|---|---|---|---|');
  for (const item of study.winnerMaps) {
    lines.push(`| ${item.id} | ${formatMap(item.baseline)} | ${formatMap(item.winner)} | ${item.newOnset ? 'yes' : 'no'} |`);
  }
  lines.push('', '## Interpretation', '',
    '- Replay decisions use telemetry frame `db` and `dt`; recorded output fields are used only for fidelity/anchor comparisons.',
    '- Two no-telemetry sessions are skipped. The thinned 20261021-231954 history is excluded rather than interpolating missing levels, because inventing db values could change latch decisions.',
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
        baselineTriggerCount: study.idleGap.baseline.triggerCount,
        baselineSessionsWithTriggers: study.idleGap.baseline.sessionsWithTriggers,
        sessions: study.idleGap.baseline.sessions,
        winnerTriggerCount: study.idleGap.underWinner?.triggerCount ?? null,
      },
    },
    details: {
      bestSafeParameters: study.bestSafeParameters,
      frontier: study.frontier,
      gates: study.gates,
      fidelity: study.fidelity,
      latchAnchor: study.latchAnchor,
      sensitivityAnchor: study.sensitivityAnchor,
      sensitivity: study.sensitivity,
      missingTelemetryIds: study.missingTelemetryIds,
      thinnedSessionIds: study.thinnedSessionIds,
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
  const inventory = readCorpusInventory(corpusPath);
  const corpusSessions = inventory.sessions;
  const allSessions = discoverClientTelemetry(corpusPath);
  const missingTelemetryIds = inventory.totals.telemetryMissing ?? [];
  const thinnedWarnings = inventory.totals.telemetryRetentionWarnings ?? [];
  const thinnedIds = new Set(thinnedWarnings.map(item => item.id));
  const thinnedSessions = allSessions.filter(session => thinnedIds.has(session.id));
  const sessions = allSessions.filter(session => !thinnedIds.has(session.id));
  const targetSession = sessions.find(session => session.id === TARGET_ID);
  if (!targetSession) throw new Error(`required target session ${TARGET_ID} not found in ${corpusPath}`);

  const baselineById = new Map();
  const fidelity = sessions.map(session => {
    const baselineConfig = session.id === TARGET_ID
      ? { ...session.config, loudRegimeEnterDb: -34 }
      : session.config;
    const replay = replaySession(session, baselineConfig);
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
  for (const session of thinnedSessions) {
    const warning = thinnedWarnings.find(item => item.id === session.id);
    fidelity.push({
      id: session.id,
      frameCount: session.frames.length,
      recorded: recordedEmissionMap(session),
      replayed: [],
      pass: false,
      excludedFromFidelity: true,
      classification: 'thinned-history-excluded',
      reason: `telemetry retained ${warning?.retainedFrames ?? session.frames.length} frames of ${warning?.summaryFrameCount ?? 'unknown'}; dropped historical frames make db/dt replay incomplete, so inserted frames were not fabricated`,
      frameDivergence: null,
      firstMismatch: null,
      mismatch: null,
    });
  }
  for (const id of missingTelemetryIds) {
    fidelity.push({
      id,
      frameCount: 0,
      recorded: [],
      replayed: [],
      pass: false,
      excludedFromFidelity: false,
      skippedFromFidelity: true,
      classification: 'missing-telemetry-skipped',
      reason: 'client_telemetry.json absent in rebuilt 40-session corpus',
      frameDivergence: null,
      firstMismatch: null,
      mismatch: null,
    });
  }
  fidelity.sort((left, right) => left.id.localeCompare(right.id));
  const fidelityPassCount = fidelity.filter(item => item.pass).length;
  const fidelityExcludedCount = fidelity.filter(item => item.excludedFromFidelity).length;
  const fidelitySkippedCount = fidelity.filter(item => item.skippedFromFidelity).length;
  const fidelityUnclassifiedCount = fidelity.filter(item => !item.pass
    && !item.excludedFromFidelity
    && !item.skippedFromFidelity).length;
  const expectedTelemetryCount = corpusSessions.length - missingTelemetryIds.length;
  const fidelityPass = corpusSessions.length === 40
    && allSessions.length === expectedTelemetryCount
    && fidelityPassCount + fidelityExcludedCount + fidelitySkippedCount === corpusSessions.length
    && fidelityUnclassifiedCount === 0;

  const baselineTarget = baselineById.get(TARGET_ID);
  const baselineOnsets = baselineTarget ? onsetTimes(baselineTarget) : [];
  const baselineFirstOnset = baselineOnsets[0] ?? null;
  const recordedTargetOnsets = recordedOnsetTimes(targetSession);
  const baselineTargetEmissions = baselineTarget ? emissionMap(baselineTarget) : [];
  const targetBaselinePass = baselineFirstOnset !== null
    && baselineFirstOnset >= TARGET_BASELINE_FIRST_ONSET_SECONDS
    && Math.abs(baselineFirstOnset - TARGET_BASELINE_FIRST_ONSET_SECONDS) <= 0.15
    && recordedTargetOnsets.length === 2
    && baselineOnsets.length === 2
    && Math.abs(recordedTargetOnsets[0] - TARGET_BASELINE_FIRST_ONSET_SECONDS) <= 0.15
    && baselineTargetEmissions.length === 2;
  const recordedLatchPromotions = targetSession.recordedFrames.filter(frame => frame.ll === true).length;
  const mirrorLatchPromotions = baselineTarget?.frames.filter(frame => frame.ll === true).length ?? 0;
  const corpusRecordedLatchPromotions = sessions.reduce((total, session) =>
    total + session.recordedFrames.filter(frame => frame.ll === true).length, 0);
  const corpusMirrorLatchPromotions = sessions.reduce((total, session) =>
    total + baselineById.get(session.id).frames.filter(frame => frame.ll === true).length, 0);
  const latchAnchorPass = recordedLatchPromotions === 0
    && mirrorLatchPromotions === 0;
  const safetySessions = sessions.filter(session => session.id !== TARGET_ID);
  const whisperFixturePath = new URL('../fixtures/vad-never-onset/quiet-room-whisper.json', import.meta.url);
  const whisperPayload = JSON.parse(fs.readFileSync(whisperFixturePath, 'utf8'));
  const whisper = expandTraceFixture(whisperPayload, 'synthetic-whisper');
  const baselineWhisper = replaySession(whisper);
  const tuningReady = fidelityPass && targetBaselinePass && latchAnchorPass;
  const candidateResults = (tuningReady ? candidateConfigs(baselineTarget.config) : []).map(config => {
    const targetReplay = replaySession(targetSession, config, { compare: false });
    let addedSafetyOnsets = 0;
    let addedSafetyEmissions = 0;
    for (const session of safetySessions) {
      const baseline = baselineById.get(session.id);
      const candidate = replaySession(
        session,
        applyLatchParameters(baseline.config, config),
        { compare: false },
      );
      addedSafetyOnsets += newOnsetCount(baseline, candidate);
      addedSafetyEmissions += newEmissionCount(baseline, candidate);
    }
    const candidateWhisper = replaySession(
      whisper,
      applyLatchParameters(baselineWhisper.config, config),
      { compare: false },
    );
    addedSafetyOnsets += newOnsetCount(baselineWhisper, candidateWhisper);
    addedSafetyEmissions += newEmissionCount(baselineWhisper, candidateWhisper);
    return {
      config,
      recall: hasTargetRecall(targetReplay, baselineFirstOnset),
      targetReplay,
      latchPromotionBeforeBaselineOnset: targetReplay.frames.some(frame =>
        frame.time < TARGET_BASELINE_FIRST_ONSET_SECONDS && frame.ll),
      addedSafetyOnsets,
      addedSafetyEmissions,
    };
  });
  for (const result of candidateResults) {
    result.passesSafety = result.addedSafetyOnsets === 0 && result.addedSafetyEmissions === 0;
  }
  const violating = candidateResults.filter(result => !result.passesSafety);
  for (const result of candidateResults) result.margins = perKnobMargins(result, violating);
  const rankedSafe = rankCandidates(candidateResults);
  const winner = rankedSafe[0] ?? null;
  const nearestSafe = rankedSafe[0] ?? null;
  const margins = winner?.margins ?? nearestSafe?.margins ?? null;
  const marginPass = Boolean(winner);
  const safetyPass = Boolean(nearestSafe);
  const recallPass = candidateResults.some(result => result.recall);
  const recallCandidate = candidateResults.filter(result => result.recall)
    .sort((left, right) => {
      const leftDeviation = conservativeDeviation(left.config);
      const rightDeviation = conservativeDeviation(right.config);
      return leftDeviation.changedKnobs - rightDeviation.changedKnobs
        || leftDeviation.normalizedSteps - rightDeviation.normalizedSteps;
    })[0] ?? null;
  const sensitivityAnchor = winner ?? recallCandidate;
  const reportedCandidate = winner ?? nearestSafe ?? recallCandidate;
  const winnerMaps = reportedCandidate ? sessions.map(session => {
    const baseline = baselineById.get(session.id);
    const candidate = replaySession(
      session,
      applyLatchParameters(baseline.config, reportedCandidate.config),
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
      applyLatchParameters(baselineWhisper.config, reportedCandidate.config),
      { compare: false },
    );
    winnerMaps.push({
      id: 'synthetic-whisper',
      baseline: emissionMap(baselineWhisper),
      winner: emissionMap(candidateWhisper),
      newOnset: hasNewOnset(baselineWhisper, candidateWhisper),
    });
  }
  const sensitivity = Object.fromEntries(LATCH_KNOBS.map(knob => {
    const points = sensitivityAnchor
      ? candidateResults.filter(result => LATCH_KNOBS.every(other => other === knob
        || result.config[other] === sensitivityAnchor.config[other]))
        .sort((left, right) => left.config[knob] - right.config[knob])
        .map(result => ({
          value: result.config[knob],
          recall: result.recall,
          passesSafety: result.passesSafety,
          addedSafetyEmissions: result.addedSafetyEmissions,
          addedSafetyOnsets: result.addedSafetyOnsets,
          latchPromotionBeforeBaselineOnset: result.latchPromotionBeforeBaselineOnset,
          margin: result.margins[knob],
        }))
      : [];
    return [knob, points];
  }));
  const idleGapBaseline = idleTriggerSummary(sessions, baselineById);
  let idleGapWinner = null;
  let idleGapReference = null;
  if (reportedCandidate) {
    const candidateById = new Map(sessions.map(session => {
      const baseline = baselineById.get(session.id);
      const replay = replaySession(
        session,
        applyLatchParameters(baseline.config, reportedCandidate.config),
        { compare: false },
      );
      return [session.id, replay];
    }));
    const idleSummary = idleTriggerSummary(sessions, candidateById);
    if (winner) idleGapWinner = idleSummary;
    else idleGapReference = idleSummary;
  }
  const idleGap = {
    baseline: idleGapBaseline,
    underWinner: idleGapWinner,
    underReference: idleGapReference,
    change: idleGapWinner
      ? idleGapWinner.triggerCount - idleGapBaseline.triggerCount
      : null,
  };
  const sweep = candidateResults.map(result => ({
    config: {
      latchAmbiguousGraceMs: result.config.latchAmbiguousGraceMs,
      loudRegimeEnterDb: result.config.loudRegimeEnterDb,
      loudLatchMs: result.config.loudLatchMs,
      dynamicsWitnessDb: result.config.dynamicsWitnessDb,
    },
    recall: result.recall,
    passesSafety: result.passesSafety,
    passesAll: result.recall && result.passesSafety,
    addedSafetyOnsets: result.addedSafetyOnsets,
    addedSafetyEmissions: result.addedSafetyEmissions,
    margins: result.margins,
  }));
  const frontier = {
    recallPoints: sweep.filter(result => result.recall).map(result => result.config),
    recallAndSafetyPoints: sweep.filter(result => result.recall && result.passesSafety)
      .map(result => ({ ...result.config, margins: result.margins })),
    winnerPoints: sweep.filter(result => result.passesAll).map(result => result.config),
  };
  const latchAnchor = {
    sessionId: TARGET_ID,
    pass: latchAnchorPass,
    recordedFirstOnsetSeconds: recordedTargetOnsets[0] ?? null,
    mirrorFirstOnsetSeconds: baselineFirstOnset,
    baselineEmissionCount: baselineTargetEmissions.length,
    recordedPromotionCount: recordedLatchPromotions,
    mirrorPromotionCount: mirrorLatchPromotions,
    corpusRecordedPromotionCount: corpusRecordedLatchPromotions,
    corpusMirrorPromotionCount: corpusMirrorLatchPromotions,
  };
  const gates = {
    fidelity: {
      pass: fidelityPass,
      passCount: fidelityPassCount,
      excludedCount: fidelityExcludedCount,
      skippedCount: fidelitySkippedCount,
      unclassifiedCount: fidelityUnclassifiedCount,
      sessionCount: corpusSessions.length,
      comparedCount: sessions.length,
      detail: `${fidelityPassCount}/${sessions.length} full telemetry replays matched; ${fidelityExcludedCount} thinned/version-specific exclusion(s); ${fidelitySkippedCount} no-telemetry skip(s); ${fidelityUnclassifiedCount} unexplained mismatch(es)`,
      exceptions: fidelity.filter(item => item.excludedFromFidelity || item.skippedFromFidelity || !item.pass).map(item => ({
        sessionId: item.id,
        classification: item.classification,
        recordedEmissionMap: item.recorded,
        simulatedEmissionMap: item.replayed,
        firstDivergence: item.frameDivergence,
        reason: item.reason,
      })),
    },
    baselineTarget: {
      pass: targetBaselinePass,
      detail: `first simulated onset ${baselineFirstOnset?.toFixed(3) ?? 'none'} s (must match ${TARGET_BASELINE_FIRST_ONSET_SECONDS.toFixed(3)} s baseline); ${baselineTargetEmissions.length} simulated emissions (expected 2)`,
    },
    latchAnchor: {
      pass: latchAnchorPass,
      detail: `recorded ll=true frames ${recordedLatchPromotions}; mirror ll=true frames ${mirrorLatchPromotions}; expected both zero`,
    },
    recall: {
      pass: recallPass,
      detail: recallCandidate
        ? `${candidateLabel(recallCandidate.config)} starts at ${firstOnsetTime(recallCandidate.targetReplay)?.toFixed(3)} s, before ${TARGET_BASELINE_FIRST_ONSET_SECONDS.toFixed(3)} s`
        : tuningReady ? `no candidate starts before ${TARGET_BASELINE_FIRST_ONSET_SECONDS.toFixed(3)} s` : 'not tuned because a fidelity/baseline/latch-anchor gate failed',
    },
    safety: {
      pass: safetyPass,
      detail: nearestSafe
        ? `0 new utterances/emissions across ${safetySessions.length} other sessions and synthetic whisper`
        : 'no recall candidate clears the zero-addition check',
    },
    margin: {
      pass: marginPass,
      detail: winner
        ? `per-knob margins reported against nearest one-knob safety-violating neighbors`
        : 'no combination passes target recall and zero-addition safety',
    },
  };
  const study = {
    generatedAt: 'deterministic-from-inputs',
    corpusPath,
    sessionCount: corpusSessions.length,
    telemetrySessionCount: allSessions.length,
    missingTelemetryIds,
    thinnedSessionIds: [...thinnedIds],
    verdict: fidelityPass && targetBaselinePass && latchAnchorPass
      && recallPass && safetyPass && marginPass ? 'GO' : 'NO-GO',
    gates,
    latchAnchor,
    winner: winner ? {
      parameters: Object.fromEntries(LATCH_KNOBS.map(key => [key, winner.config[key]])),
      config: Object.fromEntries(LATCH_KNOBS.map(key => [key, winner.config[key]])),
    } : null,
    bestSafeParameters: nearestSafe
      ? Object.fromEntries(LATCH_KNOBS.map(key => [key, nearestSafe.config[key]]))
      : null,
    sensitivity,
    sensitivityAnchor: sensitivityAnchor ? {
      config: Object.fromEntries(LATCH_KNOBS.map(key => [key, sensitivityAnchor.config[key]])),
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
      baselineTriggerCount: study.idleGap.baseline.triggerCount,
      baselineSessionsWithTriggers: study.idleGap.baseline.sessionsWithTriggers,
      sessions: study.idleGap.baseline.sessions,
      winnerTriggerCount: study.idleGap.underWinner?.triggerCount ?? null,
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
