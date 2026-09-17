import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { StreamingSplitPlanner } from '../lib/streaming-split-planner.mjs';

const samples = milliseconds => milliseconds * 16;

describe('StreamingSplitPlanner', () => {
  it('chooses the latest usable pause after the one-second minimum', () => {
    const planner = new StreamingSplitPlanner({
      maxUtteranceSamples: samples(3000),
      usablePauseSamples: samples(300),
      minimumUtteranceSamples: samples(1000),
    });
    planner.begin(0);
    planner.append('strong', samples(1100));
    planner.append('silence', samples(350));
    planner.append('strong', samples(200));
    planner.append('silence', samples(400));
    planner.append('strong', samples(1));
    planner.append('silence', samples(500));
    planner.append('strong', samples(500));

    assert.deepEqual(planner.splitPoint(), {
      offsetSamples: samples(2551),
      reason: 'pause',
    });
  });

  it('falls back to an exact cap when there is no usable pause', () => {
    const planner = new StreamingSplitPlanner({ maxUtteranceSamples: samples(2000) });
    planner.begin(0);
    planner.append('strong', samples(2000));
    assert.deepEqual(planner.splitPoint(), {
      offsetSamples: samples(2000),
      reason: 'cap',
    });
  });

  it('honors configured overlap without changing the pause offset bookkeeping', () => {
    const planner = new StreamingSplitPlanner({
      maxUtteranceSamples: samples(2000),
      usablePauseSamples: samples(300),
      minimumUtteranceSamples: samples(1000),
      overlapSamples: samples(50),
    });
    planner.begin(0);
    planner.append('strong', samples(1200));
    planner.append('silence', samples(300));
    planner.append('strong', samples(1500));
    assert.deepEqual(planner.splitPoint(), {
      offsetSamples: samples(1450),
      reason: 'pause',
    });
  });
});
