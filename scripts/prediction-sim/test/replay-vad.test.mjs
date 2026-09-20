import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import {
  computeLabelMetrics,
  decodeWav,
  dcCorrectedRMS,
  dbFromSamples,
  expandSweep,
  parseSession,
  replaySession,
} from '../bin/replay-vad.mjs';
import { dbFromRms } from '../lib/vad-gate.mjs';

function serializeRecords(records) {
  return `${records.map(record => JSON.stringify(record)).join('\n')}\n`;
}

function collectSession(frameDbs, options = {}) {
  const records = [];
  const harness = makeRecorderHarness({
    gateConfig: { mode: 'static', staticRms: 0.025 },
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs: 300,
      resumeMs: 120,
      ambiguousRescueMs: 320,
      preRollMs: 100,
    },
    ...options,
    onFrame: record => records.push(record),
    onEvent: record => records.push(record),
  });
  for (const db of frameDbs) harness.drive(db);
  harness.end();
  return parseSession(serializeRecords(records));
}

function adaptiveSession() {
  const config = {
    mode: 'adaptive',
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
    endpointEndEvidenceMs: 70,
    endpointSilenceMs: 300,
    endpointResumeMs: 120,
    endpointAmbiguousRescueMs: 320,
    endpointPreRollMs: 0,
    silenceMs: 300,
    minSpeechMs: 0,
    minChunkMs: 0,
    maxNoiseSec: 6,
    analysisHpfEnabled: false,
    analysisHpfCutoffHz: 100,
  };
  const frames = [];
  const append = (db, count) => {
    for (let index = 0; index < count; index += 1) {
      frames.push({ t: 'f', q: frames.length, dt: 0.01, db });
    }
  };
  append(-20, 100);
  append(-14, 120);
  append(-16, 50);
  append(-10, 40);
  append(-80, 100);
  return { config, frames, events: [{ t: 'ev', k: 'session_start', c: config }] };
}

function makeWav({ audioFormat, channels, sampleRate = 16000, samples }) {
  const bitsPerSample = audioFormat === 3 ? 32 : 16;
  const bytesPerSample = bitsPerSample / 8;
  const blockAlign = channels * bytesPerSample;
  const data = Buffer.alloc(samples.length * blockAlign);
  samples.forEach((frame, frameIndex) => {
    const values = Array.isArray(frame) ? frame : Array(channels).fill(frame);
    for (let channel = 0; channel < channels; channel += 1) {
      const offset = frameIndex * blockAlign + channel * bytesPerSample;
      if (audioFormat === 3) data.writeFloatLE(values[channel], offset);
      else data.writeInt16LE(Math.round(values[channel] * 32768), offset);
    }
  });
  const fmt = Buffer.alloc(16);
  fmt.writeUInt16LE(audioFormat, 0);
  fmt.writeUInt16LE(channels, 2);
  fmt.writeUInt32LE(sampleRate, 4);
  fmt.writeUInt32LE(sampleRate * blockAlign, 8);
  fmt.writeUInt16LE(blockAlign, 12);
  fmt.writeUInt16LE(bitsPerSample, 14);
  const header = Buffer.alloc(12);
  header.write('RIFF', 0, 4, 'ascii');
  header.write('WAVE', 8, 4, 'ascii');
  const fmtHeader = Buffer.alloc(8);
  fmtHeader.write('fmt ', 0, 4, 'ascii');
  fmtHeader.writeUInt32LE(fmt.length, 4);
  const dataHeader = Buffer.alloc(8);
  dataHeader.write('data', 0, 4, 'ascii');
  dataHeader.writeUInt32LE(data.length, 4);
  const result = Buffer.concat([header, fmtHeader, fmt, dataHeader, data]);
  result.writeUInt32LE(result.length - 8, 4);
  return result;
}

describe('VAD replay', () => {
  it('round-trips recorder telemetry with zero divergence', () => {
    const source = collectSession([
      ...Array(20).fill(-80),
      ...Array(30).fill(-20),
      ...Array(50).fill(-80),
    ]);
    const replay = replaySession(source, source.config);

    assert.equal(replay.divergence.mismatchCount, 0);
    assert.equal(replay.divergence.fieldMismatchCount, 0);
    assert.equal(replay.metrics.utteranceCount, 1);
    assert.equal(replay.metrics.chunkCount, 1);
    assert.ok(Math.abs(replay.metrics.sessionDurationSeconds - 1) < 1e-9);
    assert.equal(replay.utterances[0].status, 'emitted');
  });

  it('applies windy-session threshold, silence, and dynamics overrides', () => {
    const session = adaptiveSession();
    const labels = [{ start: 2.7, end: 3.1 }];
    const base = replaySession(session, session.config, { labels });
    const continuation = replaySession(session, {
      ...session.config,
      continuationDeltaDb: 8,
    }, { labels, compare: false });
    const silence = replaySession(session, {
      ...session.config,
      silenceDeltaDb: 5,
    }, { labels, compare: false });
    assert.notDeepEqual(continuation.metrics, base.metrics);
    assert.notDeepEqual(silence.metrics, base.metrics);

    const speechOnly = {
      ...session,
      frames: [
        ...Array.from({ length: 100 }, (_, q) => ({ t: 'f', q, dt: 0.01, db: -20 })),
        ...Array.from({ length: 40 }, (_, index) => ({ t: 'f', q: index + 100, dt: 0.01, db: -10 })),
        ...Array.from({ length: 100 }, (_, index) => ({ t: 'f', q: index + 140, dt: 0.01, db: -80 })),
      ],
    };
    const speechLabels = [{ start: 1, end: 1.4 }];
    const speechBase = replaySession(speechOnly, session.config, { labels: speechLabels });
    const speechSpread = replaySession(speechOnly, {
      ...session.config,
      dynamicsSpreadDb: 24,
    }, { labels: speechLabels, compare: false });
    assert.notDeepEqual(speechSpread.metrics, speechBase.metrics);
  });

  it('expands sweep keys as a cartesian product', () => {
    const configs = expandSweep({ mode: 'adaptive', silenceMs: 700 }, [
      { key: 'strongDeltaDb', values: [8, 10] },
      { key: 'silenceDeltaDb', values: [2, 3, 4] },
    ]);
    assert.equal(configs.length, 6);
    assert.deepEqual(
      configs.map(config => [config.strongDeltaDb, config.silenceDeltaDb]),
      [[8, 2], [8, 3], [8, 4], [10, 2], [10, 3], [10, 4]],
    );
  });

  it('computes false-open and missed-speech interval math', () => {
    const metrics = computeLabelMetrics(
      [{ start: 1, end: 3 }],
      [{ start: 0, end: 2 }, { start: 4, end: 5 }],
    );
    assert.equal(metrics.falseOpenSeconds, 1);
    assert.equal(metrics.missedSpeechSeconds, 2);
    assert.deepEqual(metrics.onsetLatencies, [1, null]);
  });

  it('decodes float32 and PCM16 WAV buffers and mono-mixes channels', () => {
    const floatWav = decodeWav(makeWav({
      audioFormat: 3,
      channels: 1,
      samples: [0.1, 0.2, 0.3],
    }));
    assert.ok(floatWav.samples.every((sample, index) => Math.abs(sample - [0.1, 0.2, 0.3][index]) < 1e-7));

    const pcmWav = decodeWav(makeWav({
      audioFormat: 1,
      channels: 2,
      samples: [[0.25, 0.75], [0.5, -0.5]],
    }));
    assert.ok(Math.abs(pcmWav.samples[0] - 0.5) < 1 / 32768);
    assert.ok(Math.abs(pcmWav.samples[1]) < 1 / 32768);
  });

  it('matches the dc-corrected RMS and dB formulas for a DC-offset signal', () => {
    const signal = [0.15, 0.25, 0.35];
    const expectedRms = Math.sqrt((0.01 + 0 + 0.01) / 3);
    assert.ok(Math.abs(dcCorrectedRMS(signal) - expectedRms) < 1e-12);
    assert.ok(Math.abs(dbFromSamples(signal) - dbFromRms(expectedRms)) < 1e-12);
  });
});
