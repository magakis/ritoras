import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import { parseSession, replaySession } from '../bin/replay-vad.mjs';

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
      gateConfig: { adaptiveDynamicsSpreadDb: 24, loudRegimeEnabled: false },
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
      gateConfig: { adaptiveDynamicsSpreadDb: 24, loudRegimeEnabled: false },
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

  it('rejects a steady pure-tone streak whose spread is below the witness', () => {
    const harness = makeRecorderHarness({
      gateConfig: {
        loudRegimeEnabled: true,
        loudDynamicsSpreadDb: 9,
      },
      recorderConfig: { loudLatchMs: 100 },
    });
    prefill(harness, -30);
    harness.gate.floorDb = -30;
    harness.gate.isLoudRegime = true;
    for (let index = 0; index < 400; index += 1) harness.gate.process(-20, 0.01);
    harness.gate.updateFloorTracking = () => {};

    for (let index = 0; index < 120; index += 1) {
      const frame = harness.drive(-20);
      assert.strictEqual(frame.output.evidence, 'continuing');
      assert.ok(frame.output.dynamicsSpreadDb < harness.loudLatchWitnessDb);
      assert.strictEqual(frame.latchedContinuingOnset, false);
    }

    assert.strictEqual(harness.latchMissingDynamicsWitnessCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('rescues the E31F3FEF cold-seed speech regression with the 3 dB witness', () => {
    const telemetry = fs.readFileSync(new URL(
      '../fixtures/vad-telemetry/E31F3FEF-15A6-467B-AF05-7C7D7D9ACD06-vad.jsonl',
      import.meta.url,
    ), 'utf8');
    const session = parseSession(telemetry);
    const baseline = replaySession(session, {
      ...session.config,
      loudRegimeEnabled: false,
      strongDeltaDb: 10,
      continuationDeltaDb: 6,
      silenceDeltaDb: 3,
      loudLatchMs: 1500,
    }, { compare: false });
    assert.equal(baseline.metrics.chunkCount, 0);
    assert.equal(baseline.events.find(event => event.k === 'stop_flush').r, 'empty');

    const rescued = replaySession(session, session.config, { compare: false });
    const start = rescued.events.find(event => event.k === 'start_utterance');
    const emitted = rescued.events.find(event => event.k === 'emit');
    assert.equal(session.config.loudLatchAmbiguousEnabled, false);
    assert.equal(session.config.loudLatchWitnessDb, 3);
    assert.equal(rescued.metrics.utteranceCount, 1);
    assert.equal(rescued.metrics.chunkCount, 1);
    assert.ok(start.time >= 0.9 && start.time <= 1.2);
    assert.equal(emitted.s0, 0);
    assert.ok(emitted.s1 >= 2100);
    assert.ok(emitted.sm >= 1000);
    assert.ok(rescued.frames.some(frame => frame.lr === true));
    assert.ok(rescued.frames.every(frame => frame.lr === undefined || frame.lr === true));
    assert.ok(rescued.frames.filter(frame => frame.q >= 4 && frame.q <= 6)
      .every(frame => frame.e === 'ambiguous' && frame.ls === 0 && frame.ll === false));
    const witnessedSpeech = rescued.frames.filter(frame => frame.q >= 7 && frame.q <= 10);
    assert.ok(witnessedSpeech.some(frame => frame.dy >= 4 && frame.dy < 7));
  });

  it('leaves the quiet continuing branch unchanged with the loud master enabled', () => {
    function quietTrace(loudRegimeEnabled) {
      const frames = [];
      const events = [];
      const harness = makeRecorderHarness({
        gateConfig: { loudRegimeEnabled },
        onFrame: frame => frames.push(frame),
        onEvent: event => events.push(event),
      });
      prefill(harness, -52);
      for (let index = 0; index < 110; index += 1) harness.drive(-43);
      harness.flush();
      return {
        frames,
        starts: events.filter(event => event.k === 'start_utterance'),
        emits: events.filter(event => event.k === 'emit'),
      };
    }

    assert.deepStrictEqual(quietTrace(true), quietTrace(false));
  });

  it('keeps ambiguous-only streaks inert when the ambiguous option defaults off', () => {
    const harness = makeRecorderHarness({
      gateConfig: { loudRegimeEnabled: true },
      recorderConfig: { loudLatchMs: 100 },
    });
    prefill(harness, -30);
    harness.gate.floorDb = -30;
    harness.gate.isLoudRegime = true;
    for (let index = 0; index < 400; index += 1) harness.gate.process(-27.5, 0.01);
    harness.gate.updateFloorTracking = () => {};

    for (let index = 0; index < 120; index += 1) {
      const frame = harness.drive(-27.5);
      assert.strictEqual(frame.output.evidence, 'ambiguous');
      assert.strictEqual(frame.latchedContinuingOnset, false);
    }

    assert.strictEqual(harness.loudLatchAmbiguousEnabled, false);
    assert.strictEqual(harness.endpoint.state, 'idle');
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
        loudRegimeEnabled: false,
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
