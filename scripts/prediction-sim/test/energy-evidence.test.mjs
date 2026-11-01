import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_ENERGY_CONTINUATION_ELEVATION_DB,
  DEFAULT_ENERGY_COOLDOWN_MS,
  DEFAULT_ENERGY_ONSET_ELEVATION_DB,
  DEFAULT_ENERGY_ONSET_SUSTAIN_MS,
  DEFAULT_ENERGY_RECALL_ENABLED,
  EnergyEvidenceProcessor,
  normalizeEnergyEvidenceConfig,
} from '../lib/energy-evidence.mjs';

const fixturePath = fileURLToPath(new URL('../fixtures/vad-energy-recall.json', import.meta.url));
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

function expandTrace(trace) {
  return trace.frames.flatMap(frame => Array.from({ length: frame.repeat ?? 1 }, () => ({
    frameDb: frame.frameDb,
    floorDb: frame.floorDb,
    frameDurationMs: frame.frameDurationMs,
  })));
}

function processTrace(trace, processor = new EnergyEvidenceProcessor()) {
  return expandTrace(trace).map(frame => processor.process(
    frame.frameDb,
    frame.floorDb,
    frame.frameDurationMs,
  ));
}

function startEnergyUtterance(processor) {
  const onset = Array.from({ length: 10 }, () => processor.process(-25, -60, 100));
  assert.equal(onset.at(-1).suppliesStrong, true);
  processor.noteEnergyOriginatedEmission();
  processor.noteUtteranceEnded();
}

describe('energy evidence second opinion', () => {
  it('uses the default-on switch and settled thresholds, with bounded overrides', () => {
    assert.equal(DEFAULT_ENERGY_RECALL_ENABLED, true);
    assert.equal(DEFAULT_ENERGY_ONSET_ELEVATION_DB, 30);
    assert.equal(DEFAULT_ENERGY_ONSET_SUSTAIN_MS, 1_000);
    assert.equal(DEFAULT_ENERGY_CONTINUATION_ELEVATION_DB, 10);
    assert.equal(DEFAULT_ENERGY_COOLDOWN_MS, 2_000);
    assert.deepEqual(normalizeEnergyEvidenceConfig(), {
      enabled: true,
      onsetElevationDb: 30,
      onsetSustainMs: 1_000,
      continuationElevationDb: 10,
      cooldownMs: 2_000,
    });
    assert.deepEqual(normalizeEnergyEvidenceConfig({
      energyRecallEnabled: false,
      energyOnsetElevationDb: 100,
      energyOnsetSustainMs: 1,
      energyContinuationElevationDb: -1,
      energyCooldownMs: 20_000,
    }), {
      enabled: false,
      onsetElevationDb: 60,
      onsetSustainMs: 100,
      continuationElevationDb: 0,
      cooldownMs: 10_000,
    });
  });

  it('loads synthetic-only traces with no recorded telemetry or audio', () => {
    assert.equal(fixture.syntheticOnly, true);
    assert.equal(Object.keys(fixture.traces).length, 8);
  });

  it('opens on a sustained whisper-class trace and reports continuing evidence afterward', () => {
    const opinions = processTrace(fixture.traces.whisperClass);

    assert.deepEqual(opinions.slice(0, 9).map(opinion => opinion.suppliesStrong), Array(9).fill(false));
    assert.equal(opinions[9].suppliesStrong, true);
    assert.equal(opinions[9].suppliesContinuing, false);
    assert.ok(opinions.slice(10).every(opinion => opinion.suppliesContinuing));
  });

  it('opens on fluctuating soft whisper after one consecutive second at or above floor+30 dB', () => {
    const opinions = processTrace(fixture.traces.softWhisperFluctuating);
    const firstStrongIndex = opinions.findIndex(opinion => opinion.suppliesStrong);

    assert.equal(firstStrongIndex, 18);
    assert.equal(opinions[firstStrongIndex].suppliesStrong, true);
    assert.equal(opinions[firstStrongIndex - 1].suppliesStrong, false);
  });

  it('rejects separated 100-500 ms breath and junk transients', () => {
    const opinions = processTrace(fixture.traces.breathAndJunkTransients);

    assert.equal(opinions.some(opinion => opinion.suppliesStrong), false);
    assert.equal(opinions.some(opinion => opinion.suppliesContinuing), false);
  });

  it('does not onset during a near-floor pause or silence trace', () => {
    const opinions = processTrace(fixture.traces.pauseAndSilence);

    assert.equal(opinions.some(opinion => opinion.suppliesStrong), false);
    assert.equal(opinions.some(opinion => opinion.suppliesContinuing), false);
  });

  it('blocks re-onset at 1999 ms after emission and opens at 2001 ms', () => {
    const processor = new EnergyEvidenceProcessor();
    startEnergyUtterance(processor);
    const opinions = processTrace(fixture.traces.cooldownBoundary1999And2001, processor);

    assert.equal(opinions.slice(0, -1).some(opinion => opinion.suppliesStrong), false);
    assert.equal(opinions.at(-1).suppliesStrong, true);
  });

  it('accumulates frame duration rather than frame count at 999/1001 ms', () => {
    const opinions = processTrace(fixture.traces.onsetSustainBoundary999And1001);

    assert.equal(opinions.slice(0, -1).some(opinion => opinion.suppliesStrong), false);
    assert.equal(opinions.at(-1).suppliesStrong, true);
  });

  it('requires the onset elevation boundary, rejecting +29 dB and accepting +31 dB', () => {
    const opinions = processTrace(fixture.traces.onsetElevationBoundary29And31);

    assert.equal(opinions.slice(0, 12).some(opinion => opinion.suppliesStrong), false);
    assert.equal(opinions.at(-1).suppliesStrong, true);
  });

  it('tracks rising and falling per-frame floors for onset and continuation margins', () => {
    const opinions = processTrace(fixture.traces.risingAndFallingFloor);

    assert.equal(opinions.slice(0, 5).some(opinion => opinion.suppliesStrong), false);
    assert.equal(opinions[14].suppliesStrong, true);
    assert.equal(opinions[15].suppliesContinuing, true);
    assert.equal(opinions[16].suppliesContinuing, false);
    assert.equal(opinions[17].suppliesContinuing, true);
  });

  it('ends continuation eligibility and partial sustain when the utterance ends', () => {
    const processor = new EnergyEvidenceProcessor();
    for (let index = 0; index < 10; index += 1) processor.process(-25, -60, 100);
    assert.equal(processor.process(-51, -60, 100).suppliesContinuing, false);
    assert.equal(processor.process(-50, -60, 100).suppliesContinuing, true);

    processor.noteUtteranceEnded();
    assert.deepEqual(processor.process(-25, -60, 100), {
      suppliesStrong: false,
      suppliesContinuing: false,
    });
    const restartedRun = Array.from({ length: 8 }, () => processor.process(-25, -60, 100));
    assert.equal(restartedRun.some(opinion => opinion.suppliesStrong), false);
    assert.equal(processor.process(-25, -60, 100).suppliesStrong, true);

    const partialSustain = new EnergyEvidenceProcessor();
    for (let index = 0; index < 5; index += 1) partialSustain.process(-25, -60, 100);
    partialSustain.noteUtteranceEnded();
    const freshRun = Array.from({ length: 9 }, () => partialSustain.process(-25, -60, 100));
    assert.equal(freshRun.some(opinion => opinion.suppliesStrong), false);
    assert.equal(partialSustain.process(-25, -60, 100).suppliesStrong, true);
  });

  it('lets cooldown expire in silence without synthesizing evidence or sticking closed', () => {
    const processor = new EnergyEvidenceProcessor();
    startEnergyUtterance(processor);

    for (let index = 0; index < 20; index += 1) {
      assert.deepEqual(processor.process(-55, -60, 100), {
        suppliesStrong: false,
        suppliesContinuing: false,
      });
    }
    const laterOnset = Array.from({ length: 10 }, () => processor.process(-25, -60, 100));

    assert.equal(laterOnset.slice(0, -1).some(opinion => opinion.suppliesStrong), false);
    assert.equal(laterOnset.at(-1).suppliesStrong, true);
  });

  it('keeps a disabled processor silent across an otherwise qualifying run', () => {
    const processor = new EnergyEvidenceProcessor({ energyRecallEnabled: false });
    const opinions = Array.from({ length: 20 }, () => processor.process(-25, -60, 100));

    assert.equal(opinions.some(opinion => opinion.suppliesStrong || opinion.suppliesContinuing), false);
  });
});
