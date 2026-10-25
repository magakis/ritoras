#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  decodeWav,
  normalizeConfig,
  parseAssignment,
  replaySession,
  SHIPPING_SESSION_CONFIG,
} from './replay-vad.mjs';
import { GapRetentionPolicy } from '../lib/gap-retention-policy.mjs';

const SAMPLE_RATE = 16_000;
const CONFIG_KEYS = new Set(Object.keys(SHIPPING_SESSION_CONFIG));

function parseArgs(argv) {
  const options = {
    policy: null,
    wavPaths: [],
    outputDir: null,
    overrides: {},
    help: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') {
      options.help = true;
      continue;
    }
    if (argument === '--policy' || argument === '--output-dir' || argument === '--wav') {
      const value = argv[++index];
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${argument} requires a value`);
      }
      if (argument === '--policy') options.policy = value;
      else if (argument === '--output-dir') options.outputDir = value;
      else options.wavPaths.push(value);
      continue;
    }
    if (argument === '--set') {
      const assignment = argv[++index];
      if (assignment === undefined || assignment.startsWith('--')) {
        throw new Error('--set requires k=v');
      }
      const parsed = parseAssignment(assignment);
      if (!CONFIG_KEYS.has(parsed.key)) {
        throw new Error(`unknown VAD config key: ${parsed.key}`);
      }
      options.overrides[parsed.key] = parsed.value;
      continue;
    }
    if (argument.startsWith('--')) throw new Error(`unknown option: ${argument}`);
    options.wavPaths.push(argument);
  }

  if (!options.help) {
    if (!['current', 'gap-retention'].includes(options.policy)) {
      throw new Error('--policy must be current or gap-retention');
    }
    if (options.wavPaths.length === 0) throw new Error('provide at least one WAV path');
    if (!options.outputDir) throw new Error('--output-dir is required');
  }
  return options;
}

function mergeIntervals(intervals, sampleCount) {
  const sorted = intervals
    .map(interval => ({
      start: Math.max(0, Math.min(sampleCount, interval.start)),
      end: Math.max(0, Math.min(sampleCount, interval.end)),
    }))
    .filter(interval => interval.end > interval.start)
    .sort((left, right) => left.start - right.start);
  const merged = [];
  for (const interval of sorted) {
    const previous = merged.at(-1);
    if (!previous || interval.start > previous.end) {
      merged.push({ ...interval });
    } else {
      previous.end = Math.max(previous.end, interval.end);
    }
  }
  return merged;
}

function complementIntervals(intervals, sampleCount) {
  const merged = mergeIntervals(intervals, sampleCount);
  const complement = [];
  let cursor = 0;
  for (const interval of merged) {
    if (interval.start > cursor) complement.push({ start: cursor, end: interval.start });
    cursor = Math.max(cursor, interval.end);
  }
  if (cursor < sampleCount) complement.push({ start: cursor, end: sampleCount });
  return complement;
}

function voicedDurationInRange(frames, startSample, endSample) {
  let voicedSamples = 0;
  let frameStart = 0;
  for (const frame of frames) {
    const frameSamples = Math.round(frame.dt * SAMPLE_RATE);
    const overlap = Math.max(
      0,
      Math.min(endSample, frameStart + frameSamples) - Math.max(startSample, frameStart),
    );
    if (frame.e === 'strong' || frame.e === 'continuing') voicedSamples += overlap;
    frameStart += frameSamples;
  }
  return voicedSamples / (SAMPLE_RATE / 1000);
}

function aboveSilenceDurationInRange(frames, startSample, endSample) {
  let aboveSilenceSamples = 0;
  let frameStart = 0;
  for (const frame of frames) {
    const frameSamples = Math.round(frame.dt * SAMPLE_RATE);
    const overlap = Math.max(
      0,
      Math.min(endSample, frameStart + frameSamples) - Math.max(startSample, frameStart),
    );
    if (frame.db >= frame.st) aboveSilenceSamples += overlap;
    frameStart += frameSamples;
  }
  return aboveSilenceSamples / (SAMPLE_RATE / 1000);
}

function scheduleChunksFromCurrentReplay(replay, sampleCount) {
  const onsetFrames = replay.events.filter(event => event.k === 'start_utterance');
  const endpointFinalizes = replay.frames
    .filter(frame => frame.d === 'finalize_endpoint')
    .map((frame, index) => ({ index: index + 1, timeMs: frame.time * 1000 }));
  return replay.events
    .filter(event => event.k === 'emit')
    .map((event, index) => {
      const startSample = Math.max(0, Math.round(event.s0 * 16));
      const endSample = Math.max(startSample, Math.min(sampleCount, Math.round(event.s1 * 16)));
      const finalizeMs = Number.isFinite(event.time) ? event.time * 1000 : endSample / 16;
      const matchingFinalize = endpointFinalizes.find(item =>
        Math.abs(item.timeMs - finalizeMs) < 0.001,
      );
      const onset = [...onsetFrames].reverse().find(item => item.time <= (event.time ?? Infinity));
      const reason = event.r === 'endpoint'
        ? 'endpoint-silence'
        : event.r === 'flush'
          ? 'stop-flush'
          : String(event.r ?? 'unknown');
      return {
        chunk_index: index,
        start_sample: startSample,
        end_sample: endSample,
        start_ms: startSample / 16,
        end_ms: endSample / 16,
        onset_ms: onset ? onset.time * 1000 : null,
        finalize_ms: finalizeMs,
        finalize_reason: reason,
        endpoint_finalize_index: matchingFinalize?.index ?? null,
        voice_ms: voicedDurationInRange(replay.frames, startSample, endSample),
        above_silence_ms: aboveSilenceDurationInRange(replay.frames, startSample, endSample),
      };
    });
}

function scheduleChunksFromGapPolicy(policy) {
  return policy.chunks.map((chunk, index) => ({
    chunk_index: index,
    start_sample: chunk.startSample,
    end_sample: chunk.endSample,
    start_ms: chunk.startSample / 16,
    end_ms: chunk.endSample / 16,
    onset_ms: chunk.onsetSample === null ? null : chunk.onsetSample / 16,
    finalize_ms: chunk.finalizeSample / 16,
    finalize_reason: chunk.reason,
    endpoint_finalize_index: chunk.endpointFinalizeIndex,
    voice_ms: chunk.voiceSamples / 16,
    above_silence_ms: chunk.aboveSilenceSamples / 16,
  }));
}

function buildSeams(chunks) {
  return chunks.slice(1).map((following, index) => {
    const preceding = chunks[index];
    return {
      boundary_index: index + 1,
      boundary_ms: preceding.end_ms,
      finalize_ms: preceding.finalize_ms,
      follows_endpoint_silence: preceding.finalize_reason === 'endpoint-silence',
      preceding_chunk_index: preceding.chunk_index,
      following_chunk_index: following.chunk_index,
      audio_gap_ms: following.start_ms - preceding.end_ms,
    };
  });
}

function toSampleSlab(interval, frames, reason) {
  return {
    start: interval.start,
    end: interval.end,
    start_sample: interval.start,
    end_sample: interval.end,
    start_ms: interval.start / 16,
    end_ms: interval.end / 16,
    duration_ms: (interval.end - interval.start) / 16,
    voice_ms: voicedDurationInRange(frames, interval.start, interval.end),
    reason,
  };
}

function buildCoverage(chunks, shedSlabs, tailFloorDrops, sampleCount, policyName) {
  const emittedIntervals = mergeIntervals(chunks.map(chunk => ({
    start: chunk.start_sample,
    end: chunk.end_sample,
  })), sampleCount);
  const actualShedIntervals = mergeIntervals(shedSlabs.map(slab => ({
    start: slab.start_sample,
    end: slab.end_sample,
  })), sampleCount);
  const tailFloorIntervals = mergeIntervals(tailFloorDrops.map(drop => ({
    start: drop.start_sample,
    end: drop.end_sample,
  })), sampleCount);
  const accountingIntervals = mergeIntervals(
    [...emittedIntervals, ...actualShedIntervals, ...tailFloorIntervals],
    sampleCount,
  );
  const uncoveredIntervals = complementIntervals(accountingIntervals, sampleCount);
  const emittedSamples = emittedIntervals.reduce(
    (sum, interval) => sum + interval.end - interval.start,
    0,
  );
  const shedSamples = actualShedIntervals.reduce(
    (sum, interval) => sum + interval.end - interval.start,
    0,
  );
  const tailFloorSamples = tailFloorIntervals.reduce(
    (sum, interval) => sum + interval.end - interval.start,
    0,
  );
  const chunkSamples = chunks.reduce(
    (sum, chunk) => sum + chunk.end_sample - chunk.start_sample,
    0,
  );
  const uncoveredSamples = uncoveredIntervals.reduce(
    (sum, interval) => sum + interval.end - interval.start,
    0,
  );
  const bucketSamples = emittedSamples + shedSamples + tailFloorSamples;
  const unionSamples = accountingIntervals.reduce(
    (sum, interval) => sum + interval.end - interval.start,
    0,
  );
  return {
    total_samples: sampleCount,
    emitted_samples: emittedSamples,
    shed_samples: shedSamples,
    tail_floor_drop_samples: tailFloorSamples,
    uncovered_samples: uncoveredSamples,
    total_ms: sampleCount / 16,
    emitted_ms: emittedSamples / 16,
    emitted_chunk_ms: chunkSamples / 16,
    shed_ms: shedSamples / 16,
    shed_count: shedSlabs.length,
    shed_voice_ms: shedSlabs.reduce((sum, slab) => sum + slab.voice_ms, 0),
    max_shed_duration_ms: shedSlabs.reduce(
      (maximum, slab) => Math.max(maximum, slab.end_sample - slab.start_sample),
      0,
    ) / 16,
    max_shed_voice_ms: shedSlabs.reduce(
      (maximum, slab) => Math.max(maximum, slab.voice_ms),
      0,
    ),
    tail_floor_drop_ms: tailFloorSamples / 16,
    tail_floor_drop_count: tailFloorDrops.length,
    tail_floor_drop_voice_ms: tailFloorDrops.reduce((sum, drop) => sum + drop.voice_ms, 0),
    max_tail_floor_drop_duration_ms: tailFloorDrops.reduce(
      (maximum, drop) => Math.max(maximum, drop.end_sample - drop.start_sample),
      0,
    ) / 16,
    max_tail_floor_drop_voice_ms: tailFloorDrops.reduce(
      (maximum, drop) => Math.max(maximum, drop.voice_ms),
      0,
    ),
    uncovered_ms: uncoveredSamples / 16,
    coverage_accounted_ms: (bucketSamples + uncoveredSamples) / 16,
    buckets_are_disjoint: bucketSamples === unionSamples,
    coverage_matches_total: bucketSamples === sampleCount && bucketSamples === unionSamples,
    accounting_reconciles_total:
      bucketSamples + uncoveredSamples === sampleCount,
    shed_semantics: policyName === 'current'
      ? 'legacy-unretained-or-trimmed-audio'
      : 'whole-pending-buffer-over-cap-with-less-than-100ms-voice-evidence',
  };
}

function simulateGapRetention(replay, config, sampleCount) {
  const normalized = normalizeConfig(config);
  const policy = new GapRetentionPolicy({
    maxNoiseSamples: normalized.maxNoiseSamples,
    minSpeechSamples: normalized.minSpeechSamples,
    minChunkSamples: normalized.minChunkSamples,
  });
  let sampleCursor = 0;
  for (const frame of replay.frames) {
    const frameSamples = Math.round(frame.dt * SAMPLE_RATE);
    const endSample = sampleCursor + frameSamples;
    policy.processFrame({
      startSample: sampleCursor,
      endSample,
      db: frame.db,
      evidence: frame.e,
      silenceThresholdDb: frame.st,
      decision: frame.d,
      endpointState: frame.es,
    });
    sampleCursor = endSample;
  }
  const policyState = policy.flush({ endSample: sampleCursor });
  const snapshot = policy.snapshot();
  const chunks = scheduleChunksFromGapPolicy(snapshot);
  const shedSlabs = snapshot.shedSlabs.map(slab => toSampleSlab({
    start: slab.startSample,
    end: slab.endSample,
  }, replay.frames, 'max-noise-voice-evidence'));
  const tailFloorDrops = snapshot.tailFloorDrops.map(drop => toSampleSlab({
    start: drop.startSample,
    end: drop.endSample,
  }, replay.frames, 'tail-floor'));
  const belowMinimumFinalizes = snapshot.events.filter(
    event => event.type === 'endpoint-finalize-held',
  );
  const accounted = mergeIntervals([
    ...chunks.map(chunk => ({ start: chunk.start_sample, end: chunk.end_sample })),
    ...shedSlabs.map(slab => ({ start: slab.start_sample, end: slab.end_sample })),
    ...tailFloorDrops.map(drop => ({ start: drop.start_sample, end: drop.end_sample })),
  ], sampleCount);
  const uncoveredSlabs = complementIntervals(accounted, sampleCount)
    .map(interval => toSampleSlab(interval, replay.frames, 'not-emitted-or-shed'));
  return {
    chunks,
    shedSlabs,
    tailFloorDrops,
    uncoveredSlabs,
    events: snapshot.events,
    flush: policyState,
    belowMinimumFinalizes,
  };
}

function simulateCurrent(replay, sampleCount) {
  const chunks = scheduleChunksFromCurrentReplay(replay, sampleCount);
  const uncovered = complementIntervals(chunks.map(chunk => ({
    start: chunk.start_sample,
    end: chunk.end_sample,
  })), sampleCount);
  const shedSlabs = uncovered.map(interval => toSampleSlab(
    interval,
    replay.frames,
    'legacy-unretained-or-trimmed-audio',
  ));
  return {
    chunks,
    shedSlabs,
    tailFloorDrops: [],
    uncoveredSlabs: [],
    events: [],
    flush: null,
  };
}

function runSchedule(wavPath, policyName, overrides, outputPath) {
  const wavBytes = fs.readFileSync(wavPath);
  const decoded = decodeWav(wavBytes);
  if (decoded.sampleRate !== SAMPLE_RATE) {
    throw new Error(`${wavPath}: expected 16 kHz audio, got ${decoded.sampleRate} Hz`);
  }
  if (decoded.channels !== 1) {
    throw new Error(`${wavPath}: expected mono audio, got ${decoded.channels} channels`);
  }
  if (decoded.samples.length === 0) throw new Error(`${wavPath}: WAV has no samples`);
  for (const sample of decoded.samples) {
    if (!Number.isFinite(sample)) throw new Error(`${wavPath}: audio contains a non-finite sample`);
  }

  const config = { ...SHIPPING_SESSION_CONFIG, ...overrides };
  if (Object.hasOwn(overrides, 'endpointSilenceMs')) {
    config.silenceMs = overrides.endpointSilenceMs;
  } else if (Object.hasOwn(overrides, 'silenceMs')) {
    config.endpointSilenceMs = overrides.silenceMs;
  }
  const sampleCount = decoded.samples.length;
  const replay = replaySession({
    frames: [],
    events: [],
    config: SHIPPING_SESSION_CONFIG,
    configIsTelemetry: false,
  }, config, {
    fromWav: decoded,
    compare: false,
  });
  const replayedSamples = replay.frames.reduce(
    (total, frame) => total + Math.round(frame.dt * SAMPLE_RATE),
    0,
  );
  if (replayedSamples !== sampleCount) {
    throw new Error(
      `VAD replay classified ${replayedSamples} of ${sampleCount} samples; `
      + 'the schedule cannot account for the whole WAV',
    );
  }
  const simulated = policyName === 'current'
    ? simulateCurrent(replay, sampleCount)
    : simulateGapRetention(replay, config, sampleCount);
  const chunks = simulated.chunks;
  const coverage = buildCoverage(
    chunks,
    simulated.shedSlabs,
    simulated.tailFloorDrops,
    sampleCount,
    policyName,
  );
  const belowMinimumFinalizes = simulated.belowMinimumFinalizes ?? [];
  const payload = {
    format: 'ritoras-boundary-schedule-v1',
    policy: policyName,
    session_id: path.basename(wavPath).replace(/\.wav$/i, ''),
    source_wav: path.resolve(wavPath),
    source_wav_sha256: createHash('sha256').update(wavBytes).digest('hex'),
    sample_rate_hz: SAMPLE_RATE,
    total_samples: sampleCount,
    duration_ms: sampleCount / 16,
    config: replay.config,
    chunks,
    shed_slabs: simulated.shedSlabs,
    tail_floor_drops: simulated.tailFloorDrops,
    uncovered_slabs: simulated.uncoveredSlabs,
    seams: buildSeams(chunks),
    coverage,
    policy_diagnostics: {
      events: simulated.events,
      stop_flush: simulated.flush,
      ...(policyName === 'gap-retention'
        ? {
          below_minimum_finalize_count: belowMinimumFinalizes.length,
          below_minimum_finalize_duration_ms: belowMinimumFinalizes
            .reduce((sum, event) => sum + event.duration_ms, 0),
          below_minimum_finalize_voice_ms: belowMinimumFinalizes
            .reduce((sum, event) => sum + event.voice_ms, 0),
        }
        : {}),
    },
  };
  fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`);
  return payload;
}

function buildCorpusSummary(policyName, sessions) {
  const total = key => sessions.reduce(
    (sum, session) => sum + session.coverage[key],
    0,
  );
  const coverage = {
    total_samples: total('total_samples'),
    emitted_samples: total('emitted_samples'),
    shed_samples: total('shed_samples'),
    tail_floor_drop_samples: total('tail_floor_drop_samples'),
    uncovered_samples: total('uncovered_samples'),
    total_ms: total('total_ms'),
    emitted_ms: total('emitted_ms'),
    emitted_chunk_ms: total('emitted_chunk_ms'),
    shed_ms: total('shed_ms'),
    shed_voice_ms: total('shed_voice_ms'),
    tail_floor_drop_ms: total('tail_floor_drop_ms'),
    tail_floor_drop_voice_ms: total('tail_floor_drop_voice_ms'),
    max_shed_duration_ms: Math.max(
      ...sessions.map(session => session.coverage.max_shed_duration_ms),
    ),
    max_shed_voice_ms: Math.max(
      ...sessions.map(session => session.coverage.max_shed_voice_ms),
    ),
    max_tail_floor_drop_duration_ms: Math.max(
      ...sessions.map(session => session.coverage.max_tail_floor_drop_duration_ms),
    ),
    max_tail_floor_drop_voice_ms: Math.max(
      ...sessions.map(session => session.coverage.max_tail_floor_drop_voice_ms),
    ),
    uncovered_ms: total('uncovered_ms'),
    coverage_accounted_ms: total('coverage_accounted_ms'),
    shed_count: sessions.reduce((sum, session) => sum + session.shed_slabs.length, 0),
    tail_floor_drop_count: sessions.reduce(
      (sum, session) => sum + session.tail_floor_drops.length,
      0,
    ),
    uncovered_count: sessions.reduce(
      (sum, session) => sum + session.uncovered_slabs.length,
      0,
    ),
    buckets_are_disjoint: sessions.every(session => session.coverage.buckets_are_disjoint),
    coverage_matches_total: sessions.every(session => session.coverage.coverage_matches_total)
      && total('emitted_samples') + total('shed_samples') + total('tail_floor_drop_samples')
        === total('total_samples'),
    accounting_reconciles_total: sessions.every(
      session => session.coverage.accounting_reconciles_total,
    ),
  };
  const belowMinimumFinalizes = sessions.reduce(
    (sum, session) => sum
      + (session.policy_diagnostics.below_minimum_finalize_count ?? 0),
    0,
  );
  const belowMinimumFinalizeDurationMs = sessions.reduce(
    (sum, session) => sum
      + (session.policy_diagnostics.below_minimum_finalize_duration_ms ?? 0),
    0,
  );
  const belowMinimumFinalizeVoiceMs = sessions.reduce(
    (sum, session) => sum
      + (session.policy_diagnostics.below_minimum_finalize_voice_ms ?? 0),
    0,
  );
  const stopFlushChunkCount = sessions.reduce(
    (sum, session) => sum + session.chunks.filter(
      chunk => chunk.finalize_reason === 'stop-flush',
    ).length,
    0,
  );
  const stopFlushOfferedMs = sessions.reduce(
    (sum, session) => sum + (session.policy_diagnostics.stop_flush?.durationMs ?? 0),
    0,
  );
  const stopFlushOfferedSessionCount = sessions.reduce(
    (count, session) => count + Number(Boolean(session.policy_diagnostics.stop_flush?.offered)),
    0,
  );
  return {
    format: 'ritoras-boundary-schedule-corpus-v1',
    policy: policyName,
    session_count: sessions.length,
    chunk_count: sessions.reduce((sum, session) => sum + session.chunks.length, 0),
    below_minimum_finalize_count: belowMinimumFinalizes,
    below_minimum_finalize_duration_ms: belowMinimumFinalizeDurationMs,
    below_minimum_finalize_voice_ms: belowMinimumFinalizeVoiceMs,
    stop_flush_chunk_count: stopFlushChunkCount,
    stop_flush_offered_ms: stopFlushOfferedMs,
    stop_flush_offered_session_count: stopFlushOfferedSessionCount,
    coverage,
    sessions: sessions.map(session => ({
      session_id: session.session_id,
      source_wav: session.source_wav,
      source_wav_sha256: session.source_wav_sha256,
      chunk_count: session.chunks.length,
      shed_slabs: session.shed_slabs.length,
      tail_floor_drops: session.tail_floor_drops.length,
      uncovered_slabs: session.uncovered_slabs.length,
      below_minimum_finalize_count:
        session.policy_diagnostics.below_minimum_finalize_count ?? 0,
      below_minimum_finalize_duration_ms:
        session.policy_diagnostics.below_minimum_finalize_duration_ms ?? 0,
      below_minimum_finalize_voice_ms:
        session.policy_diagnostics.below_minimum_finalize_voice_ms ?? 0,
      stop_flush_offered_ms: session.policy_diagnostics.stop_flush?.durationMs ?? 0,
      stop_flush_offered: Boolean(session.policy_diagnostics.stop_flush?.offered),
      stop_flush_chunk_count: session.chunks.filter(
        chunk => chunk.finalize_reason === 'stop-flush',
      ).length,
      coverage: session.coverage,
    })),
  };
}

function usage() {
  return [
    'Usage: node scripts/prediction-sim/bin/sim-boundary-schedule.mjs \\',
    '  --policy current|gap-retention --output-dir DIR WAV [WAV ...] [options]',
    '',
    '  --wav PATH               Add one WAV (repeatable; positional WAVs also accepted)',
    '  --set k=v                Override a VAD replay config value (repeatable)',
    '  --output-dir DIR         Write one <recording>.<policy>.json per WAV',
  ].join('\n');
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    console.log(usage());
    return;
  }
  const outputDir = path.resolve(options.outputDir);
  fs.mkdirSync(outputDir, { recursive: true });
  const sessions = [];
  for (const wavPath of options.wavPaths) {
    const stem = path.basename(wavPath).replace(/\.wav$/i, '');
    const outputPath = path.join(outputDir, `${stem}.${options.policy}.json`);
    sessions.push(runSchedule(wavPath, options.policy, options.overrides, outputPath));
    console.log(outputPath);
  }
  const summaryPath = path.join(outputDir, `${options.policy}.corpus-summary.json`);
  fs.writeFileSync(
    summaryPath,
    `${JSON.stringify(buildCorpusSummary(options.policy, sessions), null, 2)}\n`,
  );
  console.log(summaryPath);
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
