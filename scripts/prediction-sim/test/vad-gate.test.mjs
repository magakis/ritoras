import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  dbFromRms,
  rmsFromDb,
  makeVadGateConfig,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import { StreamingEndpoint } from '../lib/streaming-endpoint.mjs';

function config(partial = {}) {
  return makeVadGateConfig(partial);
}

function seedAdaptiveGate(partial = {}, seedDb = -50) {
  const gate = new VADThresholdGate(config({
    mode: 'adaptive',
    ...partial,
  }));
  for (let i = 0; i < 10; i++) gate.process(seedDb, 0.1);
  return gate;
}

function advancePastAdaptiveEarlyWindow(gate, frameDb = -65) {
  for (let i = 0; i < 41; i++) {
    gate.process(frameDb, 0.1);
    gate.updateFloorIfIdle(frameDb, 0.1, false);
  }
}

describe('VADThresholdGate', () => {
  describe('AudioMath mirror and static mode', () => {
    it('converts RMS to dB and back without a zero-input NaN', () => {
      assert.ok(Math.abs(dbFromRms(0.025) - -32.0412) < 0.01);
      assert.strictEqual(dbFromRms(0), -100);
      assert.strictEqual(rmsFromDb(-100) > 0, true);
    });

    it('flips at the static threshold and matches linear RMS comparison', () => {
      const gate = new VADThresholdGate(config({ mode: 'static', staticRms: 0.025 }));
      const thresholdDb = gate.snapshot.thresholdDb;
      assert.strictEqual(gate.process(thresholdDb - 0.0001, 0.1).isSpeech, false);
      assert.strictEqual(gate.process(thresholdDb + 0.0001, 0.1).isSpeech, true);

      for (const rms of [0, 1e-12, 0.01, 0.024999, 0.025, 0.1]) {
        const result = new VADThresholdGate(
          config({ mode: 'static', staticRms: 0.025 }),
        ).process(dbFromRms(rms), 0.1);
        assert.strictEqual(result.isSpeech, rms >= 0.025, `RMS ${rms}`);
        assert.strictEqual(Number.isNaN(result.thresholdDb), false);
      }
    });
  });

  describe('calibrated mode', () => {
    it('holds a quiet calibration window and then applies Q1 plus offset', () => {
      const gate = new VADThresholdGate(config({
        mode: 'calibrated',
        calibrationMs: 300,
        calibratedOffsetDb: 10,
      }));
      for (const frameDb of [-50, -49, -51]) {
        const output = gate.process(frameDb, 0.1);
        assert.strictEqual(output.calibrating, true);
        assert.strictEqual(output.isSpeech, false);
        assert.strictEqual(output.floorDb, null);
      }

      const output = gate.process(-40.9, 0.1);
      assert.strictEqual(output.calibrating, false);
      assert.strictEqual(output.usedFallback, false);
      assert.strictEqual(output.thresholdDb, -41);
      assert.strictEqual(output.isSpeech, true);
    });

    it('accepts a talk-immediately-safe window with speech in its upper half', () => {
      const gate = new VADThresholdGate(config({
        mode: 'calibrated',
        calibrationMs: 1000,
        calibratedOffsetDb: 10,
      }));
      const window = [-50, -30, -50, -30, -50, -30, -50, -30, -50, -30];
      for (const frameDb of window) {
        const output = gate.process(frameDb, 0.1);
        assert.strictEqual(output.calibrating, true);
        assert.strictEqual(output.isSpeech, false);
      }

      const output = gate.process(-29.5, 0.1);
      assert.strictEqual(output.calibrating, false);
      assert.strictEqual(output.usedFallback, false);
      assert.strictEqual(output.thresholdDb, -40);
      assert.strictEqual(output.isSpeech, true);
      assert.ok(Math.abs(output.retroactiveSpeechMs - 500) < 0.001);
      assert.strictEqual(output.trailingSilenceMs, 0);

      const second = gate.process(-29.5, 0.1);
      assert.strictEqual(second.retroactiveSpeechMs, 0);
      assert.strictEqual(second.trailingSilenceMs, null);
    });

    it('rejects a contaminated window and falls back to adaptive tracking', () => {
      const gate = new VADThresholdGate(config({
        mode: 'calibrated',
        calibrationMs: 600,
        calibratedOffsetDb: 10,
        adaptiveDeltaDb: 10,
      }));
      for (const frameDb of [-60, -60, -20, -20, -20, -20]) {
        gate.process(frameDb, 0.1);
      }

      const output = gate.process(-70, 0.5);
      assert.strictEqual(output.usedFallback, true);
      assert.strictEqual(output.isSpeech, false);
      assert.strictEqual(output.floorDb, -60);
      assert.ok(Math.abs(output.retroactiveSpeechMs - 400) < 0.001);
      gate.process(-70, 0.5);
      gate.updateFloorIfIdle(-70, 0.5);
      const expectedFloor = -60 + (1 - Math.exp(-1)) * (-10);
      assert.ok(Math.abs(gate.snapshot.floorDb - expectedFloor) < 0.001);
    });

    it('accepts exactly the quiet-count quality boundary and rejects one fewer', () => {
      const accepted = new VADThresholdGate(config({
        mode: 'calibrated',
        calibrationMs: 1200,
      }));
      for (const frameDb of [-50, -50, -50, -50, ...Array(8).fill(-30)]) {
        accepted.process(frameDb, 0.1);
      }
      assert.strictEqual(accepted.process(-30, 0.1).usedFallback, false);

      const rejected = new VADThresholdGate(config({
        mode: 'calibrated',
        calibrationMs: 1200,
      }));
      for (const frameDb of [-50, -50, -50, ...Array(9).fill(-30)]) {
        rejected.process(frameDb, 0.1);
      }
      assert.strictEqual(rejected.process(-30, 0.1).usedFallback, true);
    });

    it('credits speech and trailing silence once after the window', () => {
      const gate = new VADThresholdGate(config({
        mode: 'calibrated',
        calibrationMs: 1700,
        calibratedOffsetDb: 10,
      }));
      const window = [
        ...Array(6).fill(-50),
        ...Array(8).fill(-30),
        ...Array(3).fill(-50),
      ];
      for (const frameDb of window) gate.process(frameDb, 0.1);

      const first = gate.process(-50, 0.1);
      assert.ok(Math.abs(first.retroactiveSpeechMs - 800) < 0.001);
      assert.ok(Math.abs(first.trailingSilenceMs - 300) < 0.001);
      const second = gate.process(-30, 0.1);
      assert.strictEqual(second.retroactiveSpeechMs, 0);
      assert.strictEqual(second.trailingSilenceMs, null);
    });
  });

  describe('adaptive mode', () => {
    it('opens a speech utterance from frame one and flushes a quick recording', () => {
      const gate = new VADThresholdGate(config({
        mode: 'adaptive',
      }));
      const endpoint = new StreamingEndpoint();
      const frameSamples = 160;
      let openedAtMs = null;
      let speechSamples = 0;

      for (let i = 0; i < 150; i++) {
        const output = gate.process(-45, 0.01);
        if (i === 0) assert.strictEqual(output.evidence, 'strong');
        if (output.isSpeech) speechSamples += frameSamples;
        const decision = endpoint.process(output.evidence, frameSamples);
        if (decision.type === 'startUtterance' && openedAtMs === null) {
          openedAtMs = (i + 1) * 10;
        }
      }

      assert.ok(openedAtMs !== null && openedAtMs <= 70);
      assert.ok(speechSamples >= 300 * 16);
      assert.deepStrictEqual(endpoint.forceFinalize('stop'), {
        type: 'finalizeUtterance',
        kind: 'stop',
      });
    });

    it('keeps the low seed from rising when speech starts on frame one', () => {
      const gate = new VADThresholdGate(config({ mode: 'adaptive' }));
      for (let i = 0; i < 10; i++) {
        gate.process(-45, 0.1);
      }
      assert.ok(gate.snapshot.floorDb <= -45);
    });

    it('stabilizes a quiet room near ambient during the five-second early window', () => {
      const gate = new VADThresholdGate(config({ mode: 'adaptive' }));
      for (let i = 0; i < 50; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorIfIdle(-65, 0.1, true);
      }
      assert.ok(Math.abs(gate.snapshot.floorDb - -65) <= 3);
      assert.notStrictEqual(gate.process(-65, 0.1).evidence, 'strong');
    });

    it('returns to the sustained-idle rise gate after the early window', () => {
      const gate = new VADThresholdGate(config({ mode: 'adaptive' }));
      for (let i = 0; i < 50; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorIfIdle(-65, 0.1, false);
      }
      gate.floorDb = -78;

      gate.process(-65, 0.1);
      gate.updateFloorIfIdle(-65, 0.1, true);
      assert.ok(Math.abs(gate.snapshot.floorDb - -77.85) < 0.001);
    });

    it('uses the fast fall tau and capped upward movement', () => {
      const fallGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -60);
      fallGate.floorDb = -50;
      fallGate.process(-60, 0.1);
      const fall = fallGate.updateFloorIfIdle(-60, 0.5) || fallGate.snapshot;
      const expectedFall = -50 + (1 - Math.exp(-1)) * (-10);
      assert.ok(Math.abs(fall.floorDb - expectedFall) < 0.001);

      const riseGate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -58);
      riseGate.floorDb = -60;
      riseGate.updateFloorIfIdle(-58, 7);
      const rise = riseGate.snapshot;
      const expectedRise = -58;
      assert.ok(Math.abs(rise.floorDb - expectedRise) < 0.001);
    });

    it('respects both floor clamp bounds', () => {
      const lowGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -100);
      assert.strictEqual(lowGate.snapshot.floorDb, -80);

      const highGate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -10);
      highGate.updateFloorIfIdle(-10, 10, true);
      assert.strictEqual(highGate.snapshot.floorDb, -20);
    });

    it('uses a lower continuation threshold than the onset threshold', () => {
      const gate = seedAdaptiveGate({
        adaptiveDeltaDb: 10,
      }, -50);
      gate.floorDb = -50;
      const output = gate.process(-42, 0.1);
      assert.ok(output.continuationThresholdDb < output.thresholdDb);
      assert.strictEqual(output.evidence, 'continuing');
      assert.strictEqual(output.isSpeech, true);
    });

    it('freezes during non-idle states and resumes immediately when idle', () => {
      const gate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -50);
      gate.floorDb = -50;
      advancePastAdaptiveEarlyWindow(gate, -60);
      gate.process(-30, 0.1);
      assert.strictEqual(gate.snapshot.floorDb, -50);

      for (let i = 0; i < 31; i++) {
        gate.process(-60, 0.1);
        gate.updateFloorIfIdle(-60, 0.1, false);
      }
      assert.strictEqual(gate.snapshot.floorDb, -50);
      gate.process(-60, 0.1);
      gate.updateFloorIfIdle(-60, 0.1, true);
      assert.ok(gate.snapshot.floorDb < -50);
    });

    it('keeps baseline rise capped before sustained idle and then catches up', () => {
      const gate = seedAdaptiveGate({}, -65);
      advancePastAdaptiveEarlyWindow(gate, -65);
      gate.floorDb = -78;

      for (let i = 0; i < 14; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorIfIdle(-65, 0.1, true);
      }
      assert.ok(gate.snapshot.floorDb <= -75.9 + 0.001);

      for (let i = 0; i < 16; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorIfIdle(-65, 0.1, true);
      }
      assert.ok(Math.abs(gate.snapshot.floorDb - -66.3) < 0.001);
    });

    it('does not reset sustained idle time for a cancelled onset', () => {
      const gate = seedAdaptiveGate({}, -65);
      advancePastAdaptiveEarlyWindow(gate, -65);
      gate.floorDb = -78;

      for (let i = 0; i < 14; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorIfIdle(-65, 0.1, true);
      }
      const beforeBlip = gate.snapshot.floorDb;
      gate.updateFloorIfIdle(-65, 0.1, false);
      gate.updateFloorIfIdle(-65, 0.1, true);
      assert.ok(gate.snapshot.floorDb - beforeBlip >= 0.6 - 0.001);

      gate.updateFloorIfIdle(-65, 0.1, false, true);
      gate.process(-65, 0.1);
      gate.updateFloorIfIdle(-65, 0.1, true);
      assert.ok(gate.snapshot.floorDb - (beforeBlip + 0.6) <= 0.15 + 0.001);
    });

    it('classifies the gap between silence and continuation as ambiguous', () => {
      const gate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -50);
      for (let i = 0; i < 50; i++) {
        gate.process(-50, 0.1);
        gate.updateFloorIfIdle(-50, 0.1, true);
      }
      const output = gate.process(-45, 0.1);
      assert.strictEqual(output.evidence, 'ambiguous');
      assert.strictEqual(output.isSpeech, false);
    });

    it('converges to the same floor for equivalent variable frame durations', () => {
      const coarse = seedAdaptiveGate({ adaptiveDeltaDb: 30 }, -60);
      const fine = seedAdaptiveGate({ adaptiveDeltaDb: 30 }, -60);
      coarse.floorDb = -50;
      fine.floorDb = -50;
      for (let i = 0; i < 5; i++) {
        coarse.process(-60, 0.08533);
        coarse.updateFloorIfIdle(-60, 0.08533);
      }
      for (let i = 0; i < 5; i++) {
        fine.process(-60, 0.042665);
        fine.updateFloorIfIdle(-60, 0.042665);
        fine.process(-60, 0.042665);
        fine.updateFloorIfIdle(-60, 0.042665);
      }
      assert.ok(Math.abs(coarse.snapshot.floorDb - fine.snapshot.floorDb) < 1e-9);
    });
  });
});
