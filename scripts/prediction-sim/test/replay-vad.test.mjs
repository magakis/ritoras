import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import {
  computeLabelMetrics,
  decodeWav,
  dcCorrectedRMS,
  dbFromSamples,
  expandSweep,
  parseSession,
  parseArgs,
  normalizeConfig,
  SHIPPING_SESSION_CONFIG,
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
    loudRegimeEnabled: false,
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
  it('keeps an explicit endpoint silence override ahead of the default alias', () => {
    const session = parseSession(serializeRecords([{
      t: 'ev',
      k: 'session_start',
      c: { mode: 'adaptive', endpointSilenceMs: 1900 },
    }]));

    assert.equal(session.config.endpointSilenceMs, 1900);
    assert.equal(session.config.silenceMs, 1900);
    assert.equal(normalizeConfig(session.config).config.endpointSilenceMs, 1900);
    assert.equal(normalizeConfig({ silenceMs: 450 }).config.endpointSilenceMs, 450);
  });

  it('parses the recorded 2026-10-24 session from the fixture JSONL convention', () => {
    const session = parseSession(fs.readFileSync(new URL(
      '../fixtures/vad-telemetry/20261024-124619/session.jsonl',
      import.meta.url,
    ), 'utf8'));

    assert.equal(session.frames.length, 119);
    assert.equal(session.frames[50].q, 50);
    assert.equal(session.frames[50].e, 'continuing');
    assert.equal(session.frames[50].es, 'idle');
    assert.equal(session.frames[50].d, 'none');
    assert.equal(session.config.endpointSilenceMs, 1900);
    assert.equal(session.events.some(event => event.k === 'stop_flush'), true);
  });

  it('retains the inter-utterance gap and the soft frames before the next strong onset', () => {
    const session = parseSession(fs.readFileSync(new URL(
      '../fixtures/vad-telemetry/20261024-124619/session.jsonl',
      import.meta.url,
    ), 'utf8'));
    const replay = replaySession(session, session.config, { compare: false });
    const starts = replay.frames.filter(frame => frame.d === 'start_utterance');
    const emits = replay.events.filter(event => event.k === 'emit');
    const finalizeFrame = replay.frames.find(frame => frame.d === 'finalize_endpoint');
    const firstSoftFrame = replay.frames.find(frame => frame.q === 50);
    const lastSoftFrame = replay.frames.find(frame => frame.q === 55);

    assert.equal(replay.config.endpointSilenceMs, 1900);
    assert.equal(replay.config.silenceMs, 1900);
    assert.equal(starts.length, 2);
    assert.equal(emits.length, 3);
    assert.ok(finalizeFrame);
    assert.ok(firstSoftFrame);
    assert.ok(lastSoftFrame);
    assert.equal(finalizeFrame.q, 41);
    assert.equal(starts[0].q, 6);
    assert.equal(starts[1].q, 56);
    assert.equal(starts[1].e, 'strong');
    assert.equal(emits[0].s0, 0);
    assert.equal(emits[0].s1, 2679.5);
    assert.equal(emits[1].s0, emits[0].s1);
    assert.equal(emits[1].s1, 9996.3125);
    assert.equal(emits[2].r, 'flush');
    assert.equal(emits[2].s0, emits[1].s1);
    assert.equal(emits[2].s1, 11898.8125);
    assert.ok(Math.abs((starts[1].time - starts[1].dt) * 1000 - emits[1].s0 - 2414.4375) < 1);
    assert.ok(emits[1].s0 <= (firstSoftFrame.time - firstSoftFrame.dt) * 1000);
    assert.ok(emits[1].s1 >= lastSoftFrame.time * 1000);
  });

  it('accepts WAV-only invocation and pins shipping session defaults', () => {
    const options = parseArgs(['audio.wav', '--from-wav', '--labels-file', 'speech.txt']);
    assert.strictEqual(options.wavPath, 'audio.wav');
    assert.strictEqual(options.sessionPath, null);
    assert.strictEqual(options.labelsFile, 'speech.txt');
    assert.strictEqual(SHIPPING_SESSION_CONFIG.mode, 'adaptive');
    assert.strictEqual(SHIPPING_SESSION_CONFIG.endpointSilenceMs, 700);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.silenceMs, 700);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.maxNoiseSec, 6);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.minSpeechMs, 300);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.minChunkMs, 300);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.loudRegimeEnabled, true);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.loudStrongDeltaDb, 7);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.loudContinuationDeltaDb, 3);
    assert.strictEqual(SHIPPING_SESSION_CONFIG.loudSilenceDeltaDb, 2);
    assert.strictEqual(Object.hasOwn(SHIPPING_SESSION_CONFIG, 'endpointPreRollMs'), false);
    assert.strictEqual(Object.hasOwn(SHIPPING_SESSION_CONFIG, 'loudLatchMs'), false);
  });
  it('records emitted chunk span and the endpoint state at the emission decision', () => {
    const events = [];
    const harness = makeRecorderHarness({
      gateConfig: { mode: 'static', staticRms: 0.025 },
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 300,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      onEvent: event => events.push(event),
    });
    for (const db of [
      ...Array(20).fill(-80),
      ...Array(30).fill(-20),
      ...Array(50).fill(-80),
    ]) harness.drive(db);

    const emitted = events.find(event => event.k === 'emit');
    assert.ok(emitted !== undefined);
    assert.equal(emitted.es, 'endPending');
    assert.ok(Number.isFinite(emitted.s0));
    assert.ok(Number.isFinite(emitted.s1));
    assert.ok(emitted.s0 >= 0);
    assert.ok(emitted.s1 > emitted.s0);
    assert.ok(Math.abs(emitted.s1 - emitted.s0 - emitted.n / 16) < 1e-9);
  });

  it('records stop-flush span and pre-reset endpoint state on flush events', () => {
    const events = [];
    const harness = makeRecorderHarness({
      gateConfig: { mode: 'static', staticRms: 0.025 },
      endpointConfig: { onsetMs: 70 },
      onEvent: event => events.push(event),
    });
    for (const db of [...Array(20).fill(-80), ...Array(30).fill(-20)]) harness.drive(db);
    harness.flush();

    const stopFlush = events.find(event => event.k === 'stop_flush');
    const emitted = events.find(event => event.k === 'emit');
    assert.ok(stopFlush !== undefined);
    assert.ok(emitted !== undefined);
    assert.equal(stopFlush.es, 'speechActive');
    assert.equal(emitted.es, 'speechActive');
    assert.ok(Number.isFinite(stopFlush.s0));
    assert.ok(Number.isFinite(stopFlush.s1));
    assert.ok(Math.abs(stopFlush.s1 - stopFlush.s0 - stopFlush.n / 16) < 1e-9);
  });

  it('round-trips recorder telemetry with zero divergence', () => {
    const source = collectSession([
      ...Array(20).fill(-80),
      ...Array(30).fill(-20),
      ...Array(50).fill(-80),
    ]);
    const replay = replaySession(source, source.config);

    assert.equal(replay.divergence.mismatchCount, 0);
    assert.equal(replay.divergence.fieldMismatchCount, 0);
    assert.equal(replay.divergence.comparedFrameCount, source.frames.length);
    assert.equal(replay.divergence.matchedFrameCount, source.frames.length);
    assert.equal(replay.divergence.matchRate, 1);
    assert.deepEqual(replay.divergence.mismatches, []);
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
    // Strong frames still initiate the endpoint independently of wind-band evidence.
    assert.deepEqual(continuation.metrics, base.metrics);
    // Strong frames dominate endpoint initiation, so this windy fixture ignores silence-delta changes.
    assert.deepEqual(silence.metrics, base.metrics);

    const quietBase = {
      config: session.config,
      frames: [
        ...Array.from({ length: 100 }, (_, q) => ({ t: 'f', q, dt: 0.01, db: -40 })),
        ...Array.from({ length: 100 }, (_, index) => ({ t: 'f', q: index + 100, dt: 0.01, db: -80 })),
      ],
      events: [],
    };
    const quietWind = {
      ...quietBase,
      frames: [
        ...quietBase.frames.slice(0, 100),
        ...Array.from({ length: 130 }, (_, index) => ({
          t: 'f',
          q: index + 100,
          dt: 0.01,
          db: index % 2 === 0 ? -33 : -34,
        })),
        ...Array.from({ length: 100 }, (_, index) => ({
          t: 'f',
          q: index + 230,
          dt: 0.01,
          db: -80,
        })),
      ],
    };
    const quietBaseReplay = replaySession(quietBase, quietBase.config, { compare: false });
    const quietWindReplay = replaySession(quietWind, quietWind.config, { compare: false });
    assert.ok(quietWindReplay.floorStats.max < -35);
    assert.ok(quietWindReplay.frames.slice(100, 230).every(frame => frame.e === 'continuing'));
    assert.ok(quietWindReplay.metrics.utteranceCount > quietBaseReplay.metrics.utteranceCount);
    assert.ok(quietWindReplay.metrics.chunkCount > quietBaseReplay.metrics.chunkCount);

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
