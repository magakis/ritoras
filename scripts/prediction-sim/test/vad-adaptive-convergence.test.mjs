import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  makeVadGateConfig as makeVadGateConfigBase,
  VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB,
  VAD_ADAPTIVE_IMPLAUSIBLE_SPEECH_S,
  VAD_SPEECH_CEILING_MARGIN_DB,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import { StreamingEndpoint } from '../lib/streaming-endpoint.mjs';
import { makeRecorderHarness as makeRecorderHarnessBase } from '../lib/recorder-sim.mjs';

const frameDurationMs = 10;
const frameDuration = frameDurationMs / 1000;
const frameSamples = frameDurationMs * 16;

// Convergence mechanics were originally specified against the 10/6 gate.
function makeVadGateConfig(partial = {}) {
  return makeVadGateConfigBase({
    adaptiveDeltaDb: 10,
    adaptiveContinuationDeltaDb: 6,
    ...partial,
  });
}

function makeRecorderHarness(options = {}) {
  return makeRecorderHarnessBase({
    ...options,
    gateConfig: {
      adaptiveDeltaDb: 10,
      adaptiveContinuationDeltaDb: 6,
      ...options.gateConfig,
    },
  });
}

function makeGate(partial = {}) {
  return new VADThresholdGate(makeVadGateConfig({
    mode: 'adaptive',
    ...partial,
  }));
}

function makeEndpoint(endpointSilenceMs = 3000) {
  return new StreamingEndpoint({ endpointSilenceMs });
}

function prefillAmbient(harness, frames = 300, frameDb = -80) {
  harness.gate.floorDb = Math.min(Math.max(frameDb, -80), -20);
  harness.gate.coldStartConverged = true;
  harness.gate.adaptiveRefinementComplete = true;
  for (let i = 0; i < frames; i++) harness.drive(frameDb);
}

function endPendingMappingProbe(seedDb) {
  const harness = makeRecorderHarness();
  for (let i = 0; i < 10; i++) harness.gate.process(seedDb, 0.1);
  harness.gate.floorDb = -70;
  harness.endpoint.state = 'endPending';
  for (let i = 0; i < 4; i++) harness.gate.process(-53, 0.1);
  return harness.drive(-50);
}

function driveFrame(gate, endpoint, frameDb) {
  const output = gate.process(frameDb, frameDuration);
  const reanchorEvent = gate.takePendingReanchorEvent();
  const previousState = endpoint.state;
  const decision = endpoint.process(output.evidence, frameSamples);
  gate.updateFloorTracking(
    frameDb,
    frameDuration,
    previousState === 'idle' && endpoint.state === 'idle',
  );
  return { output, decision, previousState, reanchorEvent };
}

function driveIdleFrame(gate, endpoint, frameDb, trackingDuration = frameDuration) {
  const output = gate.process(frameDb, frameDuration);
  const reanchorEvent = gate.takePendingReanchorEvent();
  const decision = endpoint.process(output.evidence, frameSamples);
  gate.updateFloorTracking(frameDb, trackingDuration, true);
  return { output, decision, reanchorEvent };
}

describe('adaptive VAD convergence', () => {
  it('slews the cold-start fallback toward persistent idle noise', () => {
    const gate = makeGate();
    let previousFloorDb = gate.snapshot.floorDb;

    for (let i = 0; i < 700; i++) {
      const output = gate.process(-65, frameDuration);
      gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, frameDuration, true);
      const floorDb = gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      assert.notStrictEqual(output.evidence, 'strong');
      previousFloorDb = floorDb;
    }

    assert.ok(Math.abs(gate.snapshot.floorDb - -65) <= 0.1);
    assert.strictEqual(gate.coldStartConverged, true);
  });

  it('slew-seeds speech-shaped fallback only below the tracked speech ceiling', () => {
    const gate = makeGate();

    for (let i = 0; i < 60; i++) {
      const frameDb = i % 4 === 0 ? -10 : -25;
      gate.process(frameDb, frameDuration, { withinUtteranceContext: true });
      gate.updateFloorTracking(frameDb, frameDuration, false);
    }

    assert.strictEqual(gate.coldStartSpeechShapedNow, true);
    assert.strictEqual(gate.coldStartConverged, true);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);
    assert.ok(gate.snapshot.floorDb > -80);
    assert.ok(gate.snapshot.floorDb <= -25 - gate.effectiveCeilingMarginDb);
  });

  it('holds the seed and absolute guard when speech starts at cold-start frame zero', () => {
    const gate = makeGate();

    for (let i = 0; i < 400; i++) {
      const output = gate.process(-37, frameDuration, { withinUtteranceContext: true });
      gate.updateFloorTracking(-37, frameDuration, false);
      assert.ok(-37 >= output.continuationThresholdDb);
      assert.strictEqual(output.continuationThresholdDb, -50);
      assert.ok(gate.snapshot.floorDb < -45);
    }

    assert.strictEqual(gate.coldStartConverged, true);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);
  });

  it('slew-limits post-grace cold-start seeding from silence samples', () => {
    const gate = makeGate();
    let previousFloorDb = gate.snapshot.floorDb;

    for (let i = 0; i < 50; i++) {
      gate.process(-78, frameDuration);
      gate.updateFloorTracking(-78, frameDuration, true);
      const floorDb = gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      previousFloorDb = floorDb;
    }

    assert.strictEqual(gate.coldStartConverged, true);
    assert.ok(gate.snapshot.floorDb > -80);
    assert.ok(gate.snapshot.floorDb < -78);
  });

  it('tracks a genuine idle noise rise within the per-frame slew cap', () => {
    const gate = makeGate();
    gate.floorDb = -60;
    gate.coldStartConverged = true;
    gate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 30; i++) {
      gate.process(-60, 0.1);
      gate.updateFloorTracking(-60, 0.1, true);
    }

    const frameDurationSeconds = 0.1;
    const maximumRiseDb = 12 * frameDurationSeconds;
    let previousFloorDb = gate.snapshot.floorDb;
    for (let i = 0; i < 50; i++) {
      gate.process(-58.5, frameDurationSeconds);
      gate.updateFloorTracking(-58.5, frameDurationSeconds, true);
      const floorDb = gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= maximumRiseDb + 1e-9);
      previousFloorDb = floorDb;
    }

    assert.ok(Math.abs(gate.snapshot.floorDb - -58.5) <= 0.1);
  });

  it('adapts cold-start directly into persistent noise without opening speech', () => {
    const harness = makeRecorderHarness({
      gateConfig: { adaptiveAbsoluteSpeechFloorDb: -40 },
    });
    let previousFloorDb = harness.gate.snapshot.floorDb;

    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-45);
      const floorDb = harness.gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      assert.strictEqual(frame.decision.type, 'none');
      assert.strictEqual(harness.endpoint.state, 'idle');
      previousFloorDb = floorDb;
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -45) <= 0.1);
  });

  it('finalizes a speech chunk after persistent non-silence noise becomes floor', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 100; i++) harness.drive(i % 8 === 0 ? -35 : -25);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    let endpointFinalizations = 0;
    let finalNoiseFrame = null;
    for (let i = 0; i < 12_000; i++) {
      const frame = harness.drive(-48);
      finalNoiseFrame = frame;
      if (frame.decision.type === 'finalizeUtterance') endpointFinalizations += 1;
    }

    assert.ok(endpointFinalizations >= 1);
    assert.ok(harness.chunkCount >= 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -48) <= 3);
    assert.strictEqual(finalNoiseFrame.output.evidence, 'silence');
  });

  it('refuses an implausibly high all-frame P10 re-anchor target', () => {
    const harness = makeRecorderHarness({
      gateConfig: {
        adaptiveDeltaDb: 7,
        adaptiveContinuationDeltaDb: 4,
        adaptiveAbsoluteSpeechFloorDb: -50,
      },
    });
    prefillAmbient(harness, 300, -45);
    for (let i = 0; i < 100; i++) harness.drive(i % 8 === 0 ? -20 : -10);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    const maximumReanchorFloor = -20 - harness.gate.effectiveAdaptiveDeltaDb;
    for (let i = 0; i < 12_000; i++) {
      const frame = harness.drive(-22);
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.ok(harness.gate.snapshot.floorDb <= maximumReanchorFloor);
    }

    assert.strictEqual(harness.gate.snapshot.floorDb, -45);
    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('N1/N6: continuous speech emits one chunk only after a real pause', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    prefillAmbient(harness, 300, -53);
    const monologueMs = 60_000;
    let previousFloorDb = harness.gate.snapshot.floorDb;
    let previousAccumulatorSamples = 0;
    let onsetMs = null;

    for (let i = 0; i < monologueMs / frameDurationMs; i++) {
      const frame = harness.drive(i % 8 === 0 ? -35 : -21);
      if (i >= 40) {
        assert.strictEqual(frame.output.evidence, 'strong');
      }
      const floorDb = harness.gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      assert.ok(floorDb <= -35 - harness.gate.effectiveCeilingMarginDb + 1e-9);
      previousFloorDb = floorDb;
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.strictEqual(frame.discarded, false);
      assert.ok(harness.accumulatorSamples >= 0);
      previousAccumulatorSamples = harness.accumulatorSamples;
      if (harness.accumulatorSamples > 0 && onsetMs === null) {
        onsetMs = (i + 1) * frameDurationMs;
      }
    }
    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.ok(harness.accumulatorSamples > 0);

    let pauseMs = 0;
    let finalizeCount = 0;
    let finalized = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-80);
      pauseMs += frameDurationMs;
      if (frame.decision.type === 'finalizeUtterance') {
        finalizeCount += 1;
        finalized = frame;
        break;
      }
    }

    assert.ok(pauseMs >= 700);
    assert.strictEqual(finalizeCount, 1);
    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.ok(onsetMs !== null);
    // The sim now credits actual head fill at first onset, not the old flat 500 ms pre-roll.
    assert.ok(harness.emittedTotalMs > 0);
  });

  it('does not snap the settled floor after sustained speech and a pause', () => {
    const gate = makeGate();
    gate.floorDb = -53;
    gate.coldStartConverged = true;
    gate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 10; i++) gate.process(-53, 0.1);

    let previousFloorDb = gate.snapshot.floorDb;
    for (let i = 0; i < 100; i++) {
      const output = gate.process(-37, 0.108, { withinUtteranceContext: true });
      gate.updateFloorTracking(-37, 0.108, false);
      assert.ok(-37 >= output.continuationThresholdDb);
      assert.ok(output.evidence === 'strong' || output.evidence === 'continuing');
      assert.ok(gate.snapshot.floorDb <= -37 - gate.effectiveCeilingMarginDb);
      assert.ok(gate.snapshot.floorDb - previousFloorDb <= 12 * 0.108 + 1e-9);
      previousFloorDb = gate.snapshot.floorDb;
    }

    const floorBeforePauseDb = gate.snapshot.floorDb;
    gate.process(-80, 0.108, { withinUtteranceContext: true });
    gate.updateFloorTracking(-80, 0.108, false, true);
    assert.ok(gate.snapshot.floorDb - floorBeforePauseDb <= 12 * 0.108 + 1e-9);
  });

  it('keeps the floor unchanged when the silence-only window starves in an utterance', () => {
    const gate = makeGate();
    gate.floorDb = -53;
    gate.coldStartConverged = true;
    gate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 10; i++) gate.process(-53, 0.1);

    for (let i = 0; i < 400; i++) {
      const output = gate.process(-37, frameDuration, { withinUtteranceContext: true });
      gate.updateFloorTracking(-37, frameDuration, false);
      assert.strictEqual(output.evidence === 'strong' || output.evidence === 'continuing', true);
    }

    assert.strictEqual(gate.adaptiveRollingPercentileCache, null);
    assert.strictEqual(gate.snapshot.floorDb, -53);
  });

  it('caps the floor below the utterance level during a loud non-speech burst', () => {
    const gate = makeGate();
    gate.floorDb = -50;
    gate.coldStartConverged = true;
    gate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 300; i++) {
      gate.process(-50, frameDuration);
      gate.updateFloorTracking(-50, frameDuration, true);
    }

    for (let i = 0; i < 20; i++) {
      gate.process(-42, frameDuration, { withinUtteranceContext: true });
      gate.updateFloorTracking(-42, frameDuration, false);
    }
    assert.strictEqual(gate.speechCeilingDb, -42);

    for (let i = 0; i < 400; i++) {
      const output = gate.process(-47.1, frameDuration, { withinUtteranceContext: true });
      gate.updateFloorTracking(-47.1, frameDuration, false, true);
      assert.strictEqual(output.evidence, 'silence');
      assert.ok(gate.snapshot.floorDb <= -42 - gate.effectiveCeilingMarginDb + 1e-9);
    }

    assert.strictEqual(gate.snapshot.floorDb, -50);
  });

  it('ends talk-then-real-silence after endpoint silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    for (let i = 0; i < 1000; i++) {
      const frameDb = i % 8 === 0 ? -35 : -21;
      const { decision, output } = driveFrame(gate, endpoint, frameDb);
      if (i >= 40) {
        assert.strictEqual(output.evidence, 'strong');
      }
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    for (let i = 0; i < 720; i++) {
      const { decision } = driveFrame(gate, endpoint, -80);
      if (decision.type === 'finalizeUtterance') {
        finalizedAtMs = 10_000 + (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.ok(finalizedAtMs !== null);
    assert.ok(finalizedAtMs <= 17_200);
  });

  it('tracks idle non-silence noise without changing the threshold formulas', () => {
    const gate = makeGate();
    let previousFloorDb = gate.snapshot.floorDb;

    for (let i = 0; i < 500; i++) {
      const output = gate.process(-65, frameDuration);
      gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, frameDuration, true);
      const floorDb = gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      assert.notStrictEqual(output.evidence, 'strong');
      previousFloorDb = floorDb;
    }

    assert.strictEqual(gate.snapshot.floorDb, -65);
    assert.strictEqual(gate.snapshot.silenceThresholdDb, -62);
  });

  it('adapts flat idle noise without opening an utterance', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let lastFrame = null;
    let endpointReached = false;
    let previousFloorDb = gate.snapshot.floorDb;

    for (let i = 0; i < 600; i++) {
      lastFrame = driveFrame(gate, endpoint, -25);
      const floorDb = gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      assert.ok(floorDb <= -25 + 1e-9);
      previousFloorDb = floorDb;
      if (lastFrame.decision.type === 'finalizeUtterance') {
        endpointReached = true;
        break;
      }
    }

    assert.ok(lastFrame !== null);
    assert.ok(Math.abs(gate.snapshot.floorDb - -25) <= 0.1, `floor=${gate.snapshot.floorDb}`);
    assert.ok(lastFrame.output.evidence === 'continuing' || lastFrame.output.evidence === 'silence');
    assert.strictEqual(endpointReached, false);
    assert.strictEqual(endpoint.state, 'idle');
    assert.strictEqual(gate.coldStartConverged, true);
  });

  it('N4: adapts idle ambiguous noise after the stale interval without opening endpoint', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    gate.floorDb = -70;
    gate.adaptiveRefinementComplete = true;
    let reanchorEventCount = 0;
    let sawSilence = false;

    for (let i = 0; i < 400; i++) {
      const { output, decision, reanchorEvent } = driveIdleFrame(gate, endpoint, -65);
      if (reanchorEvent) reanchorEventCount += 1;
      if (output.evidence === 'silence') sawSilence = true;
      assert.strictEqual(decision.type, 'none');
    }

    assert.ok(reanchorEventCount > 0);
    assert.ok(Math.abs(gate.snapshot.floorDb - -65) <= 1);
    assert.strictEqual(sawSilence, true);
    assert.strictEqual(endpoint.state, 'idle');
  });

  it('keeps a short recording slew-limited before the stale interval', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();

    for (let i = 0; i < 290; i++) {
      const frameDb = i % 8 === 0 ? -35 : -21;
      const { output, decision } = driveFrame(gate, endpoint, frameDb);
      if (i >= 40) {
        assert.strictEqual(output.evidence, 'strong');
      }
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    assert.ok(gate.snapshot.floorDb > -80);
    assert.ok(gate.snapshot.floorDb < -35 - gate.effectiveCeilingMarginDb);
    assert.strictEqual(gate.coldStartConverged, true);
  });

  it('R3 (c/e): steady non-silence ambient adapts without opening an utterance', () => {
    const harness = makeRecorderHarness();
    let graceSpeechEvidence = false;
    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(-60);
      if (i < 40 && frame.output.evidence === 'strong' && frame.output.isSpeech) {
        graceSpeechEvidence = true;
      }
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.strictEqual(frame.decision.type, 'none');
    }

    assert.strictEqual(graceSpeechEvidence, false);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.gate.snapshot.floorDb, -60);
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('(a): quiet room converges before delayed speech and returns idle mid-session', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    prefillAmbient(harness, 150, -75);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -75) <= 1);

    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? -58 : -45);
    }
    let finalized = false;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.reanchorEventCount, 0);
  });

  it('(e): flat loud room noise adapts without opening an utterance', () => {
    const harness = makeRecorderHarness();
    let previousFloorDb = harness.gate.snapshot.floorDb;
    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(-50);
      assert.strictEqual(frame.decision.type, 'none');
      const floorDb = harness.gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      previousFloorDb = floorDb;
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -50) <= 0.1,
      `floor=${harness.gate.snapshot.floorDb}`);
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.deepStrictEqual(harness.endpoint.forceFinalize('stop'), { type: 'none' });
  });

  it('(b\' / veto): speech-shaped frames do not seed the silence percentile', () => {
    const gate = makeGate();
    let firstStrongAtMs = null;
    let firstShapedNowAtMs = null;
    let sawPreShapedContinuing = false;

    for (let i = 0; i < 40; i++) {
      const frameDb = i % 8 === 0 ? -35 : -25;
      const output = gate.process(frameDb, frameDuration);
      gate.updateFloorTracking(frameDb, frameDuration, false);
      const elapsedMs = (i + 1) * frameDurationMs;
      if (output.evidence === 'strong' && firstStrongAtMs === null) {
        firstStrongAtMs = elapsedMs;
      }
      if (gate.coldStartSpeechShapedNow && firstShapedNowAtMs === null) {
        firstShapedNowAtMs = elapsedMs;
      }
      if (!gate.coldStartSpeechShapedNow && output.evidence === 'continuing') {
        sawPreShapedContinuing = true;
      }
      if (elapsedMs <= 400 && gate.coldStartSpeechShapedNow) {
        assert.strictEqual(output.evidence, 'strong');
        assert.strictEqual(output.isSpeech, true);
      }
    }

    assert.ok(firstShapedNowAtMs !== null && firstShapedNowAtMs < 400);
    assert.ok(firstStrongAtMs !== null && firstStrongAtMs <= 400);
    assert.strictEqual(sawPreShapedContinuing, true);
    assert.strictEqual(gate.coldStartConverged, true);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);
    assert.ok(gate.snapshot.floorDb > -80);
    assert.ok(gate.snapshot.floorDb <= -35 - gate.effectiveCeilingMarginDb);
  });

  it('(h): route-change reset restarts slew-limited cold-start convergence', () => {
    const gate = makeGate();
    for (let i = 0; i < 500; i++) {
      gate.process(-60, frameDuration);
      gate.updateFloorTracking(-60, frameDuration, true);
    }
    assert.ok(Math.abs(gate.snapshot.floorDb - -60) <= 0.1);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);

    gate.resetFloorAfterRouteChange();
    assert.strictEqual(gate.adaptiveRefinementComplete, false);
    assert.strictEqual(gate.coldStartSpeechShapedNow, false);
    assert.strictEqual(gate.coldStartConverged, false);

    for (let i = 0; i < 500; i++) {
      gate.process(-55, frameDuration);
      gate.updateFloorTracking(-55, frameDuration, true);
    }
    assert.ok(Math.abs(gate.snapshot.floorDb - -55) <= 0.1);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);
  });

  it('(i-a): a small grace-window transient does not leave idle', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 6000; i++) {
      harness.drive(i === 20 ? -52 : -60);
      assert.strictEqual(harness.endpoint.state, 'idle');
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 0.1);
    assert.strictEqual(harness.chunkCount, 0);
  });

  it('(i-b): a grace-window slam stays below onset duration during ambient adaptation', () => {
    const harness = makeRecorderHarness({
      endpointSilenceMs: 700,
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });
    let sawMinGateDiscard = false;

    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(i === 20 ? -40 : -60);
      sawMinGateDiscard ||= frame.discarded;
    }

    assert.strictEqual(sawMinGateDiscard, false);
    assert.strictEqual(harness.chunkCount, 0);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 0.1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('(ii): a post-convergence loud frame does not wedge the ambient floor', () => {
    const harness = makeRecorderHarness({
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });

    for (let i = 0; i < 600; i++) {
      harness.drive(i === 120 ? -40 : -60);
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 0.1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.chunkCount, 0);
  });

  it('(ii): converged -50 dB ambient with SNR-10 speech opens strongly and emits one chunk', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    prefillAmbient(harness, 300, -50);

    for (let i = 0; i < 400; i++) {
      harness.drive(-50);
    }
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -50) <= 1);

    let onsetMs = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-40);
      assert.strictEqual(frame.output.evidence, 'strong');
      if (frame.decision.type === 'startUtterance' && onsetMs === null) {
        onsetMs = (i + 1) * frameDurationMs;
      }
    }

    assert.ok(onsetMs !== null && onsetMs <= 200);
    let finalized = false;
    for (let i = 0; i < 100; i++) {
      if (harness.drive(-80).decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('(iii): an SNR-14 raised voice opens immediately after loud ambient', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -50);
    let onsetMs = null;

    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-36);
      assert.strictEqual(frame.output.evidence, 'strong');
      if (frame.decision.type === 'startUtterance' && onsetMs === null) {
        onsetMs = (i + 1) * frameDurationMs;
      }
      if (onsetMs !== null) break;
    }

    assert.ok(onsetMs !== null && onsetMs <= 200);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('(iv): sigma-2.5 loud ambient stays idle for 60 seconds with a converged floor', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -52.5);

    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(i % 2 === 0 ? -52.5 : -47.5);
      assert.strictEqual(frame.decision.type, 'none');
      assert.strictEqual(harness.endpoint.state, 'idle');
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -52.5) <= 1);
    assert.strictEqual(harness.chunkCount, 0);
  });

  it('(iv\'): a modulated ambient ride recovers to idle and allows subsequent speech', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    prefillAmbient(harness, 300, -50);

    for (let i = 0; i < 300; i++) {
      const frame = harness.drive(i % 2 === 0 ? -40 : -35);
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    let finalized = false;
    for (let i = 0; i < 100; i++) {
      if (harness.drive(-80).decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');

    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(i % 2 === 0 ? -48 : -52);
      assert.strictEqual(frame.decision.type, 'none');
      assert.strictEqual(harness.endpoint.state, 'idle');
    }
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -52) <= 1,
      `floor=${harness.gate.snapshot.floorDb}`);

    let onsetMs = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-41.5);
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.ok(onsetMs !== null && onsetMs <= 200);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('(iii): immediate modulated speech remains active until the real pause', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    let onsetMs = null;
    let sawShapedNow = false;

    for (let i = 0; i < 200; i++) {
      const frameDb = i % 8 === 0 ? -35 : -25;
      const frame = harness.drive(frameDb);
      sawShapedNow ||= harness.gate.coldStartSpeechShapedNow;
      if (harness.accumulatorSamples > 0 && onsetMs === null) {
        onsetMs = (i + 1) * frameDurationMs;
      }
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
    }

    assert.ok(onsetMs !== null && onsetMs >= 450);
    const emittedStartMs = harness.chunkStartSessionSamples / 16;
    assert.ok(emittedStartMs <= 0);
    assert.strictEqual(sawShapedNow, true);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.strictEqual(harness.gate.adaptiveRefinementComplete, true);
    assert.ok(harness.gate.snapshot.floorDb > -80);
    assert.ok(harness.gate.snapshot.floorDb <= -35 - harness.gate.effectiveCeilingMarginDb);

    let finalized = false;
    for (let i = 0; i < 100; i++) {
      if (harness.drive(-80).decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.ok(harness.emittedTotalMs >= 2000);

    for (let i = 0; i < 10; i++) harness.drive(-80);
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.strictEqual(harness.gate.adaptiveRefinementComplete, true);
  });

  it('(iv): two close transients stay below onset duration during ambient adaptation', () => {
    const harness = makeRecorderHarness({
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });

    for (let i = 0; i < 6000; i++) {
      const frameDb = i === 20 || i === 45 ? -40 : -60;
      harness.drive(frameDb);
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 0.1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.reanchorEventCount, 0);
  });

  it('N7: stale time is retained until the machine becomes idle', () => {
    const gate = makeGate();
    gate.floorDb = -70;
    gate.coldStartConverged = true;
    gate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 30; i++) {
      gate.process(-69, 0.01);
      gate.updateFloorTracking(-69, 0.01, false);
    }
    gate.lastKnownMachineIsIdle = true;

    for (let i = 0; i < 149; i++) {
      gate.process(-65, frameDuration);
      assert.strictEqual(gate.takePendingReanchorEvent(), false);
      gate.updateFloorTracking(-65, frameDuration, false);
    }

    gate.process(-65, frameDuration);
    assert.strictEqual(gate.takePendingReanchorEvent(), false);
    gate.updateFloorTracking(-65, 0, true);

    gate.process(-65, frameDuration);
    assert.strictEqual(gate.takePendingReanchorEvent(), true);
    assert.ok(Math.abs(gate.snapshot.floorDb - -69.88) < 0.001);
  });

  it('T1: flat stuck-run fallback re-anchors only after the implausible-speech interval', () => {
    const gate = makeGate();
    gate.floorDb = -70;
    gate.coldStartConverged = true;
    gate.adaptiveRefinementComplete = true;

    for (let i = 0; i < 799; i++) {
      gate.process(-65, 0.01);
      assert.strictEqual(gate.takePendingReanchorEvent(), false);
      gate.updateFloorTracking(-65, 0.01, false);
    }

    assert.ok(gate.secondsSinceSilenceEvidence >= 7.98);
    assert.ok(gate.secondsSinceSilenceEvidence <= VAD_ADAPTIVE_IMPLAUSIBLE_SPEECH_S);

    const output = gate.process(-65, 0.01);
    assert.strictEqual(gate.takePendingReanchorEvent(), true);
    assert.ok(Math.abs(gate.snapshot.floorDb - -69.88) < 0.001);
    assert.strictEqual(output.evidence, 'ambiguous');
    assert.ok(gate.secondsSinceSilenceEvidence >= VAD_ADAPTIVE_IMPLAUSIBLE_SPEECH_S - 1e-8);
    gate.updateFloorTracking(-65, 0.01, false);
  });

  it('T2: modulated non-idle input never passes the stuck-run flatness gate', () => {
    const gate = makeGate();
    gate.floorDb = -70;
    gate.adaptiveRefinementComplete = true;
    let reanchorEventCount = 0;

    for (let i = 0; i < 2000; i++) {
      gate.process(i % 8 === 0 ? -35 : -21, 0.01);
      if (gate.takePendingReanchorEvent()) reanchorEventCount += 1;
      gate.updateFloorTracking(i % 8 === 0 ? -35 : -21, 0.01, false);
    }

    assert.strictEqual(reanchorEventCount, 0);
    assert.strictEqual(gate.snapshot.floorDb, -70);
  });

  it('T3: the dynamics kill-switch still permits a slew-capped stuck-run fallback', () => {
    const gate = makeGate({ adaptiveDynamicsEnabled: false });
    gate.floorDb = -70;
    gate.adaptiveRefinementComplete = true;

    let output = null;
    let reanchorEvent = false;
    for (let i = 0; i < 800; i++) {
      output = gate.process(-65, 0.01);
      reanchorEvent ||= gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, 0.01, false);
    }

    assert.strictEqual(reanchorEvent, true);
    assert.strictEqual(output.shortSpreadDb, null);
    assert.ok(Math.abs(gate.snapshot.floorDb - -69.88) < 0.001);
    assert.strictEqual(output.evidence, 'ambiguous');
  });

  it('T4: an implausible flat run releases a stale ceiling only for capped fallback', () => {
    const gate = makeGate();
    gate.floorDb = -70;
    gate.adaptiveRefinementComplete = true;
    gate.speechCeilingDb = -55;

    let output = null;
    let reanchorEvent = false;
    for (let i = 0; i < 800; i++) {
      output = gate.process(-65, 0.01);
      reanchorEvent ||= gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, 0.01, false);
    }

    assert.strictEqual(reanchorEvent, true);
    assert.strictEqual(output.evidence, 'ambiguous');
    assert.ok(Math.abs(gate.snapshot.floorDb - -69.88) < 0.001);
    assert.strictEqual(gate.speechCeilingDb, null);
  });

  it('uses the configured stale interval when silence P10 starves', () => {
    const shortGate = makeGate({
      adaptiveStaleFloorSeconds: 1.5,
      adaptiveRiseSpeedMultiplier: 4,
    });
    const longGate = makeGate({
      adaptiveStaleFloorSeconds: 3,
      adaptiveRiseSpeedMultiplier: 0.5,
    });
    for (const gate of [shortGate, longGate]) {
      gate.floorDb = -70;
      gate.coldStartConverged = true;
      gate.adaptiveRefinementComplete = true;
      for (let i = 0; i < 30; i++) {
        gate.process(-69, 0.01);
        gate.updateFloorTracking(-69, 0.01, false);
      }
      gate.lastKnownMachineIsIdle = true;
    }

    function firstReanchorSeconds(gate) {
      for (let i = 0; i < 700; i++) {
        gate.process(-65, 0.01);
        if (gate.takePendingReanchorEvent()) return (i + 1) * 0.01;
      }
      return null;
    }

    const shortReanchorSeconds = firstReanchorSeconds(shortGate);
    const longReanchorSeconds = firstReanchorSeconds(longGate);
    assert.ok(shortReanchorSeconds >= 0.37 && shortReanchorSeconds <= 0.39);
    assert.ok(longReanchorSeconds >= 5.99 && longReanchorSeconds <= 6.01);
  });

  it('pins the shipped default profile: 12 dB/s rise and 1.5 s stale window', () => {
    const defaultTiming = {
      adaptiveRiseSpeedMultiplier: 1,
      adaptiveStaleFloorSeconds: 1.5,
    };
    const staleGate = makeGate(defaultTiming);
    staleGate.floorDb = -70;
    staleGate.coldStartConverged = true;
    staleGate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 30; i++) {
      staleGate.process(-69, 0.01);
      staleGate.updateFloorTracking(-69, 0.01, false);
    }
    staleGate.lastKnownMachineIsIdle = true;

    let reanchorSeconds = null;
    for (let i = 0; i < 200; i++) {
      staleGate.process(-65, 0.01);
      if (staleGate.takePendingReanchorEvent()) {
        reanchorSeconds = (i + 1) * 0.01;
        break;
      }
    }
    assert.ok(reanchorSeconds >= 1.49 && reanchorSeconds <= 1.51);

    const riseGate = makeGate(defaultTiming);
    riseGate.floorDb = -60;
    riseGate.coldStartConverged = true;
    riseGate.adaptiveRefinementComplete = true;
    for (let i = 0; i < 10; i++) riseGate.process(-63, 0.1);
    riseGate.floorDb = -70;
    riseGate.process(-63, 0.1);
    riseGate.updateFloorTracking(-63, 0.1, true);
    assert.ok(Math.abs(riseGate.snapshot.floorDb - -68.8) < 0.001);
  });

  it('keeps an utterance when real speech follows continuous ambient', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-65);
    for (let i = 0; i < 30; i++) harness.drive(i % 8 === 0 ? -35 : -21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
  });

  it('noisy pause after real speech does not discard the utterance', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;
    let sawReanchor = false;

    prefillAmbient(harness, 400, -65);
    for (let i = 0; i < 220; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb - 14 : quietestStrongDb);
    }

    // Ambiguous evidence keeps the active utterance alive, but cannot move the
    // floor or trigger a stale re-anchor while the endpoint is non-idle.
    for (let i = 0; i < 320; i++) {
      const floorDb = harness.gate.snapshot.floorDb;
      const frameDb = floorDb + (i % 2 === 0 ? 3 : 9);
      const frame = harness.drive(frameDb);
      sawReanchor ||= frame.reanchorEvent;
    }

    let finalized = null;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.strictEqual(sawReanchor, false);
    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.strictEqual(harness.noteUtteranceEndedValues.at(-1), -49);
  });

  it('R3: kept utterances still respect the min-chunk/min-speech gates', () => {
    const events = [];
    const quietestStrongDb = -35;
    const harness = makeRecorderHarness({
      minChunkSamples: 1,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
      onEvent: event => events.push(event),
    });

    prefillAmbient(harness, 400, -65);
    for (let i = 0; i < 220; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb - 14 : quietestStrongDb);
    }
    let finalized = null;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.ok(harness.accumulatorSamples > 0);
    assert.strictEqual(harness.endpoint.state, 'idle');

    harness.flush();

    assert.equal(harness.chunkCount, 1);
    assert.ok(events.some(event => event.k === 'emit' && event.r === 'flush'));
  });

  it('holds an utterance below both gates, then applies the stop-flush floor', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 10,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 10,
        endpointSilenceMs: 10,
        resumeMs: 10,
        ambiguousRescueMs: 20,
      },
      minChunkSamples: Number.MAX_SAFE_INTEGER,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });

    for (let i = 0; i < 7; i++) harness.drive(-20);
    const firstSilence = harness.drive(-80);
    const finalized = harness.drive(-80);

    assert.equal(firstSilence.decision.type, 'continueUtterance');
    assert.equal(finalized.decision.type, 'finalizeUtterance');
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.equal(harness.accumulatorSamples, 9 * 160);

    harness.flush();

    assert.equal(harness.chunkCount, 0);
    assert.equal(harness.tailFloorSampleCount, 9 * 160);
    assert.ok(events.some(event => event.k === 'discard' && event.r === 'tail_floor'));
  });

  it('does not discard speech that starts on the first frame', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) {
      harness.drive(i % 8 === 0 ? -35 : -21);
    }

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('N2/R1: modulated speech stays active for 60 seconds and resumes after pause', () => {
    const events = [];
    const harness = makeRecorderHarness({
      endpointSilenceMs: 3_000,
      onEvent: event => events.push(event),
    });
    prefillAmbient(harness, 300, -54);
    const monologueMs = 60_000;
    const initialFloor = harness.gate.snapshot.floorDb;
    let previousFloorDb = initialFloor;

    for (let i = 0; i < monologueMs / frameDurationMs; i++) {
      const injectedPause = (i >= 2_950 && i < 2_960) || (i >= 5_950 && i < 5_960);
      const forcedResume = (i >= 2_960 && i < 2_972) || (i >= 5_960 && i < 5_972);
      const frameDb = injectedPause ? -52 : forcedResume ? -40 : i % 8 === 0 ? -54 : -40;
      const frame = harness.drive(frameDb);
      const floorDb = harness.gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      assert.ok(floorDb <= initialFloor + 0.5);
      assert.ok(floorDb <= -40 - harness.gate.effectiveCeilingMarginDb + 1e-9);
      previousFloorDb = floorDb;
      if (i >= 40 && !injectedPause && !forcedResume) {
        assert.strictEqual(frame.output.evidence, i % 8 === 0 ? 'silence' : 'strong');
      }
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
    }

    assert.ok(harness.gate.snapshot.floorDb <= initialFloor + 0.5);
    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
    const prematureEmissions = events.filter(event => event.k === 'emit' || event.k === 'split');
    assert.equal(prematureEmissions.length, 0);

    let finalized = null;
    for (let i = 0; i < 400; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    const emittedChunks = events.filter(event => event.k === 'emit');
    assert.equal(emittedChunks.length, 1);
    assert.equal(harness.emittedSampleCount,
      emittedChunks.reduce((total, event) => total + event.n, 0));
    for (let index = 1; index < emittedChunks.length; index += 1) {
      assert.equal(emittedChunks[index].s0, emittedChunks[index - 1].s1);
    }

    let resumeOnsetMs = null;
    for (let i = 0; i < 50; i++) {
      const frame = harness.drive(i % 8 === 0 ? -54 : -40);
      if (frame.decision.type === 'startUtterance') {
        resumeOnsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }
    assert.ok(resumeOnsetMs !== null && resumeOnsetMs >= 60 && resumeOnsetMs <= 300);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('post-endpoint floor does not eat speech — resumed speech re-onsets', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;
    const ceilingFloor = -49 - VAD_SPEECH_CEILING_MARGIN_DB;

    prefillAmbient(harness, 400, -65);
    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb - 14 : quietestStrongDb);
    }
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    for (let i = 0; i < 30; i++) harness.drive(-80);
    assert.strictEqual(harness.endpoint.state, 'endPending');

    let sawAbruptGustBankSilence = false;
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(i % 10 === 9 ? -72 : -78);
      if (harness.endpoint.state === 'endPending'
        && frame.output.shortSpreadDb >= 5
        && !frame.output.speechShaped
        && frame.endpointEvidence === 'silence') {
        sawAbruptGustBankSilence = true;
      }
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }

    assert.strictEqual(sawAbruptGustBankSilence, true);
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.gate.speechCeilingDb, -49);
    assert.strictEqual(harness.endpoint.state, 'idle');

    for (let i = 0; i < 200; i++) {
      harness.drive(-75);
      assert.strictEqual(harness.endpoint.state, 'idle');
      assert.ok(harness.gate.snapshot.floorDb <= ceilingFloor);
    }

    let onsetMs = null;
    for (let i = 0; i < 50; i++) {
      const frame = harness.drive(i % 8 === 0 ? quietestStrongDb - 14 : quietestStrongDb);
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }
    assert.ok(onsetMs !== null && onsetMs <= 500);
  });

  it('joint-gates end-pending mapping at 6 dB of long-window dispersion', () => {
    const below = endPendingMappingProbe(-55.9);
    assert.ok(Math.abs(below.output.dynamicsSpreadDb - 5.9) < 0.001);
    assert.ok(Math.abs(below.output.shortSpreadDb - 3) < 0.001);
    assert.ok(below.output.shortSpreadDb < makeVadGateConfig().adaptiveFlatSpreadDb);
    assert.ok(below.output.dynamicsSpreadDb < VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB);
    assert.strictEqual(below.endpointEvidence, 'silence');

    const above = endPendingMappingProbe(-56.1);
    assert.ok(Math.abs(above.output.dynamicsSpreadDb - 6.1) < 0.001);
    assert.ok(above.output.shortSpreadDb < makeVadGateConfig().adaptiveFlatSpreadDb);
    assert.strictEqual(above.endpointEvidence, 'continuing');
  });

  it('W3: flat gust cycling closes end-pending without resurrection under the speech ceiling', () => {
    const endpointSilenceMs = 3000;
    const harness = makeRecorderHarness({
      endpointSilenceMs,
      gateConfig: {
        adaptiveAbsoluteSpeechFloorDb: -80,
        adaptiveFlatSpreadDb: 5.5,
      },
    });
    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 30; i++) harness.drive(-45);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    const initialFloor = harness.gate.snapshot.floorDb;
    const gustDb = initialFloor + 7.4;
    const lullDb = initialFloor + 2.2;
    for (let i = 0; i < 400; i++) {
      harness.drive(i % 2 === 0 ? gustDb : lullDb);
    }
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    let enteredEndPending = false;
    for (let i = 0; i < 20; i++) {
      const frame = harness.drive(lullDb);
      enteredEndPending ||= harness.endpoint.state === 'endPending';
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.strictEqual(enteredEndPending, true, JSON.stringify({
      state: harness.endpoint.state,
      silenceSamples: harness.endpoint.accumulatedSilenceSamples,
      floorDb: harness.gate.snapshot.floorDb,
      silenceThresholdDb: harness.gate.snapshot.silenceThresholdDb,
      lullDb,
      evidence: harness.gate.snapshot.evidence,
    }));

    let finalizedAfterMs = null;
    let sawFlatGust = false;
    let maximumFlatGustDispersion = -Infinity;
    let resurrected = false;
    for (let i = 0; i < 400; i++) {
      const frame = harness.drive(i % 2 === 0 ? gustDb : lullDb);
      assert.ok(harness.gate.snapshot.floorDb
        <= harness.gate.utteranceSpeechLevelDb - harness.gate.effectiveCeilingMarginDb + 1e-9);
      if (frame.output.shortSpreadDb < harness.gate.effectiveFlatSpreadDb) {
        sawFlatGust = true;
        maximumFlatGustDispersion = Math.max(
          maximumFlatGustDispersion,
          frame.output.dynamicsSpreadDb,
        );
      }
      resurrected ||= harness.endpoint.state === 'speechActive';
      if (frame.decision.type === 'finalizeUtterance') {
        finalizedAfterMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.strictEqual(resurrected, false);
    assert.strictEqual(sawFlatGust, true);
    assert.ok(maximumFlatGustDispersion < 5.5);
    assert.deepStrictEqual(
      [5.5, 6, 6.5].map(threshold => maximumFlatGustDispersion < threshold),
      [true, true, true],
    );
    assert.ok(harness.gate.snapshot.floorDb
      <= harness.gate.utteranceSpeechLevelDb - harness.gate.effectiveCeilingMarginDb + 1e-9);
    assert.ok(finalizedAfterMs !== null && finalizedAfterMs <= endpointSilenceMs + frameDurationMs);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('W3 negative: short square-wave gusts with dy 8+ preserve the pause', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 1000 });
    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 30; i++) harness.drive(-45);
    const floorDb = harness.gate.snapshot.floorDb;
    const gustDb = floorDb + 10.5;
    const lullDb = floorDb + 1.5;
    for (let i = 0; i < 400; i++) {
      harness.drive(i % 2 === 0 ? gustDb : lullDb);
    }
    for (let i = 0; i < 20; i++) harness.drive(lullDb);
    assert.strictEqual(harness.endpoint.state, 'endPending');

    let sawDynamicGust = false;
    let finalized = false;
    for (let i = 0; i < 200; i++) {
      const frame = harness.drive(i % 2 === 0 ? gustDb : lullDb);
      if (frame.output.dynamicsSpreadDb >= 8) {
        sawDynamicGust = true;
        assert.strictEqual(frame.output.speechShaped, false);
        assert.strictEqual(frame.endpointEvidence, 'silence');
      }
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(sawDynamicGust, true);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('W2: a 1.3-second thinking pause survives a dynamic speech attack', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 2000 });
    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 30; i++) harness.drive(-45);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    const floorBeforePause = harness.gate.snapshot.floorDb;
    let enteredEndPending = false;
    for (let i = 0; i < 130; i++) {
      const frame = harness.drive(-80);
      enteredEndPending ||= harness.endpoint.state === 'endPending';
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.strictEqual(enteredEndPending, true);
    assert.strictEqual(harness.chunkCount, 0);

    let sawDynamicAttack = false;
    let resumed = false;
    for (let i = 0; i < 40; i++) {
      const frame = harness.drive(i % 2 === 0
        ? floorBeforePause + 7
        : floorBeforePause + 13);
      sawDynamicAttack ||= frame.output.dynamicsSpreadDb
        >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB;
      if (harness.endpoint.state === 'speechActive') {
        resumed = true;
        break;
      }
    }

    assert.strictEqual(sawDynamicAttack, true);
    assert.strictEqual(resumed, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('W1: flat continuing speech does not raise the floor while active', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -50);
    for (let i = 0; i < 30; i++) harness.drive(-35);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    const stableFloor = harness.gate.snapshot.floorDb;
    for (let i = 0; i < 120; i++) {
      const frame = harness.drive(stableFloor + 7);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(harness.endpoint.state, 'speechActive');
      assert.strictEqual(harness.gate.snapshot.floorDb, stableFloor - 1);
    }
  });

  it('W6: whisper spread just below flat closes, just above resumes', () => {
    const below = makeRecorderHarness({ endpointSilenceMs: 1000 });
    prefillAmbient(below, 300, -60);
    for (let i = 0; i < 30; i++) below.drive(-45);
    // Ambiguous frames now reset active-state silence, matching the speech-like
    // rule intended for StreamingEndpoint.swift:155–173. Seed endPending with
    // real silence so this remains a test of the recorder's just-below-flat
    // close boundary under legacy (120/320 ms, no-ratio) settings.
    for (let i = 0; i < 10; i++) below.drive(-80);
    assert.strictEqual(below.endpoint.state, 'endPending');
    const belowFloor = below.gate.snapshot.floorDb;
    const belowHighDb = belowFloor + 5.9;
    const belowLowDb = belowFloor + 2.5;

    let sawEndPending = false;
    let sawBelowBoundary = false;
    let sawMappedContinuing = false;
    let finalized = false;
    for (let i = 0; i < 200; i++) {
      const frame = below.drive(i % 2 === 0 ? belowHighDb : belowLowDb);
      sawEndPending ||= below.endpoint.state === 'endPending';
      if (frame.output.shortSpreadDb < below.gate.effectiveFlatSpreadDb) {
        sawBelowBoundary = true;
      }
      if (frame.output.evidence === 'continuing' || frame.output.evidence === 'ambiguous') {
        sawMappedContinuing ||= frame.endpointEvidence === 'silence';
      }
      finalized ||= frame.decision.type === 'finalizeUtterance';
      if (finalized) break;
    }

    assert.strictEqual(sawEndPending, true);
    assert.strictEqual(sawBelowBoundary, true);
    assert.strictEqual(sawMappedContinuing, true);
    assert.strictEqual(finalized, true);
    assert.strictEqual(below.chunkCount, 1);
    assert.strictEqual(below.endpoint.state, 'idle');

    const above = makeRecorderHarness({
      endpointSilenceMs: 1000,
      endpointConfig: { resumeMs: 600 },
    });
    prefillAmbient(above, 300, -60);
    for (let i = 0; i < 30; i++) above.drive(-45);
    const aboveFloor = above.gate.snapshot.floorDb;
    const aboveHighDb = aboveFloor + 10.5;
    const aboveLowDb = aboveFloor + 2.5;
    for (let i = 0; i < 400; i++) {
      above.drive(i % 2 === 0 ? aboveHighDb : aboveLowDb);
    }
    for (let i = 0; i < 20; i++) above.drive(aboveLowDb);
    assert.strictEqual(above.endpoint.state, 'endPending');

    let sawAboveBoundary = false;
    let sawAbovePreserved = false;
    let resumed = false;
    for (let i = 0; i < 100; i++) {
      const frame = above.drive(aboveHighDb);
      sawAboveBoundary ||= frame.output.shortSpreadDb >= above.gate.effectiveFlatSpreadDb;
      sawAbovePreserved ||= frame.output.shortSpreadDb < above.gate.effectiveFlatSpreadDb
        && frame.output.dynamicsSpreadDb >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
        && frame.endpointEvidence === frame.output.evidence;
      if (above.endpoint.state === 'speechActive') {
        resumed = true;
        break;
      }
    }

    assert.strictEqual(sawAboveBoundary, true);
    assert.strictEqual(sawAbovePreserved, true);
    assert.ok(above.gate.snapshot.dynamicsSpreadDb === null
      || above.gate.snapshot.dynamicsSpreadDb >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB);
    assert.strictEqual(resumed, true);
    assert.strictEqual(above.chunkCount, 0);
    assert.strictEqual(above.endpoint.state, 'speechActive');
  });

  it('adaptive dynamics kill-switch preserves pre-change end-pending rescue semantics', () => {
    const harness = makeRecorderHarness({
      endpointSilenceMs: 1000,
      gateConfig: { adaptiveDynamicsEnabled: false },
    });
    for (let i = 0; i < 300; i++) {
      harness.gate.process(-60, frameDuration);
      harness.gate.takePendingReanchorEvent();
      harness.gate.updateFloorTracking(-60, frameDuration, true);
    }
    for (let i = 0; i < 30; i++) harness.drive(-45);
    for (let i = 0; i < 20; i++) harness.drive(-80);
    assert.strictEqual(harness.endpoint.state, 'endPending');

    const floorBeforeRescue = harness.gate.snapshot.floorDb;
    let rescued = false;
    for (let i = 0; i < 40; i++) {
      const frame = harness.drive(harness.gate.snapshot.floorDb + 4);
      assert.strictEqual(frame.output.shortSpreadDb, null);
      assert.strictEqual(frame.output.dynamicsSpreadDb, null);
      assert.strictEqual(frame.endpointEvidence, frame.output.evidence);
      if (harness.endpoint.state === 'speechActive') {
        rescued = true;
        break;
      }
    }

    assert.strictEqual(rescued, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.ok(harness.gate.snapshot.floorDb <= floorBeforeRescue + 1e-9);
  });

  it('steady non-silence input during cold start settles without opening an utterance', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;

    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb : -21);
    }
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.gate.speechCeilingDb, quietestStrongDb);
    assert.strictEqual(harness.endpoint.state, 'idle');

    let onset = false;
    let firstSilenceMs = null;
    let lastOutput = null;
    for (let i = 0; i < 200; i++) {
      lastOutput = harness.drive(-73);
      if (lastOutput.decision.type === 'startUtterance') onset = true;
      if (lastOutput.output.evidence === 'silence' && firstSilenceMs === null) {
        firstSilenceMs = (i + 1) * frameDurationMs;
      }
    }

    assert.strictEqual(onset, false);
    assert.ok(firstSilenceMs !== null && firstSilenceMs < 1000);
    assert.strictEqual(lastOutput.output.evidence, 'silence');
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('speech ceiling caps re-anchor and idle rise until decay releases it', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;

    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb : -21);
    }
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');

    const gate = harness.gate;
    const ceilingFloor = quietestStrongDb - VAD_SPEECH_CEILING_MARGIN_DB;
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
    gate.floorDb = -40;

    for (let i = 0; i < 150; i++) {
      const loudFrameDb = gate.floorDb + 5;
      gate.process(loudFrameDb, frameDuration);
      gate.updateFloorTracking(loudFrameDb, frameDuration, false);
      assert.strictEqual(gate.snapshot.floorDb, ceilingFloor);
    }
    assert.strictEqual(gate.snapshot.floorDb, ceilingFloor);

    for (let i = 0; i < 300; i++) {
      const loudFrameDb = gate.floorDb + 2;
      gate.process(loudFrameDb, frameDuration);
      gate.updateFloorTracking(loudFrameDb, frameDuration, true);
    }

    assert.strictEqual(gate.speechCeilingDb, null);
    assert.ok(gate.snapshot.floorDb > ceilingFloor);
  });

  it('(3.4): a mid-session loud event sets, caps, decays, and releases its ceiling', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;

    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb : -25);
    }
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') break;
    }

    const gate = harness.gate;
    const ceilingFloor = quietestStrongDb - VAD_SPEECH_CEILING_MARGIN_DB;
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
    gate.floorDb = -40;

    for (let i = 0; i < 150; i++) {
      const frameDb = gate.floorDb + 5;
      gate.process(frameDb, frameDuration);
      gate.updateFloorTracking(frameDb, frameDuration, false);
      assert.strictEqual(gate.snapshot.floorDb, ceilingFloor);
    }

    for (let i = 0; i < 300; i++) {
      const frameDb = gate.floorDb + 2;
      gate.process(frameDb, frameDuration);
      gate.updateFloorTracking(frameDb, frameDuration, true);
    }

    assert.strictEqual(gate.speechCeilingDb, null);
    assert.ok(gate.snapshot.floorDb > ceilingFloor);
  });

  it('stale re-anchor stays slew-capped below the continuous speech ceiling', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;

    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb : -21);
    }
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.gate.speechCeilingDb, quietestStrongDb);

    const gate = harness.gate;
    gate.floorDb = -60;
    let reanchorEvent = false;
    let previousFloorDb = gate.floorDb;
    for (let i = 0; i < 301; i++) {
      const frameDb = quietestStrongDb + 7;
      gate.process(frameDb, frameDuration);
      if (gate.takePendingReanchorEvent()) reanchorEvent = true;
      gate.updateFloorTracking(frameDb, 0, true);
      const floorDb = gate.snapshot.floorDb;
      assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
      previousFloorDb = floorDb;
    }

    assert.strictEqual(reanchorEvent, true);
    assert.ok(gate.snapshot.floorDb > -60);
    assert.ok(gate.snapshot.floorDb <= quietestStrongDb - gate.effectiveCeilingMarginDb);
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
  });
});
