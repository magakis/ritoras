import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  decodeUnifiedAudioFrame,
  encodeUnifiedAudioFrame,
  UnifiedStreamChunkIdSequence,
} from '../lib/unified-frame-codec.mjs';

describe('unified stream frame codec', () => {
  it('writes a big-endian chunk ID and little-endian Float32 samples', () => {
    const frame = encodeUnifiedAudioFrame(0x01020304, [1, -2]);

    assert.equal(frame.toString('hex'), '010203040000803f000000c0');
  });

  it('round-trips chunk IDs and Float32 sample values', () => {
    const samples = [0, 0.1, -0.75, Math.PI];
    const decoded = decodeUnifiedAudioFrame(encodeUnifiedAudioFrame(0xfedcba98, samples));

    assert.equal(decoded.chunkId, 0xfedcba98);
    assert.deepEqual(decoded.samples, samples.map(Math.fround));
  });

  it('rejects audio frames shorter than eight bytes', () => {
    for (const length of [0, 4, 7]) {
      assert.throws(() => decodeUnifiedAudioFrame(Buffer.alloc(length)), RangeError);
    }
  });

  it('rejects payload lengths that are not whole Float32 samples', () => {
    assert.throws(() => decodeUnifiedAudioFrame(Buffer.alloc(9)), RangeError);
  });

  it('rejects empty sample buffers and invalid chunk IDs', () => {
    assert.throws(() => encodeUnifiedAudioFrame(1, []), RangeError);
    assert.throws(() => encodeUnifiedAudioFrame(-1, [0]), RangeError);
    assert.throws(() => encodeUnifiedAudioFrame(0x1_0000_0000, [0]), RangeError);
  });

  it('issues unique monotonic IDs and stops before reusing an exhausted ID', () => {
    const sequence = new UnifiedStreamChunkIdSequence();
    assert.deepEqual([sequence.next(), sequence.next(), sequence.next()], [0, 1, 2]);

    const lastIDs = new UnifiedStreamChunkIdSequence(0xffff_fffe);
    assert.equal(lastIDs.next(), 0xffff_fffe);
    assert.equal(lastIDs.next(), 0xffff_ffff);
    assert.throws(() => lastIDs.next(), RangeError);
  });

  it('rejects an invalid starting chunk ID', () => {
    assert.throws(() => new UnifiedStreamChunkIdSequence(-1), RangeError);
    assert.throws(() => new UnifiedStreamChunkIdSequence(0x1_0000_0000), RangeError);
  });
});
