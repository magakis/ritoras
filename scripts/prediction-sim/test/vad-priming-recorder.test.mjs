import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import { makeVadGateConfig } from '../lib/vad-gate.mjs';

function run(harness, levels) {
  for (const db of levels) harness.drive(db);
}

describe('recorder-layer adaptive VAD priming', () => {
  it('retains audio captured before adaptive priming completes', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 30,
      onEvent: event => events.push(event),
    });
    run(harness, [...Array(14).fill(-70), ...Array(20).fill(-43), ...Array(20).fill(-80)]);
    harness.flush();

    assert.equal(events.some(event => event.r === 'priming_window'), false);
    assert.ok(harness.emittedSampleCount + harness.shedSampleCount
      + harness.tailFloorSampleCount + harness.accumulatorSamples
      === harness.sessionElapsedSamples);
  });

  it('retains frame-zero speech in the first continuous chunk', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 100,
      onEvent: event => events.push(event),
    });
    run(harness, Array.from({ length: 80 }, (_, i) => (i % 8 === 0 ? -42 : -30)));
    run(harness, Array(20).fill(-80));
    const emitted = events.find(event => event.k === 'emit');
    assert.ok(emitted);
    assert.equal(emitted.s0, 0);
  });

  it('keeps gate and endpoint learning bit-identical with recorder priming disabled', () => {
    const enabled = makeRecorderHarness({ frameMs: 10 });
    const disabled = makeRecorderHarness({
      frameMs: 10,
      gateConfig: makeVadGateConfig({ mode: 'adaptive', primingMaximumSeconds: 0 }),
    });
    const sequence = Array.from({ length: 180 }, (_, i) => (i % 9 === 0 ? -45 : -30));
    for (const db of sequence) {
      const left = enabled.drive(db);
      const right = disabled.drive(db);
      assert.equal(left.output.floorDb, right.output.floorDb);
      assert.equal(left.output.thresholdDb, right.output.thresholdDb);
      assert.equal(enabled.gate.speechCeilingDb, disabled.gate.speechCeilingDb);
      assert.equal(enabled.endpoint.state, disabled.endpoint.state);
      assert.equal(enabled.endpoint.utteranceDurationSamples, disabled.endpoint.utteranceDurationSamples);
    }
  });

  it('emits priming completion once and accepts a burst that spans the cap', () => {
    const events = [];
    const harness = makeRecorderHarness({ frameMs: 10, onEvent: event => events.push(event) });
    run(harness, [...Array(30).fill(-70), ...Array(30).fill(-30)]);
    assert.equal(events.filter(event => event.k === 'priming_complete').length, 1);
    assert.ok(harness.accumulatorSamples > 0);
    assert.equal(events.find(event => event.k === 'priming_complete').tm, 450);
  });

  it('records completion before a same-frame endpoint finalize is handled', () => {
    const events = [];
    const frames = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 150,
      minChunkSamples: 100 * 16,
      minSpeechSamples: 100 * 16,
      gateConfig: { adaptiveDynamicsEnabled: false, primingQuietSeedSeconds: 1 },
      onEvent: event => events.push(event),
      onFrame: frame => frames.push(frame),
    });
    run(harness, [...Array(30).fill(-30), ...Array(15).fill(-80)]);
    const completionIndex = events.findIndex(event => event.k === 'priming_complete');
    const emissionIndex = events.findIndex(event => event.k === 'emit');
    assert.ok(completionIndex >= 0);
    assert.ok(emissionIndex > completionIndex, JSON.stringify(events));
    assert.equal(events[completionIndex].r, 'duration_cap');
    assert.equal(events.some(event => event.k === 'discard' && event.r === 'below_minimums'), false);
    assert.ok(events[emissionIndex].n >= 100 * 16);
    const finalizeFrame = frames.find(frame => frame.d === 'finalize_endpoint');
    assert.ok(finalizeFrame);
    assert.equal((finalizeFrame.q + 1) * finalizeFrame.dt * 1_000, events[completionIndex].tm);
    assert.equal(harness.chunkCount, 1);
  });

  it('re-arms priming after a route change during an active utterance', () => {
    const events = [];
    const harness = makeRecorderHarness({ frameMs: 10, onEvent: event => events.push(event) });
    const speech = index => (index % 8 === 0 ? -42 : -30);
    run(harness, Array.from({ length: 80 }, (_, index) => speech(index)));
    assert.equal(harness.primingComplete, true);
    assert.equal(events.filter(event => event.k === 'priming_complete').length, 1);
    const accumulatedBeforeRouteChange = harness.accumulatorSamples;

    harness.resetAfterRouteChange();
    assert.equal(harness.primingComplete, false);
    run(harness, Array.from({ length: 45 }, (_, index) => speech(index)));

    assert.equal(harness.primingComplete, true);
    assert.equal(events.filter(event => event.k === 'priming_complete').length, 2);
    assert.ok(harness.accumulatorSamples > accumulatedBeforeRouteChange);
    assert.notEqual(harness.endpoint.state, 'idle');
  });

  it('keeps gate learning bit-identical when an utterance finalizes inside priming', () => {
    const events = [];
    const frames = [];
    const enabled = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 150,
      minChunkSamples: 0,
      minSpeechSamples: 0,
      gateConfig: { adaptiveDynamicsEnabled: false, primingQuietSeedSeconds: 1 },
      onEvent: event => events.push(event),
      onFrame: frame => frames.push(frame),
    });
    const disabled = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 150,
      minChunkSamples: 0,
      minSpeechSamples: 0,
      gateConfig: makeVadGateConfig({
        mode: 'adaptive',
        adaptiveDynamicsEnabled: false,
        primingMaximumSeconds: 0,
        primingQuietSeedSeconds: 1,
      }),
    });
    for (const db of [...Array(20).fill(-30), ...Array(15).fill(-80)]) {
      const left = enabled.drive(db);
      const right = disabled.drive(db);
      assert.equal(left.output.floorDb, right.output.floorDb);
      assert.equal(left.output.thresholdDb, right.output.thresholdDb);
      assert.equal(enabled.gate.speechCeilingDb, disabled.gate.speechCeilingDb);
      assert.equal(enabled.endpoint.state, disabled.endpoint.state);
    }
    assert.equal(events.filter(event => event.k === 'discard' && event.r === 'priming_window').length, 1,
      JSON.stringify(events));
    assert.equal(frames.at(-1).d, 'finalize_endpoint');
    assert.equal(enabled.primingComplete, false);
    assert.equal(enabled.noteUtteranceEndedValues.length, 1);
    assert.equal(enabled.gate.speechCeilingDb, disabled.gate.speechCeilingDb);
    assert.equal(enabled.utteranceQuietestStrongDb, null);
  });

  it('accounts a stop tail inside priming below the 250 ms floor', () => {
    const events = [];
    const harness = makeRecorderHarness({ frameMs: 10, onEvent: event => events.push(event) });
    run(harness, Array(12).fill(-30));
    harness.flush();
    assert.equal(events.filter(event => event.k === 'emit').length, 0);
    assert.equal(events.find(event => event.k === 'stop_flush')?.r, 'tail_floor');
    assert.ok(events.some(event => event.k === 'discard' && event.r === 'tail_floor'));
  });
});
