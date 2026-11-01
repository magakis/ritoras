import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  UNIFIED_FRAME_SAMPLE_COUNT,
  UnifiedFrameCoalescer,
} from '../lib/unified-frame-coalescer.mjs';

function samplesFrom(start, count) {
  return Array.from({ length: count }, (_, index) => start + index);
}

describe('unified audio frame coalescer', () => {
  it('emits one frame at exactly 8,960 samples', () => {
    const coalescer = new UnifiedFrameCoalescer();
    const samples = samplesFrom(0, UNIFIED_FRAME_SAMPLE_COUNT);

    assert.deepEqual(coalescer.append(samples), [samples]);
    assert.equal(coalescer.flush(), null);
  });

  it('emits an all-zero frame without silence filtering', () => {
    const coalescer = new UnifiedFrameCoalescer();
    const silence = new Array(UNIFIED_FRAME_SAMPLE_COUNT).fill(0);

    assert.deepEqual(coalescer.append(silence), [silence]);
  });

  it('carries a sub-frame remainder into the next buffer', () => {
    const coalescer = new UnifiedFrameCoalescer();

    assert.deepEqual(coalescer.append(samplesFrom(0, 4_000)), []);
    const frames = coalescer.append(samplesFrom(4_000, 4_960));

    assert.equal(frames.length, 1);
    assert.deepEqual(frames[0], samplesFrom(0, UNIFIED_FRAME_SAMPLE_COUNT));
  });

  it('flushes a non-empty remainder and clears it', () => {
    const coalescer = new UnifiedFrameCoalescer();
    const samples = samplesFrom(10, 123);

    assert.deepEqual(coalescer.append(samples), []);
    assert.deepEqual(coalescer.flush(), samples);
    assert.equal(coalescer.flush(), null);
  });

  it('accumulates multiple buffers into complete frames', () => {
    const coalescer = new UnifiedFrameCoalescer();
    const buffers = [
      samplesFrom(0, 2_000),
      samplesFrom(2_000, 3_000),
      samplesFrom(5_000, 5_000),
    ];

    assert.deepEqual(coalescer.append(buffers[0]), []);
    assert.deepEqual(coalescer.append(buffers[1]), []);
    const frames = coalescer.append(buffers[2]);

    assert.equal(frames.length, 1);
    assert.deepEqual(frames[0], samplesFrom(0, UNIFIED_FRAME_SAMPLE_COUNT));
    assert.deepEqual(coalescer.flush(), samplesFrom(UNIFIED_FRAME_SAMPLE_COUNT, 1_040));
  });

  it('conserves samples without drops or duplicates across frames and flush', () => {
    const coalescer = new UnifiedFrameCoalescer();
    const buffers = [
      samplesFrom(0, 5_000),
      samplesFrom(5_000, 7_000),
      samplesFrom(12_000, 10_000),
    ];
    const frames = buffers.flatMap((buffer) => coalescer.append(buffer));
    const remainder = coalescer.flush();
    const output = [...frames.flat(), ...remainder];

    assert.equal(frames.length, 2);
    assert.equal(output.length, 22_000);
    assert.deepEqual(output, samplesFrom(0, 22_000));
  });

  it('treats an empty flush as a no-op', () => {
    const coalescer = new UnifiedFrameCoalescer();

    assert.equal(coalescer.flush(), null);
    assert.deepEqual(coalescer.append([42]), []);
    assert.deepEqual(coalescer.flush(), [42]);
  });
});
