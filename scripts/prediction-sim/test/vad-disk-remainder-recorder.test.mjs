import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseSession, replaySession } from '../bin/replay-vad.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const MAX_RECOVERY_CHUNK_SAMPLES = 60 * 16_000;

function serializeRecords(records) {
  return `${records.map(record => JSON.stringify(record)).join('\n')}\n`;
}

function assertEmissionCoverage(harness) {
  const spans = [...harness.emittedSourceSpans]
    .sort((left, right) => left.startSample - right.startSample);
  let cursor = 0;
  let coveredSamples = 0;
  for (const span of spans) {
    assert.equal(span.startSample, cursor, 'emitted spans must cover each source sample once');
    assert.ok(span.endSample > span.startSample);
    coveredSamples += span.endSample - span.startSample;
    cursor = span.endSample;
  }
  assert.equal(cursor, harness.sessionElapsedSamples);
  assert.equal(coveredSamples, harness.emittedSampleCount);
  assert.equal(harness.emittedSampleCount, harness.diskWrittenSampleCount);
}

describe('disk-backed stop remainder recovery', () => {
  it('recovers repeated six-second never-onset sheds in chronological bounded chunks', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 100,
      diskRecovery: true,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });

    for (let index = 0; index < 6_000; index += 1) harness.drive(-80);
    harness.flush();

    const remainders = events.filter(event => event.k === 'emit' && event.r === 'disk_remainder');
    assert.ok(harness.retentionShedCount > 2);
    assert.equal(remainders.length, 10);
    assert.ok(remainders.every(event => event.n <= MAX_RECOVERY_CHUNK_SAMPLES));
    assert.deepEqual(remainders.map(event => event.id), Array.from({ length: 10 }, (_, id) => id));
    assertEmissionCoverage(harness);
  });

  it('recovers sheds between mid-session chunks without gaps or duplicate samples', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 100,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 100,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      minChunkSamples: 0,
      minSpeechSamples: 0,
      maxNoiseSamples: 1_600,
      recorderConfig: { postRollSamples: 0 },
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onEvent: event => events.push(event),
    });

    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);
    for (let index = 0; index < 80; index += 1) harness.drive(-80);
    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);
    assert.ok(events.filter(event => event.k === 'emit' && event.r !== 'disk_remainder').length >= 2);
    assert.ok(harness.retentionShedCount > 0);

    harness.flush();

    const remainders = events.filter(event => event.k === 'emit' && event.r === 'disk_remainder');
    assert.ok(remainders.length > 0);
    assert.deepEqual(
      remainders.map(event => event.sourceStartSample),
      [...remainders].map(event => event.sourceStartSample).sort((left, right) => left - right),
    );
    assert.deepEqual(events.filter(event => event.k === 'emit').map(event => event.id),
      events.filter(event => event.k === 'emit').map((_, index) => index));
    assertEmissionCoverage(harness);
  });

  it('emits a sub-250 ms trailing span from disk without a tail-floor discard', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      maxNoiseSamples: 10 * 16_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 20; index += 1) harness.drive(-80);

    harness.flush();

    const emission = events.find(event => event.k === 'emit' && event.r === 'disk_remainder');
    assert.ok(emission);
    assert.equal(emission.n, 3_200);
    assert.ok(events.some(event => event.k === 'stop_flush' && event.r === 'tail_floor'));
    assert.equal(events.some(event => event.k === 'discard' && event.r === 'tail_floor'), false);
    assert.equal(harness.emittedSampleCount, 3_200);
    assertEmissionCoverage(harness);
  });

  it('emits nothing when mid-session chunks already cover the written WAV', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 300,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 300,
      },
      minChunkSamples: 0,
      minSpeechSamples: 0,
      maxNoiseSamples: 10 * 16_000,
      recorderConfig: { postRollSamples: 10 * 16_000 },
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 100 && harness.chunkCount === 0; index += 1) {
      harness.drive(index < 15 ? -20 : -80);
    }
    assert.equal(harness.chunkCount, 1);
    assert.equal(harness.emittedSampleCount, harness.diskWrittenSampleCount);

    harness.flush();

    assert.equal(events.some(event => event.k === 'emit' && event.r === 'disk_remainder'), false);
    assertEmissionCoverage(harness);
  });

  it('keeps accumulator spill accounting intact while recovering bounded spans', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 100,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 700; index += 1) harness.drive(-20);
    assert.equal(harness.spillOccurred, true);

    harness.flush();

    const remainders = events.filter(event => event.k === 'emit' && event.r === 'disk_remainder');
    assert.deepEqual(remainders.map(event => event.n), [MAX_RECOVERY_CHUNK_SAMPLES, 160_000]);
    assert.equal(harness.spilledSampleCount, 0);
    assertEmissionCoverage(harness);
  });

  it('does not recover spilled samples twice after a mid-session emission', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 100,
      endpointSilenceMs: 300,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 300,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      minChunkSamples: 300 * 16,
      minSpeechSamples: 300 * 16,
      recorderConfig: { postRollSamples: 0 },
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 700; index += 1) harness.drive(-20);
    assert.equal(harness.spillOccurred, true);
    for (let index = 0; index < 20 && harness.chunkCount === 0; index += 1) {
      harness.drive(-80);
    }

    const midSessionEmission = events.find(event => event.k === 'emit'
      && event.r !== 'disk_remainder');
    assert.ok(midSessionEmission);
    assert.ok(midSessionEmission.n > 1_048_576);

    harness.flush();

    const firstRemainder = events.find(event => event.k === 'emit'
      && event.r === 'disk_remainder');
    assert.ok(firstRemainder);
    assert.equal(firstRemainder.sourceStartSample, midSessionEmission.sourceEndSample);
    assertEmissionCoverage(harness);
  });

  it('splits a cap-straddling recovery span at a nonzero source offset without gaps', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 100,
      endpointSilenceMs: 100,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 100,
      },
      minChunkSamples: 0,
      minSpeechSamples: 0,
      recorderConfig: { postRollSamples: 0 },
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);
    assert.ok(events.some(event => event.k === 'emit' && event.r !== 'disk_remainder'));
    for (let index = 0; index < 620; index += 1) harness.drive(-80);

    harness.flush();

    const remainders = events.filter(event => event.k === 'emit' && event.r === 'disk_remainder');
    assert.ok(remainders.length >= 2);
    assert.ok(remainders[0].sourceStartSample > 0);
    assert.equal(remainders[0].n, MAX_RECOVERY_CHUNK_SAMPLES);
    for (let index = 1; index < remainders.length; index += 1) {
      assert.equal(remainders[index - 1].sourceEndSample, remainders[index].sourceStartSample);
    }
    assertEmissionCoverage(harness);
  });

  it('replays disk_remainder sessions with matching emission decisions', () => {
    const records = [];
    const harness = makeRecorderHarness({
      frameMs: 100,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      diskRecovery: true,
      onFrame: frame => records.push(frame),
      onEvent: event => records.push(event),
    });
    for (let index = 0; index < 650; index += 1) harness.drive(-80);
    harness.flush();
    harness.end();

    const session = parseSession(serializeRecords(records));
    const replay = replaySession(session, session.config, { compare: true });
    const recordedRemainders = session.events
      .filter(event => event.k === 'emit' && event.r === 'disk_remainder');
    const replayedRemainders = replay.events
      .filter(event => event.k === 'emit' && event.r === 'disk_remainder');

    assert.ok(recordedRemainders.length > 0);
    assert.deepEqual(replayedRemainders.map(event => [
      event.id,
      event.n,
      event.sourceStartSample,
      event.sourceEndSample,
    ]), recordedRemainders.map(event => [
      event.id,
      event.n,
      event.sourceStartSample,
      event.sourceEndSample,
    ]));
    assert.equal(replay.decisionParity.status, 'matched');
    assert.equal(replay.decisionParity.mismatchCount, 0);
    assert.equal(replay.divergence.mismatchCount, 0);
  });

  it('keeps the no-disk stop tail floor unchanged', () => {
    const defaultEvents = [];
    const defaultHarness = makeRecorderHarness({
      frameMs: 10,
      maxNoiseSamples: 10 * 16_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => defaultEvents.push(event),
    });
    for (let index = 0; index < 20; index += 1) defaultHarness.drive(-80);
    defaultHarness.flush();
    assert.equal(defaultEvents.some(event => event.k === 'emit'), false);
    assert.ok(defaultEvents.some(event => event.k === 'discard' && event.r === 'tail_floor'));
  });
});
