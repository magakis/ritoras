import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const FRAME_MS = 10;

function prefill(harness, frameDb, frames = 300) {
  for (let i = 0; i < frames; i++) harness.drive(frameDb);
  harness.gate.updateFloorTracking = () => {};
}

describe('sustained continuing onset latch regime split', () => {
  it('does not latch flat continuation-band wobble on a quiet converged floor', () => {
    const harness = makeRecorderHarness({
      gateConfig: { adaptiveContinuationDeltaDb: 2 },
    });
    prefill(harness, -52);
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -52) < 1);

    for (let i = 0; i < 120; i++) {
      const frame = harness.drive(i % 2 === 0 ? -49.5 : -50);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.ok(frame.output.dynamicsSpreadDb < harness.gate.effectiveFlatSpreadDb);
      assert.strictEqual(frame.latchedContinuingOnset, false);
      assert.strictEqual(frame.decision.type, 'none');
    }

    assert.strictEqual(harness.chunkCount, 0);
  });

  it('does not latch dispersive loud-regime noise whose peaks stay below floor plus strong delta', () => {
    const harness = makeRecorderHarness({
      gateConfig: { adaptiveDynamicsSpreadDb: 24 },
    });
    prefill(harness, -30);
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.ok(Math.abs(harness.gate.snapshot.floorDb - -30) < 1);

    for (let i = 0; i < 120; i++) {
      const frame = harness.drive(i % 2 === 0 ? -23 : -20.5);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(frame.latchedContinuingOnset, false);
      assert.strictEqual(frame.decision.type, 'none');
    }

    assert.strictEqual(harness.chunkCount, 0);
  });

  it('latches a loud-room speech interjection after 1.5 seconds of strong-level continuing evidence', () => {
    const harness = makeRecorderHarness({
      gateConfig: { adaptiveDynamicsSpreadDb: 24 },
    });
    prefill(harness, -30);
    let latchAtMs = null;

    for (let i = 0; i < 170; i++) {
      const frame = harness.drive(i % 2 === 0 ? -19 : -21);
      assert.strictEqual(frame.output.evidence, 'continuing');
      if (frame.latchedContinuingOnset && latchAtMs === null) {
        latchAtMs = (i + 1) * FRAME_MS;
      }
    }

    assert.ok(latchAtMs !== null && latchAtMs >= 1500);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
    assert.strictEqual(harness.chunkCount, 0);
  });

  it('preserves quiet-room soft phrase-tail continuation with sufficient level margin', () => {
    const harness = makeRecorderHarness();
    prefill(harness, -52);
    let latchAtMs = null;

    for (let i = 0; i < 110; i++) {
      const frame = harness.drive(-43);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.ok(frame.output.dynamicsSpreadDb >= harness.gate.effectiveFlatSpreadDb);
      if (frame.latchedContinuingOnset && latchAtMs === null) {
        latchAtMs = (i + 1) * FRAME_MS;
      }
    }

    assert.ok(latchAtMs !== null && latchAtMs >= 1000 && latchAtMs <= 1010);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('latches quiet modulated in-band continuation despite peaks below floor plus strong delta', () => {
    const harness = makeRecorderHarness();
    prefill(harness, -52);
    let sawLatch = false;

    for (let i = 0; i < 110; i++) {
      // Quiet-regime modulated in-band noise remains a documented residual:
      // energy-only VAD cannot separate it from soft speech (reduced, not eliminated, per R3).
      const frameDb = i % 2 === 0 ? -42.5 : -45.5;
      const frame = harness.drive(frameDb);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.ok(frame.output.dynamicsSpreadDb >= 9);
      assert.ok(frameDb < harness.gate.snapshot.floorDb + 10);
      sawLatch ||= frame.latchedContinuingOnset;
    }

    assert.strictEqual(sawLatch, true);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('latches continuing evidence after contaminated calibration seeds a converged floor', () => {
    const harness = makeRecorderHarness({
      gateConfig: {
        mode: 'calibrated',
        calibrationMs: 120,
        adaptiveAbsoluteSpeechFloorDb: -80,
      },
    });
    for (let i = 0; i < 12; i++) {
      harness.drive(i < 3 ? -30 : -21);
    }
    assert.strictEqual(harness.gate.coldStartConverged, true);
    assert.notStrictEqual(harness.gate.behaviorMode, 'calibrated');
    harness.gate.updateFloorTracking = () => {};

    // The latch qualifies at 1.5 s (frame 150); that frame contributes 10 ms
    // of the 70 ms onset window, so six more frames complete the onset.
    for (let i = 0; i < 157; i++) {
      const frame = harness.drive(-20);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.strictEqual(frame.output.floorConverged, true);
      if (i < 149) {
        assert.strictEqual(frame.latchedContinuingOnset, false);
      } else if (i < 156) {
        assert.strictEqual(frame.latchedContinuingOnset, true);
      } else {
        assert.strictEqual(frame.latchedContinuingOnset, false);
      }
    }

    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });
});
