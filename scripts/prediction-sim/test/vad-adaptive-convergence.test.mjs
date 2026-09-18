import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  makeVadGateConfig,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import { StreamingEndpoint } from '../lib/streaming-endpoint.mjs';

const frameDurationMs = 10;
const frameDuration = frameDurationMs / 1000;
const frameSamples = frameDurationMs * 16;

function makeGate() {
  return new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
}

function makeEndpoint() {
  return new StreamingEndpoint({ endpointSilenceMs: 3000 });
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

function makeRecorderHarness() {
  const harness = {
    gate: makeGate(),
    endpoint: makeEndpoint(),
    chunkCount: 0,
    reanchorEventCount: 0,
    requiresPostReanchorSpeech: false,

    drive(frameDb) {
      const output = this.gate.process(frameDb, frameDuration);
      const reanchorEvent = this.gate.takePendingReanchorEvent();
      const previousState = this.endpoint.state;
      if (reanchorEvent) this.reanchorEventCount += 1;

      if (reanchorEvent
        && (previousState === 'speechActive' || previousState === 'endPending')) {
        this.requiresPostReanchorSpeech = true;
      } else if (!reanchorEvent
        && this.requiresPostReanchorSpeech
        && output.evidence === 'strong') {
        this.requiresPostReanchorSpeech = false;
      }

      const decision = this.endpoint.process(output.evidence, frameSamples);
      this.gate.updateFloorTracking(
        frameDb,
        frameDuration,
        previousState === 'idle' && this.endpoint.state === 'idle',
      );

      let discarded = false;
      if (decision.type === 'finalizeUtterance') {
        if (this.requiresPostReanchorSpeech) {
          this.requiresPostReanchorSpeech = false;
          discarded = true;
        } else {
          this.chunkCount += 1;
        }
      }
      return { output, decision, reanchorEvent, discarded };
    },
  };
  return harness;
}

describe('adaptive VAD convergence', () => {
  it('breaks the sustained ambient deadlock and reaches the endpoint', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let firstSilenceMs = null;
    let endpointMs = null;

    for (let i = 0; i < 700; i++) {
      const { output, decision } = driveFrame(gate, endpoint, -65);
      const elapsedMs = (i + 1) * frameDurationMs;
      if (output.evidence === 'silence' && firstSilenceMs === null) {
        firstSilenceMs = elapsedMs;
      }
      if (decision.type === 'finalizeUtterance') {
        endpointMs = elapsedMs;
        break;
      }
    }

    assert.ok(firstSilenceMs !== null && firstSilenceMs <= 4100);
    assert.ok(endpointMs !== null && endpointMs <= 7100);
  });

  it('keeps continuous voiced speech strong and never chases its floor', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalized = false;
    let maximumFloor = -Infinity;

    for (let i = 0; i < 6000; i++) {
      const { output, decision } = driveFrame(gate, endpoint, -21);
      assert.strictEqual(output.evidence, 'strong');
      if (i >= 6) assert.strictEqual(endpoint.state, 'speechActive');
      maximumFloor = Math.max(maximumFloor, gate.snapshot.floorDb);
      if (decision.type === 'finalizeUtterance') finalized = true;
    }

    assert.strictEqual(finalized, false);
    assert.ok(maximumFloor <= -21);
  });

  it('ends talk-then-silence after stale-floor convergence plus endpoint silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    for (let i = 0; i < 1000; i++) {
      const { decision } = driveFrame(gate, endpoint, -21);
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    for (let i = 0; i < 720; i++) {
      const { decision } = driveFrame(gate, endpoint, -65);
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
    const endpoint = makeEndpoint();

    for (let i = 0; i < 500; i++) {
      driveFrame(gate, endpoint, -65);
    }

    assert.ok(Math.abs(gate.snapshot.silenceThresholdDb - -62) <= 0.5);
  });

  it('refuses re-anchor above the headroom guard and keeps the floor pinned', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let lastFrame = null;
    let endpointReached = false;

    for (let i = 0; i < 600; i++) {
      lastFrame = driveFrame(gate, endpoint, -25);
      if (lastFrame.decision.type === 'finalizeUtterance') {
        endpointReached = true;
        break;
      }
    }

    // Extreme ambient above the -30 dB headroom guard cannot converge: the
    // floor stays at its refined -80 dB seed, so silence remains undetectable.
    // This is app-target only; stop/flush still delivers the audio, with the
    // accumulator growing at the bounded input rate (about 64 KB/s).
    assert.ok(lastFrame !== null);
    assert.strictEqual(lastFrame.output.floorDb, -80);
    assert.strictEqual(gate.snapshot.floorDb, -80);
    assert.strictEqual(lastFrame.output.evidence, 'strong');
    assert.strictEqual(lastFrame.reanchorEvent, false);
    assert.strictEqual(endpointReached, false);
    assert.strictEqual(endpoint.state, 'speechActive');
  });

  it('survives the ambiguous rescue during re-anchor convergence and reaches silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let rescued = false;

    for (let i = 0; i < 450; i++) {
      driveFrame(gate, endpoint, -65);
    }

    for (let i = 0; i < 50; i++) {
      const { output, previousState } = driveFrame(gate, endpoint, -60);
      if (previousState === 'endPending'
        && endpoint.state === 'speechActive'
        && output.evidence === 'ambiguous') {
        rescued = true;
      }
    }

    let endpointReached = false;
    for (let i = 0; i < 800; i++) {
      const { decision } = driveFrame(gate, endpoint, -60);
      if (decision.type === 'finalizeUtterance') {
        endpointReached = true;
        break;
      }
    }

    assert.strictEqual(rescued, true);
    assert.strictEqual(endpointReached, true);
  });

  it('does not stale-reanchor a quick recording shorter than three seconds', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();

    for (let i = 0; i < 290; i++) {
      const { output, decision } = driveFrame(gate, endpoint, -21);
      assert.strictEqual(output.evidence, 'strong');
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    assert.strictEqual(gate.snapshot.floorDb, -80);
  });

  it('discards a pure-ambient utterance after re-anchor endpoint', () => {
    const harness = makeRecorderHarness();
    let finalized = false;
    let discarded = false;

    for (let i = 0; i < 700; i++) {
      const frame = harness.drive(-65);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        discarded = frame.discarded;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 1);
    assert.strictEqual(finalized, true);
    assert.strictEqual(discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('keeps an utterance when real speech follows ambient re-anchor', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-65);
    for (let i = 0; i < 30; i++) harness.drive(-21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-65);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 1);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('does not discard speech that starts on the first frame', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-65);
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

  it('documents flat monotone speech re-anchoring onto itself', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    // With fewer than 3 dB of dynamics, the stale window's P10 is the speech
    // level itself. The floor re-anchors to -40 dB, so the thresholds become
    // -30/-34/-37 dB and this flat monologue is classified as silence and ends
    // at the configured silence duration.
    // Realistic speech has inter-word dips of at least 10 dB, placing P10 below
    // the speech mode instead of on top of it.
    for (let i = 0; i < 6000; i++) {
      const { decision } = driveFrame(gate, endpoint, -40);
      if (decision.type === 'finalizeUtterance') {
        finalizedAtMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.ok(finalizedAtMs !== null);
    assert.ok(finalizedAtMs >= 5000 && finalizedAtMs <= 7100);
    assert.strictEqual(endpoint.state, 'idle');
  });
});
