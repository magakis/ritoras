#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  dbFromRms,
  makeVadGateConfig,
  VADHighBandRatioAnalyzer,
  VADThresholdGate,
  VAD_WHISPER_HPF_CUTOFF_HZ,
  VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT,
  VAD_WHISPER_MODULATION_SPREAD_DB,
  VAD_WHISPER_CONTEXT_MS,
} from '../lib/vad-gate.mjs';
import {
  makeStreamingEndpointConfig,
  StreamingEndpoint,
} from '../lib/streaming-endpoint.mjs';
import { VADHighPassFilter } from '../lib/vad-hpf.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import { loadVadFixtures } from '../lib/vad-fixtures.mjs';

export const SHIPPING_SESSION_CONFIG = Object.freeze({
  mode: 'adaptive',
  strongDeltaDb: 7,
  absoluteSpeechFloorDb: -50,
  continuationDeltaDb: 4,
  silenceDeltaDb: 3,
  whisperHighPassCutoffHz: VAD_WHISPER_HPF_CUTOFF_HZ,
  whisperHighBandRatioDb: VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT,
  whisperModulationSpreadDb: VAD_WHISPER_MODULATION_SPREAD_DB,
  whisperContextMs: VAD_WHISPER_CONTEXT_MS,
  dynamicsSpreadDb: 9,
  flatSpreadDb: 5,
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
  silenceMs: 700,
  minSpeechMs: 300,
  minChunkMs: 300,
  maxNoiseSec: 6,
  analysisHpfEnabled: false,
  analysisHpfCutoffHz: 100,
  loudRegimeEnabled: true,
  loudRegimeEnterDb: -35,
  loudRegimeExitDb: -38,
  loudRegimeEnterMs: 300,
  loudRegimeExitMs: 1000,
  loudStrongDeltaDb: 7,
  loudContinuationDeltaDb: 3,
  loudSilenceDeltaDb: 2,
  loudDynamicsSpreadDb: 9,
  loudRiseDbPerSec: 12,
  quietRiseCapAppliesToAmbiguous: false,
  quietRiseCapWitnessDb: 3.0,
  quietContinuationRiseCapDbPerSec: 12.0,
  slowOnsetEnabled: false,
  slowOnsetDeltaDb: 6,
  slowOnsetEvidenceMs: 400,
  slowOnsetWindowSeconds: 1.5,
  loudFlatTerminateEnabled: false,
  loudFlatSpreadDb: 2.5,
  loudFlatTerminateSeconds: 3,
});

export const DEFAULT_SESSION_CONFIG = Object.freeze({
  ...SHIPPING_SESSION_CONFIG,
  mode: 'static',
});

const PCM16_WAV_KNOWN_DIVERGENCE = Object.freeze({
  id: 'KD-3',
  cause: "replay source WAV is a Float32→PCM16 round-toward-zero quantization of the VAD's "
    + 'unquantized analysis input; near-threshold whisper frames can shift ~0.1–0.6 dB and flip '
    + 'evidence classes; decision-parity mismatches attributable to this are expected on knife-edge sessions',
  attributionHeuristic: 'KD-3 mismatch tags are heuristic: the decision frame must be within 1.0 dB '
    + 'of its strong or silence threshold; proximity does not prove causation.',
  cascadeAttributionRule: 'aggregate count differences inherit KD-3 when the session shows KD-3 '
    + 'evidence flips and no other unattributed mismatches — count differences are the downstream '
    + 'cascade of near-threshold flips changing emit boundaries',
});

export function mergeSessionConfig(overrides = {}) {
  const supplied = overrides ?? {};
  const config = { ...DEFAULT_SESSION_CONFIG, ...supplied };
  if (Object.hasOwn(supplied, 'endpointSilenceMs')) {
    config.silenceMs = supplied.endpointSilenceMs;
  } else if (Object.hasOwn(supplied, 'silenceMs')) {
    config.endpointSilenceMs = supplied.silenceMs;
  }
  return config;
}

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
    onlyFixtures: false,
    sample: null,
    seed: 1,
    stopOnFirstFail: false,
    jsonPath: null,
    labelsFile: null,
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
    if (argument === '--only-fixtures') {
      options.onlyFixtures = true;
      continue;
    }
    if (argument === '--stop-on-first-fail') {
      options.stopOnFirstFail = true;
      continue;
    }
    if (argument === '--sample' || argument === '--seed') {
      const value = argv[++index];
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${argument} requires an integer`);
      }
      const number = Number(value);
      if (!Number.isSafeInteger(number) || number < 0) {
        throw new Error(`${argument} requires a non-negative safe integer`);
      }
      if (argument === '--sample') {
        if (number === 0) throw new Error('--sample must be greater than zero');
        options.sample = number;
      } else {
        options.seed = number;
      }
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
    if (argument === '--labels' || argument === '--json' || argument === '--labels-file') {
      const value = argv[++index];
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${argument} requires a value`);
      }
      if (argument === '--labels') options.labels = parseLabels(value);
      else if (argument === '--labels-file') options.labelsFile = value;
      else options.jsonPath = value;
      continue;
    }
    throw new Error(`unknown option: ${argument}`);
  }

  if (options.onlyFixtures) {
    if (options.fromWav) throw new Error('--from-wav cannot be combined with --only-fixtures');
    if (positional.length > 0) throw new Error('--only-fixtures does not take positional paths');
  } else if (options.fromWav) {
    const telemetryFirst = /\.(?:jsonl?|ndjson)$/i.test(positional[0] ?? '');
    const wavSecond = /\.wav$/i.test(positional[1] ?? '');
    const legacyOrder = telemetryFirst || wavSecond;
    options.wavPath = positional[legacyOrder ? 1 : 0] ?? null;
    options.sessionPath = positional[legacyOrder ? 0 : 1] ?? null;
    if (positional.length > 2) throw new Error('expected WAV path and optional session JSONL path');
    if (!options.wavPath) throw new Error('--from-wav requires a WAV path');
  } else {
    options.sessionPath = positional[0] ?? null;
    options.wavPath = positional[1] ?? null;
    if (positional.length > 2) throw new Error('expected one JSONL path and one optional WAV path');
    if (!options.help && options.sessionPath === null) throw new Error('missing session JSONL path');
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
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    payload = null;
  }
  if (payload && typeof payload === 'object'
    && Array.isArray(payload.frames) && Array.isArray(payload.events)) {
    const events = payload.events.map(event => ({ ...event, t: 'ev' }));
    const frames = payload.frames.map(frame => ({ ...frame, t: 'f' }));
    const config = payload.vad_config
      ?? payload.config
      ?? events.find(event => event.k === 'session_start')?.c
      ?? null;
    const session = {
      frames,
      events,
      config: mergeSessionConfig(config ?? {}),
      summary: payload.summary ?? null,
    };
    Object.defineProperty(session, 'configIsTelemetry', {
      value: config !== null,
      enumerable: false,
    });
    return session;
  }

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
    config: mergeSessionConfig(config ?? {}),
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
  const raw = mergeSessionConfig(rawConfig);
  if (!['static', 'adaptive'].includes(raw.mode)) {
    throw new Error(`mode must be static or adaptive; got ${raw.mode}`);
  }

  const gateConfig = makeVadGateConfig({
    mode: raw.mode,
    adaptiveDeltaDb: asFiniteNumber(raw.strongDeltaDb, 'strongDeltaDb'),
    adaptiveAbsoluteSpeechFloorDb: asFiniteNumber(
      raw.absoluteSpeechFloorDb,
      'absoluteSpeechFloorDb',
    ),
    adaptiveContinuationDeltaDb: asFiniteNumber(raw.continuationDeltaDb, 'continuationDeltaDb'),
    adaptiveSilenceDeltaDb: asFiniteNumber(raw.silenceDeltaDb, 'silenceDeltaDb'),
    adaptiveDynamicsSpreadDb: asFiniteNumber(raw.dynamicsSpreadDb, 'dynamicsSpreadDb'),
    adaptiveFlatSpreadDb: asFiniteNumber(raw.flatSpreadDb, 'flatSpreadDb'),
    adaptiveDynamicsEnabled: Boolean(raw.dynamicsEnabled),
    adaptiveStaleFloorSeconds: asFiniteNumber(raw.staleFloorSeconds, 'staleFloorSeconds'),
    adaptiveFallTauSeconds: asFiniteNumber(raw.fallTauSeconds, 'fallTauSeconds'),
    adaptiveRiseSpeedMultiplier: asFiniteNumber(raw.riseMultiplier, 'riseMultiplier'),
    whisperHighBandRatioDb: asFiniteNumber(
      raw.whisperHighBandRatioDb,
      'whisperHighBandRatioDb',
    ),
    whisperModulationSpreadDb: asFiniteNumber(
      raw.whisperModulationSpreadDb,
      'whisperModulationSpreadDb',
    ),
    whisperContextMs: asFiniteNumber(raw.whisperContextMs, 'whisperContextMs'),
    loudRegimeEnabled: Boolean(raw.loudRegimeEnabled),
    loudRegimeEnterDb: asFiniteNumber(raw.loudRegimeEnterDb, 'loudRegimeEnterDb'),
    loudRegimeExitDb: asFiniteNumber(raw.loudRegimeExitDb, 'loudRegimeExitDb'),
    loudRegimeEnterMs: asFiniteNumber(raw.loudRegimeEnterMs, 'loudRegimeEnterMs'),
    loudRegimeExitMs: asFiniteNumber(raw.loudRegimeExitMs, 'loudRegimeExitMs'),
    loudStrongDeltaDb: asFiniteNumber(raw.loudStrongDeltaDb, 'loudStrongDeltaDb'),
    loudContinuationDeltaDb: asFiniteNumber(raw.loudContinuationDeltaDb, 'loudContinuationDeltaDb'),
    loudSilenceDeltaDb: asFiniteNumber(raw.loudSilenceDeltaDb, 'loudSilenceDeltaDb'),
    loudDynamicsSpreadDb: asFiniteNumber(raw.loudDynamicsSpreadDb, 'loudDynamicsSpreadDb'),
    loudRiseDbPerSec: asFiniteNumber(raw.loudRiseDbPerSec, 'loudRiseDbPerSec'),
    quietContinuationRiseCapDbPerSec: asFiniteNumber(
      raw.quietContinuationRiseCapDbPerSec,
      'quietContinuationRiseCapDbPerSec',
    ),
  });
  const gate = new VADThresholdGate(gateConfig);
  const endpointSilenceMs = asFiniteNumber(raw.endpointSilenceMs, 'endpointSilenceMs');
  const endpoint = new StreamingEndpoint(makeStreamingEndpointConfig({
    onsetMs: asFiniteNumber(raw.endpointOnsetMs, 'endpointOnsetMs'),
    endEvidenceMs: asFiniteNumber(raw.endpointEndEvidenceMs, 'endpointEndEvidenceMs'),
    endpointSilenceMs,
    resumeMs: asFiniteNumber(raw.endpointResumeMs, 'endpointResumeMs'),
    ambiguousRescueMs: asFiniteNumber(raw.endpointAmbiguousRescueMs, 'endpointAmbiguousRescueMs'),
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
    loudDynamicsSpreadDb: gate.config.loudDynamicsSpreadDb,
    flatSpreadDb: gate.effectiveFlatSpreadDb,
    dynamicsEnabled: gate.config.adaptiveDynamicsEnabled,
    staleFloorSeconds: gate.effectiveStaleFloorSeconds,
    fallTauSeconds: gate.effectiveFallTauSeconds,
    riseMultiplier: gate.effectiveRiseSpeedMultiplier,
    whisperHighPassCutoffHz: asFiniteNumber(
      raw.whisperHighPassCutoffHz,
      'whisperHighPassCutoffHz',
    ),
    whisperHighBandRatioDb: gate.effectiveWhisperHighBandRatioDb,
    whisperModulationSpreadDb: gate.config.whisperModulationSpreadDb,
    whisperContextMs: gate.config.whisperContextMs,
    endpointMachineEnabled: Boolean(raw.endpointMachineEnabled),
    endpointOnsetMs: endpoint.configuration.onsetSamples / 16,
    endpointEndEvidenceMs: endpoint.configuration.endEvidenceSamples / 16,
    endpointSilenceMs: endpoint.configuration.endpointSilenceSamples / 16,
    endpointResumeMs: endpoint.configuration.resumeSamples / 16,
    endpointAmbiguousRescueMs: endpoint.configuration.ambiguousRescueSamples / 16,
    silenceMs: endpoint.configuration.endpointSilenceSamples / 16,
    minSpeechMs: minimum('minSpeechMs') / 16,
    minChunkMs: minimum('minChunkMs') / 16,
    maxNoiseSec: maxNoiseSamples / 16000,
    loudFlatTerminateEnabled: Boolean(raw.loudFlatTerminateEnabled),
    loudFlatSpreadDb: asFiniteNumber(raw.loudFlatSpreadDb, 'loudFlatSpreadDb'),
    loudFlatTerminateSeconds: asFiniteNumber(raw.loudFlatTerminateSeconds, 'loudFlatTerminateSeconds'),
    quietRiseCapAppliesToAmbiguous: Boolean(raw.quietRiseCapAppliesToAmbiguous),
    quietRiseCapWitnessDb: asFiniteNumber(raw.quietRiseCapWitnessDb, 'quietRiseCapWitnessDb'),
    slowOnsetEnabled: Boolean(raw.slowOnsetEnabled),
    slowOnsetDeltaDb: asFiniteNumber(raw.slowOnsetDeltaDb, 'slowOnsetDeltaDb'),
    slowOnsetEvidenceMs: asFiniteNumber(raw.slowOnsetEvidenceMs, 'slowOnsetEvidenceMs'),
    slowOnsetWindowSeconds: asFiniteNumber(
      raw.slowOnsetWindowSeconds,
      'slowOnsetWindowSeconds',
    ),
  };
  return { config: normalized, endpoint, gateConfig, minSpeechSamples: minimum('minSpeechMs'), minChunkSamples: minimum('minChunkMs'), maxNoiseSamples, recorderConfig: {
    loudFlatTerminateEnabled: normalized.loudFlatTerminateEnabled,
    loudFlatSpreadDb: normalized.loudFlatSpreadDb,
    loudFlatTerminateSeconds: normalized.loudFlatTerminateSeconds,
    quietRiseCapAppliesToAmbiguous: normalized.quietRiseCapAppliesToAmbiguous,
    quietRiseCapWitnessDb: normalized.quietRiseCapWitnessDb,
    slowOnsetEnabled: normalized.slowOnsetEnabled,
    slowOnsetDeltaDb: normalized.slowOnsetDeltaDb,
    slowOnsetEvidenceMs: normalized.slowOnsetEvidenceMs,
    slowOnsetWindowSeconds: normalized.slowOnsetWindowSeconds,
  } };
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
    recorderConfig: normalized.recorderConfig,
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

function sourceStartValue(record) {
  return record.sourceStartSample ?? record.srcStartSample ?? record.src0;
}

function sourceEndValue(record) {
  return record.sourceEndSample ?? record.srcEndSample ?? record.src1;
}

export function framesFromWav(wav, telemetryFrames = [], config = DEFAULT_SESSION_CONFIG) {
  const hasTelemetryFrames = telemetryFrames.length > 0;
  if (hasTelemetryFrames && wav.sampleRate !== 16_000) {
    throw new Error('session telemetry source coordinates require a 16 kHz WAV');
  }
  const frameDuration = hasTelemetryFrames
    ? null
    : 0.01;
  const filter = config.analysisHpfEnabled
    ? new VADHighPassFilter({ cutoffHz: asFiniteNumber(config.analysisHpfCutoffHz, 'analysisHpfCutoffHz') })
    : null;
  const witness = new VADHighBandRatioAnalyzer({
    cutoffHz: asFiniteNumber(config.whisperHighPassCutoffHz, 'whisperHighPassCutoffHz'),
    sampleRate: wav.sampleRate,
  });
  const frames = [];
  let sequentialSampleStart = 0;
  let previousSequence = null;
  let frameIndex = 0;
  while (hasTelemetryFrames ? frameIndex < telemetryFrames.length : sequentialSampleStart < wav.samples.length) {
    const source = hasTelemetryFrames ? telemetryFrames[frameIndex] : null;
    const duration = hasTelemetryFrames
      ? asFiniteNumber(source.dt, 'frame dt')
      : frameDuration;
    const sampleCount = Math.max(1, Math.round(duration * wav.sampleRate));
    const explicitStart = source ? sourceStartValue(source) : undefined;
    const explicitEnd = source ? sourceEndValue(source) : undefined;
    const hasExplicitRange = Number.isInteger(explicitStart) && Number.isInteger(explicitEnd);
    const sequence = Number.isInteger(source?.q) ? source.q : null;
    const sourceStartSample = hasExplicitRange
      ? explicitStart
      : sequence !== null && previousSequence !== null && sequence !== previousSequence + 1
        ? Math.round(sequence * sampleCount)
        : sequentialSampleStart;
    const sourceEndSample = hasExplicitRange
      ? explicitEnd
      : Math.min(sourceStartSample + sampleCount, wav.samples.length);
    if (sourceStartSample < 0 || sourceEndSample <= sourceStartSample
      || sourceEndSample > wav.samples.length) {
      throw new Error(`frame ${source?.q ?? frameIndex} source range exceeds WAV sample data`);
    }

    if (sourceStartSample > sequentialSampleStart) {
      const skipped = Array.from(wav.samples.slice(sequentialSampleStart, sourceStartSample));
      const skippedAnalysis = filter ? filter.process(skipped) : skipped;
      witness.process(skippedAnalysis, dcCorrectedRMS(skippedAnalysis));
    }
    const raw = Array.from(wav.samples.slice(sourceStartSample, sourceEndSample));
    const analysis = filter ? filter.process(raw) : raw;
    const frame = source ? { ...source } : { t: 'f', q: frameIndex };
    frame.dt = raw.length / wav.sampleRate;
    frame.db = dbFromSamples(analysis);
    frame.hbr = witness.process(analysis, dcCorrectedRMS(analysis));
    frame.sourceStartSample = sourceStartSample;
    frame.sourceEndSample = sourceEndSample;
    frames.push(frame);
    sequentialSampleStart = sourceEndSample;
    previousSequence = sequence;
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
  const mismatches = [];
  const count = Math.max(recordedFrames.length, replayFrames.length);
  for (let index = 0; index < count; index += 1) {
    const expected = recordedFrames[index];
    const actual = replayFrames[index];
    const fields = DIVERGENCE_FIELDS.filter(field => expected?.[field] !== actual?.[field]);
    if (fields.length > 0) {
      mismatchCount += 1;
      fieldMismatchCount += fields.length;
      const mismatch = {
        frame: index,
        seq: expected?.q ?? actual?.q ?? index,
        fields,
        expected: expected ? Object.fromEntries(fields.map(field => [field, expected[field]])) : null,
        actual: actual ? Object.fromEntries(fields.map(field => [field, actual[field]])) : null,
      };
      firstDivergence ??= mismatch;
      mismatches.push(mismatch);
    }
  }
  const matchedFrameCount = count - mismatchCount;
  return {
    comparedFrameCount: count,
    matchedFrameCount,
    matchRate: count === 0 ? null : matchedFrameCount / count,
    mismatchCount,
    fieldMismatchCount,
    firstDivergence,
    mismatches,
  };
}

function eventSourceRange(event) {
  const start = sourceStartValue(event);
  const end = sourceEndValue(event);
  if (Number.isInteger(start) && Number.isInteger(end)) {
    return { start, end, estimated: false };
  }
  if (event.k === 'emit' && Number.isFinite(event.s0)) {
    const legacyStart = Math.round(event.s0 * 16);
    const legacyEnd = Number.isFinite(event.s1)
      ? Math.round(event.s1 * 16)
      : legacyStart + (Number.isFinite(event.n) ? event.n : 0);
    return { start: legacyStart, end: legacyEnd, estimated: true };
  }
  return null;
}

function frameSequenceGaps(frames) {
  let gapCount = 0;
  if (Number.isInteger(frames[0]?.q) && frames[0].q > 0) gapCount += frames[0].q;
  for (let index = 1; index < frames.length; index += 1) {
    const previous = frames[index - 1].q;
    const current = frames[index].q;
    if (Number.isInteger(previous) && Number.isInteger(current) && current > previous + 1) {
      gapCount += current - previous - 1;
    }
  }
  return gapCount;
}

function decisionSample(event, sampleRate) {
  if (!event) return null;
  const range = eventSourceRange(event);
  if (range) return range.end;
  if (Number.isFinite(event.time)) return Math.round(event.time * sampleRate);
  if (Number.isFinite(event.timestampMs)) {
    return Math.round((event.timestampMs * sampleRate) / 1000);
  }
  return null;
}

function mismatchIsNearThreshold(expected, actual, replayFrames, sampleRate) {
  const samplePositions = [expected, actual]
    .map(event => decisionSample(event, sampleRate))
    .filter(Number.isInteger);
  return replayFrames.some(frame => {
    const frameStart = sourceStartValue(frame);
    const frameEnd = sourceEndValue(frame);
    if (!Number.isInteger(frameStart) || !Number.isInteger(frameEnd)) return false;
    const isDecisionFrame = samplePositions.some(sample => (
      sample === frameEnd || (sample > frameStart && sample < frameEnd)
    ));
    if (!isDecisionFrame || !Number.isFinite(frame.db)) return false;
    return [frame.th, frame.st].some(threshold => (
      Number.isFinite(threshold) && Math.abs(frame.db - threshold) <= 1.0
    ));
  });
}

function isDecisionCountDifference(mismatch) {
  return mismatch.reason === 'decision count differs';
}

function hasLegacyCoordinateKnownDivergence(mismatch, knownDivergences) {
  return knownDivergences.some(divergence => (
    divergence.decision === mismatch.decision
      && divergence.category === 'legacy_coordinates'
  ));
}

function isAttributedMismatch(mismatch, knownDivergences) {
  return mismatch.kd === PCM16_WAV_KNOWN_DIVERGENCE.id
    || hasLegacyCoordinateKnownDivergence(mismatch, knownDivergences);
}

export function compareDecisionParity(recordedEvents, replayEvents, recordedFrames = [], {
  frameTolerance = 1,
  sampleRate = 16_000,
  retention = null,
  totalFrameCount = null,
  configurationRecorded = true,
  replayFrames = [],
  pcm16Source = false,
} = {}) {
  const isCoverageDecision = event => event.k === 'emit'
    || (event.k === 'discard' && event.r !== 'priming_window');
  const recorded = recordedEvents.filter(isCoverageDecision);
  const replayed = replayEvents.filter(isCoverageDecision);
  const maximumFrameSamples = recordedFrames.reduce((maximum, frame) => {
    const start = sourceStartValue(frame);
    const end = sourceEndValue(frame);
    const samples = Number.isInteger(start) && Number.isInteger(end)
      ? end - start
      : Number.isFinite(frame.dt) ? Math.round(frame.dt * sampleRate) : 0;
    return Math.max(maximum, samples);
  }, 0);
  const toleranceSamples = Math.max(maximumFrameSamples, Math.round(sampleRate * 0.01))
    * frameTolerance;
  const mismatches = [];
  const knownDivergences = [];
  const comparedCount = Math.max(recorded.length, replayed.length);
  let matchedCount = 0;

  if (!configurationRecorded) {
    knownDivergences.push({
      reason: 'session telemetry lacks effective VAD configuration; replay used defaults',
    });
  }
  if (frameSequenceGaps(recordedFrames) > 0) {
    knownDivergences.push({
      reason: 'recorded telemetry omits frame sequence numbers; replay uses only retained frames',
    });
  }
  if (Number(retention?.events_dropped ?? 0) > 0) {
    knownDivergences.push({
      reason: `uploaded telemetry reports ${retention.events_dropped} dropped events`,
    });
  }
  if (Number.isFinite(totalFrameCount) && totalFrameCount > recordedFrames.length) {
    knownDivergences.push({
      reason: `uploaded telemetry retains ${recordedFrames.length} of ${totalFrameCount} frames`,
    });
  }
  if (pcm16Source) knownDivergences.push(PCM16_WAV_KNOWN_DIVERGENCE);

  const recordMismatch = (mismatch, expectedEvent, actualEvent) => {
    if (pcm16Source
      && !isDecisionCountDifference(mismatch)
      && mismatchIsNearThreshold(expectedEvent, actualEvent, replayFrames, sampleRate)) {
      mismatch.kd = PCM16_WAV_KNOWN_DIVERGENCE.id;
    }
    mismatches.push(mismatch);
  };

  for (let index = 0; index < comparedCount; index += 1) {
    const expected = recorded[index];
    const actual = replayed[index];
    if (!expected || !actual) {
      recordMismatch({
        decision: index,
        expected: expected?.k ?? null,
        actual: actual?.k ?? null,
        reason: 'decision count differs',
      }, expected, actual);
      continue;
    }

    const expectedRange = eventSourceRange(expected);
    const actualRange = eventSourceRange(actual);
    if (!expectedRange) {
      knownDivergences.push({
        decision: index,
        category: 'legacy_coordinates',
        reason: `recorded ${expected.k}/${expected.r ?? 'unknown'} lacks source sample coordinates`,
      });
      continue;
    }
    if (expectedRange.estimated) {
      knownDivergences.push({
        decision: index,
        category: 'legacy_coordinates',
        reason: `recorded ${expected.k} range is inferred from legacy millisecond fields`,
      });
    }
    if (!actualRange) {
      recordMismatch({
        decision: index,
        expected: expectedRange,
        actual: null,
        reason: 'replay range missing',
      }, expected, actual);
      continue;
    }
    const startDelta = Math.abs(expectedRange.start - actualRange.start);
    const endDelta = Math.abs(expectedRange.end - actualRange.end);
    const kindMatches = expected.k === actual.k;
    const reasonMatches = (expected.r ?? '') === (actual.r ?? '');
    if (kindMatches && reasonMatches && startDelta <= toleranceSamples && endDelta <= toleranceSamples) {
      matchedCount += 1;
    } else {
      recordMismatch({
        decision: index,
        expected: { kind: expected.k, reason: expected.r ?? null, ...expectedRange },
        actual: { kind: actual.k, reason: actual.r ?? null, ...actualRange },
        startDeltaSamples: startDelta,
        endDeltaSamples: endDelta,
        reason: !kindMatches ? 'decision kind differs'
          : !reasonMatches ? 'decision reason differs' : 'source range exceeds tolerance',
      }, expected, actual);
    }
  }

  const hasKD3EvidenceFlip = mismatches.some(mismatch => (
    !isDecisionCountDifference(mismatch)
      && mismatch.kd === PCM16_WAV_KNOWN_DIVERGENCE.id
  ));
  if (pcm16Source && hasKD3EvidenceFlip) {
    const initiallyAttributed = new Set(mismatches.filter(mismatch => (
      isAttributedMismatch(mismatch, knownDivergences)
    )));
    for (const mismatch of mismatches) {
      if (!isDecisionCountDifference(mismatch)) continue;
      const allOtherMismatchesAttributed = mismatches.every(other => (
        other === mismatch || initiallyAttributed.has(other)
      ));
      if (allOtherMismatchesAttributed) mismatch.kd = PCM16_WAV_KNOWN_DIVERGENCE.id;
    }
  }

  const mismatchCount = mismatches.length;
  return {
    frameTolerance,
    toleranceSamples,
    comparedCount,
    matchedCount,
    mismatchCount,
    knownDivergences,
    mismatches,
    status: mismatchCount > 0 ? 'mismatch'
      : knownDivergences.length > 0 ? 'known_divergence'
        : comparedCount > 0 ? 'matched' : 'no_decisions',
  };
}

function makeTimelineFrame(record, time) {
  return { ...record, time };
}

function primeReplayWarmup(harness, sourceFrames, warmup) {
  if (!warmup) return 0;
  if (harness.gate.config.mode !== 'adaptive' || warmup.endpoint_state !== 'idle'
    || !warmup.after_emission) {
    throw new Error('fixture warmup requires an adaptive post-emission idle state');
  }

  harness.gate.floorDb = asFiniteNumber(warmup.floor_db, 'warmup.floor_db');
  harness.gate.coldStartConverged = warmup.floor_converged;
  harness.gate.adaptiveRefinementComplete = warmup.floor_converged;
  harness.gate.adaptivePrimed = warmup.priming_complete;
  harness.primingComplete = warmup.priming_complete;
  harness.gate.refreshAdaptiveOutput();

  // Warm gate history from real clip-prefix frames, then start an empty recorder after emission.
  let prefixEndSample = 0;
  let prefixFrameCount = 0;
  while (prefixEndSample < warmup.prefix_samples) {
    const frame = sourceFrames[prefixFrameCount];
    if (!frame) throw new Error('fixture warmup prefix extends beyond WAV data');
    const frameStart = sourceStartValue(frame);
    const frameEnd = sourceEndValue(frame);
    if (frameStart !== prefixEndSample || frameEnd > warmup.prefix_samples) {
      throw new Error('fixture warmup prefix must align with complete audio frames');
    }
    const duration = asFiniteNumber(frame.dt, 'warmup frame dt');
    const frameDb = asFiniteNumber(frame.db, 'warmup frame db');
    harness.gate.process(frameDb, duration, {
      highBandRatioDb: Number.isFinite(frame.hbr) ? frame.hbr : null,
      withinUtteranceContext: warmup.within_utterance_context,
    });
    harness.gate.updateFloorTracking(
      frameDb,
      duration,
      false,
      false,
      harness.quietRiseCapAppliesToAmbiguous,
      harness.quietRiseCapWitnessDb,
    );
    prefixEndSample = frameEnd;
    prefixFrameCount += 1;
  }

  harness.endpoint.reset();
  harness.sessionElapsedSamples = prefixEndSample;
  harness.frameSequence = prefixFrameCount;
  harness.previousProcessedFrameDb = sourceFrames[prefixFrameCount - 1]?.db ?? null;
  harness.headLive = false;
  harness.headSamples = 0;
  harness.headSlices.length = 0;
  harness.postHeadPreRollSamples = 0;
  return prefixFrameCount;
}

export function replaySession(session, configInput = session.config, {
  fromWav = null,
  sourceSampleOffset = 0,
  warmup = null,
  labels = [],
  compare = true,
  onFrameDiagnostic = null,
} = {}) {
  const normalized = normalizeConfig(
    session.configIsTelemetry && configInput === session.config
      ? rawConfigFromTelemetry(configInput)
      : configInput,
  );
  const inputFrames = session.frames;
  const recordedFrames = session.recordedFrames ?? inputFrames;
  const sourceFrames = fromWav
    ? framesFromWav(fromWav, inputFrames, normalized.config)
    : inputFrames.map(frame => ({ ...frame }));
  const generatedFrames = [];
  const generatedEvents = [];
  let time = 0;
  let eventTime = 0;
  const harness = makeRecorderHarness({
    ...harnessOptions(normalized),
    onFrame: record => generatedFrames.push(makeTimelineFrame(record, eventTime)),
    onEvent: event => generatedEvents.push({ ...event, time: event.time ?? eventTime }),
  });
  if (warmup && !fromWav) throw new Error('fixture warmup requires WAV input');
  const warmupFrameCount = primeReplayWarmup(harness, sourceFrames, warmup);
  for (const source of sourceFrames.slice(warmupFrameCount)) {
    const duration = asFiniteNumber(source.dt, 'frame dt');
    eventTime = time + duration;
    const frameResult = harness.drive(asFiniteNumber(source.db, 'frame db'), duration, {
      highBandRatioDb: Number.isFinite(source.hbr) ? source.hbr : null,
    });
    if (typeof onFrameDiagnostic === 'function') {
      onFrameDiagnostic({
        frameIndex: source.q ?? generatedFrames.length,
        time: eventTime,
        frame: frameResult.frameRecord,
        diagnostic: frameResult.slowOnsetDiagnostic,
      });
    }
    time = eventTime;
  }
  if (fromWav || session.events.some(event => event.k === 'stop_flush')) {
    eventTime = time;
    harness.flush();
  }
  eventTime = time;
  harness.end();

  if (sourceSampleOffset !== 0) {
    for (const frame of generatedFrames) {
      frame.sourceStartSample += sourceSampleOffset;
      frame.sourceEndSample += sourceSampleOffset;
    }
    for (const event of generatedEvents) {
      if (Number.isInteger(event.sourceStartSample)) event.sourceStartSample += sourceSampleOffset;
      if (Number.isInteger(event.sourceEndSample)) event.sourceEndSample += sourceSampleOffset;
    }
  }

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
    terminatorActivationCount: generatedEvents.filter(event =>
      event.k === 'flat_terminate' || event.k === 'loud_flat_terminate').length,
  };
  const divergence = compare
    ? compareTelemetry(recordedFrames, generatedFrames)
    : null;
  const decisionParity = compare
    ? compareDecisionParity(session.events, generatedEvents, inputFrames, {
      retention: session.summary?.retention,
      totalFrameCount: session.summary?.frame_count,
      configurationRecorded: session.configIsTelemetry === true,
      replayFrames: generatedFrames,
      pcm16Source: fromWav?.audioFormat === 1 && fromWav.bitsPerSample === 16,
    })
    : null;
  const knownDivergences = fromWav?.audioFormat === 1 && fromWav.bitsPerSample === 16
    ? [PCM16_WAV_KNOWN_DIVERGENCE]
    : [];
  return {
    config: normalized.config,
    frames: generatedFrames,
    events: generatedEvents,
    openIntervals,
    utterances: utteranceReport(generatedEvents, labels),
    metrics,
    divergence,
    decisionParity,
    knownDivergences,
    frameSequenceGapCount: frameSequenceGaps(inputFrames),
    frameCoverageOmittedCount: Number.isFinite(session.summary?.frame_count)
      ? Math.max(0, session.summary.frame_count - inputFrames.length)
      : frameSequenceGaps(inputFrames),
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
    const parity = result.divergence.matchRate === null
      ? 'n/a'
      : `${(result.divergence.matchRate * 100).toFixed(2)}%`;
    console.log(
      `Per-frame e/es/d parity: ${result.divergence.matchedFrameCount}/${result.divergence.comparedFrameCount} (${parity})`,
    );
    console.log('');
    console.log(`Divergence: ${result.divergence.mismatchCount} frames, ${result.divergence.fieldMismatchCount} fields`);
    if (first) console.log(`First divergence: frame ${first.frame} (seq ${first.seq}), ${first.fields.join(', ')}`);
    else console.log('First divergence: none');
  }
  if (result.decisionParity) {
    const parity = result.decisionParity;
    console.log('');
    console.log(`Emit/discard parity (±${parity.frameTolerance} frame; ${parity.toleranceSamples} samples): `
      + `${parity.matchedCount}/${parity.comparedCount} verified, status=${parity.status}`);
    for (const divergence of parity.knownDivergences) {
      const label = divergence.id ? ` ${divergence.id}` : '';
      console.log(`Known divergence${label}: ${divergence.cause ?? divergence.reason}`);
    }
    for (const mismatch of parity.mismatches) {
      console.log(`Decision mismatch #${mismatch.decision}: ${mismatch.reason}`);
    }
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

function seededRandom(seed) {
  let state = seed >>> 0;
  if (state === 0) state = 0x6d2b79f5;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

export function selectSample(items, sampleCount, seed = 1) {
  if (sampleCount === null || sampleCount >= items.length) return [...items];
  const candidates = [...items];
  const random = seededRandom(seed);
  for (let index = candidates.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1));
    [candidates[index], candidates[swapIndex]] = [candidates[swapIndex], candidates[index]];
  }
  return candidates.slice(0, sampleCount).sort((left, right) => (
    left.caseId.localeCompare(right.caseId)
  ));
}

function decodeFixtureWav(filePath) {
  const wav = decodeWav(fs.readFileSync(filePath));
  if (wav.audioFormat !== 1 || wav.bitsPerSample !== 16
    || wav.channels !== 1 || wav.sampleRate !== 16_000) {
    throw new Error(`${filePath} must be 16 kHz mono PCM16`);
  }
  return wav;
}

function fixtureReplayConfig(baseConfig, warmup, explicitKeys) {
  const config = { ...baseConfig };
  if (!warmup) return config;

  for (const [configKey, warmupKey] of [
    ['absoluteSpeechFloorDb', 'absolute_speech_floor_db'],
    ['minSpeechMs', 'min_speech_ms'],
    ['minChunkMs', 'min_chunk_ms'],
    ['analysisHpfEnabled', 'analysis_hpf_enabled'],
    ['analysisHpfCutoffHz', 'analysis_hpf_cutoff_hz'],
  ]) {
    if (!explicitKeys.has(configKey) && warmup[warmupKey] !== undefined) {
      config[configKey] = warmup[warmupKey];
    }
  }
  if (!explicitKeys.has('endpointSilenceMs') && !explicitKeys.has('silenceMs')) {
    config.endpointSilenceMs = warmup.endpoint_silence_ms;
    config.silenceMs = warmup.endpoint_silence_ms;
  }
  return config;
}

function replayFixtures(options, baseConfig) {
  const fixtures = selectSample(loadVadFixtures(), options.sample, options.seed);
  if (fixtures.length === 0) {
    console.log(
      'No VAD fixtures found; missing or empty fixtures/vad-cases is allowed in a fresh checkout.',
    );
    return;
  }

  const explicitKeys = new Set([
    ...options.set.map(assignment => assignment.key),
    ...options.sweep.map(sweep => sweep.key),
  ]);
  const runs = [];
  let failures = 0;
  for (const fixture of fixtures) {
    try {
      const wav = decodeFixtureWav(fixture.wavPath);
      const fixtureConfig = fixtureReplayConfig(
        baseConfig,
        fixture.metadata.warmup,
        explicitKeys,
      );
      const configs = expandSweep(fixtureConfig, options.sweep);
      const session = {
        frames: [],
        events: [],
        config: fixtureConfig,
        configIsTelemetry: false,
      };
      for (const config of configs) {
        const replay = replaySession(session, config, {
          fromWav: wav,
          sourceSampleOffset: fixture.metadata.source_start_sample,
          warmup: fixture.metadata.warmup ?? null,
          labels: options.labels,
          compare: false,
        });
        const run = {
          caseId: fixture.caseId,
          kind: fixture.metadata.kind,
          mechanism: fixture.metadata.mechanism,
          sourceStartSample: fixture.metadata.source_start_sample,
          sourceEndSample: fixture.metadata.source_end_sample,
          config: replay.config,
          replay,
        };
        runs.push(run);
        console.log(
          `${fixture.caseId} ${fixture.metadata.kind}/${fixture.metadata.mechanism}: `
          + `${replay.metrics.utteranceCount} utterances, ${replay.metrics.chunkCount} emits, `
          + `${replay.frames.length} frames`,
        );
      }
    } catch (error) {
      failures += 1;
      console.error(`Fixture ${fixture.caseId} failed: ${error.message}`);
      if (options.stopOnFirstFail) break;
    }
  }
  console.log(`Fixtures replayed: ${runs.length}; failed cases: ${failures}; seed: ${options.seed}`);
  if (options.jsonPath) {
    fs.writeFileSync(path.resolve(options.jsonPath), `${JSON.stringify({ runs }, null, 2)}\n`);
    console.log(`Timeline JSON: ${options.jsonPath}`);
  }
  if (failures > 0) process.exitCode = 1;
}

function usage() {
  return [
    'Usage: node bin/replay-vad.mjs <session.jsonl> [session.wav] [options]',
    '       node bin/replay-vad.mjs <audio.wav> --from-wav [options]',
    '',
    '  --set k=v                 Override one config value (repeatable)',
    '  --sweep k=v1,v2,...       Sweep one config key (repeatable, cartesian)',
    '  --labels "12.3-15.9,..."  True-speech intervals in seconds',
    '  --labels-file path.txt     Read candidate speech intervals from a file',
    '  --from-wav                Recompute frame dB levels from the WAV',
    '  --json out.json           Write the full replay timeline',
    '  --only-fixtures           Replay scripts/prediction-sim/fixtures/vad-cases/',
    '  --sample N --seed S       Select N fixture cases reproducibly (seed defaults to 1)',
    '  --stop-on-first-fail      Stop after a parity mismatch or invalid fixture',
  ].join('\n');
}

export function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.help) {
    console.log(usage());
    return;
  }
  if (options.sample !== null && !options.onlyFixtures) {
    throw new Error('--sample requires --only-fixtures');
  }
  validateAssignments(options.set);
  for (const sweep of options.sweep) validateAssignments([sweep]);
  const session = options.sessionPath
    ? parseSession(fs.readFileSync(path.resolve(options.sessionPath), 'utf8'))
    : { frames: [], events: [], config: { ...SHIPPING_SESSION_CONFIG }, configIsTelemetry: false };
  const baseConfig = applyAssignments(rawConfigFromTelemetry(session.config), options.set);
  const wav = options.fromWav
    ? decodeWav(fs.readFileSync(path.resolve(options.wavPath)))
    : null;
  if (options.labelsFile) {
    const labelText = fs.readFileSync(path.resolve(options.labelsFile), 'utf8').trim();
    options.labels = parseLabels(labelText);
  }
  if (options.onlyFixtures) {
    replayFixtures(options, baseConfig);
    return;
  }
  const configs = expandSweep(baseConfig, options.sweep);
  const results = [];
  for (const config of configs) {
    const replay = replaySession(session, config, {
      fromWav: wav,
      labels: options.labels,
      compare: options.set.length === 0 && options.sweep.length === 0,
    });
    results.push({
      config,
      replay,
      label: configLabel(config, [
        ...options.set.map(item => item.key),
        ...options.sweep.map(item => item.key),
      ]),
    });
    const failed = replay.divergence?.mismatchCount > 0
      || replay.decisionParity?.mismatchCount > 0;
    if (options.stopOnFirstFail && failed) break;
  }

  if (options.sweep.length > 0) {
    printSweepTable(results);
  } else {
    printDefaultReport(results[0].replay);
  }
  if (results.some(result => result.replay.divergence?.mismatchCount > 0
    || result.replay.decisionParity?.mismatchCount > 0)) {
    process.exitCode = 1;
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
