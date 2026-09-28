import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  gateG1CoverageMonotonicity,
  gateG2EvidenceBoundedGrowth,
  gateG3NormalVoiceInvariance,
} from '../bin/sweep-vad-quiet.mjs';

describe('quiet sweep acceptance gates', () => {
  it('G1 requires baseline emitted coverage within the 150 ms edge tolerance', () => {
    assert.equal(gateG1CoverageMonotonicity(
      [{ start: 1, end: 2 }],
      [{ start: 0.95, end: 2.05 }],
    ).pass, true);
    assert.equal(gateG1CoverageMonotonicity(
      [{ start: 1, end: 2 }],
      [{ start: 1.151, end: 2.1 }],
    ).pass, false);
    assert.equal(gateG1CoverageMonotonicity(
      [{ start: 1, end: 2 }],
      [],
    ).missingIntervals, 1);
  });

  it('G2 bounds growth to continuing or supported ambiguous evidence', () => {
    const candidate = [{ start: 0, end: 1.5 }];
    const baseline = [{ start: 0, end: 1 }];
    const frames = [
      { start: 1, end: 1.3, dt: 0.3, evidence: 'continuing' },
      { start: 1.3, end: 1.4, dt: 0.1, evidence: 'ambiguous', db: -43, floorDb: -45 },
      { start: 1.4, end: 1.5, dt: 0.1, evidence: 'silence', db: -50, floorDb: -45 },
    ];
    const result = gateG2EvidenceBoundedGrowth(candidate, baseline, frames);
    assert.equal(result.growthSeconds, 0.5);
    assert.ok(Math.abs(result.growthQualifiedShare - 0.8) < 1e-9);
    assert.ok(Math.abs(result.pureSilenceGrowthSeconds - 0.1) < 1e-9);
    assert.equal(result.pass, true);

    const silenceOnly = gateG2EvidenceBoundedGrowth(
      [{ start: 0, end: 1.5 }],
      [{ start: 0, end: 1 }],
      [{ start: 1, end: 1.5, dt: 0.5, evidence: 'silence' }],
    );
    assert.equal(silenceOnly.pass, false);
  });

  it('G3 enforces exact emission interval identity above the strong-fraction threshold', () => {
    const baseline = [{ s0: 100, s1: 500 }];
    assert.equal(gateG3NormalVoiceInvariance(baseline, baseline, 0.8, 0.8).pass, true);
    assert.equal(gateG3NormalVoiceInvariance(
      baseline,
      [{ s0: 100, s1: 501 }],
      0.9,
      0.8,
    ).pass, false);
    assert.equal(gateG3NormalVoiceInvariance([], [{ s0: 0, s1: 1 }], 0.79, 0.8).pass, true);
  });
});
