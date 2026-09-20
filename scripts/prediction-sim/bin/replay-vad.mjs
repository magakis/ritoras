#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  dbFromRms,
  makeVadGateConfig,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import {
  makeStreamingEndpointConfig,
  StreamingEndpoint,
} from '../lib/streaming-endpoint.mjs';
import { VADHighPassFilter } from '../lib/vad-hpf.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

export const DEFAULT_SESSION_CONFIG = Object.freeze({
  mode: 'static',
  strongDeltaDb: 10,
  continuationDeltaDb: 6,
  silenceDeltaDb: 3,
  dynamicsSpreadDb: 9,
  dynamicsEnabled: true,
  staleFloorSeconds: 1.5,
  fallTauSeconds: 0.5,
  riseMultiplier: 1,
  endpointMachineEnabled: true,
  endpointOnsetMs: 70,
  endpointEndEvidenceMs: 100,
  endpointSilenceMs: 700,
  endpointResumeMs: 120,
  endpointAmbiguousRescueMs: 320,
  endpointPreRollMs: 500,
  silenceMs: 700,
  minSpeechMs: 300,
  minChunkMs: 300,
  maxNoiseSec: 6,
  analysisHpfEnabled: false,
  analysisHpfCutoffHz: 100,
});

const CONFIG_KEYS = new Set(Object.keys(DEFAULT_SESSION_CONFIG));
const DIVERGENCE_FIELDS = ['e', 'es', 'd'];

function asFiniteNumber(value, key) {
  const number = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(number)) throw new Error(`${key} must be a finite number`);
  return number;
}

function parseScalar(value) {
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (value !== '' && Number.isFinite(Number(value))) return Number(value);
  return value;
}

export function parseAssignment(value) {
  const separator = value.indexOf('=');
  if (separator <= 0) throw new Error(`expected k=v, got ${value}`);
  return {
    key: value.slice(0, separator),
    value: parseScalar(value.slice(separator + 1)),
  };
}

export function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    sessionPath: null,
    wavPath: null,
    set: [],
    sweep: [],
    labels: [],
    fromWav: false,
    jsonPath: null,
    help: false,
  };
  const positional = [];

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument !== '-h' && !argument.startsWith('--')) {
      positional.push(argument);
      continue;
    }
    if (argument === '--help' || argument === '-h') {
      options.help = true;
      continue;
    }
    if (argument === '--from-wav') {
      options.fromWav = true;
      continue;
    }
    if (argument === '--set' || argument === '--sweep') {
      const assignment = argv[++index];
      if (assignment === undefined || assignment.startsWith('--')) {
        throw new Error(`${argument} requires k=v`);
      }
      if (argument === '--set') {
        options.set.push(parseAssignment(assignment));
        while (index + 1 < argv.length
          && !argv[index + 1].startsWith('--')
          && argv[index + 1].includes('=')) {
          index += 1;
          options.set.push(parseAssignment(argv[index]));
        }
      } else {
        const parsed = parseAssignment(assignment);
        const values = String(assignment.slice(assignment.indexOf('=') + 1))
          .split(',')
          .map(parseScalar);
        options.sweep.push({ key: parsed.key, values });
      }
      continue;
    }
    if (argument === '--labels' || argument === '--json') {
      const value = argv[++index];
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${argument} requires a value`);
      }
      if (argument === '--labels') options.labels = parseLabels(value);
      else options.jsonPath = value;
      continue;
    }
    throw new Error(`unknown option: ${argument}`);
  }

  if (positional.length > 0) options.sessionPath = positional[0];
  if (positional.length > 1) options.wavPath = positional[1];
  if (positional.length > 2) throw new Error('expected one JSONL path and one optional WAV path');
  if (!options.help && options.sessionPath === null) throw new Error('missing session JSONL path');
  if (options.fromWav && options.wavPath === null) {
    throw new Error('--from-wav requires a session WAV path');
  }
  return options;
}

export function parseLabels(value) {
  if (!value) return [];
  return value.split(',').map((part) => {
    const match = part.trim().match(/^(-?\d+(?:\.\d+)?)-(-?\d+(?:\.\d+)?)$/);
    if (!match) throw new Error(`invalid speech label interval: ${part}`);
    const start = Number(match[1]);
    const end = Number(match[2]);
    if (start < 0 || end <= start) throw new Error(`invalid speech label interval: ${part}`);
    return { start, end };
  });
}

export function parseSession(text) {
  const frames = [];
  const events = [];
  let config = null;
  const lines = text.split(/\r?\n/);
  for (let lineNumber = 0; lineNumber < lines.length; lineNumber += 1) {
    const line = lines[lineNumber].trim();
    if (!line) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch (error) {
      throw new Error(`invalid JSONL at line ${lineNumber + 1}: ${error.message}`);
    }
    if (record.t === 'f') frames.push(record);
    else if (record.t === 'ev') {
      events.push(record);
      if (record.k === 'session_start' && record.c) config = record.c;
    }
  }
  const session = {
    frames,
    events,
    config: { ...DEFAULT_SESSION_CONFIG, ...(config ?? {}) },
  };
  Object.defineProperty(session, 'configIsTelemetry', {
    value: config !== null,
    enumerable: false,
  });
  return session;
}

function validateAssignments(assignments) {
  for (const { key } of assignments) {
    if (!CONFIG_KEYS.has(key)) throw new Error(`unknown VAD config key: ${key}`);
  }
}

function applyAssignment(config, assignment) {
  const next = { ...config, [assignment.key]: assignment.value };
  if (assignment.key === 'silenceMs') next.endpointSilenceMs = assignment.value;
  if (assignment.key === 'endpointSilenceMs') next.silenceMs = assignment.value;
  return next;
}

function rawConfigFromTelemetry(config) {
  if (!config || !Number.isFinite(config.staleFloorSeconds)
    || !Number.isFinite(config.riseMultiplier)) return config;
  return {
    ...config,
    staleFloorSeconds: config.staleFloorSeconds * config.riseMultiplier,
  };
}

export function normalizeConfig(rawConfig = {}) {
  const raw = { ...DEFAULT_SESSION_CONFIG, ...(rawConfig ?? {}) };
  if (!['static', 'calibrated', 'adaptive'].includes(raw.mode)) {
    throw new Error(`mode must be static, calibrated, or adaptive; got ${raw.mode}`);
  }

  const gateConfig = makeVadGateConfig({
    mode: raw.mode,
    adaptiveDeltaDb: asFiniteNumber(raw.strongDeltaDb, 'strongDeltaDb'),
    adaptiveContinuationDeltaDb: asFiniteNumber(raw.continuationDeltaDb, 'continuationDeltaDb'),
    adaptiveSilenceDeltaDb: asFiniteNumber(raw.silenceDeltaDb, 'silenceDeltaDb'),
    adaptiveDynamicsSpreadDb: asFiniteNumber(raw.dynamicsSpreadDb, 'dynamicsSpreadDb'),
    adaptiveDynamicsEnabled: Boolean(raw.dynamicsEnabled),
    adaptiveStaleFloorSeconds: asFiniteNumber(raw.staleFloorSeconds, 'staleFloorSeconds'),
    adaptiveFallTauSeconds: asFiniteNumber(raw.fallTauSeconds, 'fallTauSeconds'),
    adaptiveRiseSpeedMultiplier: asFiniteNumber(raw.riseMultiplier, 'riseMultiplier'),
  });
  const gate = new VADThresholdGate(gateConfig);
  const endpointSilenceMs = asFiniteNumber(raw.silenceMs ?? raw.endpointSilenceMs, 'silenceMs');
  const endpoint = new StreamingEndpoint(makeStreamingEndpointConfig({
    onsetMs: asFiniteNumber(raw.endpointOnsetMs, 'endpointOnsetMs'),
    endEvidenceMs: asFiniteNumber(raw.endpointEndEvidenceMs, 'endpointEndEvidenceMs'),
    endpointSilenceMs,
    resumeMs: asFiniteNumber(raw.endpointResumeMs, 'endpointResumeMs'),
    ambiguousRescueMs: asFiniteNumber(raw.endpointAmbiguousRescueMs, 'endpointAmbiguousRescueMs'),
    preRollMs: asFiniteNumber(raw.endpointPreRollMs, 'endpointPreRollMs'),
  }));
  const minimum = key => Math.max(0, Math.floor(asFiniteNumber(raw[key], key) * 16));
  const maxNoiseSamples = Math.max(0, Math.floor(
    asFiniteNumber(raw.maxNoiseSec, 'maxNoiseSec') * 16000,
  ));
  const normalized = {
    ...raw,
    mode: gate.config.mode,
    strongDeltaDb: gate.effectiveAdaptiveDeltaDb,
    continuationDeltaDb: gate.effectiveAdaptiveContinuationDeltaDb,
    silenceDeltaDb: gate.effectiveSilenceDeltaDb,
    dynamicsSpreadDb: gate.effectiveDynamicsSpreadDb,
    dynamicsEnabled: gate.config.adaptiveDynamicsEnabled,
    staleFloorSeconds: gate.effectiveStaleFloorSeconds,
    fallTauSeconds: gate.effectiveFallTauSeconds,
    riseMultiplier: gate.effectiveRiseSpeedMultiplier,
    endpointMachineEnabled: Boolean(raw.endpointMachineEnabled),
    endpointOnsetMs: endpoint.configuration.onsetSamples / 16,
    endpointEndEvidenceMs: endpoint.configuration.endEvidenceSamples / 16,
    endpointSilenceMs: endpoint.configuration.endpointSilenceSamples / 16,
    endpointResumeMs: endpoint.configuration.resumeSamples / 16,
    endpointAmbiguousRescueMs: endpoint.configuration.ambiguousRescueSamples / 16,
    endpointPreRollMs: endpoint.configuration.preRollSamples / 16,
    silenceMs: endpoint.configuration.endpointSilenceSamples / 16,
    minSpeechMs: minimum('minSpeechMs') / 16,
    minChunkMs: minimum('minChunkMs') / 16,
    maxNoiseSec: maxNoiseSamples / 16000,
  };
  return { config: normalized, endpoint, gateConfig, minSpeechSamples: minimum('minSpeechMs'), minChunkSamples: minimum('minChunkMs'), maxNoiseSamples };
}

function harnessOptions(normalized) {
  return {
    gateConfig: normalized.gateConfig,
    endpointConfig: normalized.endpoint.configuration,
    endpointSilenceMs: normalized.config.endpointSilenceMs,
    endpointMachineEnabled: normalized.config.endpointMachineEnabled,
    minSpeechSamples: normalized.minSpeechSamples,
    minChunkSamples: normalized.minChunkSamples,
    maxNoiseSamples: normalized.maxNoiseSamples,
  };
}

export function dcCorrectedRMS(samples) {
  if (!samples || samples.length === 0) return 0;
  let mean = 0;
  for (const sample of samples) mean += sample;
  mean /= samples.length;
  let squared = 0;
  for (const sample of samples) squared += (sample - mean) ** 2;
  return Math.sqrt(squared / samples.length);
}

export function dbFromSamples(samples) {
  return dbFromRms(dcCorrectedRMS(samples));
}

export function decodeWav(input) {
  const data = Buffer.isBuffer(input) ? input : Buffer.from(input);
  if (data.length < 12 || data.toString('ascii', 0, 4) !== 'RIFF'
    || data.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('WAV must have a RIFF/WAVE header');
  }
  let format = null;
  let dataOffset = null;
  let dataSize = null;
  let offset = 12;
  while (offset + 8 <= data.length) {
    const chunkId = data.toString('ascii', offset, offset + 4);
    const chunkSize = data.readUInt32LE(offset + 4);
    const chunkOffset = offset + 8;
    if (chunkOffset + chunkSize > data.length) throw new Error('WAV chunk exceeds file length');
    if (chunkId === 'fmt ') {
      if (chunkSize < 16) throw new Error('WAV fmt chunk is too short');
      format = {
        audioFormat: data.readUInt16LE(chunkOffset),
        channels: data.readUInt16LE(chunkOffset + 2),
        sampleRate: data.readUInt32LE(chunkOffset + 4),
        blockAlign: data.readUInt16LE(chunkOffset + 12),
        bitsPerSample: data.readUInt16LE(chunkOffset + 14),
      };
    } else if (chunkId === 'data') {
      dataOffset = chunkOffset;
      dataSize = chunkSize;
    }
    offset = chunkOffset + chunkSize + (chunkSize % 2);
  }
  if (!format || dataOffset === null || dataSize === null) {
    throw new Error('WAV must contain fmt and data chunks');
  }
  if (format.channels < 1 || format.sampleRate < 1) throw new Error('invalid WAV format');
  if (!((format.audioFormat === 1 && format.bitsPerSample === 16)
    || (format.audioFormat === 3 && format.bitsPerSample === 32))) {
    throw new Error('WAV must be PCM16 or IEEE float32');
  }
  const bytesPerSample = format.bitsPerSample / 8;
  const expectedBlockAlign = format.channels * bytesPerSample;
  if (format.blockAlign !== expectedBlockAlign) throw new Error('unsupported WAV block alignment');
  const frameCount = Math.floor(dataSize / format.blockAlign);
  const samples = new Float64Array(frameCount);
  for (let frame = 0; frame < frameCount; frame += 1) {
    let mixed = 0;
    const frameOffset = dataOffset + frame * format.blockAlign;
    for (let channel = 0; channel < format.channels; channel += 1) {
      const sampleOffset = frameOffset + channel * bytesPerSample;
      mixed += format.audioFormat === 3
        ? data.readFloatLE(sampleOffset)
        : data.readInt16LE(sampleOffset) / 32768;
    }
    samples[frame] = mixed / format.channels;
  }
  return { ...format, samples };
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

export function framesFromWav(wav, telemetryFrames = [], config = DEFAULT_SESSION_CONFIG) {
  const durations = telemetryFrames.length > 0
    ? telemetryFrames.map(frame => asFiniteNumber(frame.dt, 'frame dt'))
    : [0.01];
  const frames = telemetryFrames.length > 0
    ? telemetryFrames.map(frame => ({ ...frame }))
    : [];
  const filter = config.analysisHpfEnabled
    ? new VADHighPassFilter({ cutoffHz: asFiniteNumber(config.analysisHpfCutoffHz, 'analysisHpfCutoffHz') })
    : null;
  let sampleOffset = 0;
  let frameIndex = 0;
  while (sampleOffset < wav.samples.length && (telemetryFrames.length === 0 || frameIndex < frames.length)) {
    const duration = durations[Math.min(frameIndex, durations.length - 1)];
    const sampleCount = Math.max(1, Math.round(duration * wav.sampleRate));
    const end = Math.min(wav.samples.length, sampleOffset + sampleCount);
    const raw = Array.from(wav.samples.slice(sampleOffset, end));
    const analysis = filter ? filter.process(raw) : raw;
    const db = dbFromSamples(analysis);
    if (telemetryFrames.length > 0) frames[frameIndex].db = db;
    else frames.push({ t: 'f', q: frameIndex, dt: raw.length / wav.sampleRate, db });
    sampleOffset = end;
    frameIndex += 1;
  }
  return frames;
}

function applyAssignments(base, assignments) {
  return assignments.reduce((config, assignment) => applyAssignment(config, assignment), base);
}

export function expandSweep(baseConfig, sweeps) {
  if (sweeps.length === 0) return [baseConfig];
  return sweeps.reduce((configs, sweep) => configs.flatMap(config => sweep.values.map(value => applyAssignment(config, { key: sweep.key, value }))), [baseConfig]);
}

function intervalOverlapDuration(left, right) {
  return Math.max(0, Math.min(left.end, right.end) - Math.max(left.start, right.start));
}

export function intervalDifferenceDuration(intervals, subtract) {
  let total = 0;
  for (const interval of intervals) {
    const cuts = subtract
      .filter(other => other.end > interval.start && other.start < interval.end)
      .sort((a, b) => a.start - b.start);
    let cursor = interval.start;
    for (const cut of cuts) {
      if (cut.start > cursor) total += Math.max(0, Math.min(cut.start, interval.end) - cursor);
      cursor = Math.max(cursor, cut.end);
      if (cursor >= interval.end) break;
    }
    if (cursor < interval.end) total += interval.end - cursor;
  }
  return total;
}

export function computeLabelMetrics(openIntervals, labels) {
  const falseOpenSeconds = intervalDifferenceDuration(openIntervals, labels);
  const missedSpeechSeconds = intervalDifferenceDuration(labels, openIntervals);
  const onsetLatencies = labels.map(label => {
    const match = openIntervals.find(open => intervalOverlapDuration(open, label) > 0);
    return match ? Math.max(0, match.start - label.start) : null;
  });
  const finiteLatencies = onsetLatencies.filter(value => value !== null);
  return {
    falseOpenSeconds,
    missedSpeechSeconds,
    onsetLatencies,
    meanOnsetLatencySeconds: finiteLatencies.length > 0
      ? finiteLatencies.reduce((sum, value) => sum + value, 0) / finiteLatencies.length
      : null,
  };
}

function buildOpenIntervals(frames, events, duration) {
  const starts = events.filter(event => event.k === 'start_utterance');
  const closes = events.filter(event => event.k === 'emit'
    || event.k === 'discard'
    || (event.k === 'stop_flush' && event.r === 'below_minimums'));
  const usedCloses = new Set();
  const intervals = [];
  for (const start of starts) {
    const closeIndex = closes.findIndex((event, index) =>
      event.time >= start.time && !usedCloses.has(index));
    const close = closeIndex >= 0 ? closes[closeIndex] : null;
    if (close) usedCloses.add(closeIndex);
    intervals.push({ start: start.time, end: close?.time ?? duration });
  }
  if (intervals.length > 0) return intervals.filter(interval => interval.end >= interval.start);
  const fallback = [];
  let open = null;
  for (const frame of frames) {
    if (frame.es !== 'idle' && open === null) open = frame.time - frame.dt;
    if (frame.es === 'idle' && open !== null) {
      fallback.push({ start: open, end: frame.time });
      open = null;
    }
  }
  if (open !== null) fallback.push({ start: open, end: duration });
  return fallback;
}

function utteranceReport(events, labels) {
  const starts = events.filter(event => event.k === 'start_utterance');
  const closes = events.filter(event => event.k === 'emit'
    || event.k === 'discard'
    || (event.k === 'stop_flush' && event.r === 'below_minimums'));
  const usedCloses = new Set();
  return starts.map((start, index) => {
    const closeIndex = closes.findIndex((event, closeIndex) =>
      event.time >= start.time && !usedCloses.has(closeIndex));
    const close = closeIndex >= 0 ? closes[closeIndex] : null;
    if (close) usedCloses.add(closeIndex);
    const label = labels.find(candidate => close && intervalOverlapDuration(
      { start: start.time, end: close.time }, candidate,
    ) > 0);
    return {
      index,
      onset: start.time,
      onsetLatency: label ? Math.max(0, start.time - label.start) : null,
      openDuration: close ? close.time - start.time : null,
      status: close?.k === 'emit' ? 'emitted' : close ? 'discarded' : 'open',
      samples: close?.n ?? start.n ?? 0,
      reason: close?.r ?? null,
    };
  });
}

function floorStats(frames) {
  const floors = frames.map(frame => frame.fl).filter(value => Number.isFinite(value));
  if (floors.length === 0) return { min: null, median: null, max: null };
  const sorted = [...floors].sort((a, b) => a - b);
  return {
    min: sorted[0],
    median: median(sorted),
    max: sorted.at(-1),
  };
}

export function compareTelemetry(recordedFrames, replayFrames) {
  let mismatchCount = 0;
  let fieldMismatchCount = 0;
  let firstDivergence = null;
  const count = Math.max(recordedFrames.length, replayFrames.length);
  for (let index = 0; index < count; index += 1) {
    const expected = recordedFrames[index];
    const actual = replayFrames[index];
    const fields = DIVERGENCE_FIELDS.filter(field => expected?.[field] !== actual?.[field]);
    if (fields.length > 0) {
      mismatchCount += 1;
      fieldMismatchCount += fields.length;
      firstDivergence ??= {
        frame: index,
        seq: expected?.q ?? actual?.q ?? index,
        fields,
        expected: expected ? Object.fromEntries(fields.map(field => [field, expected[field]])) : null,
        actual: actual ? Object.fromEntries(fields.map(field => [field, actual[field]])) : null,
      };
    }
  }
  return { mismatchCount, fieldMismatchCount, firstDivergence };
}

function makeTimelineFrame(record, time) {
  return { ...record, time };
}

export function replaySession(session, configInput = session.config, {
  fromWav = null,
  labels = [],
  compare = true,
} = {}) {
  const normalized = normalizeConfig(
    session.configIsTelemetry && configInput === session.config
      ? rawConfigFromTelemetry(configInput)
      : configInput,
  );
  const sourceFrames = fromWav
    ? framesFromWav(fromWav, session.frames, normalized.config)
    : session.frames.map(frame => ({ ...frame }));
  const generatedFrames = [];
  const generatedEvents = [];
  let time = 0;
  let eventTime = 0;
  const harness = makeRecorderHarness({
    ...harnessOptions(normalized),
    onFrame: record => generatedFrames.push(makeTimelineFrame(record, eventTime)),
    onEvent: event => generatedEvents.push({ ...event, time: eventTime }),
  });
  for (const source of sourceFrames) {
    const duration = asFiniteNumber(source.dt, 'frame dt');
    eventTime = time + duration;
    harness.drive(asFiniteNumber(source.db, 'frame db'), duration);
    time = eventTime;
  }
  if (session.events.some(event => event.k === 'stop_flush')) {
    eventTime = time;
    harness.flush();
  }
  eventTime = time;
  harness.end();

  const openIntervals = buildOpenIntervals(generatedFrames, generatedEvents, time);
  const labelMetrics = computeLabelMetrics(openIntervals, labels);
  const emitted = generatedEvents.filter(event => event.k === 'emit');
  const metrics = {
    sessionDurationSeconds: time,
    utteranceCount: generatedEvents.filter(event => event.k === 'start_utterance').length,
    totalOpenSeconds: openIntervals.reduce((sum, interval) => sum + interval.end - interval.start, 0),
    falseOpenSeconds: labelMetrics.falseOpenSeconds,
    missedSpeechSeconds: labelMetrics.missedSpeechSeconds,
    chunkCount: emitted.length,
    meanOnsetLatencySeconds: labelMetrics.meanOnsetLatencySeconds,
  };
  const divergence = compare && !fromWav
    ? compareTelemetry(session.frames, generatedFrames)
    : null;
  return {
    config: normalized.config,
    frames: generatedFrames,
    events: generatedEvents,
    openIntervals,
    utterances: utteranceReport(generatedEvents, labels),
    metrics,
    divergence,
    floorStats: floorStats(generatedFrames),
    thresholdsAtEnd: generatedFrames.length === 0 ? null : {
      strong: generatedFrames.at(-1).th,
      continuation: generatedFrames.at(-1).ct,
      silence: generatedFrames.at(-1).st,
    },
    audioDbDeltaMean: fromWav && session.frames.length > 0 && sourceFrames.length > 0
      ? session.frames.slice(0, sourceFrames.length)
        .reduce((sum, frame, index) => sum + Math.abs(frame.db - sourceFrames[index].db), 0)
        / Math.min(session.frames.length, sourceFrames.length)
      : null,
  };
}

function formatNumber(value, digits = 2) {
  return value === null || value === undefined || !Number.isFinite(value)
    ? 'n/a'
    : value.toFixed(digits);
}

function formatMilliseconds(value) {
  return formatNumber(value === null || value === undefined ? null : value * 1000);
}

function configLabel(config, keys) {
  return keys.map(key => `${key}=${String(config[key])}`).join(',');
}

function printDefaultReport(result) {
  const { metrics, floorStats: floors, thresholdsAtEnd: thresholds } = result;
  console.log('=== VAD replay ===');
  console.log(`Session duration: ${formatNumber(metrics.sessionDurationSeconds)} s`);
  console.log(`Frames: ${result.frames.length}`);
  console.log(`Utterances: ${metrics.utteranceCount}  chunks: ${metrics.chunkCount}`);
  console.log(`Open time: ${formatNumber(metrics.totalOpenSeconds)} s`);
  console.log(`False-open time: ${formatNumber(metrics.falseOpenSeconds)} s`);
  console.log(`Missed-speech time: ${formatNumber(metrics.missedSpeechSeconds)} s`);
  console.log(`Mean onset latency: ${formatMilliseconds(metrics.meanOnsetLatencySeconds)} ms`);
  if (result.audioDbDeltaMean !== null) console.log(`Mean |Δdb| from WAV: ${formatNumber(result.audioDbDeltaMean)} dB`);
  console.log(`Floor dB min/median/max: ${formatNumber(floors.min)} / ${formatNumber(floors.median)} / ${formatNumber(floors.max)}`);
  console.log(`End thresholds dB strong/continuing/silence: ${formatNumber(thresholds?.strong)} / ${formatNumber(thresholds?.continuation)} / ${formatNumber(thresholds?.silence)}`);
  console.log('');
  if (result.utterances.length === 0) {
    console.log('Utterances: none');
  } else {
    console.log('Utterances:');
    for (const utterance of result.utterances) {
      console.log(`  #${utterance.index + 1} onset=${formatNumber(utterance.onset)}s latency=${formatMilliseconds(utterance.onsetLatency)}ms open=${formatNumber(utterance.openDuration)}s ${utterance.status} samples=${utterance.samples}`);
    }
  }
  if (result.divergence) {
    const first = result.divergence.firstDivergence;
    console.log('');
    console.log(`Divergence: ${result.divergence.mismatchCount} frames, ${result.divergence.fieldMismatchCount} fields`);
    if (first) console.log(`First divergence: frame ${first.frame} (seq ${first.seq}), ${first.fields.join(', ')}`);
    else console.log('First divergence: none');
  }
}

function printSweepTable(results) {
  const headings = ['config', 'utterances', 'open(s)', 'false(s)', 'missed(s)', 'chunks', 'onset(ms)'];
  const rows = results.map(result => [
    result.label,
    String(result.replay.metrics.utteranceCount),
    formatNumber(result.replay.metrics.totalOpenSeconds),
    formatNumber(result.replay.metrics.falseOpenSeconds),
    formatNumber(result.replay.metrics.missedSpeechSeconds),
    String(result.replay.metrics.chunkCount),
    formatMilliseconds(result.replay.metrics.meanOnsetLatencySeconds),
  ]);
  const widths = headings.map((heading, index) => Math.max(heading.length, ...rows.map(row => row[index].length)));
  const render = row => row.map((value, index) => index === 0 ? value.padEnd(widths[index]) : value.padStart(widths[index])).join(' | ');
  console.log(render(headings));
  console.log(widths.map(width => '-'.repeat(width)).join('-+-'));
  for (const row of rows) console.log(render(row));
}

function usage() {
  return [
    'Usage: node bin/replay-vad.mjs <session.jsonl> [session.wav] [options]',
    '',
    '  --set k=v                 Override one config value (repeatable)',
    '  --sweep k=v1,v2,...       Sweep one config key (repeatable, cartesian)',
    '  --labels "12.3-15.9,..."  True-speech intervals in seconds',
    '  --from-wav                Recompute frame dB levels from the WAV',
    '  --json out.json           Write the full replay timeline',
  ].join('\n');
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    console.log(usage());
    return;
  }
  validateAssignments(options.set);
  for (const sweep of options.sweep) validateAssignments([sweep]);
  const session = parseSession(fs.readFileSync(path.resolve(options.sessionPath), 'utf8'));
  const baseConfig = applyAssignments(rawConfigFromTelemetry(session.config), options.set);
  const wav = options.fromWav
    ? decodeWav(fs.readFileSync(path.resolve(options.wavPath)))
    : null;
  const configs = expandSweep(baseConfig, options.sweep);
  const results = configs.map(config => ({
    config,
    replay: replaySession(session, config, {
      fromWav: wav,
      labels: options.labels,
      compare: options.set.length === 0 && options.sweep.length === 0,
    }),
    label: configLabel(config, [...options.set.map(item => item.key), ...options.sweep.map(item => item.key)]),
  }));

  if (options.sweep.length > 0) {
    printSweepTable(results);
  } else {
    printDefaultReport(results[0].replay);
  }
  if (options.jsonPath) {
    const payload = options.sweep.length > 0
      ? { session: session.config, runs: results.map(result => ({ config: result.replay.config, ...result.replay })) }
      : { session: session.config, ...results[0].replay };
    fs.writeFileSync(path.resolve(options.jsonPath), `${JSON.stringify(payload, null, 2)}\n`);
    console.log(`Timeline JSON: ${options.jsonPath}`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
