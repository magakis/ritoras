import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  makeVadGateConfig,
  VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB,
  VAD_SPEECH_CEILING_MARGIN_DB,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import { StreamingEndpoint } from '../lib/streaming-endpoint.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const frameDurationMs = 10;
const frameDuration = frameDurationMs / 1000;
const frameSamples = frameDurationMs * 16;

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
  it('reaches the ambient floor without endpoint onset', () => {
    const gate = makeGate();
    let firstSilenceMs = null;

    for (let i = 0; i < 700; i++) {
      const output = gate.process(-65, frameDuration);
      gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, frameDuration, true);
      const elapsedMs = (i + 1) * frameDurationMs;
      if (output.evidence === 'silence' && firstSilenceMs === null) {
        firstSilenceMs = elapsedMs;
      }
    }

    assert.ok(firstSilenceMs !== null && firstSilenceMs <= 4100);
    assert.strictEqual(gate.snapshot.floorDb, -65);
  });

  it('N1/N6: continuous speech stays one chunk until a real pause', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    const monologueMs = 60_000;
    let initialFloor = null;
    let previousAccumulatorSamples = 0;
    let onsetMs = null;

    for (let i = 0; i < monologueMs / frameDurationMs; i++) {
      const frame = harness.drive(i % 8 === 0 ? -35 : -21);
      if (i >= 40) assert.strictEqual(frame.output.evidence, 'strong');
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.strictEqual(frame.discarded, false);
      initialFloor ??= harness.gate.snapshot.floorDb;
      assert.ok(Math.abs(harness.gate.snapshot.floorDb - initialFloor) <= 1e-9);
      assert.ok(harness.accumulatorSamples >= previousAccumulatorSamples);
      previousAccumulatorSamples = harness.accumulatorSamples;
      if (frame.decision.type === 'startUtterance' && onsetMs === null) {
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
    assert.ok(Math.abs(
      harness.emittedTotalMs - (500 + monologueMs - onsetMs + pauseMs),
    ) <= 100);
  });

  it('ends talk-then-real-silence after endpoint silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    for (let i = 0; i < 1000; i++) {
      const frameDb = i % 8 === 0 ? -35 : -21;
      const { decision } = driveFrame(gate, endpoint, frameDb);
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

  it('reports ambient headroom at approximately three decibels', () => {
    const gate = makeGate();

    for (let i = 0; i < 500; i++) {
      gate.process(-65, frameDuration);
      gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, frameDuration, true);
    }

    assert.ok(Math.abs(gate.snapshot.silenceThresholdDb - -62) <= 0.5);
  });

  it('converges extreme ambient and stays idle above the headroom guard', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let lastFrame = null;
    let endpointReached = false;
    let reanchorEventCount = 0;

    for (let i = 0; i < 600; i++) {
      lastFrame = driveFrame(gate, endpoint, -25);
      if (lastFrame.reanchorEvent) reanchorEventCount += 1;
      if (lastFrame.decision.type === 'finalizeUtterance') {
        endpointReached = true;
        break;
      }
    }

    assert.ok(lastFrame !== null);
    assert.strictEqual(lastFrame.output.floorDb, -25);
    assert.strictEqual(gate.snapshot.floorDb, -25);
    assert.strictEqual(lastFrame.output.evidence, 'silence');
    assert.strictEqual(lastFrame.reanchorEvent, false);
    assert.strictEqual(reanchorEventCount, 0);
    assert.strictEqual(endpointReached, false);
    assert.strictEqual(endpoint.state, 'idle');
  });

  it('N4: re-anchors idle ambiguous ambient without opening the endpoint', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    gate.floorDb = -70;
    gate.adaptiveRefinementComplete = true;
    let reanchorEventCount = 0;
    let sawSilence = false;

    for (let i = 0; i < 400; i++) {
      const { output, decision, reanchorEvent } = driveIdleFrame(gate, endpoint, -65, 0);
      if (reanchorEvent) reanchorEventCount += 1;
      if (output.evidence === 'silence') sawSilence = true;
      assert.strictEqual(decision.type, 'none');
    }

    assert.strictEqual(reanchorEventCount, 1);
    assert.strictEqual(gate.snapshot.floorDb, -65);
    assert.strictEqual(sawSilence, true);
    assert.strictEqual(endpoint.state, 'idle');
  });

  it('does not stale-reanchor a quick recording shorter than three seconds', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();

    for (let i = 0; i < 290; i++) {
      const frameDb = i % 8 === 0 ? -35 : -21;
      const { output, decision } = driveFrame(gate, endpoint, frameDb);
      if (i >= 40) assert.strictEqual(output.evidence, 'strong');
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    assert.strictEqual(gate.snapshot.floorDb, -80);
  });

  it('R3 (c/e): steady ambient converges from frame zero without opening', () => {
    const harness = makeRecorderHarness();
    let graceSpeechEvidence = false;
    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(-60);
      if (i < 40 && frame.output.evidence === 'strong' && frame.output.isSpeech) {
        graceSpeechEvidence = true;
      }
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.strictEqual(frame.reanchorEvent, false);
      assert.strictEqual(frame.decision.type, 'none');
    }

    assert.strictEqual(graceSpeechEvidence, false);
    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('(b): immediate modulated speech captures one complete utterance', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    const speechFrames = 150;
    let onsetMs = null;

    for (let i = 0; i < speechFrames; i++) {
      const frame = harness.drive(i < 2 ? -58 : (i % 8 === 0 ? -58 : -45));
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      if (frame.decision.type === 'startUtterance' && onsetMs === null) {
        onsetMs = (i + 1) * frameDurationMs;
      }
    }

    const pauseMs = 700;
    let finalized = false;
    for (let i = 0; i < pauseMs / frameDurationMs; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.ok(onsetMs !== null && onsetMs <= 500);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.ok(Math.abs(
      harness.emittedTotalMs - (speechFrames * frameDurationMs + 500 + pauseMs),
    ) <= 300);
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

  it('(e): loud ambient converges to idle and stop flushes nothing', () => {
    const harness = makeRecorderHarness();
    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(-50);
      assert.strictEqual(frame.decision.type, 'none');
      assert.strictEqual(frame.reanchorEvent, false);
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -50) <= 1);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.deepStrictEqual(harness.endpoint.forceFinalize('stop'), { type: 'none' });
  });

  it('(b\' / veto): dispersion during grace passes strong speech before convergence', () => {
    const gate = makeGate();
    let firstStrongAtMs = null;
    let firstShapedNowAtMs = null;
    let sawPreShapedContinuing = false;

    for (let i = 0; i < 40; i++) {
      const frameDb = i < 2 ? -58 : (i % 8 === 0 ? -58 : -45);
      const output = gate.process(frameDb, frameDuration);
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
    assert.strictEqual(gate.coldStartConverged, false);
  });

  it('(h): recalibrateFloor restarts cold start and reconverges', () => {
    const gate = makeGate();
    for (let i = 0; i < 150; i++) gate.process(-60, frameDuration);
    assert.ok(Math.abs(gate.snapshot.floorDb - -60) <= 1);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);

    gate.recalibrateFloor();
    assert.strictEqual(gate.adaptiveRefinementComplete, false);
    assert.strictEqual(gate.coldStartSpeechShapedNow, false);
    assert.strictEqual(gate.coldStartConverged, false);

    for (let i = 0; i < 150; i++) gate.process(-55, frameDuration);
    assert.ok(Math.abs(gate.snapshot.floorDb - -55) <= 1);
    assert.strictEqual(gate.adaptiveRefinementComplete, true);
  });

  it('(i-a): a small grace-window transient does not leave idle', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(i === 20 ? -52 : -60);
      assert.strictEqual(harness.endpoint.state, 'idle');
      assert.strictEqual(frame.reanchorEvent, false);
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 1);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.reanchorEventCount, 0);
  });

  it('(i-b): a grace-window slam emits one transient chunk then converges without wedging', () => {
    const harness = makeRecorderHarness({
      endpointSilenceMs: 700,
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });
    let sawMinGateDiscard = false;
    let reanchorAfterConvergence = 0;

    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(i === 20 ? -40 : -60);
      sawMinGateDiscard ||= frame.discarded;
      if (frame.reanchorEvent && harness.gate.coldStartConverged) {
        reanchorAfterConvergence += 1;
      }
    }

    assert.strictEqual(sawMinGateDiscard, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.ok(harness.emittedTotalMs >= 800 && harness.emittedTotalMs <= 1600);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(reanchorAfterConvergence, 0);
  });

  it('(ii): a post-convergence loud frame does not wedge the ambient floor', () => {
    const harness = makeRecorderHarness({
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });

    for (let i = 0; i < 600; i++) {
      harness.drive(i === 120 ? -40 : -60);
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 2);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.reanchorEventCount, 0);
  });

  it('(ii): converged -50 dB ambient with SNR-10 speech opens strongly and emits one chunk', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });

    for (let i = 0; i < 400; i++) {
      const frameDb = i % 20 === 0 ? -52 : (i % 20 === 1 ? -48 : -50);
      harness.drive(frameDb);
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
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -52) <= 1);

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

  it('(iii): immediate modulated speech remains active through sustained cold-start dynamics', () => {
    const harness = makeRecorderHarness();
    let onsetMs = null;
    let sawShapedNow = false;

    for (let i = 0; i < 200; i++) {
      const frameDb = i < 2 ? -58 : (i % 8 === 0 ? -58 : -45);
      const frame = harness.drive(frameDb);
      sawShapedNow ||= harness.gate.coldStartSpeechShapedNow;
      if (frame.decision.type === 'startUtterance' && onsetMs === null) {
        onsetMs = (i + 1) * frameDurationMs;
      }
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      if (sawShapedNow) assert.strictEqual(harness.gate.coldStartSpeechShapedNow, true);
    }

    assert.ok(onsetMs !== null && onsetMs <= 200);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
    assert.strictEqual(harness.gate.snapshot.floorDb, -80);
  });

  it('(iv): two close transients emit one chunk then converge without wedging', () => {
    const harness = makeRecorderHarness({
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });

    for (let i = 0; i < 6000; i++) {
      const frameDb = i === 20 || i === 45 ? -40 : -60;
      harness.drive(frameDb);
    }

    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -60) <= 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.reanchorEventCount, 0);
  });

  it('N7: stale time is retained until the machine becomes idle', () => {
    const gate = makeGate();
    gate.floorDb = -70;
    gate.adaptiveRefinementComplete = true;

    for (let i = 0; i < 500; i++) {
      gate.process(-65, frameDuration);
      assert.strictEqual(gate.takePendingReanchorEvent(), false);
      gate.updateFloorTracking(-65, frameDuration, false);
    }

    gate.process(-65, frameDuration);
    assert.strictEqual(gate.takePendingReanchorEvent(), false);
    gate.updateFloorTracking(-65, 0, true);

    gate.process(-65, frameDuration);
    assert.strictEqual(gate.takePendingReanchorEvent(), true);
    assert.strictEqual(gate.snapshot.floorDb, -65);
  });

  it('normalizes stale base time before applying the rise multiplier', () => {
    const shortGate = makeGate({
      adaptiveStaleFloorSeconds: 1.5,
      adaptiveRiseSpeedMultiplier: 4,
    });
    const longGate = makeGate({
      adaptiveStaleFloorSeconds: 3,
      adaptiveRiseSpeedMultiplier: 0.5,
    });
    for (const gate of [shortGate, longGate]) {
      for (let i = 0; i < 10; i++) gate.process(-65, 0.1);
      gate.floorDb = -70;
      gate.adaptiveRefinementComplete = true;
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
    staleGate.adaptiveRefinementComplete = true;

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
    riseGate.floorDb = -70;
    riseGate.adaptiveRefinementComplete = true;
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

  it('R2: emits a continuing-only fallback onset without a mid-utterance re-anchor', () => {
    const harness = makeRecorderHarness();
    let sawFallbackOnset = false;
    let finalized = null;

    prefillAmbient(harness);

    for (let i = 0; i < 200; i++) {
      const frameDb = harness.gate.snapshot.floorDb + 7;
      const frame = harness.drive(frameDb);
      assert.notStrictEqual(frame.output.evidence, 'strong');
      if (frame.output.evidence === 'continuing' && frame.endpointEvidence === 'strong') {
        sawFallbackOnset = true;
      }
    }

    assert.strictEqual(sawFallbackOnset, true);
    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.utteranceQuietestStrongDb, null);
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('N5: headroom guards preserve a valid ceiling and prevent the ambient wedge', () => {
    const gate = makeGate();
    gate.floorDb = -50;

    gate.noteUtteranceEnded(-40);
    assert.strictEqual(gate.speechCeilingDb, null);
    gate.noteUtteranceEnded(-38);
    assert.strictEqual(gate.speechCeilingDb, -38);
    gate.noteUtteranceEnded(null);
    assert.strictEqual(gate.speechCeilingDb, -38);

    const harness = makeRecorderHarness();
    let ambientDb = null;
    let ambientFinalized = null;

    prefillAmbient(harness);
    harness.gate.speechCeilingDb = -35;

    for (let i = 0; i < 200; i++) {
      const frameDb = harness.gate.snapshot.floorDb + 7;
      const frame = harness.drive(frameDb);
      if (frame.decision.type === 'startUtterance') {
        ambientDb = frameDb;
        break;
      }
    }
    assert.ok(ambientDb !== null);

    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        ambientFinalized = frame;
        break;
      }
    }
    assert.ok(ambientFinalized !== null);
    assert.strictEqual(ambientFinalized.discarded, false);
    assert.notStrictEqual(harness.gate.speechCeilingDb, null);

    const floorBeforeIdleAmbient = harness.gate.snapshot.floorDb;
    let reonset = false;
    for (let i = 0; i < 200; i++) {
      const frame = harness.drive(ambientDb);
      if (frame.decision.type === 'startUtterance') reonset = true;
    }
    assert.strictEqual(reonset, false);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.ok(harness.gate.snapshot.floorDb > floorBeforeIdleAmbient);
  });

  it('R3: kept utterances still respect the min-chunk/min-speech gates', () => {
    const quietestStrongDb = -35;
    const harness = makeRecorderHarness({
      minChunkSamples: 1,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
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
    assert.strictEqual(finalized.discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.strictEqual(harness.accumulatorSamples, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('still discards an utterance below both minimum gates', () => {
    const harness = makeRecorderHarness({
      endpointSilenceMs: 800,
      minChunkSamples: Number.MAX_SAFE_INTEGER,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
    });

    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? -35 : -21);
    }

    let finalized = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
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
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    const monologueMs = 60_000;
    let initialFloor = null;

    for (let i = 0; i < monologueMs / frameDurationMs; i++) {
      const frame = harness.drive(i % 8 === 0 ? -54 : -40);
      if (i >= 40) assert.strictEqual(frame.output.evidence, 'strong');
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      initialFloor ??= harness.gate.snapshot.floorDb;
      assert.ok(Math.abs(harness.gate.snapshot.floorDb - initialFloor) <= 1e-9);
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    let finalized = null;
    for (let i = 0; i < 100; i++) {
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
    const ceilingFloor = -49
      - makeVadGateConfig({ mode: 'adaptive' }).adaptiveDeltaDb
      - VAD_SPEECH_CEILING_MARGIN_DB;

    prefillAmbient(harness, 400, -65);
    for (let i = 0; i < 100; i++) {
      harness.drive(i % 8 === 0 ? quietestStrongDb - 14 : quietestStrongDb);
    }
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    for (let i = 0; i < 30; i++) harness.drive(-80);
    assert.strictEqual(harness.endpoint.state, 'endPending');

    let sawAmbiguousEndPending = false;
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(i % 10 === 9 ? -72 : -78);
      if (harness.endpoint.state === 'endPending' && frame.output.evidence === 'ambiguous') {
        sawAmbiguousEndPending = true;
        assert.ok(frame.output.shortSpreadDb >= 5);
      }
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }

    assert.strictEqual(sawAmbiguousEndPending, true);
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

  it('W3: flat gust cycling closes end-pending without resurrection and raises the floor', () => {
    const endpointSilenceMs = 3000;
    const harness = makeRecorderHarness({ endpointSilenceMs });
    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 30; i++) harness.drive(-45);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    const initialFloor = harness.gate.snapshot.floorDb;
    const gustDb = initialFloor + 7.4;
    const lullDb = initialFloor + 2.5;
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
    assert.strictEqual(enteredEndPending, true);

    let finalizedAfterMs = null;
    let sawFlatGust = false;
    let maximumFlatGustDispersion = -Infinity;
    let resurrected = false;
    let highestFloor = initialFloor;
    for (let i = 0; i < 400; i++) {
      const frame = harness.drive(i % 2 === 0 ? gustDb : lullDb);
      highestFloor = Math.max(highestFloor, harness.gate.snapshot.floorDb);
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
    assert.ok(highestFloor > initialFloor + 1);
    assert.ok(highestFloor <= gustDb + 0.001);
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
        assert.strictEqual(frame.endpointEvidence, frame.output.evidence);
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
    prefillAmbient(harness, 300, -60);
    for (let i = 0; i < 30; i++) harness.drive(-45);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    const stableFloor = harness.gate.snapshot.floorDb;
    for (let i = 0; i < 120; i++) {
      const frame = harness.drive(stableFloor + 7);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(harness.endpoint.state, 'speechActive');
      assert.strictEqual(harness.gate.snapshot.floorDb, stableFloor);
    }
  });

  it('W6: whisper spread just below flat closes, just above resumes', () => {
    const below = makeRecorderHarness({ endpointSilenceMs: 1000 });
    prefillAmbient(below, 300, -60);
    for (let i = 0; i < 30; i++) below.drive(-45);
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

  it('uniform quiet speech re-onsets despite stale re-anchor via the sustained continuing fallback', () => {
    const frameMs = 100;
    const harness = makeRecorderHarness({ frameMs });
    let onsetMs = null;
    let usedSustainedFallback = false;

    prefillAmbient(harness, 30, -80);
    for (let i = 0; i < 150; i++) {
      const frame = harness.drive(-73);
      if (frame.endpointEvidence === 'strong' && frame.output.evidence === 'continuing') {
        usedSustainedFallback = true;
      }
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameMs;
        break;
      }
    }

    assert.strictEqual(usedSustainedFallback, true);
    assert.ok(onsetMs !== null && onsetMs <= 1500);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

   it('f″: steady noise cannot funeral-latch while the floor chases at every rise speed', () => {
    for (const multiplier of [0.5, 1.0, 4.0]) {
      const harness = makeRecorderHarness({
        gateConfig: {
          adaptiveDynamicsEnabled: true,
          adaptiveRiseSpeedMultiplier: multiplier,
        },
      });
      prefillAmbient(harness, 300, -60);
      for (let i = 0; i < 300; i++) {
        harness.gate.process(-45, frameDuration);
        harness.gate.takePendingReanchorEvent();
        harness.gate.updateFloorTracking(-45, frameDuration, false);
      }
      harness.gate.floorDb = -60;
      let sawContinuing = false;
      let sawLatch = false;

      for (let i = 0; i < 6000; i++) {
        const frame = harness.drive(-45);
        sawContinuing ||= frame.output.evidence === 'continuing';
        sawLatch ||= frame.latchedContinuingOnset;
        assert.strictEqual(frame.decision.type, 'none');
        assert.strictEqual(harness.endpoint.state, 'idle');
      }

      assert.strictEqual(sawContinuing, true);
      assert.strictEqual(sawLatch, false);
      assert.strictEqual(harness.chunkCount, 0);
      assert.ok(harness.reanchorEventCount <= 1);
      assert.ok(harness.gate.snapshot.floorDb >= -48
        && harness.gate.snapshot.floorDb <= -45);
    }
  });

  it('quiet speech latches on a stable floor before its valleys arrive', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    prefillAmbient(harness, 300, -60);
    let latchAtMs = null;

    for (let i = 0; i < 110; i++) {
      const frame = harness.drive(-52);
      if (frame.latchedContinuingOnset && latchAtMs === null) {
        latchAtMs = (i + 1) * frameDurationMs;
      }
    }

    assert.ok(latchAtMs !== null && latchAtMs >= 1000 && latchAtMs <= 1010);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    for (let i = 0; i < 100; i++) {
      harness.drive(i % 2 === 0 ? -52 : -60);
    }
    for (let i = 0; i < 100; i++) {
      if (harness.drive(-80).decision.type === 'finalizeUtterance') break;
    }

    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('whisper-band continuing evidence still latches when the floor is stable', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -50);

    for (let i = 0; i < 120; i++) {
      const frame = harness.drive(i % 2 === 0 ? -48.5 : -51.5);
      assert.strictEqual(frame.decision.type, 'none');
      assert.strictEqual(harness.endpoint.state, 'idle');
    }

    let sawLatch = false;

    for (let i = 0; i < 110; i++) {
      const floorDb = harness.gate.snapshot.floorDb;
      const frame = harness.drive(floorDb + (i % 2 === 0 ? 6 : 8));
      sawLatch ||= frame.latchedContinuingOnset;
      assert.strictEqual(frame.output.evidence, 'continuing');
    }

    assert.strictEqual(sawLatch, true);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('latches SNR-8 continuing speech across a bidirectional 1.5 dB floor wobble', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -60);
    let latchAtMs = null;

    for (let i = 0; i < 120; i++) {
      const floorDb = i === 0 ? -50 : (i % 2 === 1 ? -51.5 : -53);
      harness.gate.floorDb = floorDb;
      const frame = harness.drive(floorDb + 8);
      assert.strictEqual(frame.output.evidence, 'continuing');
      if (frame.latchedContinuingOnset && latchAtMs === null) {
        latchAtMs = (i + 1) * frameDurationMs;
      }
    }

    assert.ok(latchAtMs !== null && latchAtMs <= 1100);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('suppresses a continuing latch during a net-upward floor chase of at least 3 dB', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -60);
    const initialFloor = -60;
    const finalFloor = -56;
    let sawLatch = false;

    for (let i = 0; i < 120; i++) {
      const floorDb = initialFloor + ((finalFloor - initialFloor) * i) / 119;
      harness.gate.floorDb = floorDb;
      const frame = harness.drive(floorDb + 8);
      sawLatch ||= frame.latchedContinuingOnset;
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(harness.endpoint.state, 'idle');
    }

    assert.strictEqual(sawLatch, false);
    assert.ok(finalFloor - initialFloor >= 3);
  });

  it('allows a continuing latch while the floor falls beneath the streak start', () => {
    const harness = makeRecorderHarness();
    prefillAmbient(harness, 300, -60);
    const initialFloor = -50;
    const finalFloor = -54;
    let latchAtMs = null;

    for (let i = 0; i < 120; i++) {
      const floorDb = initialFloor + ((finalFloor - initialFloor) * i) / 119;
      harness.gate.floorDb = floorDb;
      const frame = harness.drive(floorDb + 8);
      assert.strictEqual(frame.output.evidence, 'continuing');
      if (frame.latchedContinuingOnset && latchAtMs === null) {
        latchAtMs = (i + 1) * frameDurationMs;
      }
    }

    assert.ok(latchAtMs !== null && latchAtMs <= 1100);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('suppresses a continuing latch while a rising P10 drives the floor', () => {
    const harness = makeRecorderHarness({
      gateConfig: {
        adaptiveDynamicsEnabled: true,
        adaptiveDynamicsSpreadDb: 24,
        adaptiveRiseSpeedMultiplier: 0.5,
      },
    });

    for (let i = 0; i < 300; i++) {
      const frameDb = -60 + (15 * i) / 299;
      harness.gate.process(frameDb, frameDuration);
      harness.gate.takePendingReanchorEvent();
      harness.gate.updateFloorTracking(frameDb, frameDuration, false);
    }
    harness.gate.floorDb = -65;

    const initialFloor = harness.gate.floorDb;
    let sawLatch = false;
    for (let i = 0; i < 120; i++) {
      const frameDb = harness.gate.floorDb + 6;
      const frame = harness.drive(frameDb);
      sawLatch ||= frame.latchedContinuingOnset;
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(harness.endpoint.state, 'idle');
    }

    assert.strictEqual(sawLatch, false);
    assert.ok(harness.gate.snapshot.floorDb - initialFloor > 2);
  });

  it('clears the floor snapshot when a continuing streak breaks', () => {
    const harness = makeRecorderHarness({
      gateConfig: {
        adaptiveDynamicsEnabled: true,
        adaptiveDynamicsSpreadDb: 24,
      },
    });

    for (let i = 0; i < 300; i++) {
      harness.gate.process(-60, frameDuration);
      harness.gate.takePendingReanchorEvent();
      harness.gate.updateFloorTracking(-60, frameDuration, false);
    }
    harness.gate.floorDb = -50;

    for (let i = 0; i < 50; i++) {
      const frame = harness.drive(-44);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(frame.latchedContinuingOnset, false);
    }
    harness.drive(-80);
    for (let i = 0; i < 300; i++) harness.drive(-80);

    let sawLatch = false;
    for (let i = 0; i < 110; i++) {
      const frame = harness.drive(-72);
      sawLatch ||= frame.latchedContinuingOnset;
      assert.strictEqual(frame.output.evidence, 'continuing');
    }

    assert.strictEqual(sawLatch, true);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('fallback onset completes with small frames', () => {
    const harness = makeRecorderHarness();
    let onsetMs = null;
    let usedSustainedFallback = false;

    prefillAmbient(harness);
    for (let i = 0; i < 200; i++) {
      const frameDb = harness.gate.snapshot.continuationThresholdDb + 0.1;
      const frame = harness.drive(frameDb);
      assert.strictEqual(frame.output.evidence, 'continuing');
      if (frame.endpointEvidence === 'strong') usedSustainedFallback = true;
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.strictEqual(usedSustainedFallback, true);
    assert.ok(onsetMs !== null && onsetMs <= 2000);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('re-onsets fluctuating speech after ambiguous interruptions', () => {
    const frameMs = 100;
    const harness = makeRecorderHarness({ frameMs });
    let onsetMs = null;
    let usedSustainedFallback = false;

    prefillAmbient(harness, 30, -80);
    for (let i = 0; i < 60; i++) {
      let frameDb;
      if (i < 10) {
        frameDb = i % 5 === 0 ? -75 : -73;
      } else {
        const continuationThreshold = harness.gate.snapshot.continuationThresholdDb;
        frameDb = continuationThreshold + (i % 2 === 0 ? 0.05 : 0.2);
      }
      const frame = harness.drive(frameDb);
      if (frame.endpointEvidence === 'strong' && frame.output.evidence === 'continuing') {
        usedSustainedFallback = true;
      }
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameMs;
        break;
      }
    }

    assert.strictEqual(usedSustainedFallback, true);
    assert.ok(onsetMs !== null && onsetMs <= 2500);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('steady noise above the floor does not false-open via fallback onset', () => {
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
    const adaptiveDeltaDb = makeVadGateConfig({ mode: 'adaptive' }).adaptiveDeltaDb;
    const ceilingFloor = quietestStrongDb - adaptiveDeltaDb - VAD_SPEECH_CEILING_MARGIN_DB;
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
    gate.floorDb = -40;

    for (let i = 0; i < 150; i++) {
      const loudFrameDb = gate.floorDb + 5;
      gate.process(loudFrameDb, frameDuration);
      gate.updateFloorTracking(loudFrameDb, frameDuration, false);
      assert.strictEqual(gate.snapshot.floorDb, -40);
    }
    assert.strictEqual(gate.snapshot.floorDb, -40);

    for (let i = 0; i < 300; i++) {
      const loudFrameDb = gate.floorDb + 5;
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
    const ceilingFloor = quietestStrongDb - 10 - VAD_SPEECH_CEILING_MARGIN_DB;
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
    gate.floorDb = -40;

    for (let i = 0; i < 150; i++) {
      const frameDb = gate.floorDb + 5;
      gate.process(frameDb, frameDuration);
      gate.updateFloorTracking(frameDb, frameDuration, false);
      assert.strictEqual(gate.snapshot.floorDb, -40);
    }

    for (let i = 0; i < 300; i++) {
      const frameDb = gate.floorDb + 5;
      gate.process(frameDb, frameDuration);
      gate.updateFloorTracking(frameDb, frameDuration, true);
    }

    assert.strictEqual(gate.speechCeilingDb, null);
    assert.ok(gate.snapshot.floorDb > ceilingFloor);
  });

  it('stale re-anchor lands on the speech ceiling cap', () => {
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
    const ceilingFloor = quietestStrongDb - 10 - VAD_SPEECH_CEILING_MARGIN_DB;
    gate.floorDb = -60;
    let reanchorEvent = false;
    for (let i = 0; i < 301; i++) {
      const frameDb = quietestStrongDb + 7;
      gate.process(frameDb, frameDuration);
      if (gate.takePendingReanchorEvent()) reanchorEvent = true;
      gate.updateFloorTracking(frameDb, 0, true);
    }

    assert.strictEqual(reanchorEvent, true);
    assert.ok(Math.abs(gate.snapshot.floorDb - ceilingFloor) < 0.001);
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
  });
});
