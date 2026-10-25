import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

function drive(harness, frames) {
  for (const frame of frames) harness.drive(frame);
}

describe('recorder max-chunk splitting', () => {
  it('keeps the split as a continuation and reports boundary offsets', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 1_000,
      recorderConfig: {
        maxChunkSamples: 80_000,
        splitSearchSamples: 32_000,
        minimumSplitSilenceSamples: 1_600,
      },
      onEvent: event => events.push(event),
    });
    drive(harness, [...Array.from({ length: 400 }, (_, i) => (i % 8 === 0 ? -35 : -21)),
      ...Array(10).fill(-80),
      ...Array.from({ length: 700 }, (_, i) => (i % 8 === 0 ? -35 : -21))]);
    const split = events.find(event => event.k === 'split');
    assert.ok(split);
    assert.equal(split.r, 'split_gap');
    assert.equal(split.boundaryOffsetSamples, split.n);
    assert.notEqual(harness.endpoint.state, 'idle');
    assert.ok(harness.accumulatorSamples > 0);
  });

  it('uses distinct hard-cut reason without a qualifying gap', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 1_000,
      recorderConfig: { maxChunkSamples: 48_000 },
      onEvent: event => events.push(event),
    });
    drive(harness, Array.from({ length: 700 }, (_, i) => (i % 8 === 0 ? -35 : -21)));
    assert.ok(events.some(event => event.k === 'split' && event.r === 'split_hardcut'));
  });

  it('applies the same split policy to synthesized and real chunk starts', () => {
    const splitReasonsFor = (levels) => {
      const events = [];
      const harness = makeRecorderHarness({
        frameMs: 10,
        endpointSilenceMs: 1_000,
        recorderConfig: {
          maxChunkSamples: 8_000,
          splitSearchSamples: 3_200,
          minimumSplitSilenceSamples: 1_600,
        },
        onEvent: event => events.push(event),
      });
      drive(harness, levels);
      return events.filter(event => event.k === 'split').map(event => event.r);
    };
    const speech = Array.from({ length: 200 }, (_, index) => (index % 8 === 0 ? -42 : -30));
    const synthesizedStartReasons = splitReasonsFor([
      ...Array.from({ length: 50 }, (_, index) => (index % 8 === 0 ? -42 : -30)),
      ...speech,
    ]);
    const realStartReasons = splitReasonsFor([...Array(40).fill(-65), ...speech]);
    assert.equal(synthesizedStartReasons[0], realStartReasons[0]);
    assert.ok(synthesizedStartReasons.length > 0);
  });
});
