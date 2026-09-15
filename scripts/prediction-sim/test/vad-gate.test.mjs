import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  dbFromRms,
  rmsFromDb,
  makeVadGateConfig,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';

function config(partial = {}) {
  return makeVadGateConfig(partial);
}

function seedAdaptiveGate(partial = {}, seedDb = -50) {
  const gate = new VADThresholdGate(config({
    mode: 'adaptive',
    adaptiveHysteresisEnabled: false,
    ...partial,
  }));
  for (let i = 0; i < 6; i++) gate.process(seedDb, 0.1);
  return gate;
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
      const expectedFloor = -60 + (1 - Math.exp(-1)) * (-10);
      assert.strictEqual(output.usedFallback, true);
      assert.strictEqual(output.isSpeech, false);
      assert.ok(Math.abs(output.floorDb - expectedFloor) < 0.001);
      assert.ok(Math.abs(output.retroactiveSpeechMs - 400) < 0.001);
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
    it('seeds the floor from the minimum of the first six frames', () => {
      const gate = new VADThresholdGate(config({
        mode: 'adaptive',
        adaptiveHysteresisEnabled: false,
      }));
      for (const frameDb of [-50, -49, -48, -47, -46, -70]) {
        gate.process(frameDb, 0.1);
      }
      assert.strictEqual(gate.snapshot.floorDb, -70);

      const speech = gate.process(-30, 0.1);
      assert.strictEqual(speech.isSpeech, true);
      assert.strictEqual(speech.floorDb, -70);
      assert.strictEqual(gate.process(-30, 0.1).floorDb, -70);
    });

    it('uses the fast fall and slow rise time constants', () => {
      const fallGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -50);
      const fall = fallGate.process(-60, 0.5);
      const expectedFall = -50 + (1 - Math.exp(-1)) * (-10);
      assert.ok(Math.abs(fall.floorDb - expectedFall) < 0.001);

      const riseGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -60);
      const rise = riseGate.process(-50, 7);
      const expectedRise = -60 + (1 - Math.exp(-1)) * 10;
      assert.ok(Math.abs(rise.floorDb - expectedRise) < 0.001);
    });

    it('respects both floor clamp bounds', () => {
      const lowGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -100);
      assert.strictEqual(lowGate.snapshot.floorDb, -80);

      const highGate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -10);
      assert.strictEqual(highGate.snapshot.floorDb, -20);
    });

    it('uses hysteresis for entering and continuing speech', () => {
      const gate = seedAdaptiveGate({
        adaptiveDeltaDb: 10,
        adaptiveHysteresisEnabled: true,
      }, -50);
      const inSpeechProbe = -50 + 10 + 1.5;
      assert.strictEqual(gate.process(inSpeechProbe, 0.1).isSpeech, true);
      assert.strictEqual(gate.process(inSpeechProbe, 0.1).isSpeech, false);

      const noHysteresisGate = seedAdaptiveGate({
        adaptiveDeltaDb: 10,
        adaptiveHysteresisEnabled: false,
      }, -50);
      assert.strictEqual(noHysteresisGate.process(inSpeechProbe, 0.1).isSpeech, true);
      assert.strictEqual(noHysteresisGate.process(inSpeechProbe, 0.1).isSpeech, true);
    });

    it('converges to the same floor for equivalent variable frame durations', () => {
      const coarse = seedAdaptiveGate({ adaptiveDeltaDb: 30 }, -50);
      const fine = seedAdaptiveGate({ adaptiveDeltaDb: 30 }, -50);
      const trajectory = [-60, -55, -65, -58, -62];
      for (const frameDb of trajectory) coarse.process(frameDb, 0.08533);
      for (const frameDb of trajectory) {
        fine.process(frameDb, 0.042665);
        fine.process(frameDb, 0.042665);
      }
      assert.ok(Math.abs(coarse.snapshot.floorDb - fine.snapshot.floorDb) < 1e-9);
    });
  });
});
