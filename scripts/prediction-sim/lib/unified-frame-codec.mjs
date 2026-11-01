// Pure-logic mirror of shared/UnifiedStreamProtocol.swift frame encoding.

export const UNIFIED_STREAM_MAX_CHUNK_ID = 0xffff_ffff;

export class UnifiedStreamChunkIdSequence {
  #nextId;

  constructor(startingAt = 0) {
    if (!Number.isInteger(startingAt)
        || startingAt < 0
        || startingAt > UNIFIED_STREAM_MAX_CHUNK_ID) {
      throw new RangeError('Starting chunk ID must be an unsigned 32-bit integer.');
    }
    this.#nextId = startingAt;
  }

  next() {
    if (this.#nextId > UNIFIED_STREAM_MAX_CHUNK_ID) {
      throw new RangeError('Unified stream chunk IDs are exhausted.');
    }
    const chunkId = this.#nextId;
    this.#nextId += 1;
    return chunkId;
  }
}

export function encodeUnifiedAudioFrame(chunkId, samples) {
  if (!Number.isInteger(chunkId)
      || chunkId < 0
      || chunkId > UNIFIED_STREAM_MAX_CHUNK_ID) {
    throw new RangeError('Chunk ID must be an unsigned 32-bit integer.');
  }
  if (!Array.isArray(samples) || samples.length === 0) {
    throw new RangeError('A unified audio frame must contain at least one Float32 sample.');
  }

  const frame = Buffer.allocUnsafe(4 + samples.length * 4);
  frame.writeUInt32BE(chunkId, 0);
  for (let index = 0; index < samples.length; index += 1) {
    frame.writeFloatLE(samples[index], 4 + index * 4);
  }
  return frame;
}

export function decodeUnifiedAudioFrame(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError('A unified audio frame must be supplied as bytes.');
  }
  const frame = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (frame.length < 8 || (frame.length - 4) % 4 !== 0) {
    throw new RangeError('Unified audio frames require an ID and whole Float32 samples.');
  }

  const samples = [];
  for (let offset = 4; offset < frame.length; offset += 4) {
    samples.push(frame.readFloatLE(offset));
  }
  return { chunkId: frame.readUInt32BE(0), samples };
}
