import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { VADThresholdGate, makeVadGateConfig as makeVadGateConfigBase } from '../lib/vad-gate.mjs';

// These mechanics fixtures were calibrated against the pre-change 10/6 gate.
function makeVadGateConfig(partial = {}) {
  return makeVadGateConfigBase({
    adaptiveDeltaDb: 10,
    adaptiveContinuationDeltaDb: 6,
    ...partial,
  });
}

describe('quiet-path VAD floor behavior', () => {
  it('keeps the quiet continuation rise cap at the former 12 dB/s default', () => {
    const defaults = new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
    assert.equal(defaults.config.quietContinuationRiseCapDbPerSec, 12);

    const capped = new VADThresholdGate(makeVadGateConfig({
      mode: 'adaptive',
      loudRegimeEnabled: false,
      quietContinuationRiseCapDbPerSec: 3,
    }));
    capped.floorDb = -50;
    capped.adaptiveRefinementComplete = true;
    capped.adaptiveRollingPercentileCache = -10;
    capped.lastOutput = { ...capped.lastOutput, evidence: 'continuing', dynamicsSpreadDb: 3 };
    capped.updateFloorTracking(-10, 1, true);
    assert.equal(capped.snapshot.floorDb, -47);
  });

  it('shape-gates the quiet rise cap and lets flat continuing ambient track normally', () => {
    const flat = new VADThresholdGate(makeVadGateConfig({
      mode: 'adaptive',
      loudRegimeEnabled: false,
      quietContinuationRiseCapDbPerSec: 0,
    }));
    flat.floorDb = -50;
    flat.adaptiveRefinementComplete = true;
    flat.adaptiveRollingPercentileCache = -10;
    flat.lastOutput = { ...flat.lastOutput, evidence: 'continuing', dynamicsSpreadDb: 2.99 };
    flat.updateFloorTracking(-10, 0.1, true);
    assert.ok(Math.abs(flat.snapshot.floorDb - -48.8) < 0.001);

    const speech = new VADThresholdGate(makeVadGateConfig({
      mode: 'adaptive',
      loudRegimeEnabled: false,
      quietContinuationRiseCapDbPerSec: 0,
    }));
    speech.floorDb = -50;
    speech.adaptiveRefinementComplete = true;
    speech.adaptiveRollingPercentileCache = -10;
    speech.lastOutput = { ...speech.lastOutput, evidence: 'continuing', dynamicsSpreadDb: 3 };
    speech.updateFloorTracking(-10, 0.1, true);
    assert.equal(speech.snapshot.floorDb, -50);
  });

  it('does not admit flat D1-like noise while it is classified as non-silence', () => {
    const gate = new VADThresholdGate(makeVadGateConfig({
      mode: 'adaptive',
      loudRegimeEnabled: false,
      quietContinuationRiseCapDbPerSec: 0,
    }));
    gate.floorDb = -42.11;
    gate.adaptiveRefinementComplete = true;
    gate.coldStartConverged = true;
    let output;
    for (let index = 0; index < 10; index += 1) {
      output = gate.process(-36.8, 0.1);
      gate.updateFloorTracking(-36.8, 0.1, true, false, false, 3);
    }
    assert.equal(gate.snapshot.floorDb, -42.11);
    assert.equal(gate.adaptiveRollingPercentileCache, null);
    assert.equal(output.evidence, 'ambiguous');
  });

  it('keeps a speech-shaped Tele1 whisper margin under the configured rise cap', () => {
    function floorAfter(capDbPerSecond) {
      const gate = new VADThresholdGate(makeVadGateConfig({
        mode: 'adaptive',
        loudRegimeEnabled: false,
        quietContinuationRiseCapDbPerSec: capDbPerSecond,
      }));
      const initialFloorDb = -41.706642150878906;
      const whisperDb = -33.24956512451172;
      gate.floorDb = initialFloorDb;
      gate.adaptiveRefinementComplete = true;
      gate.adaptiveRollingPercentileCache = whisperDb;
      gate.lastOutput = { ...gate.lastOutput, evidence: 'continuing', dynamicsSpreadDb: 3.2584127426147447 };
      gate.updateFloorTracking(whisperDb, 0.108, true, false, false, 3);
      return { initialFloorDb, floorDb: gate.snapshot.floorDb, marginDb: whisperDb - gate.snapshot.floorDb };
    }

    const frozen = floorAfter(0);
    const capped = floorAfter(3);
    assert.equal(frozen.floorDb, frozen.initialFloorDb);
    assert.ok(Math.abs(capped.floorDb - (capped.initialFloorDb + 0.324)) < 0.001);
    assert.ok(frozen.marginDb >= capped.marginDb);
  });

  it('gates ambiguous floor rise only when enabled and uses its independent witness', () => {
    function floorAfter({ applies, witness, spread, cap }) {
      const gate = new VADThresholdGate(makeVadGateConfig({
        mode: 'adaptive',
        loudRegimeEnabled: false,
        quietContinuationRiseCapDbPerSec: cap,
      }));
      gate.floorDb = -50;
      gate.adaptiveRefinementComplete = true;
      gate.adaptiveRollingPercentileCache = -10;
      gate.lastOutput = { ...gate.lastOutput, evidence: 'ambiguous', dynamicsSpreadDb: spread };
      gate.updateFloorTracking(-10, 0.1, true, false, applies, witness);
      return gate.snapshot.floorDb;
    }

    assert.ok(Math.abs(floorAfter({ applies: false, witness: 2, spread: 2.5, cap: 0 }) - -48.8) < 0.001);
    assert.equal(floorAfter({ applies: true, witness: 2, spread: 2.5, cap: 0 }), -50);
    assert.ok(Math.abs(floorAfter({ applies: true, witness: 3, spread: 2.5, cap: 0 }) - -48.8) < 0.001);
    assert.ok(Math.abs(floorAfter({ applies: true, witness: 2, spread: 2.5, cap: 3 }) - -49.7) < 0.001);
  });

});
