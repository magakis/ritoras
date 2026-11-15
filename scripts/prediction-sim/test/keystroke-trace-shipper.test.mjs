import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  TRACE_SHIPPER_CADENCE_MS,
  TRACE_UPLOAD_LIVE_FILE_NAME,
  TRACE_UPLOAD_MAX_BODY_BYTES,
  TRACE_UPLOAD_ROUTE,
  TRACE_UPLOAD_ROTATED_FILE_NAME,
  applyTraceUploadResponse,
  createInitialTraceShipState,
  keepTraceShipStateAfterFailure,
  nextTraceUploadChunk,
  reconcileTraceShipState,
  toggleTraceCapture,
} from '../lib/keystroke-trace-shipper.mjs';

const MAX_REQUEST_BYTES = 65_536;
const REQUEST_FRAMING_ALLOWANCE_BYTES = 4 * 1024;

function segment(name, identity, lines) {
  return {
    name,
    identity,
    bytes: Buffer.concat(lines.map(line => Buffer.from(`${line}\n`))),
  };
}

describe('keystroke trace shipper policy mirror', () => {
  it('keeps the loopback contract and keyboard-local toggle default-off', () => {
    assert.strictEqual(TRACE_UPLOAD_ROUTE, '/trace');
    assert.strictEqual(TRACE_SHIPPER_CADENCE_MS, 2_000);
    assert.strictEqual(TRACE_UPLOAD_MAX_BODY_BYTES, 60 * 1024);
    const disabled = {
      enabledPreference: false,
      recorderEnabled: false,
      idleFlushTimerActive: false,
      didLogFailure: false,
    };
    const enabled = toggleTraceCapture(disabled);
    assert.strictEqual(enabled.state.enabledPreference, true);
    assert.deepStrictEqual(enabled.actions, ['persist-preference']);
    assert.throws(() => toggleTraceCapture({}), TypeError);
  });

  it('flushes at idle before persisting the disable preference', () => {
    const enabled = {
      enabledPreference: true,
      recorderEnabled: true,
      idleFlushTimerActive: true,
      didLogFailure: false,
    };

    const result = toggleTraceCapture(enabled);

    assert.deepStrictEqual(result.actions, ['flush-idle', 'persist-preference']);
    assert.strictEqual(result.state.enabledPreference, false);
    assert.strictEqual(result.state.recorderEnabled, true);
    assert.strictEqual(enabled.enabledPreference, true);
  });

  it('stops capture after flush failure and latches failure logging once', () => {
    const enabled = {
      enabledPreference: true,
      recorderEnabled: true,
      idleFlushTimerActive: true,
      didLogFailure: false,
    };

    const failed = toggleTraceCapture(enabled, { flushSucceeded: false });

    assert.deepStrictEqual(
      failed.actions,
      ['flush-idle', 'log-failure', 'persist-preference']
    );
    assert.strictEqual(failed.shouldLogFailure, true);
    assert.strictEqual(failed.state.enabledPreference, false);
    assert.strictEqual(failed.state.recorderEnabled, false);
    assert.strictEqual(failed.state.idleFlushTimerActive, false);
    assert.strictEqual(failed.state.didLogFailure, true);

    const recovered = {
      ...failed.state,
      enabledPreference: true,
      recorderEnabled: true,
      idleFlushTimerActive: true,
    };
    const failedAgain = toggleTraceCapture(recovered, { flushSucceeded: false });

    assert.deepStrictEqual(failedAgain.actions, ['flush-idle', 'persist-preference']);
    assert.strictEqual(failedAgain.shouldLogFailure, false);
    assert.strictEqual(failedAgain.state.didLogFailure, true);
  });

  it('makes the encoded request fit the cap without splitting NDJSON lines', () => {
    const largeLine = JSON.stringify({ text: 'x'.repeat(18 * 1024) });
    const source = segment(
      TRACE_UPLOAD_LIVE_FILE_NAME,
      'live-file-1',
      [largeLine, largeLine, largeLine]
    );
    const state = createInitialTraceShipState(4);

    const result = nextTraceUploadChunk(state, [source]);

    assert.ok(result.chunk);
    assert.ok(result.chunk.body.length <= TRACE_UPLOAD_MAX_BODY_BYTES);
    assert.ok(
      result.chunk.body.length + REQUEST_FRAMING_ALLOWANCE_BYTES
        <= MAX_REQUEST_BYTES
    );
    assert.strictEqual(result.chunk.request.segmentName, TRACE_UPLOAD_LIVE_FILE_NAME);
    assert.strictEqual(result.chunk.request.segmentIdentity, 'live-file-1');
    assert.strictEqual(result.chunk.request.offset, 0);
    assert.strictEqual(result.chunk.request.epoch, 4);
    assert.deepStrictEqual(
      Buffer.from(result.chunk.request.payload, 'base64'),
      Buffer.concat([Buffer.from(`${largeLine}\n`), Buffer.from(`${largeLine}\n`)])
    );
    assert.strictEqual(
      result.chunk.payload[result.chunk.payload.length - 1],
      0x0a
    );
    assert.strictEqual(
      result.chunk.nextOffset,
      result.chunk.payload.length
    );
  });

  it('shrinks an underestimated fill against the actual body before dispatch', () => {
    const largeLine = JSON.stringify({ text: 'x'.repeat(18 * 1024) });
    const source = segment(
      TRACE_UPLOAD_LIVE_FILE_NAME,
      'live-estimate-drift',
      [largeLine, largeLine, largeLine]
    );
    const result = nextTraceUploadChunk(
      createInitialTraceShipState(4),
      [source],
      TRACE_UPLOAD_MAX_BODY_BYTES,
      { estimateBodyBytes: () => 0 }
    );
    assert.ok(result.chunk);
    const expectedPayload = Buffer.concat([
      Buffer.from(`${largeLine}\n`),
      Buffer.from(`${largeLine}\n`),
    ]);
    const oversizedBody = Buffer.from(JSON.stringify({
      ...result.chunk.request,
      payload: source.bytes.toString('base64'),
    }));

    assert.ok(oversizedBody.length > TRACE_UPLOAD_MAX_BODY_BYTES);
    assert.ok(result.chunk.body.length <= TRACE_UPLOAD_MAX_BODY_BYTES);
    assert.deepStrictEqual(result.chunk.payload, expectedPayload);
    assert.strictEqual(result.chunk.nextOffset, expectedPayload.length);
  });

  it('leaves an incomplete trailing record out of the upload chunk', () => {
    const source = {
      name: TRACE_UPLOAD_LIVE_FILE_NAME,
      identity: 'live-partial',
      bytes: Buffer.from('complete\npartial'),
    };

    const result = nextTraceUploadChunk(createInitialTraceShipState(), [source]);

    assert.strictEqual(
      Buffer.from(result.chunk.request.payload, 'base64').toString('utf8'),
      'complete\n'
    );
    assert.strictEqual(result.chunk.nextOffset, Buffer.byteLength('complete\n'));
  });

  it('does not skip a line that cannot fit in a request', () => {
    const source = segment(
      TRACE_UPLOAD_LIVE_FILE_NAME,
      'live-oversized',
      [JSON.stringify({ text: 'x'.repeat(256) })]
    );
    const state = createInitialTraceShipState();

    const result = nextTraceUploadChunk(state, [source], 200);

    assert.strictEqual(result.chunk, null);
    assert.deepStrictEqual(result.state.cursors, {});
  });

  it('chooses the rotated segment before the live segment', () => {
    const live = segment(TRACE_UPLOAD_LIVE_FILE_NAME, 'live-2', ['new']);
    const rotated = segment(TRACE_UPLOAD_ROTATED_FILE_NAME, 'rotated-1', ['old']);

    const result = nextTraceUploadChunk(createInitialTraceShipState(), [live, rotated]);

    assert.strictEqual(result.chunk.request.segmentName, TRACE_UPLOAD_ROTATED_FILE_NAME);
    assert.strictEqual(
      Buffer.from(result.chunk.request.payload, 'base64').toString('utf8'),
      'old\n'
    );
  });

  it('advances the durable cursor only on an acknowledged matching-epoch response', () => {
    const source = segment(TRACE_UPLOAD_LIVE_FILE_NAME, 'live-3', ['one', 'two']);
    const state = createInitialTraceShipState(2);
    const { chunk } = nextTraceUploadChunk(state, [source]);

    assert.strictEqual(
      keepTraceShipStateAfterFailure(state),
      state
    );
    const rejected = applyTraceUploadResponse(state, chunk, {
      acknowledged: false,
      epoch: 2,
    });
    assert.strictEqual(rejected.advanced, false);
    assert.deepStrictEqual(rejected.state, state);

    const acknowledged = applyTraceUploadResponse(state, chunk, {
      acknowledged: true,
      epoch: 2,
    });
    assert.strictEqual(acknowledged.advanced, true);
    assert.strictEqual(acknowledged.shouldWipeLocalData, false);
    assert.strictEqual(
      acknowledged.state.cursors['live-3'],
      chunk.nextOffset
    );
  });

  it('wipes local state when the server epoch changes', () => {
    const state = {
      epoch: 3,
      cursors: { 'rotated-4': 128, 'live-4': 64 },
    };
    const chunk = {
      request: {
        segmentIdentity: 'rotated-4',
        offset: 128,
      },
      nextOffset: 256,
    };

    const result = applyTraceUploadResponse(
      state,
      chunk,
      {
        acknowledged: false,
        epoch: 4,
      },
      { didWipeLocalData: true }
    );

    assert.strictEqual(result.shouldWipeLocalData, true);
    assert.strictEqual(result.advanced, false);
    assert.deepStrictEqual(result.state, createInitialTraceShipState(4));
  });

  it('keeps the old epoch and retries when the local wipe fails', () => {
    const state = {
      epoch: 3,
      cursors: { 'rotated-4': 128, 'live-4': 64 },
    };
    const chunk = {
      request: {
        segmentIdentity: 'rotated-4',
        offset: 128,
      },
      nextOffset: 256,
    };
    const response = { acknowledged: false, epoch: 4 };

    const failedWipe = applyTraceUploadResponse(
      state,
      chunk,
      response,
      { didWipeLocalData: false }
    );

    assert.strictEqual(failedWipe.state, state);
    assert.strictEqual(failedWipe.shouldWipeLocalData, true);
    assert.strictEqual(failedWipe.advanced, false);

    const retriedWipe = applyTraceUploadResponse(
      failedWipe.state,
      chunk,
      response,
      { didWipeLocalData: true }
    );

    assert.deepStrictEqual(retriedWipe.state, createInitialTraceShipState(4));
    assert.strictEqual(retriedWipe.shouldWipeLocalData, true);
    assert.strictEqual(retriedWipe.advanced, false);
  });

  it('evicts cursors for rotated-away segments and rewinds invalid offsets', () => {
    const live = segment(TRACE_UPLOAD_LIVE_FILE_NAME, 'live-5', ['one']);
    const state = {
      epoch: 0,
      cursors: {
        'evicted-5': 90,
        'live-5': 99,
      },
    };

    const result = reconcileTraceShipState(state, [live]);

    assert.deepStrictEqual(result.evictedIdentities, ['evicted-5']);
    assert.deepStrictEqual(result.resetIdentities, ['live-5']);
    assert.deepStrictEqual(result.state, {
      epoch: 0,
      cursors: { 'live-5': 0 },
    });
  });

  it('rewinds a cursor that lands in the middle of a line', () => {
    const live = segment(TRACE_UPLOAD_LIVE_FILE_NAME, 'live-midline', ['record']);
    const state = {
      epoch: 0,
      cursors: { 'live-midline': 2 },
    };

    const result = reconcileTraceShipState(state, [live]);

    assert.deepStrictEqual(result.resetIdentities, ['live-midline']);
    assert.deepStrictEqual(result.state.cursors, { 'live-midline': 0 });
  });
});
