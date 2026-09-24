import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  makeVadGateConfig,
  VAD_ABSOLUTE_SPEECH_FLOOR_DB,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const FRAME_MS = 10;
const FRAME_DURATION_S = FRAME_MS / 1000;

describe('adaptive VAD absolute speech guard', () => {
  it('seeds a flat -55 dB room within 0.6 seconds without emitting chunks', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    let seededAtMs = null;

    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-55);
      if (seededAtMs === null && frame.output.floorDb > -70) {
        seededAtMs = (i + 1) * FRAME_MS;
      }
      assert.strictEqual(frame.decision.type, 'none');
    }

    assert.ok(seededAtMs !== null && seededAtMs <= 600);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -55) <= 0.5);
    assert.strictEqual(harness.chunkCount, 0);
  });

  it('seeds loud dynamic ambience from p10 and leaves the absolute guard inert', () => {
    const events = [];
    const harness = makeRecorderHarness({
      endpointSilenceMs: 700,
      onEvent: event => events.push(event),
    });
    let seededAtMs = null;
    let finalFrame = null;
    let maximumDispersionDb = -Infinity;

    for (let i = 0; i < 500; i++) {
      const frameDb = i < 50 ? -25 : (i % 5 === 0 ? -10 : -25);
      finalFrame = harness.drive(frameDb);
      if (seededAtMs === null && finalFrame.output.floorDb > -70) {
        seededAtMs = (i + 1) * FRAME_MS;
      }
      maximumDispersionDb = Math.max(
        maximumDispersionDb,
        finalFrame.output.dynamicsSpreadDb ?? -Infinity,
      );
      if (i < 50) assert.strictEqual(harness.endpoint.state, 'idle');
    }

    assert.ok(seededAtMs !== null && seededAtMs <= 1000);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -25) <= 0.5);
    assert.ok(maximumDispersionDb >= 12);
    assert.ok(finalFrame !== null);
    assert.ok(Math.abs(finalFrame.output.thresholdDb - (-25 + 10)) <= 0.5);
    assert.strictEqual(events.some(event => event.k === 'start_utterance'), false);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('keeps stationary -30 dB ambience chunk-free after its cold-start seed', () => {
    const events = [];
    const minimumSamples = 600 * 16;
    const harness = makeRecorderHarness({
      endpointSilenceMs: 700,
      minSpeechSamples: minimumSamples,
      minChunkSamples: minimumSamples,
      gateConfig: { adaptiveDynamicsEnabled: false },
      onEvent: event => events.push(event),
    });

    for (let i = 0; i < 500; i++) harness.drive(-30);

    assert.strictEqual(harness.gate.snapshot.floorDb, -30);
    assert.ok(-30 < harness.gate.snapshot.floorDb + harness.gate.effectiveAdaptiveDeltaDb);
    const startEvents = events.filter(event => event.k === 'start_utterance');
    const belowMinimumDiscards = events.filter(
      event => event.k === 'discard' && event.r === 'below_minimums',
    );
    if (startEvents.length > 0) assert.ok(belowMinimumDiscards.length >= startEvents.length);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(events.some(event => event.k === 'emit'), false);
  });

  it('captures speech from frame zero in quiet and loud rooms', () => {
    for (const ambientDb of [-65, -45]) {
      const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
      const speechFrames = 150;
      let onsetAtMs = null;

      for (let i = 0; i < speechFrames; i++) {
        const frameDb = i % 8 === 0
          ? (ambientDb > -50 ? ambientDb : -42)
          : -30;
        const frame = harness.drive(frameDb);
        if (frame.decision.type === 'startUtterance' && onsetAtMs === null) {
          onsetAtMs = (i + 1) * FRAME_MS;
        }
      }
      assert.ok(onsetAtMs !== null && onsetAtMs <= 400);

      let finalized = false;
      for (let i = 0; i < 100; i++) {
        if (harness.drive(ambientDb).decision.type === 'finalizeUtterance') {
          finalized = true;
          break;
        }
      }

      assert.strictEqual(finalized, true);
      assert.strictEqual(harness.chunkCount, 1);
      assert.ok(harness.headPrependedAtOnset >= onsetAtMs * 16 - FRAME_MS * 16);
      assert.ok(Math.abs(harness.emittedTotalMs - (speechFrames * FRAME_MS + 700)) <= 50);
      assert.strictEqual(harness.endpoint.state, 'idle');
    }
  });

  it('never derives an adaptive strong threshold below the absolute floor', () => {
    const gate = new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
    gate.floorDb = -80;
    gate.adaptiveRefinementComplete = true;

    const output = gate.process(-80, FRAME_DURATION_S);

    assert.ok(output.thresholdDb >= VAD_ABSOLUTE_SPEECH_FLOOR_DB);
    assert.strictEqual(output.thresholdDb, VAD_ABSOLUTE_SPEECH_FLOOR_DB);
  });
});
