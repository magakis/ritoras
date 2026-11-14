#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadVadFixtures } from '../lib/vad-fixtures.mjs';
import {
  decodeWav,
  parseSession,
  replaySession,
  selectSample,
  SHIPPING_SESSION_CONFIG,
} from './replay-vad.mjs';

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const TELEMETRY_SESSION_PATH = path.resolve(
  SCRIPT_DIRECTORY,
  '../fixtures/vad-telemetry/20261024-124619/session.jsonl',
);
const TELEMETRY_SESSION_ID = '20261024-124619';
const TIER_0_CASE_ID = '20261027-000217-shed';
const EXPECTED_FIXTURE_COUNT = 12;
const SAMPLE_RATE = 16_000;
// Keep gap classification aligned with recorder-sim's retained-gap evidence threshold.
const GAP_SPEECH_PEAK_ABOVE_FLOOR_DB = 6;
const GAP_EVIDENCE_RULE_NOTE = [
  'Gap evidence follows the recorder rule: sp, sh, strong/continuing evidence, or db - fl >= 6 dB.',
  'speechShaped may conservatively over-fire on near-silent/tonal controls; this validates',
  'filter retention against that rule, not detector threshold tuning.',
].join(' ');
const PRE_ROLL_VALUES_MS = [0, 100, 200, 300, 500, 900, 1000];
const DEFAULT_PRE_ROLL_MS = 500;
const CORE_INTERVAL_PATTERN = /Core interval \[(\d+),(\d+)\) samples/i;

function parseArgs(argv) {
  const options = {
    sample: null,
    seed: 1,
    onlyFixtures: false,
    stopOnFirstFail: false,
    jsonPath: null,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--sample' || argument === '--seed' || argument === '--json') {
      const value = argv[++index];
      if (!value || value.startsWith('--')) throw new Error(`${argument} requires a value`);
      if (argument === '--json') {
        options.jsonPath = path.resolve(value);
      } else {
        const number = Number(value);
        if (!Number.isSafeInteger(number) || (argument === '--sample' && number < 0)) {
          const requirement = argument === '--sample' ? 'a non-negative integer' : 'an integer';
          throw new Error(`${argument} requires ${requirement}`);
        }
        options[argument === '--sample' ? 'sample' : 'seed'] = number;
      }
    } else if (argument === '--only-fixtures') {
      options.onlyFixtures = true;
    } else if (argument === '--stop-on-first-fail') {
      options.stopOnFirstFail = true;
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }

  if (options.sample !== null && !options.onlyFixtures) {
    throw new Error('--sample requires --only-fixtures');
  }
  return options;
}

function usage() {
  return [
    'Usage: node bin/validate-vad-silence-filtering.mjs [options]',
    '',
    '  --sample N --seed S       Select N fixtures reproducibly (seed defaults to 1)',
    '  --only-fixtures           Skip the checked-in telemetry session replay',
    '  --stop-on-first-fail      Stop after the first failed criterion',
    '  --json out.json           Write machine-readable validation results',
    '  --help                    Show this help',
    '',
    'Default: Tier 0 plus all 12 fixtures and the telemetry session, with filtering',
    'ON/OFF replays and an ON pre-roll sweep at 0, 100, 200, 300, 500, 900, and 1000 ms.',
    'The Tier 0 shed fixture is always replayed, even when --sample selects other fixtures.',
  ].join('\n');
}

function normalizeSpans(spans) {
  const sorted = spans
    .filter(span => Number.isInteger(span.start) && Number.isInteger(span.end)
      && span.end > span.start)
    .map(span => ({ start: span.start, end: span.end }))
    .sort((left, right) => left.start - right.start || left.end - right.end);
  const merged = [];
  for (const span of sorted) {
    const previous = merged.at(-1);
    if (previous && span.start <= previous.end) {
      previous.end = Math.max(previous.end, span.end);
    } else {
      merged.push(span);
    }
  }
  return merged;
}

function subtractSpans(spans, excludedSpans) {
  const excluded = normalizeSpans(excludedSpans);
  const remaining = [];
  for (const span of normalizeSpans(spans)) {
    let cursor = span.start;
    for (const excludedSpan of excluded) {
      if (excludedSpan.end <= cursor) continue;
      if (excludedSpan.start >= span.end) break;
      if (excludedSpan.start > cursor) {
        remaining.push({ start: cursor, end: Math.min(excludedSpan.start, span.end) });
      }
      cursor = Math.max(cursor, excludedSpan.end);
      if (cursor >= span.end) break;
    }
    if (cursor < span.end) remaining.push({ start: cursor, end: span.end });
  }
  return remaining;
}

function intersectSpans(spans, otherSpans) {
  const left = normalizeSpans(spans);
  const right = normalizeSpans(otherSpans);
  const intersections = [];
  for (const span of left) {
    for (const other of right) {
      if (other.end <= span.start) continue;
      if (other.start >= span.end) break;
      const start = Math.max(span.start, other.start);
      const end = Math.min(span.end, other.end);
      if (end > start) intersections.push({ start, end });
    }
  }
  return normalizeSpans(intersections);
}

function frameSpans(replay, predicate = () => true) {
  return normalizeSpans(replay.frames
    .filter(predicate)
    .map(frame => ({ start: frame.sourceStartSample, end: frame.sourceEndSample })));
}

function isSpeechEvidenceFrame(frame) {
  return frame.sp === true
    || frame.sh === true
    || frame.e === 'strong'
    || frame.e === 'continuing'
    || (Number.isFinite(frame.db) && Number.isFinite(frame.fl)
      && frame.db - frame.fl >= GAP_SPEECH_PEAK_ABOVE_FLOOR_DB);
}

function maximumPeakAboveFloorDb(replay, span) {
  return replay.frames.reduce((maximum, frame) => {
    if (!Number.isFinite(frame.sourceStartSample)
      || !Number.isFinite(frame.sourceEndSample)
      || frame.sourceStartSample >= span.end
      || frame.sourceEndSample <= span.start
      || !Number.isFinite(frame.db)
      || !Number.isFinite(frame.fl)) {
      return maximum;
    }
    return Math.max(maximum, frame.db - frame.fl);
  }, Number.NEGATIVE_INFINITY);
}

function speechEvidenceSpans(replay, span, { aggregateTailFallback = false } = {}) {
  const evidenceSpans = intersectSpans(
    frameSpans(replay, isSpeechEvidenceFrame),
    [span],
  );
  // The recorder can keep a whole buffered tail from aggregate peak evidence alone.
  if (aggregateTailFallback
    && evidenceSpans.length === 0
    && maximumPeakAboveFloorDb(replay, span) >= GAP_SPEECH_PEAK_ABOVE_FLOOR_DB) {
    return [span];
  }
  return evidenceSpans;
}

function emittedSpans(replay) {
  const emissions = replay.events.filter(event => event.k === 'emit');
  const invalid = emissions.filter(event => !Number.isInteger(event.sourceStartSample)
    || !Number.isInteger(event.sourceEndSample)
    || event.sourceEndSample <= event.sourceStartSample);
  if (invalid.length > 0) {
    throw new Error(`${invalid.length} emission(s) lack valid source sample spans`);
  }
  return normalizeSpans(emissions.map(event => ({
    start: event.sourceStartSample,
    end: event.sourceEndSample,
  })));
}

function emissionSpanMismatches(replay, targetSpans) {
  const targets = normalizeSpans(targetSpans);
  // Preserve this cross-check as diagnostic context; sample coverage is graded separately.
  return replay.events
    .filter(event => event.k === 'emit'
      && event.sourceStartSample < event.sourceEndSample
      && Number.isInteger(event.sourceStartSample)
      && Number.isInteger(event.sourceEndSample)
      && event.sourceEndSample - event.sourceStartSample !== event.n
      && targets.some(span => event.sourceStartSample < span.end
        && event.sourceEndSample > span.start))
    .map(event => ({
      sourceStartSample: event.sourceStartSample,
      sourceEndSample: event.sourceEndSample,
      sampleCount: event.n,
    }));
}

function measureCoverage(spans, replay) {
  const emissions = emittedSpans(replay);
  const cores = spans
    .filter(span => Number.isInteger(span.start) && Number.isInteger(span.end)
      && span.end > span.start)
    .map((span, index) => ({
      id: span.id ?? `core-${index + 1}`,
      start: span.start,
      end: span.end,
    }));
  const coreResults = cores.map(core => {
    const missingSpans = subtractSpans([core], emissions);
    const sourceSpanMismatches = emissionSpanMismatches(replay, [core]);
    const totalSamples = core.end - core.start;
    const missingSamples = missingSpans.reduce(
      (sum, span) => sum + span.end - span.start,
      0,
    );
    const contiguityNotes = sourceSpanMismatches.length > 0
      ? [
        `${sourceSpanMismatches.length} emission span(s) are non-contiguous by sample count; `
          + 'bounding ranges may contain internally discarded samples',
      ]
      : [];
    return {
      ...core,
      pass: missingSamples === 0,
      totalSamples,
      coveredSamples: totalSamples - missingSamples,
      missingSamples,
      missingSpans,
      sourceSpanMismatches,
      contiguityNotes,
    };
  });
  const totalSamples = coreResults.reduce((sum, core) => sum + core.totalSamples, 0);
  const missingSamples = coreResults.reduce((sum, core) => sum + core.missingSamples, 0);
  const missing = coreResults.flatMap(core => core.missingSpans);
  const contiguityNotes = coreResults.flatMap(core => core.contiguityNotes);
  return {
    pass: coreResults.every(core => core.pass),
    totalSamples,
    coveredSamples: totalSamples - missingSamples,
    missingSamples,
    missingSpans: missing,
    contiguityNotes,
    cores: coreResults,
  };
}

function fixtureCoreSpan(fixture) {
  // Fixture evidence records the core bounds; use those captured intervals as the oracle.
  const evidence = fixture.metadata.evidence.find(item => CORE_INTERVAL_PATTERN.test(item));
  const match = evidence?.match(CORE_INTERVAL_PATTERN);
  if (!match) throw new Error(`${fixture.caseId} metadata has no parseable core interval`);
  return { start: Number(match[1]), end: Number(match[2]) };
}

function fixtureHasSpeechEvidence(replay, core) {
  return speechEvidenceSpans(replay, core, { aggregateTailFallback: true }).length > 0;
}

function telemetrySpeechCores(offReplay) {
  // The OFF replay is the telemetry oracle where no separate labeled core interval exists.
  const speechFrames = frameSpans(offReplay, isSpeechEvidenceFrame);
  return intersectSpans(speechFrames, emittedSpans(offReplay))
    .map((span, index) => ({ id: `baseline-speech-${index + 1}`, ...span }));
}

function startFrames(replay) {
  return replay.frames
    .filter(frame => frame.d === 'start_utterance')
    .sort((left, right) => (
      (left.sourceEndSample ?? Number.POSITIVE_INFINITY)
      - (right.sourceEndSample ?? Number.POSITIVE_INFINITY)
    ));
}

function hasValidSourceBounds(frame) {
  return Number.isInteger(frame.sourceStartSample)
    && Number.isInteger(frame.sourceEndSample)
    && frame.sourceEndSample > frame.sourceStartSample;
}

function aggregatePeakRetainedTail(replay, close) {
  const tail = {
    start: close.event.sourceEndSample,
    end: close.frame.sourceEndSample,
  };
  if (tail.end <= tail.start) return [];

  // Recorder aggregation spans the trailing run, but can retain only its trimmed tail.
  const trailingSilenceSamples = Number.isInteger(close.frame.ts)
    ? close.frame.ts
    : Number.isFinite(close.event.physicalTrailingSilenceMs)
      ? Math.round(close.event.physicalTrailingSilenceMs * (SAMPLE_RATE / 1000))
      : null;
  if (trailingSilenceSamples === null || trailingSilenceSamples < tail.end - tail.start) {
    return null;
  }

  const trailingSilence = {
    start: Math.max(
      close.event.sourceStartSample,
      close.frame.sourceEndSample - trailingSilenceSamples,
    ),
    end: close.frame.sourceEndSample,
  };
  return maximumPeakAboveFloorDb(replay, trailingSilence) >= GAP_SPEECH_PEAK_ABOVE_FLOOR_DB
    ? [tail]
    : [];
}

function deriveGapOnlySpans(replay, preRollMs) {
  const gaps = [];
  const onsets = startFrames(replay);
  if (onsets.some(onset => !hasValidSourceBounds(onset))) {
    return {
      spans: [],
      derivable: false,
      intervalCount: 0,
      detail: 'one or more start_utterance decisions lack valid source sample bounds',
    };
  }

  if (onsets.length === 0) {
    return {
      spans: [],
      derivable: true,
      intervalCount: 0,
      detail: 'replay contains no start_utterance decisions for an inter-chunk interval',
    };
  }

  const closeDecisionFrames = replay.frames
    .filter(frame => frame.d === 'finalize_endpoint' || frame.d === 'finalize_pause')
    .sort((left, right) => (
      (left.sourceEndSample ?? Number.POSITIVE_INFINITY)
      - (right.sourceEndSample ?? Number.POSITIVE_INFINITY)
    ));
  const allCloseEvents = replay.events
    .filter(event => event.k === 'emit'
      && (event.r === 'endpoint' || event.r === 'pause'));
  if (allCloseEvents.some(event => !hasValidSourceBounds(event))) {
    return {
      spans: [],
      derivable: false,
      intervalCount: 0,
      detail: 'one or more emitted chunk closes lack valid source sample bounds',
    };
  }
  const closeEvents = allCloseEvents
    .filter(event => onsets.some(onset => onset.sourceEndSample > event.sourceEndSample))
    .sort((left, right) => left.sourceEndSample - right.sourceEndSample);

  if (closeEvents.length > 0
    && closeDecisionFrames.some(frame => !hasValidSourceBounds(frame))) {
    return {
      spans: [],
      derivable: false,
      intervalCount: 0,
      detail: 'an emitted chunk close or finalize decision lacks valid source sample bounds',
    };
  }

  const matchedCloses = [];
  let lastMatchedFrameIndex = -1;
  for (const event of closeEvents) {
    const matchingFrameIndex = closeDecisionFrames.findIndex((frame, index) => (
      index > lastMatchedFrameIndex
      && frame.d === `finalize_${event.r}`
      && frame.sourceEndSample >= event.sourceEndSample
    ));
    if (matchingFrameIndex === -1) {
      return {
        spans: [],
        derivable: false,
        intervalCount: 0,
        detail: `emission ending at ${event.sourceEndSample} has no matching `
          + `finalize_${event.r} frame decision`,
      };
    }
    matchedCloses.push({
      event,
      frame: closeDecisionFrames[matchingFrameIndex],
    });
    lastMatchedFrameIndex = matchingFrameIndex;
  }

  const closeWithoutFollowingOnset = matchedCloses.find(close => {
    const nextOnset = onsets.find(onset => (
      onset.sourceEndSample > close.event.sourceEndSample
    ));
    return nextOnset && nextOnset.sourceEndSample < close.frame.sourceEndSample;
  });
  if (closeWithoutFollowingOnset) {
    return {
      spans: [],
      derivable: false,
      intervalCount: 0,
      detail: `finalize decision for emission ending at `
        + `${closeWithoutFollowingOnset.event.sourceEndSample} occurs after its next onset`,
    };
  }

  const offEmissions = emittedSpans(replay);
  const speechEvidence = frameSpans(replay, isSpeechEvidenceFrame);
  const preRollSamples = preRollMs * (SAMPLE_RATE / 1000);
  let previousOnsetSample = Number.NEGATIVE_INFINITY;
  let intervalCount = 0;
  const addGap = (span, onsetSample, source) => {
    gaps.push({
      id: `${source}-${gaps.length + 1}`,
      ...span,
      onsetSample,
      source,
    });
  };

  for (const onset of onsets) {
    const precedingCloses = matchedCloses.filter(close => (
      close.frame.sourceEndSample > previousOnsetSample
      && close.frame.sourceEndSample <= onset.sourceEndSample
    ));
    if (precedingCloses.length > 1) {
      const previousOnset = Number.isFinite(previousOnsetSample)
        ? previousOnsetSample
        : 'clip start';
      return {
        spans: [],
        derivable: false,
        intervalCount: 0,
        detail: `multiple emitted chunk closes occur between onset decisions at `
          + `${previousOnset} and ${onset.sourceEndSample}`,
      };
    }
    previousOnsetSample = onset.sourceEndSample;
    if (precedingCloses.length === 0) continue;

    const close = precedingCloses[0];
    const interval = {
      // Intra-chunk pauses and configured post-roll remain inside the preceding emission.
      start: close.event.sourceEndSample,
      // start_utterance is recorded on the onset frame; its end is the pre-roll seam.
      end: onset.sourceEndSample,
    };
    if (interval.end < interval.start) {
      return {
        spans: [],
        derivable: false,
        intervalCount: 0,
        detail: `next onset at ${interval.end} precedes chunk close at ${interval.start}`,
      };
    }
    if (interval.end === interval.start) continue;
    intervalCount += 1;

    const preRoll = {
      start: Math.max(interval.start, interval.end - preRollSamples),
      end: interval.end,
    };
    const aggregatePeakTail = aggregatePeakRetainedTail(replay, close);
    if (aggregatePeakTail === null) {
      return {
        spans: [],
        derivable: false,
        intervalCount: 0,
        detail: `aggregate trailing-silence bounds are unavailable for close at `
          + `${close.event.sourceEndSample}`,
      };
    }
    const excludedSpans = [
      ...intersectSpans(speechEvidence, [interval]),
      ...aggregatePeakTail,
      preRoll,
    ];
    const gapOnlySpans = subtractSpans([interval], excludedSpans);
    for (const gapOnlySpan of intersectSpans(gapOnlySpans, offEmissions)) {
      addGap(gapOnlySpan, interval.end, 'inter-chunk-gap');
    }
  }

  return {
    spans: gaps,
    derivable: true,
    intervalCount,
    detail: intervalCount === 0
      ? 'replay contains no emitted close-to-next-onset intervals'
      : `${intervalCount} emitted close-to-next-onset interval(s) derived`,
  };
}

function checkGapAbsence(gaps, onReplay, preRollMs) {
  const preRollSamples = preRollMs * (SAMPLE_RATE / 1000);
  const gapChecks = gaps.map(gap => {
    const allowedPreRoll = Number.isInteger(gap.onsetSample)
      ? [{
        start: Math.max(gap.start, gap.onsetSample - preRollSamples),
        end: Math.min(gap.end, gap.onsetSample),
      }]
      : [];
    // The trailing pre-roll is intentionally retained; all other gap-only samples are not.
    const disallowed = subtractSpans([gap], allowedPreRoll);
    return {
      id: gap.id,
      span: { start: gap.start, end: gap.end },
      allowedPreRoll,
      disallowedSpans: disallowed,
    };
  });
  const disallowedSpans = normalizeSpans(gapChecks.flatMap(check => check.disallowedSpans));
  const emissionAccounting = disallowedSpans.length === 0
    ? []
    : onReplay.events
      .filter(event => event.k === 'emit'
        && Number.isInteger(event.sourceStartSample)
        && Number.isInteger(event.sourceEndSample)
        && event.sourceEndSample > event.sourceStartSample)
      .map(event => {
        const eventRange = {
          start: event.sourceStartSample,
          end: event.sourceEndSample,
        };
        const forbidden = intersectSpans(disallowedSpans, [eventRange]);
        const forbiddenSamples = forbidden.reduce(
          (sum, span) => sum + span.end - span.start,
          0,
        );
        const rangeSamples = eventRange.end - eventRange.start;
        const emittedSamples = Number.isInteger(event.n) ? event.n : null;
        // Event ranges are bounds; subtract forbidden gaps before comparing sample counts.
        const allowedCapacity = rangeSamples - forbiddenSamples;
        const excessSamples = emittedSamples === null
          ? null
          : Math.max(0, emittedSamples - allowedCapacity);
        return {
          eventId: event.id,
          eventRange,
          emittedSamples,
          forbiddenSamples,
          allowedCapacity,
          excessSamples,
          forbiddenSpans: forbidden,
        };
      })
      .filter(accounting => accounting.forbiddenSpans.length > 0);
  const checks = gapChecks.map(check => {
    const affectedEmissions = emissionAccounting
      .filter(accounting => accounting.forbiddenSpans.some(span => (
        span.start < check.span.end && span.end > check.span.start
      )));
    const leaked = affectedEmissions.filter(accounting => accounting.excessSamples === null
      || accounting.excessSamples > 0);
    const disallowed = check.disallowedSpans;
    const unrepresentableEmissions = emissionSpanMismatches(onReplay, disallowed);
    const leakedSpans = leaked.flatMap(accounting => (
      intersectSpans(accounting.forbiddenSpans, [check.span])
    ));
    const contiguityNotes = unrepresentableEmissions.length > 0
      ? [
        `${unrepresentableEmissions.length} overlapping emission span(s) have internal `
          + 'discards; sample-count accounting determines whether gap audio leaked',
      ]
      : [];
    return {
      id: check.id,
      span: check.span,
      allowedPreRoll: check.allowedPreRoll,
      leakedSpans,
      unrepresentableEmissions,
      sampleAccounting: affectedEmissions.map(({
        eventId,
        eventRange,
        emittedSamples,
        forbiddenSamples,
        allowedCapacity,
        excessSamples,
      }) => ({
        eventId,
        eventRange,
        emittedSamples,
        forbiddenSamples,
        allowedCapacity,
        excessSamples,
      })),
      contiguityNotes,
      pass: leaked.length === 0,
    };
  });
  return {
    pass: checks.every(check => check.pass),
    checkedSpanCount: checks.length,
    leakedSpanCount: checks.filter(check => !check.pass).length,
    contiguityNotes: checks.flatMap(check => check.contiguityNotes),
    emissionAccounting,
    checks,
  };
}

function fixtureReplayConfig(baseConfig, warmup) {
  const config = { ...baseConfig };
  if (!warmup) return config;

  // Match replay-vad's fixture-mode warmup overrides so these runs remain comparable.
  for (const [configKey, warmupKey] of [
    ['absoluteSpeechFloorDb', 'absolute_speech_floor_db'],
    ['minSpeechMs', 'min_speech_ms'],
    ['minChunkMs', 'min_chunk_ms'],
    ['analysisHpfEnabled', 'analysis_hpf_enabled'],
    ['analysisHpfCutoffHz', 'analysis_hpf_cutoff_hz'],
  ]) {
    if (warmup[warmupKey] !== undefined) config[configKey] = warmup[warmupKey];
  }
  config.endpointSilenceMs = warmup.endpoint_silence_ms;
  config.silenceMs = warmup.endpoint_silence_ms;
  return config;
}

function decodeFixtureWav(fixture) {
  const wav = decodeWav(fs.readFileSync(fixture.wavPath));
  if (wav.audioFormat !== 1 || wav.bitsPerSample !== 16
    || wav.channels !== 1 || wav.sampleRate !== SAMPLE_RATE) {
    throw new Error(`${fixture.caseId} WAV must be 16 kHz mono PCM16`);
  }
  return wav;
}

function replayFixture(fixture, wav, filteringEnabled, preRollMs) {
  const config = fixtureReplayConfig({
    ...SHIPPING_SESSION_CONFIG,
    vadSilenceFilteringEnabled: filteringEnabled,
    vadSilenceFilteringPreRollMs: preRollMs,
  }, fixture.metadata.warmup);
  const session = {
    frames: [],
    events: [],
    config,
    configIsTelemetry: false,
  };
  const replay = replaySession(session, config, {
    fromWav: wav,
    sourceSampleOffset: fixture.metadata.source_start_sample,
    warmup: fixture.metadata.warmup ?? null,
    compare: false,
  });
  return requireReplay(replay, fixture.caseId);
}

function telemetryConfigFromRecorded(session, filteringEnabled, preRollMs) {
  const recorded = session.config;
  const config = recorded && Number.isFinite(recorded.staleFloorSeconds)
    && Number.isFinite(recorded.riseMultiplier)
    ? { ...recorded, staleFloorSeconds: recorded.staleFloorSeconds * recorded.riseMultiplier }
    : { ...recorded };
  return {
    ...config,
    vadSilenceFilteringEnabled: filteringEnabled,
    vadSilenceFilteringPreRollMs: preRollMs,
  };
}

function replayTelemetry(session, filteringEnabled, preRollMs) {
  const config = telemetryConfigFromRecorded(session, filteringEnabled, preRollMs);
  return requireReplay(replaySession(session, config, { compare: false }), 'telemetry');
}

function requireReplay(replay, caseId) {
  if (replay.status === 'unsupported_skipped') {
    throw new Error(`${caseId} replay was skipped: ${replay.reason}`);
  }
  if (!Array.isArray(replay.frames) || !Array.isArray(replay.events)) {
    throw new Error(`${caseId} replay returned no frame/event timeline`);
  }
  return replay;
}

function replaySummary(replay, coreSpans) {
  const emitted = emittedSpans(replay);
  return {
    frameCount: replay.frames.length,
    emittedChunkCount: replay.events.filter(event => event.k === 'emit').length,
    utteranceCount: replay.metrics?.utteranceCount ?? null,
    emittedSpans: emitted,
    coverage: measureCoverage(coreSpans, replay),
  };
}

function makeCaseReport(entry) {
  return {
    id: entry.id,
    type: entry.type,
    kind: entry.kind,
    speechCoreSpans: [],
    gapOnlySpans: [],
    runs: {},
  };
}

function formatCoverage(coverage) {
  const contiguityDetail = coverage.contiguityNotes.length > 0
    ? `; informational: ${coverage.contiguityNotes.join('; ')}`
    : '';
  return `${coverage.coveredSamples}/${coverage.totalSamples} samples covered${contiguityDetail}`;
}

function coverageFailureDetail(mode, coverage) {
  const contiguityDetail = coverage.contiguityNotes.length > 0
    ? `; informational: ${coverage.contiguityNotes.join('; ')}`
    : '';
  return `${mode}: ${coverage.missingSamples} core samples missing${contiguityDetail}`;
}

function initializeCriterionCaseResults(criterion, entries, {
  telemetryIncluded,
  telemetryNotIncludedDetail,
}) {
  criterion.caseResults = entries.map(entry => ({
    id: entry.id,
    type: entry.type,
    included: true,
    status: 'NOT RUN',
    detail: 'criterion case has not run yet',
  }));
  if (!telemetryIncluded) {
    criterion.caseResults.push({
      id: TELEMETRY_SESSION_ID,
      type: 'telemetry',
      included: false,
      status: 'NOT INCLUDED',
      detail: telemetryNotIncludedDetail,
    });
  }
}

function setCriterionCaseResult(criterion, result) {
  const existingIndex = criterion.caseResults.findIndex(item => item.id === result.id);
  if (existingIndex === -1) {
    criterion.caseResults.push(result);
  } else {
    criterion.caseResults[existingIndex] = result;
  }
}

function printCriteria(criteria) {
  console.log('Criterion summary:');
  for (const criterion of criteria) {
    const detail = criterion.detail ? ` — ${criterion.detail}` : '';
    console.log(`${criterion.status.padEnd(7)} ${criterion.name}${detail}`);
    const telemetryResult = criterion.caseResults?.find(
      result => result.id === TELEMETRY_SESSION_ID,
    );
    if (telemetryResult) {
      const inclusion = telemetryResult.included ? 'included' : 'not included';
      console.log(
        `        Telemetry ${TELEMETRY_SESSION_ID}: ${telemetryResult.status} (${inclusion})`,
      );
    }
  }
}

function writeReport(report, jsonPath) {
  if (!jsonPath) return;
  fs.mkdirSync(path.dirname(jsonPath), { recursive: true });
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`JSON results: ${jsonPath}`);
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    console.log(usage());
    return;
  }

  const fixtures = loadVadFixtures();
  const tier1Fixtures = selectSample(fixtures, options.sample, options.seed);
  const tier0Fixture = fixtures.find(fixture => fixture.caseId === TIER_0_CASE_ID) ?? null;
  const tier1Entries = tier1Fixtures.map(fixture => ({
    id: fixture.caseId,
    type: 'fixture',
    kind: fixture.metadata.kind,
    fixture,
  }));
  const tier0Entry = tier0Fixture ? {
    id: tier0Fixture.caseId,
    type: 'fixture',
    kind: tier0Fixture.metadata.kind,
    fixture: tier0Fixture,
  } : null;

  let telemetrySession = null;
  let telemetryEntry = null;
  if (!options.onlyFixtures) {
    telemetrySession = parseSession(fs.readFileSync(TELEMETRY_SESSION_PATH, 'utf8'));
    if (telemetrySession.frames.length === 0) {
      throw new Error(`telemetry session has no frames: ${TELEMETRY_SESSION_PATH}`);
    }
    telemetryEntry = {
      id: TELEMETRY_SESSION_ID,
      type: 'telemetry',
      kind: 'recorded-session',
      session: telemetrySession,
    };
  }
  const tier1EntriesWithTelemetry = [
    ...tier1Entries,
    ...(telemetryEntry ? [telemetryEntry] : []),
  ];
  const sweepEntries = [
    ...(tier0Entry && !tier1Fixtures.some(fixture => fixture.caseId === TIER_0_CASE_ID)
      ? [tier0Entry]
      : []),
    ...tier1Entries,
    ...(telemetryEntry ? [telemetryEntry] : []),
  ];

  const report = {
    generatedAt: new Date().toISOString(),
    options: {
      sample: options.sample,
      seed: options.seed,
      onlyFixtures: options.onlyFixtures,
      stopOnFirstFail: options.stopOnFirstFail,
    },
    fixtureCount: fixtures.length,
    tier1CaseIds: tier1Entries.map(entry => entry.id),
    telemetrySession: telemetryEntry?.id ?? null,
    gapEvidenceRule: GAP_EVIDENCE_RULE_NOTE,
    tier0: null,
    cases: [],
    preRollSweep: [],
    criteria: [
      {
        id: 'tier0',
        name: 'Tier 0 shed fixture has full speech-core coverage at 500 ms',
        status: 'NOT RUN',
        caseResults: [],
      },
      {
        id: 'tier1-coverage',
        name: 'Tier 1 speech cores are covered with filtering OFF and ON',
        status: 'NOT RUN',
        caseResults: [],
      },
      {
        id: 'tier1-gap-removal',
        name: 'Tier 1 gap-only spans are absent with filtering ON',
        status: 'NOT RUN',
        caseResults: [],
      },
      {
        id: 'sweep-baseline',
        name: '500 ms speech coverage is no worse than filtering OFF',
        status: 'NOT RUN',
        caseResults: [],
      },
    ],
  };
  const tier0CriterionEntries = tier0Entry
    ? [tier0Entry]
    : [{ id: TIER_0_CASE_ID, type: 'fixture' }];
  initializeCriterionCaseResults(report.criteria[0], tier0CriterionEntries, {
    telemetryIncluded: false,
    telemetryNotIncludedDetail: 'Tier 0 checks only the shed fixture.',
  });
  for (const criterion of report.criteria.slice(1, 3)) {
    initializeCriterionCaseResults(criterion, tier1EntriesWithTelemetry, {
      telemetryIncluded: Boolean(telemetryEntry),
      telemetryNotIncludedDetail: 'Skipped by --only-fixtures.',
    });
  }
  initializeCriterionCaseResults(report.criteria[3], sweepEntries, {
    telemetryIncluded: Boolean(telemetryEntry),
    telemetryNotIncludedDetail: 'Skipped by --only-fixtures.',
  });
  const reportByCase = new Map();
  const wavByCase = new Map();
  const replayCache = new Map();
  const getCaseReport = entry => {
    if (!reportByCase.has(entry.id)) {
      const caseReport = makeCaseReport(entry);
      reportByCase.set(entry.id, caseReport);
      report.cases.push(caseReport);
    }
    return reportByCase.get(entry.id);
  };
  const getReplay = (entry, filteringEnabled, preRollMs) => {
    const key = `${entry.id}:${filteringEnabled}:${preRollMs}`;
    if (replayCache.has(key)) {
      const cached = replayCache.get(key);
      if (cached.error) throw new Error(cached.error);
      return cached.replay;
    }
    try {
      let replay;
      if (entry.type === 'fixture') {
        if (!wavByCase.has(entry.id)) wavByCase.set(entry.id, decodeFixtureWav(entry.fixture));
        replay = replayFixture(
          entry.fixture,
          wavByCase.get(entry.id),
          filteringEnabled,
          preRollMs,
        );
      } else {
        replay = replayTelemetry(entry.session, filteringEnabled, preRollMs);
      }
      replayCache.set(key, { replay });
      return replay;
    } catch (error) {
      const mode = filteringEnabled ? 'ON' : 'OFF';
      const message = `${entry.id} ${mode} ${preRollMs} ms: ${error.message}`;
      replayCache.set(key, { error: message });
      throw new Error(message, { cause: error });
    }
  };

  console.log(`INFO    ${GAP_EVIDENCE_RULE_NOTE}`);

  let tier0Failed = false;
  if (!tier0Entry) {
    tier0Failed = true;
    report.tier0 = { error: `required fixture ${TIER_0_CASE_ID} is missing` };
    setCriterionCaseResult(report.criteria[0], {
      id: TIER_0_CASE_ID,
      type: 'fixture',
      included: true,
      status: 'FAIL',
      detail: report.tier0.error,
    });
  } else {
    try {
      const offReplay = getReplay(tier0Entry, false, DEFAULT_PRE_ROLL_MS);
      const onReplay = getReplay(tier0Entry, true, DEFAULT_PRE_ROLL_MS);
      const core = fixtureCoreSpan(tier0Fixture);
      if (!fixtureHasSpeechEvidence(offReplay, core)) {
        throw new Error('the metadata core has no speech-evidence frames in the OFF replay');
      }
      const coverage = measureCoverage([core], onReplay);
      report.tier0 = {
        coreSpan: core,
        off: replaySummary(offReplay, [core]),
        on: replaySummary(onReplay, [core]),
      };
      tier0Failed = !coverage.pass;
      report.criteria[0] = {
        ...report.criteria[0],
        status: tier0Failed ? 'FAIL' : 'PASS',
        detail: formatCoverage(coverage),
      };
      setCriterionCaseResult(report.criteria[0], {
        id: tier0Entry.id,
        type: tier0Entry.type,
        included: true,
        status: tier0Failed ? 'FAIL' : 'PASS',
        detail: formatCoverage(coverage),
      });
      const caseReport = getCaseReport(tier0Entry);
      caseReport.speechCoreSpans = [{ id: 'metadata-core', ...core }];
      caseReport.runs.off = report.tier0.off;
      caseReport.runs.on500 = report.tier0.on;
    } catch (error) {
      tier0Failed = true;
      report.tier0 = { error: error.message };
      report.criteria[0] = { ...report.criteria[0], status: 'FAIL', detail: error.message };
      setCriterionCaseResult(report.criteria[0], {
        id: tier0Entry.id,
        type: tier0Entry.type,
        included: true,
        status: 'FAIL',
        detail: error.message,
      });
    }
  }
  if (tier0Failed && report.criteria[0].status === 'NOT RUN') {
    report.criteria[0] = { ...report.criteria[0], status: 'FAIL', detail: report.tier0.error };
  }
  setCriterionCaseResult(report.criteria[0], {
    id: TELEMETRY_SESSION_ID,
    type: 'telemetry',
    included: false,
    status: 'NOT INCLUDED',
    detail: 'Tier 0 checks only the shed fixture.',
  });

  const shouldStop = () => options.stopOnFirstFail
    && report.criteria.some(criterion => criterion.status === 'FAIL');
  const coverageFailures = [];
  const gapFailures = [];
  let checkedGapCount = 0;
  let stoppedEarly = shouldStop();

  if (!stoppedEarly) {
    if (fixtures.length !== EXPECTED_FIXTURE_COUNT) {
      coverageFailures.push(
        `expected ${EXPECTED_FIXTURE_COUNT} fixtures, found ${fixtures.length}`,
      );
    }
    if (tier1EntriesWithTelemetry.length === 0) {
      coverageFailures.push('no Tier 1 cases were selected');
      gapFailures.push('no Tier 1 cases were selected');
    }
    if (options.stopOnFirstFail
      && (coverageFailures.length > 0 || gapFailures.length > 0)) {
      stoppedEarly = true;
    }

    for (const entry of stoppedEarly ? [] : tier1EntriesWithTelemetry) {
      try {
        const offReplay = getReplay(entry, false, DEFAULT_PRE_ROLL_MS);
        const onReplay = getReplay(entry, true, DEFAULT_PRE_ROLL_MS);
        const caseReport = getCaseReport(entry);
        const coreSpans = entry.type === 'fixture'
          ? (() => {
            const core = fixtureCoreSpan(entry.fixture);
            return fixtureHasSpeechEvidence(offReplay, core)
              ? [{ id: 'metadata-core', ...core }]
              : [];
          })()
          : telemetrySpeechCores(offReplay);
        const gapDerivation = deriveGapOnlySpans(offReplay, DEFAULT_PRE_ROLL_MS);
        caseReport.speechCoreSpans = coreSpans;
        caseReport.gapOnlySpans = gapDerivation.spans;
        caseReport.runs.off = replaySummary(offReplay, coreSpans);
        caseReport.runs.on500 = replaySummary(onReplay, coreSpans);
        caseReport.runs.on500.gapAbsence = checkGapAbsence(
          gapDerivation.spans,
          onReplay,
          DEFAULT_PRE_ROLL_MS,
        );

        const offCoverage = caseReport.runs.off.coverage;
        const onCoverage = caseReport.runs.on500.coverage;
        const caseCoverageFailures = [];
        if (entry.type === 'telemetry' && coreSpans.length === 0) {
          caseCoverageFailures.push('OFF replay yielded no emitted speech-core spans');
        }
        if (!offCoverage.pass) {
          caseCoverageFailures.push(coverageFailureDetail('OFF', offCoverage));
        }
        if (!onCoverage.pass) {
          caseCoverageFailures.push(coverageFailureDetail('ON', onCoverage));
        }
        if (caseCoverageFailures.length > 0) {
          coverageFailures.push(
            ...caseCoverageFailures.map(failure => `${entry.id}: ${failure}`),
          );
        }
        const coverageStatus = caseCoverageFailures.length > 0
          ? 'FAIL'
          : coreSpans.length === 0 ? 'NOT APPLICABLE' : 'PASS';
        const coverageDetail = coreSpans.length === 0 && caseCoverageFailures.length === 0
          ? 'No speech-core spans were identified for this case.'
          : [
            `OFF ${formatCoverage(offCoverage)}`,
            `ON ${formatCoverage(onCoverage)}`,
            ...caseCoverageFailures,
          ].join('; ');
        setCriterionCaseResult(report.criteria[1], {
          id: entry.id,
          type: entry.type,
          included: true,
          status: coverageStatus,
          detail: coverageDetail,
        });

        const gapAbsence = caseReport.runs.on500.gapAbsence;
        checkedGapCount += gapAbsence.checkedSpanCount;
        if (!gapAbsence.pass) {
          const leakedCount = gapAbsence.leakedSpanCount;
          gapFailures.push(
            `${entry.id}: ${leakedCount} gap-only span(s) still emitted`,
          );
        }
        let gapStatus;
        if (!gapDerivation.derivable) {
          gapStatus = 'NOT DERIVABLE';
        } else if (gapAbsence.checkedSpanCount === 0) {
          gapStatus = 'NOT APPLICABLE';
        } else {
          gapStatus = gapAbsence.pass ? 'PASS' : 'FAIL';
        }
        const gapDetail = !gapDerivation.derivable
          ? gapDerivation.detail
          : gapAbsence.checkedSpanCount === 0
            ? `${gapDerivation.detail}; no gap-only samples to check`
            : `${gapAbsence.checkedSpanCount} span(s) checked; `
              + `${gapAbsence.leakedSpanCount} leaked; ${gapDerivation.detail}.`;
        setCriterionCaseResult(report.criteria[2], {
          id: entry.id,
          type: entry.type,
          included: true,
          status: gapStatus,
          detail: gapDetail,
        });
        if (!gapDerivation.derivable) {
          console.log(
            `INFO    ${entry.id} gap removal: NOT DERIVABLE — ${gapDerivation.detail}`,
          );
        }
        if (options.stopOnFirstFail
          && (coverageFailures.length > 0 || gapFailures.length > 0)) {
          stoppedEarly = true;
          break;
        }
      } catch (error) {
        getCaseReport(entry).error = error.message;
        coverageFailures.push(error.message);
        gapFailures.push(error.message);
        setCriterionCaseResult(report.criteria[1], {
          id: entry.id,
          type: entry.type,
          included: true,
          status: 'FAIL',
          detail: error.message,
        });
        setCriterionCaseResult(report.criteria[2], {
          id: entry.id,
          type: entry.type,
          included: true,
          status: 'FAIL',
          detail: error.message,
        });
        if (options.stopOnFirstFail) {
          stoppedEarly = true;
          break;
        }
      }
    }

    if (tier1EntriesWithTelemetry.length > 0 && tier1EntriesWithTelemetry
      .every(entry => reportByCase.get(entry.id)?.speechCoreSpans.length === 0)) {
      coverageFailures.push('no speech-core spans were identified in the selected Tier 1 cases');
    }
    if (stoppedEarly) {
      report.criteria[1] = {
        ...report.criteria[1],
        status: coverageFailures.length > 0 ? 'FAIL' : 'NOT RUN',
        detail: coverageFailures.length > 0
          ? coverageFailures.join('; ')
          : 'stopped before all Tier 1 cases were checked',
      };
      report.criteria[2] = {
        ...report.criteria[2],
        status: gapFailures.length > 0 ? 'FAIL' : 'NOT RUN',
        detail: gapFailures.length > 0
          ? gapFailures.join('; ')
          : 'stopped before all gap-only spans were checked',
      };
    } else {
      const notDerivableGapCaseCount = report.criteria[2].caseResults
        .filter(result => result.included && result.status === 'NOT DERIVABLE')
        .length;
      const notApplicableGapCaseCount = report.criteria[2].caseResults
        .filter(result => result.included && result.status === 'NOT APPLICABLE')
        .length;
      let gapStatus = 'NOT APPLICABLE';
      if (gapFailures.length > 0) {
        gapStatus = 'FAIL';
      } else if (checkedGapCount > 0) {
        gapStatus = 'PASS';
      } else if (notDerivableGapCaseCount > 0) {
        gapStatus = 'NOT DERIVABLE';
      }
      report.criteria[1] = {
        ...report.criteria[1],
        status: coverageFailures.length === 0 ? 'PASS' : 'FAIL',
        detail: coverageFailures.length === 0
          ? `${tier1EntriesWithTelemetry.length} case(s), OFF and ON`
          : coverageFailures.join('; '),
      };
      report.criteria[2] = {
        ...report.criteria[2],
        status: gapStatus,
        detail: gapFailures.length > 0
          ? gapFailures.join('; ')
          : checkedGapCount > 0
            ? `${checkedGapCount} span(s) checked; configured pre-roll allowed`
              + (notDerivableGapCaseCount > 0
                ? `; ${notDerivableGapCaseCount} case(s) NOT DERIVABLE and excluded`
                : '')
              + (notApplicableGapCaseCount > 0
                ? `; ${notApplicableGapCaseCount} case(s) had no gap-only samples`
                : '')
            : notDerivableGapCaseCount > 0
              ? `no gap-only spans checked; ${notDerivableGapCaseCount} case(s) NOT DERIVABLE`
              : `no gap-only samples were applicable across ${notApplicableGapCaseCount} case(s)`,
      };
    }
    stoppedEarly ||= shouldStop();
  }

  if (!stoppedEarly) {
    const sweepErrorsByCase = new Map();
    for (const preRollMs of PRE_ROLL_VALUES_MS) {
      const valueSummary = {
        preRollMs,
        totalSpeechSamples: 0,
        coveredSpeechSamples: 0,
        missingSpeechSamples: 0,
        clippedCases: [],
        errors: [],
      };
      for (const entry of sweepEntries) {
        try {
          const replay = getReplay(entry, true, preRollMs);
          const caseReport = getCaseReport(entry);
          const coverage = measureCoverage(caseReport.speechCoreSpans, replay);
          valueSummary.totalSpeechSamples += coverage.totalSamples;
          valueSummary.coveredSpeechSamples += coverage.coveredSamples;
          valueSummary.missingSpeechSamples += coverage.missingSamples;
          caseReport.runs[`on${preRollMs}`] = {
            ...caseReport.runs[`on${preRollMs}`],
            preRollMs,
            frameCount: replay.frames.length,
            emittedChunkCount: replay.events.filter(event => event.k === 'emit').length,
            emittedSpans: emittedSpans(replay),
            coverage,
          };
          if (coverage.missingSamples > 0) {
            valueSummary.clippedCases.push({
              id: entry.id,
              missingSamples: coverage.missingSamples,
              missingSpans: coverage.missingSpans,
            });
          }
        } catch (error) {
          valueSummary.errors.push({ id: entry.id, message: error.message });
          if (preRollMs === DEFAULT_PRE_ROLL_MS) {
            sweepErrorsByCase.set(entry.id, error.message);
          }
        }
      }
      report.preRollSweep.push(valueSummary);
      const clipDetail = valueSummary.clippedCases.length === 0
        ? 'no speech-core clipping observed'
        : `${valueSummary.missingSpeechSamples} speech-core samples missed at `
          + valueSummary.clippedCases.map(item => (
            `${item.id} ${item.missingSpans.map(span => `[${span.start},${span.end})`).join(',')}`
          )).join('; ');
      console.log(`INFO    pre-roll ${preRollMs} ms: ${clipDetail}`);
      for (const error of valueSummary.errors) {
        console.log(
          `INFO    pre-roll ${preRollMs} ms: ${error.id} replay unavailable — ${error.message}`,
        );
      }
    }

    const noWorseFailures = [];
    let comparedCoreCount = 0;
    for (const entry of sweepEntries) {
      const caseFailures = [];
      const caseReport = reportByCase.get(entry.id);
      const sweepError = sweepErrorsByCase.get(entry.id);
      if (sweepError) caseFailures.push(sweepError);
      const offCoverage = caseReport?.runs.off?.coverage;
      const onCoverage = caseReport?.runs.on500?.coverage;
      let caseStatus = 'NOT APPLICABLE';
      let caseDetail = 'No speech-core spans were available for comparison.';
      if (!caseReport || !offCoverage || !onCoverage) {
        caseFailures.push('OFF/ON 500 ms coverage is unavailable');
        caseStatus = 'FAIL';
        caseDetail = caseFailures.join('; ');
      } else if (offCoverage.cores.length > 0) {
        const onCores = new Map(onCoverage.cores.map(core => [core.id, core]));
        for (const offCore of offCoverage.cores) {
          comparedCoreCount += 1;
          const onCore = onCores.get(offCore.id);
          if (!onCore || onCore.missingSamples > offCore.missingSamples) {
            caseFailures.push(
              `${offCore.id}: ON misses ${onCore?.missingSamples ?? 'n/a'} samples `
                + `vs OFF ${offCore.missingSamples}`,
            );
          }
        }
        caseStatus = caseFailures.length === 0 ? 'PASS' : 'FAIL';
        caseDetail = caseFailures.length === 0
          ? `${offCoverage.cores.length} core span(s): ON misses no more than OFF.`
          : caseFailures.join('; ');
      }
      if (caseFailures.length > 0) {
        caseStatus = 'FAIL';
        caseDetail = caseFailures.join('; ');
        noWorseFailures.push(`${entry.id}: ${caseDetail}`);
      }
      setCriterionCaseResult(report.criteria[3], {
        id: entry.id,
        type: entry.type,
        included: true,
        status: caseStatus,
        detail: caseDetail,
      });
    }
    if (comparedCoreCount === 0) {
      noWorseFailures.push('no speech-core spans were available for comparison');
    }
    report.criteria[3] = {
      ...report.criteria[3],
      status: noWorseFailures.length === 0 ? 'PASS' : 'FAIL',
      detail: noWorseFailures.length === 0
        ? `${comparedCoreCount} core span(s) compared; ON misses no more than OFF per case`
        : noWorseFailures.join('; '),
    };
  }

  if (stoppedEarly) {
    for (const criterion of report.criteria) {
      if (criterion.status === 'NOT RUN') criterion.detail = 'stopped after an earlier failure';
    }
  }

  printCriteria(report.criteria);
  writeReport(report, options.jsonPath);
  if (report.criteria.some(criterion => criterion.status === 'FAIL')) process.exitCode = 1;
}

if (process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
