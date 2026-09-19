import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  dbFromRms,
  rmsFromDb,
  makeVadGateConfig,
  VAD_ADAPTIVE_FALL_TAU_SECONDS_MAX,
  VAD_ADAPTIVE_FALL_TAU_SECONDS_MIN,
  VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MAX,
  VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MIN,
  VAD_ADAPTIVE_RISE_MULTIPLIER_MAX,
  VAD_ADAPTIVE_RISE_MULTIPLIER_MIN,
  VAD_ADAPTIVE_SILENCE_DELTA_DB_MAX,
  VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MAX,
  VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MIN,
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

    it('N8/R5: keeps static mode free of re-anchor events and floor movement', () => {
      const gate = new VADThresholdGate(config({ mode: 'static' }));
      let reanchorEvent = false;

      for (let i = 0; i < 6000; i++) {
        const output = gate.process(-10, 0.01);
        reanchorEvent ||= gate.takePendingReanchorEvent();
        assert.strictEqual(output.floorDb, null);
      }

      assert.strictEqual(reanchorEvent, false);
      assert.strictEqual(gate.snapshot.floorDb, null);
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
      gate.updateFloorTracking(-70, 0.5);
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
      let firstStrongAtMs = null;

      for (let i = 0; i < 150; i++) {
        const frameDb = i < 2 ? -58 : (i % 8 === 0 ? -58 : -45);
        const output = gate.process(frameDb, 0.01);
        if (output.evidence === 'strong' && firstStrongAtMs === null) {
          firstStrongAtMs = (i + 1) * 10;
        }
        if (output.isSpeech) speechSamples += frameSamples;
        const decision = endpoint.process(output.evidence, frameSamples);
        if (decision.type === 'startUtterance' && openedAtMs === null) {
          openedAtMs = (i + 1) * 10;
        }
      }

      assert.ok(firstStrongAtMs !== null && firstStrongAtMs <= 170);
      assert.strictEqual(gate.coldStartSpeechShapedNow, true);
      assert.ok(openedAtMs !== null && openedAtMs <= 170);
      assert.ok(speechSamples >= 300 * 16);
      assert.deepStrictEqual(endpoint.forceFinalize('stop'), {
        type: 'finalizeUtterance',
        kind: 'stop',
      });
    });

    it('keeps the low seed from rising when speech starts on frame one', () => {
      const gate = new VADThresholdGate(config({ mode: 'adaptive' }));
      for (let i = 0; i < 10; i++) {
        gate.process(i < 2 ? -58 : (i % 8 === 0 ? -58 : -45), 0.1);
      }
      assert.ok(gate.snapshot.floorDb <= -45);
    });

    it('tracks a quiet room toward ambient while the machine is idle', () => {
      const gate = new VADThresholdGate(config({ mode: 'adaptive' }));
      for (let i = 0; i < 50; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorTracking(-65, 0.1, true);
      }
      assert.ok(Math.abs(gate.snapshot.floorDb - -65) <= 3);
      assert.notStrictEqual(gate.process(-65, 0.1).evidence, 'strong');
    });

    it('freezes strong evidence, caps continuing evidence, and elevates idle tracking', () => {
      const continuingGate = seedAdaptiveGate({}, -65);
      continuingGate.floorDb = -70;
      continuingGate.process(-63, 0.1);
      continuingGate.updateFloorTracking(-63, 0.1, false);
      assert.strictEqual(continuingGate.snapshot.floorDb, -70);

      const idleContinuingGate = seedAdaptiveGate({}, -65);
      idleContinuingGate.floorDb = -70;
      idleContinuingGate.process(-63, 0.1);
      idleContinuingGate.updateFloorTracking(-63, 0.1, true);
      assert.ok(Math.abs(idleContinuingGate.snapshot.floorDb - -68.8) < 0.001);

      const strongGate = seedAdaptiveGate({}, -65);
      strongGate.floorDb = -70;
      strongGate.process(-50, 0.1);
      strongGate.updateFloorTracking(-50, 0.1, true);
      assert.strictEqual(strongGate.snapshot.floorDb, -70);
    });

    it('uses the fast fall tau and capped upward movement while idle', () => {
      const fallGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -60);
      fallGate.floorDb = -50;
      fallGate.process(-60, 0.1);
      const fall = fallGate.updateFloorTracking(-60, 0.5) || fallGate.snapshot;
      const expectedFall = -50 + (1 - Math.exp(-1)) * (-10);
      assert.ok(Math.abs(fall.floorDb - expectedFall) < 0.001);

      const riseGate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -58);
      riseGate.floorDb = -60;
      riseGate.process(-58, 0.1);
      riseGate.updateFloorTracking(-58, 7, true);
      const rise = riseGate.snapshot;
      const expectedRise = -58;
      assert.ok(Math.abs(rise.floorDb - expectedRise) < 0.001);
    });

    it('normalizes adaptive bands and the advanced VAD bounds at construction', () => {
      assert.strictEqual(config().adaptiveDynamicsEnabled, true);
      assert.strictEqual(config().adaptiveDynamicsSpreadDb, 9);

      const wideSilenceBand = seedAdaptiveGate({
        adaptiveDeltaDb: 10,
        adaptiveContinuationDeltaDb: 4,
        adaptiveSilenceDeltaDb: VAD_ADAPTIVE_SILENCE_DELTA_DB_MAX,
      });
      assert.strictEqual(wideSilenceBand.effectiveAdaptiveDeltaDb, 10);
      assert.strictEqual(wideSilenceBand.effectiveAdaptiveContinuationDeltaDb, 4);
      assert.strictEqual(wideSilenceBand.effectiveSilenceDeltaDb, 3);

      const narrowStrongBand = seedAdaptiveGate({
        adaptiveDeltaDb: 3,
        adaptiveContinuationDeltaDb: 6,
        adaptiveSilenceDeltaDb: 5,
      });
      assert.strictEqual(narrowStrongBand.effectiveAdaptiveDeltaDb, 3);
      assert.strictEqual(narrowStrongBand.effectiveAdaptiveContinuationDeltaDb, 2);
      assert.strictEqual(narrowStrongBand.effectiveSilenceDeltaDb, 1);

      const upper = seedAdaptiveGate({
        adaptiveRiseSpeedMultiplier: 99,
        adaptiveFallTauSeconds: 99,
        adaptiveStaleFloorSeconds: 99,
      });
      assert.strictEqual(upper.effectiveRiseSpeedMultiplier, VAD_ADAPTIVE_RISE_MULTIPLIER_MAX);
      assert.strictEqual(upper.effectiveFallTauSeconds, VAD_ADAPTIVE_FALL_TAU_SECONDS_MAX);
      assert.strictEqual(
        upper.effectiveStaleFloorSeconds,
        VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MAX / VAD_ADAPTIVE_RISE_MULTIPLIER_MAX,
      );

      const lower = seedAdaptiveGate({
        adaptiveRiseSpeedMultiplier: 0.1,
        adaptiveFallTauSeconds: 0.1,
        adaptiveStaleFloorSeconds: 0.1,
      });
      assert.strictEqual(lower.effectiveRiseSpeedMultiplier, VAD_ADAPTIVE_RISE_MULTIPLIER_MIN);
      assert.strictEqual(lower.effectiveFallTauSeconds, VAD_ADAPTIVE_FALL_TAU_SECONDS_MIN);
      assert.strictEqual(
        lower.effectiveStaleFloorSeconds,
        VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MIN / VAD_ADAPTIVE_RISE_MULTIPLIER_MIN,
      );

      const dynamicsLower = seedAdaptiveGate({ adaptiveDynamicsSpreadDb: 0 });
      assert.strictEqual(dynamicsLower.effectiveDynamicsSpreadDb, VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MIN);
      const dynamicsUpper = seedAdaptiveGate({ adaptiveDynamicsSpreadDb: 99 });
      assert.strictEqual(dynamicsUpper.effectiveDynamicsSpreadDb, VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MAX);
    });

    it('gates flat strong levels while allowing modulated strong evidence', () => {
      const flatGate = seedAdaptiveGate({}, -50);
      flatGate.floorDb = -70;
      const flatOutput = flatGate.process(-50, 0.1);
      assert.strictEqual(flatOutput.evidence, 'continuing');
      assert.strictEqual(flatOutput.isSpeech, true);
      assert.strictEqual(flatGate.snapshot.evidence, 'continuing');

      const modulatedGate = seedAdaptiveGate({}, -58);
      modulatedGate.floorDb = -70;
      const modulatedOutput = modulatedGate.process(-45, 0.1);
      assert.strictEqual(modulatedOutput.evidence, 'strong');
      assert.strictEqual(modulatedOutput.isSpeech, true);
      assert.ok(Math.abs(modulatedOutput.dynamicsSpreadDb - 13) < 0.001);
    });

    it('uses the inclusive dynamics spread boundary for strong evidence', () => {
      const belowBoundary = seedAdaptiveGate({}, -58.9);
      belowBoundary.floorDb = -70;
      const belowOutput = belowBoundary.process(-50, 0.1);
      assert.ok(Math.abs(belowOutput.dynamicsSpreadDb - 8.9) < 0.001);
      assert.strictEqual(belowOutput.evidence, 'continuing');

      const aboveBoundary = seedAdaptiveGate({}, -59.1);
      aboveBoundary.floorDb = -70;
      const aboveOutput = aboveBoundary.process(-50, 0.1);
      assert.ok(Math.abs(aboveOutput.dynamicsSpreadDb - 9.1) < 0.001);
      assert.strictEqual(aboveOutput.evidence, 'strong');
    });

    it('disables dynamics gating without changing level-only classification', () => {
      const gate = seedAdaptiveGate({ adaptiveDynamicsEnabled: false }, -50);
      gate.floorDb = -70;
      const output = gate.process(-50, 0.1);
      assert.strictEqual(output.evidence, 'strong');
      assert.strictEqual(output.isSpeech, true);
      assert.strictEqual(output.dynamicsSpreadDb, null);
    });

    it('uses the spread setting as the cold-start shaped threshold', () => {
      function probe(spreadDb) {
        const gate = new VADThresholdGate(config({
          mode: 'adaptive',
          adaptiveDynamicsSpreadDb: spreadDb,
        }));
        for (let i = 0; i < 10; i++) gate.process(-59, 0.03);
        const output = gate.process(-50, 0.03);
        return { gate, output };
      }

      const belowThreshold = probe(8.9);
      assert.strictEqual(belowThreshold.gate.coldStartSpeechShapedNow, true);
      assert.strictEqual(belowThreshold.output.evidence, 'strong');

      const aboveThreshold = probe(9.1);
      assert.strictEqual(aboveThreshold.gate.coldStartSpeechShapedNow, false);
      assert.strictEqual(aboveThreshold.output.evidence, 'continuing');

      const killSwitchGate = new VADThresholdGate(config({
        mode: 'adaptive',
        adaptiveDynamicsEnabled: false,
        adaptiveDynamicsSpreadDb: 24,
      }));
      for (let i = 0; i < 10; i++) killSwitchGate.process(-62, 0.03);
      const killSwitchOutput = killSwitchGate.process(-50, 0.03);
      assert.strictEqual(killSwitchGate.coldStartSpeechShapedNow, true);
      assert.strictEqual(killSwitchOutput.evidence, 'strong');
    });

    it('reports dynamics spread only for enabled adaptive frames', () => {
      const staticOutput = new VADThresholdGate(config({ mode: 'static' })).process(-20, 0.1);
      assert.strictEqual(staticOutput.dynamicsSpreadDb, null);

      const calibratedOutput = new VADThresholdGate(config({ mode: 'calibrated' }))
        .process(-50, 0.1);
      assert.strictEqual(calibratedOutput.dynamicsSpreadDb, null);

      const disabledAdaptiveOutput = seedAdaptiveGate({ adaptiveDynamicsEnabled: false }, -50)
        .process(-50, 0.1);
      assert.strictEqual(disabledAdaptiveOutput.dynamicsSpreadDb, null);

      const enabledAdaptiveOutput = seedAdaptiveGate({}, -50).process(-50, 0.1);
      assert.strictEqual(enabledAdaptiveOutput.dynamicsSpreadDb, 0);
    });

    it('honors silence delta, fall tau, rise multiplier, and ceiling decay', () => {
      const lowSilence = seedAdaptiveGate({ adaptiveSilenceDeltaDb: 1 }, -50);
      const highSilence = seedAdaptiveGate({ adaptiveSilenceDeltaDb: 5 }, -50);
      lowSilence.floorDb = -50;
      highSilence.floorDb = -50;
      assert.strictEqual(lowSilence.process(-46, 0.1).evidence, 'ambiguous');
      assert.strictEqual(highSilence.process(-46, 0.1).evidence, 'silence');

      const fastFall = seedAdaptiveGate({
        adaptiveDeltaDb: 20,
        adaptiveFallTauSeconds: 0.2,
      }, -60);
      const slowFall = seedAdaptiveGate({
        adaptiveDeltaDb: 20,
        adaptiveFallTauSeconds: 2,
      }, -60);
      fastFall.floorDb = -50;
      slowFall.floorDb = -50;
      fastFall.process(-60, 0.1);
      slowFall.process(-60, 0.1);
      fastFall.updateFloorTracking(-60, 0.5);
      slowFall.updateFloorTracking(-60, 0.5);
      assert.ok(fastFall.snapshot.floorDb < slowFall.snapshot.floorDb);

      const slowRise = seedAdaptiveGate({ adaptiveRiseSpeedMultiplier: 0.5 }, -65);
      const fastRise = seedAdaptiveGate({ adaptiveRiseSpeedMultiplier: 2 }, -65);
      slowRise.floorDb = -70;
      fastRise.floorDb = -70;
      slowRise.process(-63, 0.1);
      fastRise.process(-63, 0.1);
      slowRise.updateFloorTracking(-63, 0.1, true);
      fastRise.updateFloorTracking(-63, 0.1, true);
      assert.ok(fastRise.snapshot.floorDb > slowRise.snapshot.floorDb);

      const slowDecay = seedAdaptiveGate({ adaptiveRiseSpeedMultiplier: 0.5 }, -65);
      const fastDecay = seedAdaptiveGate({ adaptiveRiseSpeedMultiplier: 2 }, -65);
      slowDecay.speechCeilingDb = -35;
      fastDecay.speechCeilingDb = -35;
      slowDecay.floorDb = -50;
      fastDecay.floorDb = -50;
      slowDecay.process(-45, 0.1);
      fastDecay.process(-45, 0.1);
      slowDecay.updateFloorTracking(-45, 0.1, true);
      fastDecay.updateFloorTracking(-45, 0.1, true);
      assert.ok(fastDecay.speechCeilingDb > slowDecay.speechCeilingDb);
    });

    it('pins the pre-change adaptive timing at a half-speed rise multiplier', () => {
      const gate = seedAdaptiveGate({
        adaptiveRiseSpeedMultiplier: 0.5,
        adaptiveSilenceDeltaDb: 3,
        adaptiveStaleFloorSeconds: 3,
        adaptiveFallTauSeconds: 0.5,
      }, -65);
      gate.floorDb = -70;
      gate.process(-63, 0.1);
      gate.updateFloorTracking(-63, 0.1, true);
      assert.ok(Math.abs(gate.snapshot.floorDb - -69.4) < 0.001);
    });

    it('respects both floor clamp bounds', () => {
      const lowGate = seedAdaptiveGate({ adaptiveDeltaDb: 20 }, -100);
      assert.strictEqual(lowGate.snapshot.floorDb, -80);

      const highGate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -10);
      highGate.floorDb = -20;
      highGate.process(-15, 0.1);
      highGate.updateFloorTracking(-15, 10, false);
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

    it('freezes ambient evidence while the machine is active', () => {
      const gate = seedAdaptiveGate({}, -65);
      gate.floorDb = -70;

      for (let i = 0; i < 14; i++) {
        gate.process(-65, 0.1);
        gate.updateFloorTracking(-65, 0.1, false);
      }
      assert.strictEqual(gate.snapshot.floorDb, -70);
    });

    it('freezes continuing evidence on the non-idle ceiling', () => {
      const gate = seedAdaptiveGate({}, -65);
      gate.floorDb = -70;

      for (let i = 0; i < 4; i++) {
        gate.process(-63, 0.1);
        gate.updateFloorTracking(-63, 0.1, false);
      }
      assert.strictEqual(gate.snapshot.floorDb, -70);
    });

    it('classifies the gap between silence and continuation as ambiguous', () => {
      const gate = seedAdaptiveGate({ adaptiveDeltaDb: 10 }, -50);
      for (let i = 0; i < 50; i++) {
        gate.process(-50, 0.1);
        gate.updateFloorTracking(-50, 0.1, true);
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
        coarse.updateFloorTracking(-60, 0.08533);
      }
      for (let i = 0; i < 5; i++) {
        fine.process(-60, 0.042665);
        fine.updateFloorTracking(-60, 0.042665);
        fine.process(-60, 0.042665);
        fine.updateFloorTracking(-60, 0.042665);
      }
      assert.ok(Math.abs(coarse.snapshot.floorDb - fine.snapshot.floorDb) < 1e-9);
    });
  });
});
