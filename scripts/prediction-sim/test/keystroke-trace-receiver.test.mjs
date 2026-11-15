import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  TRACE_RECEIVER_MAX_BODY_BYTES,
  commitTraceReceiveAppend,
  createInitialTraceReceiverState,
  deleteAllTraceReceiverState,
  planTraceReceive,
} from '../lib/keystroke-trace-receiver.mjs';
import {
  TRACE_UPLOAD_LIVE_FILE_NAME,
  TRACE_UPLOAD_MAX_BODY_BYTES,
  createInitialTraceShipState,
  nextTraceUploadChunk,
} from '../lib/keystroke-trace-shipper.mjs';

const MAX_REQUEST_BYTES = 65_536;
const REQUEST_FRAMING_ALLOWANCE_BYTES = 4 * 1024;

function tracePayload(action = 'sessionStarted') {
  return Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    timestamp: '2026-11-15T12:00:00.000Z',
    event: {
      type: 'meta',
      payload: { action },
    },
  })}\n`);
}

function upload(payload, epoch = 0) {
  return {
    segmentName: 'ritoras-trace.log',
    segmentIdentity: '1234:16dd2a3b4c5d',
    offset: 0,
    epoch,
    payload: payload.toString('base64'),
  };
}

describe('keystroke trace receiver mirror', () => {
  it('validates bounded line-aligned schema-v1 requests before appending', () => {
    const payload = tracePayload();
    const planned = planTraceReceive(
      createInitialTraceReceiverState(),
      upload(payload),
      { now: 100 }
    );

    assert.strictEqual(TRACE_RECEIVER_MAX_BODY_BYTES, 60 * 1024);
    assert.strictEqual(
      TRACE_RECEIVER_MAX_BODY_BYTES + REQUEST_FRAMING_ALLOWANCE_BYTES,
      MAX_REQUEST_BYTES
    );
    assert.strictEqual(planned.statusCode, 200);
    assert.strictEqual(planned.acknowledged, false);
    assert.strictEqual(planned.shouldAppend, true);
    assert.deepStrictEqual(planned.state.pendingAppend.payload, payload);
    assert.strictEqual(planned.state.pendingAppend.receivedAt, 100);
  });

  it('accepts a maximally-filled shipper chunk with HTTP framing headroom', () => {
    const line = tracePayload();
    const source = {
      name: TRACE_UPLOAD_LIVE_FILE_NAME,
      identity: '1234:16dd2a3b4c5d',
      bytes: Buffer.concat(Array.from({ length: 600 }, () => line)),
    };
    const { chunk } = nextTraceUploadChunk(
      createInitialTraceShipState(),
      [source]
    );

    assert.ok(chunk);
    assert.strictEqual(TRACE_UPLOAD_MAX_BODY_BYTES, TRACE_RECEIVER_MAX_BODY_BYTES);
    assert.ok(chunk.body.length <= TRACE_RECEIVER_MAX_BODY_BYTES);
    assert.ok(
      chunk.body.length + REQUEST_FRAMING_ALLOWANCE_BYTES
        <= MAX_REQUEST_BYTES
    );
    const nextLineRequest = {
      ...chunk.request,
      payload: Buffer.concat([chunk.payload, line]).toString('base64'),
    };
    assert.ok(
      Buffer.byteLength(JSON.stringify(nextLineRequest))
        > TRACE_RECEIVER_MAX_BODY_BYTES
    );

    const planned = planTraceReceive(
      createInitialTraceReceiverState(),
      chunk.request,
      { now: 150 }
    );

    assert.strictEqual(planned.statusCode, 200);
    assert.strictEqual(planned.shouldAppend, true);
    assert.deepStrictEqual(planned.state.pendingAppend.payload, chunk.payload);
  });

  it('rejects malformed records and oversized bodies without changing state', () => {
    const state = createInitialTraceReceiverState(3);
    const invalidSchema = tracePayload().toString('utf8')
      .replace('"schemaVersion":1', '"schemaVersion":2');
    const malformed = planTraceReceive(
      state,
      upload(Buffer.from(invalidSchema)),
      { now: 200 }
    );
    const oversized = planTraceReceive(
      state,
      upload(Buffer.alloc(TRACE_RECEIVER_MAX_BODY_BYTES)),
      { now: 200 }
    );

    assert.strictEqual(malformed.statusCode, 400);
    assert.strictEqual(malformed.acknowledged, false);
    assert.strictEqual(malformed.state, state);
    assert.strictEqual(oversized.statusCode, 413);
    assert.strictEqual(oversized.state, state);
  });

  it('returns the current epoch for stale chunks without appending them', () => {
    const state = createInitialTraceReceiverState(5);
    const stale = planTraceReceive(
      state,
      upload(Buffer.from('not NDJSON\n'), 4),
      { now: 300 }
    );

    assert.strictEqual(stale.statusCode, 200);
    assert.strictEqual(stale.acknowledged, false);
    assert.strictEqual(stale.shouldAppend, false);
    assert.strictEqual(stale.state.epoch, 5);
    assert.strictEqual(stale.state, state);
  });

  it('commits new chunks and acknowledges content-hash duplicates without appending', () => {
    const payload = tracePayload();
    const state = createInitialTraceReceiverState(2);
    const first = planTraceReceive(state, upload(payload, 2), { now: 400 });
    const committed = commitTraceReceiveAppend(first.state);
    const duplicate = planTraceReceive(
      committed,
      upload(payload, 2),
      {
        now: 500,
        storedSegments: [Buffer.concat([Buffer.from('prior record\n'), payload])],
      }
    );

    assert.strictEqual(committed.contentHashes.length, 1);
    assert.strictEqual(committed.lastDeliveryAt, 400);
    assert.strictEqual(duplicate.statusCode, 200);
    assert.strictEqual(duplicate.acknowledged, true);
    assert.strictEqual(duplicate.shouldAppend, false);
    assert.strictEqual(duplicate.state.contentHashes.length, 1);
    assert.strictEqual(duplicate.state.lastDeliveryAt, 500);
  });

  it('recognizes an append completed before its hash metadata was persisted', () => {
    const payload = tracePayload();
    const replay = planTraceReceive(createInitialTraceReceiverState(), upload(payload), {
      now: 700,
      storedSegments: [
        Buffer.from('older record\n'),
        Buffer.concat([payload, Buffer.from('newer record\n')]),
      ],
    });

    assert.strictEqual(replay.state.contentHashes.length, 1);
    assert.strictEqual(replay.state.lastDeliveryAt, 700);
    assert.strictEqual(replay.acknowledged, true);
    assert.strictEqual(replay.shouldAppend, false);
  });

  it('does not suppress a hash whose chunk has already rotated out of the store', () => {
    const payload = tracePayload();
    const planned = planTraceReceive(
      createInitialTraceReceiverState(),
      upload(payload),
      { now: 750 }
    );
    const committed = commitTraceReceiveAppend(planned.state);
    const evicted = planTraceReceive(
      committed,
      upload(payload),
      { now: 775, storedSegments: [Buffer.from('newer record\n')] }
    );

    assert.strictEqual(evicted.shouldAppend, true);
    assert.strictEqual(evicted.acknowledged, false);
    assert.deepStrictEqual(evicted.state.contentHashes, []);
  });

  it('bumps the epoch and forgets stored chunks on Delete All', () => {
    const payload = tracePayload();
    const planned = planTraceReceive(
      createInitialTraceReceiverState(8),
      upload(payload, 8),
      { now: 800 }
    );
    const committed = commitTraceReceiveAppend(planned.state);
    const deleted = deleteAllTraceReceiverState(committed);
    const oldUpload = planTraceReceive(deleted, upload(payload, 8), { now: 900 });

    assert.strictEqual(deleted.epoch, 9);
    assert.deepStrictEqual(deleted.contentHashes, []);
    assert.strictEqual(deleted.lastDeliveryAt, null);
    assert.strictEqual(oldUpload.statusCode, 200);
    assert.strictEqual(oldUpload.acknowledged, false);
    assert.strictEqual(oldUpload.state.epoch, 9);
  });
});
