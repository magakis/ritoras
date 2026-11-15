import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  chunkLogEntries,
  LOG_SHIPPER_MAX_BODY_BYTES,
} from '../lib/log-shipper.mjs';

const SERVER_REQUEST_CAP_BYTES = 65_536;

function entry(message) {
  return {
    level: 'debug',
    component: 'Keyboard',
    message,
    timestamp: '2026-11-15T00:00:00Z',
  };
}

function bodyByteCount(entries) {
  return Buffer.byteLength(JSON.stringify({ entries }), 'utf8');
}

describe('keyboard log shipper chunk budget', () => {
  it('keeps a batch under budget in one chunk', () => {
    const entries = [entry('first'), entry('second')];
    const chunks = chunkLogEntries(entries);

    assert.strictEqual(LOG_SHIPPER_MAX_BODY_BYTES, 60 * 1024);
    assert.deepStrictEqual(chunks, [entries]);
    assert.ok(bodyByteCount(chunks[0]) <= LOG_SHIPPER_MAX_BODY_BYTES);
  });

  it('splits a batch when the serialized envelope exceeds budget', () => {
    const entries = [
      entry('x'.repeat(35 * 1024)),
      entry('y'.repeat(35 * 1024)),
    ];
    const chunks = chunkLogEntries(entries);

    assert.strictEqual(chunks.length, 2);
    assert.deepStrictEqual(chunks.flat(), entries);
    for (const chunk of chunks) {
      assert.ok(bodyByteCount(chunk) <= LOG_SHIPPER_MAX_BODY_BYTES);
    }
  });

  it('drops a single entry that cannot fit below the server cap', () => {
    const oversizedEntry = entry('x'.repeat(SERVER_REQUEST_CAP_BYTES));
    const chunks = chunkLogEntries([oversizedEntry]);

    assert.ok(bodyByteCount([oversizedEntry]) > SERVER_REQUEST_CAP_BYTES);
    assert.deepStrictEqual(chunks, []);
  });
});
