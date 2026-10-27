import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import {
  computeLabelMetrics,
  compareDecisionParity,
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

  it('flags default-based replay when session telemetry has no effective config', () => {
    const session = parseSession(serializeRecords([
      { t: 'f', q: 0, dt: 0.01, db: -80 },
    ]));
    const replay = replaySession(session, session.config);

    assert.equal(session.configIsTelemetry, false);
    assert.ok(replay.decisionParity.knownDivergences.some(item => (
      item.reason.includes('lacks effective VAD configuration')
    )));
  });

  it('reports KD-3 for PCM16 WAV replay and tags near-threshold mismatches', () => {
    const samples = Array.from({ length: 160 }, (_, index) => (
      index % 2 === 0 ? 0.0255 : -0.0255
    ));
    const wav = decodeWav(makeWav({ audioFormat: 1, channels: 1, samples }));
    const config = { ...SHIPPING_SESSION_CONFIG, mode: 'static', analysisHpfEnabled: false };
    const session = {
      frames: [{ t: 'f', q: 0, dt: 0.01, db: -32, sourceStartSample: 0, sourceEndSample: 160 }],
      events: [{
        t: 'ev',
        k: 'emit',
        r: 'endpoint',
        sourceStartSample: 0,
        sourceEndSample: 160,
      }],
      config,
      configIsTelemetry: false,
    };

    const replay = replaySession(session, config, { fromWav: wav });
    const report = JSON.parse(JSON.stringify(replay));
    const divergence = report.knownDivergences.find(item => item.id === 'KD-3');

    assert.ok(divergence);
    assert.match(divergence.cause, /Float32→PCM16 round-toward-zero/);
    assert.match(divergence.attributionHeuristic, /heuristic/i);
    assert.ok(report.decisionParity.knownDivergences.some(item => item.id === 'KD-3'));
    assert.ok(Math.abs(report.frames[0].db - report.frames[0].th) <= 1.0);
    assert.equal(report.decisionParity.mismatches[0].kd, 'KD-3');
  });

  it('cascades KD-3 to count differences only when every other mismatch is attributed', () => {
    const replayFrames = [
      { sourceStartSample: 0, sourceEndSample: 160, db: -32, th: -32, st: -38 },
      { sourceStartSample: 160, sourceEndSample: 320, db: -20, th: -32, st: -38 },
      { sourceStartSample: 320, sourceEndSample: 480, db: -20, th: -32, st: -38 },
      { sourceStartSample: 480, sourceEndSample: 640, db: -20, th: -32, st: -38 },
    ];
    const recordedEvents = [
      { k: 'emit', r: 'original', sourceStartSample: 0, sourceEndSample: 160 },
      { k: 'emit', r: 'legacy', s0: 10, s1: 20 },
      { k: 'emit', r: 'stable', sourceStartSample: 320, sourceEndSample: 480 },
      { k: 'emit', r: 'extra', sourceStartSample: 480, sourceEndSample: 640 },
    ];
    const replayEvents = [
      { k: 'emit', r: 'replayed', sourceStartSample: 0, sourceEndSample: 160 },
      { k: 'emit', r: 'legacy-replayed', sourceStartSample: 180, sourceEndSample: 340 },
      { k: 'emit', r: 'stable', sourceStartSample: 320, sourceEndSample: 480 },
    ];
    const attributed = compareDecisionParity(recordedEvents, replayEvents, [{ dt: 0.01 }], {
      pcm16Source: true,
      replayFrames,
    });
    const countMismatch = attributed.mismatches.find(item => (
      item.reason === 'decision count differs'
    ));

    assert.equal(attributed.mismatches[0].kd, 'KD-3');
    assert.ok(attributed.knownDivergences.some(item => (
      item.decision === 1 && item.category === 'legacy_coordinates'
    )));
    assert.equal(countMismatch.kd, 'KD-3');
    assert.equal(attributed.knownDivergences[0].cascadeAttributionRule.includes(
      'downstream cascade of near-threshold flips',
    ), true);

    const unattributed = compareDecisionParity([
      { k: 'emit', r: 'original', sourceStartSample: 0, sourceEndSample: 160 },
      { k: 'emit', r: 'unexplained', sourceStartSample: 160, sourceEndSample: 320 },
      { k: 'emit', r: 'extra', sourceStartSample: 320, sourceEndSample: 480 },
    ], [
      { k: 'emit', r: 'replayed', sourceStartSample: 0, sourceEndSample: 160 },
      { k: 'emit', r: 'different', sourceStartSample: 160, sourceEndSample: 320 },
    ], [{ dt: 0.01 }], {
      pcm16Source: true,
      replayFrames: [
        ...replayFrames.slice(0, 2),
        { ...replayFrames[2], db: -32 },
      ],
    });
    const unexplainedCountMismatch = unattributed.mismatches.find(item => (
      item.reason === 'decision count differs'
    ));

    assert.equal(unattributed.mismatches[0].kd, 'KD-3');
    assert.equal(unattributed.mismatches[1].kd, undefined);
    assert.equal(unexplainedCountMismatch.kd, undefined);

    const noKd3Evidence = compareDecisionParity([
      { k: 'emit', r: 'extra', sourceStartSample: 0, sourceEndSample: 160 },
    ], [], [{ dt: 0.01 }], {
      pcm16Source: true,
      replayFrames: [{
        sourceStartSample: 0,
        sourceEndSample: 160,
        db: -20,
        th: -32,
        st: -38,
      }],
    });

    assert.equal(noKd3Evidence.mismatches[0].reason, 'decision count differs');
    assert.equal(noKd3Evidence.mismatches[0].kd, undefined);
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
    assert.equal(replay.decisionParity.status, 'matched');
    assert.equal(replay.decisionParity.mismatchCount, 0);
    assert.equal(replay.metrics.utteranceCount, 1);
    assert.equal(replay.metrics.chunkCount, 1);
    assert.ok(Math.abs(replay.metrics.sessionDurationSeconds - 1) < 1e-9);
    assert.equal(replay.utterances[0].status, 'emitted');
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
