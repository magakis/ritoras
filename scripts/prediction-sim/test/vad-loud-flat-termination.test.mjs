import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

function activeLoudHarness({
  frameMs = 10,
  endpointSilenceMs = 100,
  endEvidenceMs = 20,
  loudFlatTerminateEnabled = true,
  loudFlatTerminateSeconds = 0.03,
} = {}) {
  const events = [];
  const harness = makeRecorderHarness({
    frameMs,
    endpointSilenceMs,
    endpointConfig: { endEvidenceMs, endpointSilenceMs },
    gateConfig: { loudRegimeEnabled: true },
    recorderConfig: {
      loudFlatTerminateEnabled,
      loudFlatSpreadDb: 2.5,
      loudFlatTerminateSeconds,
    },
    onEvent: event => events.push(event),
  });
  for (let index = 0; index < 300; index += 1) harness.drive(-25);
  harness.gate.floorDb = -25;
  harness.gate.isLoudRegime = true;
  harness.gate.updateFloorTracking = () => {};
  harness.retentionPolicy.clearBuffer(harness.sessionElapsedSamples);
  harness.accumulatorSamples = 0;
  harness.chunkStartSessionSamples = harness.sessionElapsedSamples;
  harness.speechSamples = 0;
  harness.endpoint.state = 'speechActive';
  harness.retentionPolicy.active = true;
  return { harness, events };
}

describe('loud flat-stream termination', () => {
  it('terminates a flat loud drone through the endpoint with one event', () => {
    const { harness, events } = activeLoudHarness();

    for (let index = 0; index < 700; index += 1) harness.drive(-22);

    const terminators = events.filter(event => event.k === 'flat_terminate');
    assert.equal(terminators.length, 1);
    assert.equal(terminators[0].r, 'flat_spread');
    assert.equal(terminators[0].n, 480);
    assert.equal(harness.terminatorActivationCount, 1);
    assert.equal(harness.endpoint.state, 'idle');
    assert.equal(harness.chunkCount, 1);
  });

  it('has no effect on a loud flat signal when disabled', () => {
    const { harness, events } = activeLoudHarness({
      loudFlatTerminateEnabled: false,
      loudFlatTerminateSeconds: 0.03,
    });
    for (let index = 0; index < 100; index += 1) harness.drive(-22);

    assert.equal(harness.loudFlatTerminateEnabled, false);
    assert.equal(harness.terminatorActivationCount, 0);
    assert.equal(events.filter(event => event.k === 'flat_terminate').length, 0);
    assert.equal(harness.endpoint.state, 'speechActive');
  });

  it('resets the flat streak when either spread reaches the threshold', () => {
    const { harness, events } = activeLoudHarness({
      endpointSilenceMs: 5_000,
      endEvidenceMs: 100,
      loudFlatTerminateSeconds: 1,
    });
    for (let index = 0; index < 8; index += 1) harness.drive(-22);
    assert.ok(harness.flatFrameStreakMs > 0);
    assert.equal(harness.flatTerminatorActive, false);

    const dynamicFrame = harness.drive(-10);
    assert.ok(dynamicFrame.output.dynamicsSpreadDb >= harness.loudFlatSpreadDb);
    assert.equal(harness.flatFrameStreakMs, 0);
    assert.equal(harness.flatTerminatorActive, false);
    assert.equal(events.filter(event => event.k === 'flat_terminate').length, 0);
  });

  it('does not terminate speech that continues to have dynamics', () => {
    const { harness, events } = activeLoudHarness({
      frameMs: 100,
      endpointSilenceMs: 3_000,
      endEvidenceMs: 100,
      loudFlatTerminateSeconds: 3,
    });
    for (let index = 0; index < 400; index += 1) {
      harness.gate.process(index % 2 === 0 ? -12 : -18, 0.1);
    }
    for (let index = 0; index < 6_000; index += 1) {
      const frame = harness.drive(index % 2 === 0 ? -12 : -18, 0.1);
      assert.ok(frame.output.dynamicsSpreadDb >= harness.loudFlatSpreadDb);
      assert.ok(frame.output.shortSpreadDb >= harness.loudFlatSpreadDb);
    }

    assert.equal(harness.flatFrameStreakMs, 0);
    assert.equal(harness.terminatorActivationCount, 0);
    assert.equal(events.filter(event => event.k === 'flat_terminate').length, 0);
    assert.ok(harness.chunkCount > 0);
    assert.equal(harness.endpoint.state, 'speechActive');
  });

  it('does not alter quiet-set decisions when the disabled terminator is enabled', () => {
    function trace(enabled) {
      const frames = [];
      const events = [];
      const harness = makeRecorderHarness({
        gateConfig: { loudRegimeEnabled: true },
        recorderConfig: {
          loudFlatTerminateEnabled: enabled,
          loudFlatSpreadDb: 2.5,
          loudFlatTerminateSeconds: 3,
        },
        onFrame: frame => frames.push(frame),
        onEvent: event => events.push(event),
      });
      for (let index = 0; index < 300; index += 1) harness.drive(-52);
      for (let index = 0; index < 120; index += 1) harness.drive(-43);
      harness.flush();
      return {
        frames,
        starts: events.filter(event => event.k === 'start_utterance'),
        emits: events.filter(event => event.k === 'emit'),
        terminators: events.filter(event => event.k === 'flat_terminate'),
      };
    }

    assert.deepStrictEqual(trace(false), trace(true));
  });
});
