import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  makeRecorderHarness,
  VAD_MIN_SILENCE_AT_SPLIT_SAMPLES,
  VAD_POST_ROLL_SAMPLES,
  VAD_SPLIT_SEARCH_SAMPLES,
} from '../lib/recorder-sim.mjs';

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

  it('finds a qualifying dip while the live accumulator is backed by spill storage', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 1_000,
      recorderConfig: {
        maxChunkSamples: 80_000,
        spillThresholdSamples: 30_000,
        splitSearchSamples: 32_000,
        minimumSplitSilenceSamples: 1_600,
      },
      onEvent: event => events.push(event),
    });
    drive(harness, [...Array.from({ length: 400 }, (_, i) => (i % 8 === 0 ? -35 : -21)),
      ...Array(10).fill(-80),
      ...Array.from({ length: 700 }, (_, i) => (i % 8 === 0 ? -35 : -21))]);
    const split = events.find(event => event.k === 'split');
    assert.ok(harness.spillOccurred);
    assert.ok(split?.spilled);
    assert.equal(split.r, 'split_gap');
    assert.equal(harness.emittedSampleCount + harness.accumulatorSamples, harness.sessionElapsedSamples);
  });

  it('counts a short unqualified dip after the qualifying gap in the carry offset', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 3_000,
      headBufferSamples: 0,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      recorderConfig: {
        maxChunkSamples: 13_000,
        splitSearchSamples: 48_000,
        minimumSplitSilenceSamples: 1_600,
      },
      onEvent: event => events.push(event),
    });
    drive(harness, [...Array(60).fill(-20), ...Array(10).fill(-80),
      ...Array(10).fill(-20), ...Array(5).fill(-80), ...Array(8).fill(-20)]);
    const split = events.find(event => event.k === 'split');
    assert.ok(split);
    assert.equal(split.r, 'split_gap');
    assert.equal(split.gapSamples, 1_600);
    assert.ok(Math.abs(split.n / 16 - 630) <= 10);
  });

  it('emits at the cap when a qualifying gap is at the accumulator tail', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 3_000,
      headBufferSamples: 0,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      recorderConfig: {
        maxChunkSamples: 6_880,
        splitSearchSamples: 3_200,
        minimumSplitSilenceSamples: 1_600,
      },
      onEvent: event => events.push(event),
    });
    drive(harness, [...Array(40).fill(-20), ...Array(10).fill(-80), ...Array(10).fill(-20)]);
    const split = events.find(event => event.k === 'split');
    assert.ok(split);
    assert.equal(split.r, 'split_gap');
    assert.equal(split.n, harness.maxChunkSamples);
    assert.ok(harness.accumulatorSamples > 0);
    assert.notEqual(harness.endpoint.state, 'idle');
  });

  it('caps endpoint post-roll at 400ms while stop flush retains its full trailing audio', () => {
    const pauseEvents = [];
    const pauseHarness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 1_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => pauseEvents.push(event),
    });
    drive(pauseHarness, [...Array(300).fill(-20), ...Array(120).fill(-80)]);
    const pauseEmit = pauseEvents.find(event => event.k === 'emit');
    assert.ok(pauseEmit);
    assert.equal(pauseEmit.r, 'endpoint');
    assert.equal(pauseEmit.n, 3_400 * 16);
    assert.equal(pauseHarness.lastUntrimmedEmitSampleCount - pauseEmit.n, 600 * 16);
    assert.equal(pauseEmit.n, pauseEmit.tm * 16);

    const flushEvents = [];
    const flushHarness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 2_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => flushEvents.push(event),
    });
    drive(flushHarness, [...Array(300).fill(-20), ...Array(120).fill(-80)]);
    flushHarness.flush();
    const stopFlush = flushEvents.find(event => event.k === 'stop_flush');
    const flushEmit = flushEvents.find(event => event.k === 'emit' && event.r === 'flush');
    assert.ok(stopFlush);
    assert.ok(flushEmit);
    assert.ok(flushEmit.n > pauseEmit.n);
    assert.equal(pauseEmit.tm, pauseEmit.n / 16);
    assert.ok(flushEmit.n <= stopFlush.n);
    assert.equal(flushEmit.n, stopFlush.n);
  });

  it('retains a speech burst inside the endpoint accumulated-silence window', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 700,
      endpointConfig: { endEvidenceMs: 100, resumeMs: 120 },
      onEvent: event => events.push(event),
    });
    drive(harness, [
      ...Array.from({ length: 300 }, (_, index) => (index % 8 === 0 ? -42 : -30)),
      ...Array(60).fill(-80),
      ...Array(10).fill(-30),
      ...Array(10).fill(-80),
    ]);
    const emission = events.find(event => event.k === 'emit');
    assert.ok(emission);
    assert.equal(emission.r, 'endpoint');
    assert.equal(emission.n, 3_800 * 16);
    assert.equal(emission.s0, 0);
    assert.equal(emission.s1, 3_800);
    assert.equal(harness.lastUntrimmedEmitSampleCount, emission.n);
  });

  it('caps endpoint post-roll after carrying a trailing silence suffix through a split', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 3_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });
    drive(harness, [
      ...Array(2_970).fill(-20),
      ...Array(10).fill(-80),
      ...Array(15).fill(-20),
      ...Array(5).fill(-80),
      ...Array(295).fill(-80),
    ]);
    const split = events.find(event => event.k === 'split');
    const endpointEmission = events.find(event => event.k === 'emit' && event.r === 'endpoint');
    assert.ok(split);
    assert.equal(split.r, 'split_gap');
    assert.equal(split.s1, 29_800);
    assert.ok(endpointEmission);
    assert.equal(endpointEmission.s1, 30_350);
    assert.equal(harness.lastUntrimmedEmitSampleCount - endpointEmission.n, 2_600 * 16);
  });

  it('applies the same split policy to synthesized and real chunk starts', () => {
    const splitReasonsFor = (levels) => {
      const events = [];
      const harness = makeRecorderHarness({
        frameMs: 10,
        endpointSilenceMs: 1_000,
        headBufferSamples: 0,
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

  it('keeps the split index and tail policy bounded by named configuration', () => {
    const harness = makeRecorderHarness();
    assert.equal(harness.splitSearchSamples, VAD_SPLIT_SEARCH_SAMPLES);
    assert.equal(harness.minimumSplitSilenceSamples, VAD_MIN_SILENCE_AT_SPLIT_SAMPLES);
    assert.equal(harness.postRollSamples, VAD_POST_ROLL_SAMPLES);
    assert.ok(harness.splitEnergySamples <= harness.splitSearchSamples);
  });
});
