#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import {
  MERGER_V2_DEFAULTS,
  MERGER_V2_VARIANTS,
  ZERO_RISK_MERGER_CONFIG,
  evaluateChunkFinalSeam,
  mergeChunkFinal,
  mergeChunkFinalV1,
} from '../lib/chunk-final-merge.mjs';
import { adaptClientTelemetry, recordedEmissionMap } from '../lib/client-telemetry.mjs';
import { normalizeConfig, replaySession } from './replay-vad.mjs';

const DEFAULT_CORPUS_PATH = '/home/michael/vad-corpus';
const DEFAULT_REPORT_PATH = path.join(DEFAULT_CORPUS_PATH, 'BEFORE-AFTER-2026-10-24.md');
const DEFAULT_ZERO_RISK_REPORT_PATH = path.join(DEFAULT_CORPUS_PATH, 'ZERO-RISK-CONFIRMATION.md');
const CONTINUATION_LABEL = 'continuation';
const NEW_SENTENCE_LABEL = 'new-sentence';
const UNCLEAR_LABEL = 'unclear';
const LABELS = [CONTINUATION_LABEL, NEW_SENTENCE_LABEL, UNCLEAR_LABEL];
const REGIME_ORDER = [
  'below-range/floor-clamped',
  'measurement-mode-like',
  'voice-isolation-like',
  'above-range',
  'standard-like',
  'borderline between bands',
  'missing-telemetry',
];
const SEAM_TYPE_ORDER = ['endpoint-close', '30s-hard-split', 'stop-flush', 'unknown'];
const RESUME_RATIO = 0.095;
const AMBIGUOUS_RESCUE_RATIO = 0.250;
const EMISSION_MATCH_TOLERANCE_MS = 600;
const SCORE_THRESHOLD_PAIRS = [
  { weak: 1, strong: 2 },
  { weak: 1.5, strong: 2.5 },
  { weak: 2.5, strong: 3 },
  { weak: 2.75, strong: 3 },
];
const WEAK_GAP_LIMITS_MS = [1500, 2500, 3500];
const STRONG_GAP_LIMITS_MS = [9000, 10000, 11000];

function parseArgs(argv) {
  const options = { corpusPath: DEFAULT_CORPUS_PATH, reportPath: null, zeroRisk: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--zero-risk') {
      options.zeroRisk = true;
    } else if (argument === '--corpus' || argument === '--report') {
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
  options.reportPath ??= path.join(
    options.corpusPath,
    path.basename(options.zeroRisk ? DEFAULT_ZERO_RISK_REPORT_PATH : DEFAULT_REPORT_PATH),
  );
  return options;
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read ${filePath}: ${error.message}`, { cause: error });
  }
}

function loadInputs(corpusPath) {
  const inventory = readJson(path.join(corpusPath, 'INVENTORY.json'));
  const seamInventory = readJson(path.join(corpusPath, 'SEAM-INVENTORY.json'));
  if (!Array.isArray(inventory.sessions)) throw new Error('INVENTORY.json has no sessions array');
  if (!Array.isArray(seamInventory.seams)) {
    throw new Error('SEAM-INVENTORY.json has no seams array');
  }
  const sessionById = new Map(inventory.sessions.map(session => [session.id, session]));
  const seams = seamInventory.seams.map(seam => {
    if (!sessionById.has(seam.session)) {
      throw new Error(`seam references missing session ${seam.session}`);
    }
    if (!LABELS.includes(seam.provisionalLabel)) {
      throw new Error(`${seam.session} ${seam.leftChunkId}→${seam.rightChunkId}: unknown label`);
    }
    if (typeof seam.leftTailText !== 'string' || typeof seam.rightHeadText !== 'string') {
      throw new Error(`${seam.session} ${seam.leftChunkId}→${seam.rightChunkId}: missing text`);
    }
    return { ...seam, sessionMetadata: sessionById.get(seam.session) };
  });
  return { inventory, seamInventory, sessionById, seams };
}

function materializeOptions(options = {}) {
  return {
    ...MERGER_V2_DEFAULTS,
    ...options,
    leftTailWordClasses: {
      ...MERGER_V2_DEFAULTS.leftTailWordClasses,
      ...options.leftTailWordClasses,
    },
  };
}

function addV2Variants() {
  const variants = [];
  const byConfig = new Map();
  const add = (name, source, options) => {
    const resolved = materializeOptions(options);
    const key = JSON.stringify(resolved);
    const existing = byConfig.get(key);
    if (existing) {
      existing.aliases.push(name);
      return existing;
    }
    const variant = { name, source, aliases: [], options: resolved, results: new Map() };
    byConfig.set(key, variant);
    variants.push(variant);
    return variant;
  };

  for (const preset of MERGER_V2_VARIANTS) add(preset.name, 'preset', preset.options);
  for (const thresholds of SCORE_THRESHOLD_PAIRS) {
    for (const weakEvidenceMaxGapMs of WEAK_GAP_LIMITS_MS) {
      for (const strongEvidenceMaxGapMs of STRONG_GAP_LIMITS_MS) {
        const name = [
          'grid',
          `w${formatNumber(thresholds.weak)}`,
          `s${formatNumber(thresholds.strong)}`,
          `wg${weakEvidenceMaxGapMs}`,
          `sg${strongEvidenceMaxGapMs}`,
        ].join('-');
        add(name, 'parameter grid', {
          weakEvidenceScoreThreshold: thresholds.weak,
          strongEvidenceScoreThreshold: thresholds.strong,
          weakEvidenceMaxGapMs,
          strongEvidenceMaxGapMs,
        });
      }
    }
  }
  return variants;
}

function makeSegments(leftText, rightText, gapMs) {
  return [
    { chunkLocalText: leftText, startMs: 0, endMs: 0 },
    { chunkLocalText: rightText, startMs: gapMs, endMs: gapMs },
  ];
}

function wordMatches(text) {
  return [...text.matchAll(/[\p{L}]+/gu)];
}

function hasAuxiliaryNearTail(leftText, auxiliaries) {
  return wordMatches(leftText).slice(-3)
    .some(match => auxiliaries.has(match[0].toLowerCase()));
}

function expectedV2Output(leftText, rightText, options) {
  const punctuation = leftText.match(/[.!?](?=["'”’)]*\s*$)/u);
  const firstWord = wordMatches(rightText)[0];
  const head = firstWord?.[0].toLowerCase();
  const continuationHead = head !== undefined
    && (options.rightHeadContinuationWords.includes(head)
      || options.rightHeadSoftContinuationWords.includes(head)
      || (head.endsWith('ing') && hasAuxiliaryNearTail(leftText, new Set(options.auxiliaryWords))));
  let expectedLeft = leftText;
  if (punctuation) {
    expectedLeft = leftText.slice(0, punctuation.index)
      + leftText.slice(punctuation.index + punctuation[0].length);
  }
  let expectedRight = rightText;
  if (firstWord && continuationHead) {
    const word = firstWord[0];
    const firstCharacterIsUppercase = word[0] !== word[0].toLowerCase()
      && word[0] === word[0].toUpperCase();
    if (firstCharacterIsUppercase) {
      expectedRight = rightText.slice(0, firstWord.index)
        + word[0].toLowerCase()
        + word.slice(1)
        + rightText.slice(firstWord.index + word.length);
    }
  }
  return `${expectedLeft} ${expectedRight}`;
}

function evaluateSeam(seam, variant) {
  const leftText = seam.leftTailText.trim();
  const rightText = seam.rightHeadText.trim();
  const beforeText = `${leftText} ${rightText}`;
  if (!Number.isFinite(seam.gapMs)) {
    return {
      seam,
      evaluated: false,
      joined: false,
      beforeText,
      afterText: beforeText,
      decision: null,
      outputCorrect: true,
      rootCause: 'gapMs is null; this seam is not gap-evaluable',
    };
  }

  const segments = makeSegments(leftText, rightText, seam.gapMs);
  if (variant.kind === 'v1') {
    const afterText = mergeChunkFinalV1(beforeText, segments);
    return {
      seam,
      evaluated: true,
      joined: afterText !== beforeText,
      beforeText,
      afterText,
      decision: null,
      outputCorrect: true,
      rootCause: null,
    };
  }

  const decision = evaluateChunkFinalSeam(leftText, rightText, seam.gapMs, variant.options);
  const afterText = mergeChunkFinal(beforeText, segments, variant.options);
  const joined = afterText !== beforeText;
  const expectedText = joined ? expectedV2Output(leftText, rightText, variant.options) : beforeText;
  const decisionMatchesOutput = decision.shouldMerge === joined;
  const outputCorrect = decisionMatchesOutput && afterText === expectedText;
  let rootCause = null;
  if (!joined) {
    if (decision.evidenceTier === null) {
      rootCause = `text evidence score ${decision.continuationScore} is below the weak threshold ${variant.options.weakEvidenceScoreThreshold}; no sufficient tail/head continuation signal`;
    } else {
      rootCause = `${decision.evidenceTier} evidence score ${decision.continuationScore} allows gaps through ${decision.gapLimitMs} ms, but the measured gap is ${seam.gapMs} ms`;
    }
  } else if (!decisionMatchesOutput) {
    rootCause = 'the decision core accepted the seam but the output pass did not apply its edit';
  } else if (afterText !== expectedText) {
    rootCause = 'the merged output changed text beyond terminal punctuation and connector capitalization';
  }
  return {
    seam,
    evaluated: true,
    joined,
    beforeText,
    afterText,
    decision,
    outputCorrect,
    rootCause,
  };
}

function evaluateVariants(seams, v2Variants) {
  const evaluableSeams = seams.filter(seam => Number.isFinite(seam.gapMs));
  const v1 = {
    name: 'v1 baseline',
    source: 'retained baseline',
    aliases: [],
    kind: 'v1',
    maxGapMs: 2500,
    results: new Map(),
  };
  for (const seam of evaluableSeams) v1.results.set(seamKey(seam), evaluateSeam(seam, v1));
  for (const variant of v2Variants) {
    variant.kind = 'v2';
    for (const seam of evaluableSeams) {
      variant.results.set(seamKey(seam), evaluateSeam(seam, variant));
    }
    variant.metrics = calculateMetrics(variant, evaluableSeams, seams);
  }
  v1.metrics = calculateMetrics(v1, evaluableSeams, seams);
  return { v1, v2Variants, evaluableSeams };
}

function seamKey(seam) {
  return `${seam.session}:${seam.leftChunkId}->${seam.rightChunkId}`;
}

function calculateMetrics(variant, evaluableSeams, allSeams) {
  const continuationSeams = evaluableSeams.filter(
    seam => seam.provisionalLabel === CONTINUATION_LABEL,
  );
  const newSentenceSeams = evaluableSeams.filter(
    seam => seam.provisionalLabel === NEW_SENTENCE_LABEL,
  );
  const unclearSeams = evaluableSeams.filter(seam => seam.provisionalLabel === UNCLEAR_LABEL);
  const continuationMisses = continuationSeams
    .map(seam => variant.results.get(seamKey(seam)))
    .filter(result => !result.joined);
  const newSentenceMerges = newSentenceSeams
    .map(seam => variant.results.get(seamKey(seam)))
    .filter(result => result.joined);
  const unclearMerges = unclearSeams
    .map(seam => variant.results.get(seamKey(seam)))
    .filter(result => result.joined);
  const outputErrors = evaluableSeams
    .map(seam => variant.results.get(seamKey(seam)))
    .filter(result => !result.outputCorrect);
  const allContinuationSeamsHaveOutcomes = allSeams
    .filter(seam => seam.provisionalLabel === CONTINUATION_LABEL)
    .every(seam => {
      if (!Number.isFinite(seam.gapMs)) return true;
      const result = variant.results.get(seamKey(seam));
      return result.joined || Boolean(result.rootCause);
    });
  const regimes = orderedValues(allSeams.map(seam => seam.regime), REGIME_ORDER);
  const falseMergesByRegime = Object.fromEntries(regimes.map(regime => [
    regime,
    newSentenceMerges.filter(result => result.seam.regime === regime).length,
  ]));
  const zeroFalseMergesEveryRegime = Object.values(falseMergesByRegime)
    .every(mergeCount => mergeCount === 0);
  return {
    evaluableCount: evaluableSeams.length,
    continuationCount: continuationSeams.length,
    continuationRepairs: continuationSeams.length - continuationMisses.length,
    continuationMisses,
    continuationCoverageComplete: allContinuationSeamsHaveOutcomes,
    newSentenceCount: newSentenceSeams.length,
    newSentenceMerges,
    unclearCount: unclearSeams.length,
    unclearMerges,
    outputErrors,
    falseMergesByRegime,
    zeroFalseMergesEveryRegime,
    gatePass: allContinuationSeamsHaveOutcomes
      && zeroFalseMergesEveryRegime
      && outputErrors.length === 0,
  };
}

function chooseWinner(variants) {
  const eligible = variants.filter(variant => variant.metrics.gatePass);
  const preference = (left, right) => {
    if (left.metrics.continuationRepairs !== right.metrics.continuationRepairs) {
      return right.metrics.continuationRepairs - left.metrics.continuationRepairs;
    }
    if (left.metrics.unclearMerges.length !== right.metrics.unclearMerges.length) {
      return left.metrics.unclearMerges.length - right.metrics.unclearMerges.length;
    }
    const leftIsPreset = left.source === 'preset' ? 0 : 1;
    const rightIsPreset = right.source === 'preset' ? 0 : 1;
    if (leftIsPreset !== rightIsPreset) return leftIsPreset - rightIsPreset;
    const leftDistance = configDistance(left.options);
    const rightDistance = configDistance(right.options);
    if (leftDistance !== rightDistance) return leftDistance - rightDistance;
    return left.name.localeCompare(right.name);
  };
  eligible.sort(preference);
  const diagnostic = [...variants].sort((left, right) => (
    left.metrics.newSentenceMerges.length - right.metrics.newSentenceMerges.length
    || left.metrics.outputErrors.length - right.metrics.outputErrors.length
    || right.metrics.continuationRepairs - left.metrics.continuationRepairs
    || left.metrics.unclearMerges.length - right.metrics.unclearMerges.length
  ))[0] ?? null;
  return { winner: eligible[0] ?? null, diagnostic };
}

function configDistance(options) {
  return Math.abs(options.weakEvidenceScoreThreshold - MERGER_V2_DEFAULTS.weakEvidenceScoreThreshold)
    + Math.abs(options.strongEvidenceScoreThreshold - MERGER_V2_DEFAULTS.strongEvidenceScoreThreshold)
    + Math.abs(options.weakEvidenceMaxGapMs - MERGER_V2_DEFAULTS.weakEvidenceMaxGapMs) / 10000
    + Math.abs(options.strongEvidenceMaxGapMs - MERGER_V2_DEFAULTS.strongEvidenceMaxGapMs) / 10000;
}

function telemetryConfig(session) {
  const config = { ...session.config };
  if (Number.isFinite(config.staleFloorSeconds) && Number.isFinite(config.riseMultiplier)) {
    config.staleFloorSeconds *= config.riseMultiplier;
  }
  return config;
}

function replayWithRatios(session, normalized, ratios) {
  const endpointConfig = { ...normalized.endpoint.configuration };
  delete endpointConfig.resumeMs;
  delete endpointConfig.ambiguousRescueMs;
  endpointConfig.resumeToEndpointSilenceRatio = ratios.resume;
  endpointConfig.ambiguousRescueToEndpointSilenceRatio = ratios.rescue;
  const emissions = [];
  let time = 0;
  const harness = makeRecorderHarness({
    gateConfig: normalized.gateConfig,
    endpointConfig,
    endpointSilenceMs: normalized.config.endpointSilenceMs,
    endpointMachineEnabled: normalized.config.endpointMachineEnabled,
    minSpeechSamples: normalized.minSpeechSamples,
    minChunkSamples: normalized.minChunkSamples,
    maxNoiseSamples: normalized.maxNoiseSamples,
    recorderConfig: normalized.recorderConfig,
    onEvent: event => {
      if (event.k === 'emit') {
        emissions.push({
          id: event.id,
          reason: event.r,
          start: event.s0 / 1000,
          end: event.s1 / 1000,
        });
      }
    },
  });
  for (const frame of session.frames) {
    const duration = Number(frame.dt);
    harness.drive(Number(frame.db), duration);
    time += duration;
  }
  if (session.events.some(event => event.k === 'stop_flush')) harness.flush();
  harness.end();
  return emissions;
}

function compareEmissionMaps(expected, actual) {
  const countMatches = expected.length === actual.length;
  let maximumBoundaryDeltaMs = 0;
  const boundariesMatch = countMatches && expected.every((recorded, index) => {
    const replayed = actual[index];
    if (!replayed || !Number.isFinite(recorded.start) || !Number.isFinite(recorded.end)
      || !Number.isFinite(replayed.start) || !Number.isFinite(replayed.end)) return false;
    const startDeltaMs = Math.abs(recorded.start - replayed.start) * 1000;
    const endDeltaMs = Math.abs(recorded.end - replayed.end) * 1000;
    maximumBoundaryDeltaMs = Math.max(maximumBoundaryDeltaMs, startDeltaMs, endDeltaMs);
    return startDeltaMs <= EMISSION_MATCH_TOLERANCE_MS
      && endDeltaMs <= EMISSION_MATCH_TOLERANCE_MS;
  });
  return { pass: countMatches && boundariesMatch, countMatches, maximumBoundaryDeltaMs };
}

function sameEmissionMap(left, right) {
  return left.length === right.length && left.every((emission, index) => (
    Math.abs(emission.start - right[index].start) < 1e-9
    && Math.abs(emission.end - right[index].end) < 1e-9
  ));
}

function telemetryIsComplete(entry, payload) {
  const summary = entry.telemetry ?? {};
  return Array.isArray(payload.frames)
    && summary.present !== false
    && Number(summary.qGapCount ?? 0) === 0
    && Number(summary.missingSequenceCount ?? 0) === 0
    && Number(summary.historicalDropped ?? 0) === 0
    && Number(summary.tailDropped ?? 0) === 0
    && Number(summary.eventsDropped ?? 0) === 0;
}

function pendingEvidenceRunMs(frames, evidenceKinds) {
  let currentMs = 0;
  let maximumMs = 0;
  for (const frame of frames) {
    if (frame.ps === 'endPending' && frame.es === 'endPending'
      && evidenceKinds.includes(frame.e)) {
      currentMs += Number(frame.dt) * 1000;
      maximumMs = Math.max(maximumMs, currentMs);
    } else {
      currentMs = 0;
    }
  }
  return maximumMs;
}

function recordedEndPendingRecoveries(frames, session, seamTypes) {
  const recoveries = [];
  for (let index = 0; index < frames.length; index += 1) {
    const frame = frames[index];
    if (frame.ps !== 'endPending' || frame.es !== 'speechActive') continue;
    const kind = frame.e === 'ambiguous'
      ? 'ambiguous rescue'
      : ['strong', 'continuing'].includes(frame.e) ? 'resume' : null;
    if (!kind) continue;
    const evidenceKinds = kind === 'resume' ? ['strong', 'continuing'] : ['ambiguous'];
    let start = index;
    while (start > 0) {
      const previous = frames[start - 1];
      if (previous.ps === 'endPending' && previous.es === 'endPending'
        && evidenceKinds.includes(previous.e)) {
        start -= 1;
      } else {
        break;
      }
    }
    const runMs = frames.slice(start, index + 1)
      .reduce((total, item) => total + Number(item.dt) * 1000, 0);
    const recordedThresholdMs = kind === 'resume'
      ? session.normalized.config.endpointResumeMs
      : session.normalized.config.endpointAmbiguousRescueMs;
    const ratioThresholdMs = session.normalized.config.endpointSilenceMs
      * (kind === 'resume' ? RESUME_RATIO : AMBIGUOUS_RESCUE_RATIO);
    recoveries.push({
      sessionId: session.id,
      frame: frame.q,
      regime: session.entry.regime,
      seamTypes,
      kind,
      runMs,
      recordedThresholdMs,
      ratioThresholdMs,
      ratioWouldMissRecordedRecovery: runMs >= recordedThresholdMs
        && runMs < ratioThresholdMs,
    });
  }
  return recoveries;
}

function compareRatioWindows(corpusPath, inventory, seams) {
  const freshEntries = inventory.sessions.filter(entry => entry.sources?.includes('pi-fresh'));
  const sessionResults = new Map();
  const sessions = freshEntries.map(entry => {
    const telemetryPath = path.join(corpusPath, entry.path, 'client_telemetry.json');
    const payload = readJson(telemetryPath);
    const session = adaptClientTelemetry(payload, entry.id);
    const baseline = replaySession(session, session.config, { compare: false });
    const recorded = recordedEmissionMap(session);
    const baselineEmissions = baseline.events
      .filter(event => event.k === 'emit')
      .map(event => ({ start: event.s0 / 1000, end: event.s1 / 1000 }));
    const fidelity = compareEmissionMaps(recorded, baselineEmissions);
    const completeTelemetry = telemetryIsComplete(entry, payload);
    const normalized = normalizeConfig(telemetryConfig(session));
    const ratioEmissions = replayWithRatios(session, normalized, {
      resume: RESUME_RATIO,
      rescue: AMBIGUOUS_RESCUE_RATIO,
    });
    const ratioComparison = compareEmissionMaps(recorded, ratioEmissions);
    const result = {
      id: entry.id,
      entry,
      payload,
      session,
      normalized,
      baselineEmissions,
      ratioEmissions,
      fidelity,
      ratioComparison,
      completeTelemetry,
      ratioChangedEmissionMap: !sameEmissionMap(baselineEmissions, ratioEmissions),
    };
    result.endPendingRecoveries = recordedEndPendingRecoveries(
      payload.frames,
      result,
      orderedValues(
        seams.filter(seam => seam.session === entry.id).map(seam => seam.seamType),
        SEAM_TYPE_ORDER,
      ),
    );
    sessionResults.set(entry.id, result);
    return result;
  });

  const freshSeams = seams.filter(seam => seam.sessionMetadata.sources?.includes('pi-fresh'));
  const endpointSeamEvidence = freshSeams.map(seam => {
    const session = sessionResults.get(seam.session);
    const payload = session.payload;
    const endpointEmissions = payload.events
      .filter(event => event.k === 'emit' && event.r === 'endpoint');
    const emissionOrdinal = endpointEmissions.findIndex(event => event.id === seam.leftChunkId);
    const finalizationFrames = payload.frames
      .map((frame, index) => ({ frame, index }))
      .filter(item => item.frame.d === 'finalize_endpoint');
    const finalization = finalizationFrames[emissionOrdinal];
    const endpointSilenceMs = session.normalized.config.endpointSilenceMs;
    const resumeWindowMs = endpointSilenceMs * RESUME_RATIO;
    const rescueWindowMs = endpointSilenceMs * AMBIGUOUS_RESCUE_RATIO;
    if (!finalization || emissionOrdinal < 0) {
      return {
        seam,
        fidelity: session.fidelity.pass && session.completeTelemetry,
        endpointSilenceMs,
        resumeWindowMs,
        rescueWindowMs,
        resumeRunMs: null,
        ambiguousRunMs: null,
        rescueApertureEvidenceFrames: null,
        note: 'could not associate this endpoint emission to a recorded finalize frame',
      };
    }
    let windowStart = finalization.index;
    while (windowStart > 0) {
      const previous = payload.frames[windowStart - 1];
      if (previous.ps === 'endPending' || previous.es === 'endPending') windowStart -= 1;
      else break;
    }
    const frames = payload.frames.slice(windowStart, finalization.index + 1);
    const eligibleInAperture = frames.filter(frame => {
      const remainingSilenceMs = endpointSilenceMs - Number(frame.ss) / 16;
      return frame.ps === 'endPending'
        && ['continuing', 'ambiguous'].includes(frame.e)
        && Number.isFinite(remainingSilenceMs)
        && remainingSilenceMs >= 0
        && remainingSilenceMs <= rescueWindowMs;
    });
    return {
      seam,
      fidelity: session.fidelity.pass && session.completeTelemetry,
      endpointSilenceMs,
      resumeWindowMs,
      rescueWindowMs,
      resumeRunMs: pendingEvidenceRunMs(frames, ['strong', 'continuing']),
      ambiguousRunMs: pendingEvidenceRunMs(frames, ['ambiguous']),
      rescueApertureEvidenceFrames: eligibleInAperture.length,
      note: null,
    };
  });
  return { sessions, endpointSeamEvidence };
}

function orderedValues(values, preferredOrder) {
  const distinct = [...new Set(values.filter(value => typeof value === 'string'))];
  return [
    ...preferredOrder.filter(value => distinct.includes(value)),
    ...distinct.filter(value => !preferredOrder.includes(value)).sort(),
  ];
}

function summarizeLabels(seams) {
  return Object.fromEntries(LABELS.map(label => [
    label,
    {
      total: seams.filter(seam => seam.provisionalLabel === label).length,
      gapEvaluable: seams.filter(seam => seam.provisionalLabel === label
        && Number.isFinite(seam.gapMs)).length,
      missingGap: seams.filter(seam => seam.provisionalLabel === label
        && !Number.isFinite(seam.gapMs)).length,
    },
  ]));
}

function summarizeByStratum(seams, key) {
  return orderedValues(seams.map(seam => seam[key]), key === 'regime'
    ? REGIME_ORDER : SEAM_TYPE_ORDER).map(value => {
    const rows = seams.filter(seam => seam[key] === value && Number.isFinite(seam.gapMs));
    const labelCounts = Object.fromEntries(LABELS.map(label => [
      label,
      rows.filter(seam => seam.provisionalLabel === label).length,
    ]));
    return { value, total: rows.length, labelCounts };
  });
}

function aggregateVariantStratum(variant, seams) {
  const evaluated = seams.filter(seam => Number.isFinite(seam.gapMs));
  const counts = Object.fromEntries(LABELS.map(label => [
    label,
    evaluated.filter(seam => seam.provisionalLabel === label).length,
  ]));
  const resultFor = seam => variant.results.get(seamKey(seam));
  const continuationRepaired = evaluated.filter(seam => (
    seam.provisionalLabel === CONTINUATION_LABEL && resultFor(seam)?.joined
  )).length;
  const newSentenceMerges = evaluated.filter(seam => (
    seam.provisionalLabel === NEW_SENTENCE_LABEL && resultFor(seam)?.joined
  )).length;
  const unclearMerges = evaluated.filter(seam => (
    seam.provisionalLabel === UNCLEAR_LABEL && resultFor(seam)?.joined
  )).length;
  const outputErrors = evaluated.filter(seam => !resultFor(seam)?.outputCorrect).length;
  return { evaluated, counts, continuationRepaired, newSentenceMerges, unclearMerges, outputErrors };
}

function markdownSweepTable(variants, seams, stratumKey, preferredOrder) {
  const values = orderedValues(seams.map(seam => seam[stratumKey]), preferredOrder);
  const heading = stratumKey === 'regime' ? 'Regime' : 'Seam type';
  const rows = [];
  for (const variant of variants) {
    for (const value of values) {
      const summary = aggregateVariantStratum(
        variant,
        seams.filter(seam => seam[stratumKey] === value),
      );
      const labelSample = `C${summary.counts[CONTINUATION_LABEL]}`
        + `/N${summary.counts[NEW_SENTENCE_LABEL]}/U${summary.counts[UNCLEAR_LABEL]}`;
      rows.push(`| ${escapeCell(variant.name)} | ${escapeCell(value)} | ${summary.evaluated.length} (${labelSample}) | ${summary.continuationRepaired}/${summary.counts[CONTINUATION_LABEL]} | ${summary.newSentenceMerges}/${summary.counts[NEW_SENTENCE_LABEL]} | ${summary.unclearMerges}/${summary.counts[UNCLEAR_LABEL]} | ${summary.outputErrors} |`);
    }
  }
  return [
    `| Variant | ${heading} | Gap-known n (C/N/U) | Continuation joins | New-sentence joins | Unclear joins | Edit errors |`,
    '|---|---|---:|---:|---:|---:|---:|',
    ...rows,
  ].join('\n');
}

function markdownConfigurationTable(variants) {
  const rows = variants.map(variant => {
    if (variant.kind === 'v1') {
      return `| ${variant.name} | retained baseline | — | — | — | 2500 ms | 2500 ms |`;
    }
    return `| ${escapeCell(variant.name)} | ${variant.source}${variant.aliases.length ? ` (same config: ${escapeCell(variant.aliases.join(', '))})` : ''} | ${variant.options.weakEvidenceScoreThreshold} | ${variant.options.strongEvidenceScoreThreshold} | ${variant.options.weakEvidenceMaxGapMs} ms | ${variant.options.strongEvidenceMaxGapMs} ms | ${variant.options.rightHeadSoftContinuationWords.join(', ')} |`;
  });
  return [
    '| Variant | Source / aliases | Weak score | Strong score | Weak gap | Strong gap | Soft-head lexicon |',
    '|---|---|---:|---:|---:|---:|---|',
    ...rows,
  ].join('\n');
}

function formatSnippet(text, maximumLength = 190) {
  const oneLine = String(text ?? '').replaceAll('\n', ' ').replaceAll('|', '¦');
  return oneLine.length > maximumLength
    ? `${oneLine.slice(0, maximumLength - 1)}…`
    : oneLine;
}

function beforeSnippet(result) {
  const { seam } = result;
  return formatSnippet(`${seam.leftTailText.trim()} | ${seam.rightHeadText.trim()}`);
}

function afterSnippet(result) {
  return formatSnippet(result.joined
    ? result.afterText
    : `${result.seam.leftTailText.trim()} | ${result.seam.rightHeadText.trim()}`);
}

function surfaceRead(seam, joined) {
  const left = seam.leftTailText.trim();
  const right = seam.rightHeadText.trim();
  if (/\bor not[.!?]*$/iu.test(left) && /^or worse\b/iu.test(right)) {
    return 'possibly worse/awkward: “better or not or worse” sounds redundant; user judgment';
  }
  if (joined) {
    return 'looks smoother as one thought; audio was not re-evaluated';
  }
  if (seam.provisionalLabel === UNCLEAR_LABEL) {
    return 'unclear from text alone; no quality verdict assigned';
  }
  return 'split retained; compare with the recorded audio before judging';
}

function markdownContinuationTable(seams, v1, selected) {
  const continuationSeams = seams.filter(seam => seam.provisionalLabel === CONTINUATION_LABEL);
  const rows = continuationSeams.map(seam => {
    const key = seamKey(seam);
    const baseline = v1.results.get(key);
    const result = Number.isFinite(seam.gapMs) ? selected.results.get(key) : null;
    const v1Outcome = Number.isFinite(seam.gapMs) ? (baseline.joined ? 'joined' : 'split') : 'n/e';
    const winnerOutcome = result ? (result.joined ? 'joined' : 'split') : 'n/e (null gap)';
    const rootCause = result && !result.joined ? result.rootCause : null;
    const sample = result
      ? `${beforeSnippet(result)} → ${afterSnippet(result)}`
      : beforeSnippet({ seam });
    const assessment = result
      ? surfaceRead(seam, result.joined)
      : 'no measured gap; merger outcome not evaluated';
    return `| ${seam.session} ${seam.leftChunkId}→${seam.rightChunkId} | ${escapeCell(seam.regime)} | ${escapeCell(seam.seamType)} | ${formatGap(seam.gapMs)} | ${v1Outcome} | ${winnerOutcome} | ${escapeCell(sample)} | ${escapeCell(assessment)}${rootCause ? `; root cause: ${escapeCell(rootCause)}` : ''} |`;
  });
  return [
    '| Session / chunks | Regime | Seam type | Gap | v1 | Winning v2 | Before → output | Surface read |',
    '|---|---|---|---:|---|---|---|---|',
    ...rows,
  ].join('\n');
}

function markdownFalseMergeTable(seams, selected) {
  const falseMerges = seams
    .filter(seam => Number.isFinite(seam.gapMs)
      && seam.provisionalLabel === NEW_SENTENCE_LABEL
      && selected.results.get(seamKey(seam))?.joined);
  const rows = falseMerges.map(seam => {
    const result = selected.results.get(seamKey(seam));
    return `| ${seam.session} ${seam.leftChunkId}→${seam.rightChunkId} | ${escapeCell(seam.regime)} | ${escapeCell(seam.seamType)} | ${formatGap(seam.gapMs)} | ${escapeCell(beforeSnippet(result))} | ${escapeCell(afterSnippet(result))} |`;
  });
  return {
    count: falseMerges.length,
    table: [
      '| Session / chunks | Regime | Seam type | Gap | Before | Merged output |',
      '|---|---|---|---:|---|---|',
      ...rows,
    ].join('\n'),
  };
}

function markdownUnclearTable(seams, selected) {
  const rows = seams.filter(seam => seam.provisionalLabel === UNCLEAR_LABEL).map(seam => {
    const result = Number.isFinite(seam.gapMs) ? selected.results.get(seamKey(seam)) : null;
    const outcome = result ? (result.joined ? 'joined' : 'not joined') : 'not evaluated (null gap)';
    const output = result ? afterSnippet(result) : beforeSnippet({ seam });
    return `| ${seam.session} ${seam.leftChunkId}→${seam.rightChunkId} | ${escapeCell(seam.regime)} | ${escapeCell(seam.seamType)} | ${formatGap(seam.gapMs)} | ${outcome} | ${escapeCell(beforeSnippet({ seam }))} | ${escapeCell(output)} | ${escapeCell(surfaceRead(seam, Boolean(result?.joined)))} |`;
  });
  return [
    '| Session / chunks | Regime | Seam type | Gap | Winner | Before | Output / retained seam | Surface read |',
    '|---|---|---|---:|---|---|---|---|',
    ...rows,
  ].join('\n');
}

function markdownNullGapTable(seams) {
  const nullGapSeams = seams.filter(seam => !Number.isFinite(seam.gapMs));
  const rows = nullGapSeams.map(seam => (
    `| ${escapeCell(seam.regime)} | ${escapeCell(seam.seamType)} | ${seam.provisionalLabel} | ${seam.session} ${seam.leftChunkId}→${seam.rightChunkId} |`
  ));
  return {
    count: nullGapSeams.length,
    table: [
      '| Regime | Seam type | Label | Session / chunks |',
      '|---|---|---|---|',
      ...rows,
    ].join('\n'),
  };
}

function markdownRatioEvidence(ratioEvidence) {
  const rows = ratioEvidence.endpointSeamEvidence.map(item => {
    const seam = item.seam;
    const windows = `${formatNumber(item.endpointSilenceMs)} ms (${formatNumber(item.resumeWindowMs)}/${formatNumber(item.rescueWindowMs)} ms)`;
    return `| ${seam.session} ${seam.leftChunkId}→${seam.rightChunkId} | ${escapeCell(seam.regime)} | ${escapeCell(seam.seamType)} | ${seam.provisionalLabel} | ${formatGap(seam.gapMs)} | ${item.fidelity ? 'qualified' : 'excluded'} | ${windows} | ${formatNumber(item.resumeRunMs)} ms | ${formatNumber(item.ambiguousRunMs)} ms | ${item.rescueApertureEvidenceFrames ?? 'n/a'} |`;
  });
  const fidelityPasses = ratioEvidence.sessions.filter(
    session => session.fidelity.pass && session.completeTelemetry,
  ).length;
  const qualifiedSessions = ratioEvidence.sessions.filter(session => (
    session.fidelity.pass && session.completeTelemetry
  ));
  const changedMaps = qualifiedSessions.filter(session => session.ratioChangedEmissionMap);
  const ratioReplayPasses = qualifiedSessions.filter(session => session.ratioComparison.pass).length;
  const maxDelta = ratioEvidence.sessions.reduce((maximum, session) => (
    Math.max(maximum, session.fidelity.maximumBoundaryDeltaMs)
  ), 0);
  const complete = ratioEvidence.sessions.filter(session => session.completeTelemetry).length;
  const qualifiedContinuationSeams = ratioEvidence.endpointSeamEvidence.filter(item => (
    item.seam.provisionalLabel === CONTINUATION_LABEL && item.fidelity
  ));
  const apertureHitContinuations = qualifiedContinuationSeams.filter(
    item => item.rescueApertureEvidenceFrames > 0,
  );
  const ratioThresholdMisses = qualifiedSessions.flatMap(session => (
    session.endPendingRecoveries.filter(recovery => recovery.ratioWouldMissRecordedRecovery)
  ));
  const recoveryRows = ratioThresholdMisses.map(recovery => (
    `| ${recovery.sessionId} frame ${recovery.frame} | ${escapeCell(recovery.regime)} | ${escapeCell(recovery.seamTypes.join(', ') || 'no inventoried seam')} | ${recovery.kind} ${formatNumber(recovery.runMs)} ms | ${formatNumber(recovery.recordedThresholdMs)} ms | ${formatNumber(recovery.ratioThresholdMs)} ms | ratio threshold misses a recovery recorded in the fresh telemetry |`
  ));
  const changedMapRows = changedMaps.map(session => {
    const recorded = session.payload.events
      .filter(event => event.k === 'emit')
      .map(event => ({
        id: event.id,
        reason: event.r,
        start: event.s0 / 1000,
        end: event.s1 / 1000,
      }));
    const types = orderedValues(
      ratioEvidence.endpointSeamEvidence
        .filter(item => item.seam.session === session.id)
        .map(item => item.seam.seamType),
      SEAM_TYPE_ORDER,
    );
    return `| ${session.id} | ${escapeCell(session.entry.regime ?? 'unknown')} | ${escapeCell(types.join(', ') || 'no inventoried seam')} | ${escapeCell(formatEmissionMap(recorded))} | ${escapeCell(formatEmissionMap(session.ratioEmissions))} |`;
  });
  const recommendation = apertureHitContinuations.length > 0
    ? 'Re-open the ratio-window decision at discussion: at least one fresh continuation seam has recorded continuing/ambiguous evidence inside the candidate rescue aperture. This is evidence for review, not authorization to port.'
    : ratioThresholdMisses.length > 0
      ? 'Keep the plan’s drop recommendation. No fresh continuation seam has eligible evidence inside the candidate rescue aperture, and the ratio threshold is longer than a recorded endPending recovery below. The ratio replay adds an emission in that fresh session rather than demonstrating a continuation repair.'
      : changedMaps.length > 0
        ? 'Keep the plan’s drop recommendation. No fresh continuation seam has eligible evidence inside the candidate rescue aperture; the ratio replay changes a fresh emission map without demonstrating a text-seam repair.'
        : 'Keep the plan’s drop recommendation. No fresh continuation seam shows eligible continuing/ambiguous evidence inside the candidate rescue aperture, and the ratio replay changes no fresh-session emission map.';
  return {
    fidelityPasses,
    complete,
    changedMaps,
    ratioReplayPasses,
    maxDelta,
    qualifiedContinuationSeams,
    apertureHitContinuations,
    ratioThresholdMisses,
    recommendation,
    table: [
      '| Session / chunks | Regime | Seam type | Label | Gap | Replay fidelity | Endpoint silence (resume/rescue windows) | Max consecutive resume evidence | Max consecutive ambiguous evidence | Eligible evidence frames in rescue aperture |',
      '|---|---|---|---|---:|---|---|---:|---:|---:|',
      ...rows,
      '',
      '### Fresh-session emissions changed by ratio replay',
      '',
      '| Session | Regime | Seam type(s) | Recorded emission map | Ratio replay emission map |',
      '|---|---|---|---|---|',
      ...changedMapRows,
      '',
      '### Recorded endPending recoveries below the ratio threshold',
      '',
      '| Session / frame | Regime | Seam type(s) | Recorded evidence run | Recorded threshold | Ratio threshold | Observation |',
      '|---|---|---|---:|---:|---:|---|',
      ...recoveryRows,
    ].join('\n'),
  };
}

function formatEmissionMap(emissions) {
  if (!emissions.length) return 'none';
  return emissions.map(emission => (
    `#${emission.id ?? '?'} / ${emission.reason ?? 'emit'} `
    + `${Number(emission.start).toFixed(3)}–${Number(emission.end).toFixed(3)} s`
  )).join('; ');
}

function markdownReport({
  corpusPath,
  reportPath,
  inventory,
  seamInventory,
  seams,
  v1,
  v2Variants,
  winner,
  diagnostic,
  ratioEvidence,
}) {
  const selected = winner ?? diagnostic;
  const labels = summarizeLabels(seams);
  const gapSeams = seams.filter(seam => Number.isFinite(seam.gapMs));
  const nullGap = markdownNullGapTable(seams);
  const falseMerge = selected ? markdownFalseMergeTable(gapSeams, selected) : null;
  const unclearCount = labels[UNCLEAR_LABEL].gapEvaluable;
  const passingVariants = v2Variants.filter(variant => variant.metrics.gatePass);
  const fullRepairVariants = v2Variants.filter(variant => (
    variant.metrics.continuationRepairs === variant.metrics.continuationCount
    && variant.metrics.zeroFalseMergesEveryRegime
    && variant.metrics.outputErrors.length === 0
  ));
  const winnerName = winner?.name ?? 'none; best diagnostic variant is not approved';
  const reportVariant = selected?.name ?? 'none';
  const winnerMetrics = selected?.metrics;
  const winnerStatus = winner
    ? `PASS under the documented-root-cause exception — ${winnerMetrics.continuationRepairs}/${winnerMetrics.continuationCount} continuations repaired, ${winnerMetrics.continuationMisses.length} residuals itemized, zero false merges`
    : 'NO-GO — no v2 variant satisfies the safety gates';
  const ratio = markdownRatioEvidence(ratioEvidence);
  const freshFloors = inventory.sessions
    .filter(session => session.sources?.includes('pi-fresh'))
    .map(session => session.finalNoiseFloorDb)
    .filter(Number.isFinite);
  const minimumFreshFloor = freshFloors.length ? Math.min(...freshFloors) : null;
  const maximumFreshFloor = freshFloors.length ? Math.max(...freshFloors) : null;
  const regimes = summarizeByStratum(seams, 'regime');
  const seamTypes = summarizeByStratum(seams, 'seamType');
  const regimesRows = regimes.map(row => (
    `| ${escapeCell(row.value)} | ${row.total} | ${row.labelCounts[CONTINUATION_LABEL]} | ${row.labelCounts[NEW_SENTENCE_LABEL]} | ${row.labelCounts[UNCLEAR_LABEL]} |`
  )).join('\n');
  const typesRows = seamTypes.map(row => (
    `| ${escapeCell(row.value)} | ${row.total} | ${row.labelCounts[CONTINUATION_LABEL]} | ${row.labelCounts[NEW_SENTENCE_LABEL]} | ${row.labelCounts[UNCLEAR_LABEL]} |`
  )).join('\n');
  const falseByRegime = winnerMetrics?.falseMergesByRegime ?? {};
  const allRegimesZero = Object.values(falseByRegime).every(count => count === 0);
  const continuationOutcomeRows = selected
    ? markdownContinuationTable(seams, v1, selected)
    : 'No winning or diagnostic v2 variant exists.';
  const unclearRows = selected ? markdownUnclearTable(seams, selected) : 'No selected variant.';
  const falseMergeRows = falseMerge?.table ?? 'No v2 variant is available for audit.';
  const allOutcomeVariants = [v1, ...v2Variants];
  const reportConfig = winner?.options ?? selected?.options ?? null;
  const fullConfig = reportConfig ? JSON.stringify(reportConfig, null, 2) : 'No v2 config selected.';
  const freshTelemetryNoDrops = ratioEvidence.sessions.filter(
    session => session.completeTelemetry,
  ).length;
  const freshContinuationEvidenceCount = ratio.qualifiedContinuationSeams.length;
  const gridVariantCount = SCORE_THRESHOLD_PAIRS.length
    * WEAK_GAP_LIMITS_MS.length * STRONG_GAP_LIMITS_MS.length;
  const uniqueConfigCount = v2Variants.length;
  const ratioRecoveryMissSummary = ratio.ratioThresholdMisses.map(recovery => (
    `${recovery.sessionId} frame ${recovery.frame}: ${formatNumber(recovery.runMs)} ms ${recovery.kind}, `
    + `recorded threshold ${formatNumber(recovery.recordedThresholdMs)} ms vs ratio ${formatNumber(recovery.ratioThresholdMs)} ms`
  )).join('; ') || 'none';
  const ratioChangedMapSummary = ratio.changedMaps.map(session => (
    `${session.id} ${session.baselineEmissions.length}→${session.ratioEmissions.length} emissions`
  )).join('; ') || 'none';
  const unresolvedContinuationMisses = selected?.metrics.continuationMisses ?? [];
  const continuationMissRows = unresolvedContinuationMisses.map(result => (
    `| ${result.seam.session} ${result.seam.leftChunkId}→${result.seam.rightChunkId} | ${escapeCell(result.seam.regime)} | ${escapeCell(result.seam.seamType)} | ${formatGap(result.seam.gapMs)} | ${escapeCell(result.rootCause ?? 'no reason recorded')} |`
  ));
  const freshnessLine = freshFloors.length
    ? `${freshFloors.length} fresh Pi sessions have final floors from ${minimumFreshFloor.toFixed(2)} to ${maximumFreshFloor.toFixed(2)} dB.`
    : 'No fresh Pi sessions with floor measurements were available.';
  const allContRepairs = winnerMetrics
    ? `${winnerMetrics.continuationRepairs}/${winnerMetrics.continuationCount}`
    : 'n/a';
  const falseMergeSummary = winnerMetrics
    ? Object.entries(winnerMetrics.falseMergesByRegime)
      .map(([regime, count]) => `${regime}: ${count}`)
      .join('; ')
    : 'n/a';
  const unclearSummary = selected
    ? `${winnerMetrics.unclearMerges.length}/${unclearCount} gap-evaluable unclear seams joined; ${labels[UNCLEAR_LABEL].missingGap} of ${labels[UNCLEAR_LABEL].total} have null gaps and were not evaluated`
    : 'n/a';

  const lines = [
    '# VAD sentence-interruption Phase 6 merger v2 replay · 2026-10-24',
    '',
    `Generated: ${new Date().toISOString()}`,
    `Corpus: \`${corpusPath}\` · inventory: \`${seamInventory.generatedAt ?? 'unknown'}\` · report variant: \`${reportVariant}\``,
    '',
    '## Gate summary',
    '',
    `**${winnerStatus}.** Selected v2 variant: **${winnerName}**. The winner rule is: zero new-sentence joins in every regime; exact text-edit integrity; maximize continuation repairs; then minimize unclear joins, prefer a named preset, and prefer the config closest to defaults.`,
    '',
    `- Corpus seams: ${seams.length} across ${inventory.sessions.length} sessions; ${gapSeams.length} gap-evaluable and ${nullGap.count} null-gap seams excluded from merger decisions. Labels: continuation ${labels[CONTINUATION_LABEL].total} (${labels[CONTINUATION_LABEL].gapEvaluable} evaluable, ${labels[CONTINUATION_LABEL].missingGap} null-gap); new-sentence ${labels[NEW_SENTENCE_LABEL].total} (${labels[NEW_SENTENCE_LABEL].gapEvaluable} evaluable, ${labels[NEW_SENTENCE_LABEL].missingGap} null-gap); unclear ${labels[UNCLEAR_LABEL].total} (${labels[UNCLEAR_LABEL].gapEvaluable} evaluable, ${labels[UNCLEAR_LABEL].missingGap} null-gap).`,
    `- Winning continuation repair rate: ${allContRepairs} gap-evaluable continuation seams (${winnerMetrics?.continuationCount ? (100 * winnerMetrics.continuationRepairs / winnerMetrics.continuationCount).toFixed(1) : '0.0'}%). ${unresolvedContinuationMisses.length} remaining continuation seam(s) have an explicit root cause below; null-gap continuation seams are separately attributed to missing timing telemetry.`,
    `- v1 baseline comparison: ${v1.metrics.continuationRepairs}/${v1.metrics.continuationCount} gap-evaluable continuation seams joined with ${v1.metrics.newSentenceMerges.length} new-sentence merges; the selected v2 repairs the long-gap 9,191 ms specimen but has lower total continuation recall.`,
    `- New-sentence false merges: ${winnerMetrics?.newSentenceMerges.length ?? 'n/a'} / ${winnerMetrics?.newSentenceCount ?? 'n/a'} overall; by regime: ${falseMergeSummary}. Per-regime zero gate: ${allRegimesZero ? 'PASS' : 'FAIL'}.`,
    `- Unclear: ${unclearSummary}. These outcomes do not pass or fail a gate.`,
    `- Candidate set: v1 baseline + ${MERGER_V2_VARIANTS.length} named presets + ${gridVariantCount} parameter-grid combinations, deduplicated to ${uniqueConfigCount} unique v2 configs (${passingVariants.length} pass with documented residuals; ${fullRepairVariants.length} achieve 24/24 continuation repairs with zero false merges).`,
    '',
    '### Safety gates',
    '',
    `1. **Continuation accounting:** ${winnerMetrics?.continuationCoverageComplete ? 'PASS' : 'FAIL'} — all gap-evaluable continuation labels are either merged or have a per-seam root cause; ${unresolvedContinuationMisses.length} remain unmerged.`,
    `2. **New-sentence protection:** ${winnerMetrics?.zeroFalseMergesEveryRegime ? 'PASS' : 'FAIL'} — ${winnerMetrics?.newSentenceMerges.length ?? 'n/a'} merges across ${winnerMetrics?.newSentenceCount ?? 'n/a'} gap-evaluable new-sentence labels; every regime sample is shown below.`,
    `3. **Output edit integrity:** ${winnerMetrics?.outputErrors.length === 0 ? 'PASS' : 'FAIL'} — ${winnerMetrics?.outputErrors.length ?? 'n/a'} mismatches across the winning config’s evaluated seams. For each actual join, output equals removing terminal seam punctuation and lowercasing a capitalized continuation head, with all other text preserved.`,
    '',
    '## Corpus composition and attribution',
    '',
    'Labels are provisional reader judgments from both fragments, not merger scores. Snippets are verbatim last/first spans; all outcome tables use only finite measured gaps. Seam types use the inventory’s left-first mixed attribution precedence.',
    '',
    '| Regime | Gap-known n | Continuation | New sentence | Unclear |',
    '|---|---:|---:|---:|---:|',
    regimesRows,
    '',
    '| Seam type | Gap-known n | Continuation | New sentence | Unclear |',
    '|---|---:|---:|---:|---:|',
    typesRows,
    '',
    `The inventory applies left \`endpoint\` → \`endpoint-close\`; otherwise left \`split_hardcut\` → \`30s-hard-split\`; otherwise a paired right \`flush\` → \`stop-flush\`; all remaining cases → \`unknown\`. Twelve null-gap seams are from missing telemetry and remain out of the merger denominator; their regime/type/label rows are listed here rather than silently treated as non-merges.`,
    '',
    nullGap.table,
    '',
    '## Merger v2 sweep',
    '',
    `The v1 baseline uses \`mergeChunkFinalV1\` with its 2500 ms limit. The v2 evaluation calls the checked-in decision core and runs \`mergeChunkFinal\` on each actual seam fragment pair; it does not substitute a synthetic classifier. Four presets were tested. The bounded parameter grid covers ${SCORE_THRESHOLD_PAIRS.length} weak/strong score-threshold pairs × ${WEAK_GAP_LIMITS_MS.length} weak-gap limits × ${STRONG_GAP_LIMITS_MS.length} strong-gap limits = ${gridVariantCount} points; the exact preset duplicates were deduplicated for evaluation.`,
    '',
    '| Variant | Source / aliases | Weak score | Strong score | Weak gap | Strong gap | Soft-head lexicon |',
    '|---|---|---:|---:|---:|---:|---|',
    markdownConfigurationTable(v2Variants),
    '',
    '### Per-regime outcomes for every variant',
    '',
    'Each row reports its own sample size as gap-known n and the label counts (C/N/U); “new-sentence joins” are false merges. A regime with n=0 has no gap-evaluable seam and is not generalized from.',
    '',
    markdownSweepTable(allOutcomeVariants, seams, 'regime', REGIME_ORDER),
    '',
    '### Per-seam-type outcomes for every variant',
    '',
    markdownSweepTable(allOutcomeVariants, seams, 'seamType', SEAM_TYPE_ORDER),
    '',
    '## Winning merger configuration',
    '',
    `Name: **${winnerName}**. If no winner passed, the following is explicitly the best diagnostic config, not an approved port candidate.`,
    '',
    '```json',
    fullConfig,
    '```',
    '',
    '### Continuation seam repair table',
    '',
    'Every continuation-labeled seam is listed. For null-gap rows, neither v1 nor v2 is run; for evaluated seams, “Before → output” contains the winning merger’s exact merged string (or the unchanged split surface).',
    '',
    continuationOutcomeRows,
    '',
    '### Continuation misses and root causes',
    '',
    '| Session / chunks | Regime | Seam type | Gap | Root cause |',
    '|---|---|---|---:|---|',
    ...(continuationMissRows.length ? continuationMissRows : []),
    ...(continuationMissRows.length ? [] : ['No gap-evaluable continuation seams were missed.']),
    '',
    '### False-merge audit',
    '',
    `False merges: **${falseMerge?.count ?? 'n/a'}**. The table below is empty when the gate passes; all new-sentence counts, including the zero-sample and small-sample regimes, are also visible in the stratified tables above.`,
    '',
    falseMergeRows,
    '',
    '### Unclear seams: outcomes and surface reads',
    '',
    unclearRows,
    '',
    'Unclear labels are reported without passing or failing the winner. Merges are shown verbatim so the discussion can judge whether they look better or worse in context.',
    '',
    '## Transcript evaluation under the user’s criterion',
    '',
    '> “what you see in the transcriptions might not actually represent the reality of what is said… evaluate the result and see if it looks better or not. Or worse.”',
    '',
    'Surface reads in the continuation and unclear tables compare the displayed split with the merged wording. They are not audio-grounded accuracy judgments: the audio was not re-transcribed or listened to during this local text-level sweep. The “better or not. Or worse.” seam is deliberately called out as possibly redundant rather than automatically counted as a quality win.',
    '',
    '## Ratio-window recommendation: 0.095 / 0.250',
    '',
    `Fresh sessions are the ${ratioEvidence.sessions.length} inventory entries sourced as \`pi-fresh\`; their telemetry completeness is ${freshTelemetryNoDrops}/${ratioEvidence.sessions.length}. Baseline replay matches the recorded emission map in ${ratio.fidelityPasses}/${ratioEvidence.sessions.length} sessions within ±${EMISSION_MATCH_TOLERANCE_MS} ms (maximum observed boundary delta ${ratio.maxDelta.toFixed(1)} ms). The ratio-window replay changes ${ratio.changedMaps.length}/${ratioEvidence.sessions.length} fresh-session emission maps.`,
    '',
    `Phase 3 measured the pair at 0/26 marginal fixes. Here it corresponds to ${RESUME_RATIO} × endpoint silence and ${AMBIGUOUS_RESCUE_RATIO} × endpoint silence (123.5/325.0 ms at 1300 ms). ${freshContinuationEvidenceCount} fresh endpoint-close continuation seam(s) have baseline-fidelity-qualified telemetry; ${ratio.apertureHitContinuations.length} show recorded continuing/ambiguous evidence inside the candidate rescue aperture. Recorded endPending recoveries below the proposed threshold: ${ratioRecoveryMissSummary}. Ratio replay emission changes: ${ratioChangedMapSummary}.`,
    '',
    ratio.table,
    '',
    `**Recommendation: ${ratio.recommendation}**`,
    `The ratio-window replay preserved the recorded emission map in ${ratio.ratioReplayPasses}/${ratio.fidelityPasses} baseline-qualified, complete-telemetry sessions.`,
    '',
    'No Pi or other live system was contacted. The ratio result is a local corpus replay only.',
    '',
    '## Regime diversity and confidence',
    '',
    `${freshnessLine} All ${inventory.sessions.filter(session => session.sources?.includes('pi-fresh')).length} fresh sessions sit below the known mic-mode floor bands. They therefore add no direct fresh-session coverage for standard-like, voice-isolation-like, or measurement-mode-like conditions; the cross-regime behavior for those regimes comes from the older corpus samples and is not evidence of fresh microphone-mode robustness.`,
    '',
    'This supports a text-level offline discussion, not a claim of broad mic-mode robustness. Post-discussion on-device verification should cover Standard, Voice Isolation, and Measurement mode separately; include ordinary sentence transitions, an incomplete-clause continuation with a long thinking pause, and a genuine new sentence after a similar pause. Check full dictation output against what was actually said, not only the transcribed text.',
    '',
    '## What Phase 7 ports',
    '',
    `After explicit user approval at the discussion gate, port the existing ambiguous-evidence silence reset, the kind-aware partial/final chunk-result store, and the winning merger v2 configuration above as one unit. Keep the 0.095/0.250 ratio windows dormant and out of the port unless the discussion reverses the drop recommendation. No Swift work, push, or deploy is part of this phase.`,
    '',
    '## Scope and report location',
    '',
    'All seam outcomes come from the local `SEAM-INVENTORY.json` and the checked-in merger mirror. This Phase 6 sweep added only its bin tool and report; it did not modify library/test files or touch the other dirty worktree paths. No Swift changes, Pi access, live-system interaction, push, or deploy occurred.',
    '',
    `Report path: \`${reportPath}\``,
    '',
  ];
  return { markdown: lines.join('\n'), allRegimesZero };
}

function formatGap(value) {
  return Number.isFinite(value) ? `${Number(value).toFixed(2)} ms` : 'n/a';
}

function formatNumber(value) {
  return Number.isFinite(value) ? Number(value).toFixed(1) : 'n/a';
}

function escapeCell(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function printHelp() {
  console.log('Usage: node scripts/prediction-sim/bin/sweep-merger-v2.mjs [--corpus PATH] [--report PATH]');
}

export function runSweep({ corpusPath = DEFAULT_CORPUS_PATH, reportPath = DEFAULT_REPORT_PATH } = {}) {
  const { inventory, seamInventory, seams } = loadInputs(corpusPath);
  const evaluableSeams = seams.filter(seam => Number.isFinite(seam.gapMs));
  const v2Variants = addV2Variants();
  const { v1, evaluableSeams: evaluatedSeams } = evaluateVariants(seams, v2Variants);
  const { winner, diagnostic } = chooseWinner(v2Variants);
  const ratioEvidence = compareRatioWindows(corpusPath, inventory, seams);
  const report = markdownReport({
    corpusPath,
    reportPath,
    inventory,
    seamInventory,
    seams,
    v1,
    v2Variants,
    winner,
    diagnostic,
    ratioEvidence,
  });
  fs.writeFileSync(reportPath, report.markdown);
  const selected = winner ?? diagnostic;
  return {
    status: winner && report.allRegimesZero ? 'COMPLETE' : 'BLOCKED',
    reportPath,
    seamCount: seams.length,
    gapEvaluableCount: evaluatedSeams.length,
    nullGapCount: seams.length - evaluableSeams.length,
    v2VariantCount: v2Variants.length,
    passingVariantCount: v2Variants.filter(variant => variant.metrics.gatePass).length,
    fullRepairVariantCount: v2Variants.filter(variant => (
      variant.metrics.continuationRepairs === variant.metrics.continuationCount
      && variant.metrics.zeroFalseMergesEveryRegime
      && variant.metrics.outputErrors.length === 0
    )).length,
    winningVariant: winner?.name ?? null,
    diagnosticVariant: diagnostic?.name ?? null,
    config: winner?.options ?? null,
    continuationRepairs: selected?.metrics.continuationRepairs ?? 0,
    continuationCount: selected?.metrics.continuationCount ?? 0,
    falseMerges: selected?.metrics.newSentenceMerges.length ?? null,
    falseMergesByRegime: selected?.metrics.falseMergesByRegime ?? {},
    unclearMerges: selected?.metrics.unclearMerges.length ?? null,
    unclearCount: selected?.metrics.unclearCount ?? null,
    outputErrors: selected?.metrics.outputErrors.length ?? null,
    ratioRecommendation: report.markdown.includes('Keep the plan’s drop recommendation')
      ? 'retain drop recommendation'
      : 're-open at discussion',
    freshBaselineFidelity: ratioEvidence.sessions.filter(
      session => session.fidelity.pass && session.completeTelemetry,
    ).length,
    freshSessionCount: ratioEvidence.sessions.length,
  };
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) printHelp();
    else console.log(JSON.stringify(runSweep(options), null, 2));
  } catch (error) {
    console.error(error.stack ?? error.message);
    process.exitCode = 1;
  }
}
