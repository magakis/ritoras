import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  BackgroundUploadTerminal as Terminal,
  classifyResponse,
  classifyTransportFailure,
  IDEMPOTENCY_TTL_MS,
  isWithinIdempotencyTTL,
  MAX_RESPONSE_BYTES,
  mapHTTPFailure,
  reconcile,
  ReconcileDecision as Decision,
  SERVER_TTL_MS,
  TERMINAL_WAITER_TIMEOUT_MS,
  TerminalPersistenceDecision,
  terminalPersistenceDecision,
  shouldRecordTerminal,
  shouldNotifyDurableUpdate,
  WaiterEvent,
  WaiterState,
  transitionWaiter,
} from '../lib/background-upload-rules.mjs';

const id = 'dictation-1';
const pending = (overrides = {}) => ({ id, audioFilePath: '/audio.wav', createdAt: 0, submittedAt: 0, acceptedAt: null, terminalAt: null, state: 'submitting', ...overrides });
const accepted = classifyResponse(202, JSON.stringify({ job_id: 'job-1', status_endpoint: '/jobs/job-1' }));
const decide = (overrides = {}) => reconcile({
  pendingRecords: [pending()], liveTaskIDs: new Set(), durableTerminals: [],
  waiterIDs: new Set(), status404IDs: new Set(), now: 1, ...overrides,
})[0];

describe('background upload lifecycle rules mirror', () => {
  it('preserves unauthorized semantics for HTTP 401 while retaining 404 and generic failures', () => {
    assert.deepStrictEqual(mapHTTPFailure(401), { kind: 'unauthorized' });
    assert.deepStrictEqual(mapHTTPFailure(404), { kind: 'asyncUnsupported' });
    assert.deepStrictEqual(mapHTTPFailure(503), { kind: 'httpError', status: 503 });
  });

  it('classifies transport, HTTP, malformed 202 and valid accepted responses', () => {
    assert.deepStrictEqual(classifyTransportFailure('offline'), { kind: Terminal.transportFailure, reason: 'offline' });
    assert.deepStrictEqual(classifyResponse(404, '{}'), { kind: Terminal.httpFailure, status: 404 });
    assert.deepStrictEqual(classifyResponse(202, '{'), { kind: Terminal.malformedResponse });
    assert.deepStrictEqual(accepted, { kind: Terminal.accepted, jobID: 'job-1', statusEndpoint: '/jobs/job-1' });
  });

  it('accepts the exact byte cap and rejects overflow, including otherwise valid JSON', () => {
    assert.strictEqual(classifyResponse(200, Buffer.alloc(MAX_RESPONSE_BYTES)).kind, Terminal.httpFailure);
    assert.strictEqual(classifyResponse(202, Buffer.alloc(MAX_RESPONSE_BYTES + 1)).kind, Terminal.responseTooLarge);
  });

  it('keeps a live transfer through reconcile and retains missing-task unknown outcomes without resubmitting', () => {
    assert.deepStrictEqual(decide({ liveTaskIDs: new Set([id]) }), { action: Decision.awaitTerminal, id });
    assert.deepStrictEqual(decide(), { action: Decision.retainUnknown, id });
  });

  it('persists acceptance before waiter notification; relaunch without waiter keeps it durable', () => {
    const durableTerminals = [{ id, terminal: accepted, recordedAt: 50, notifiedAt: null }];
    assert.deepStrictEqual(decide({ durableTerminals, waiterIDs: new Set([id]) }), {
      action: Decision.notifyWaiter, id, terminal: accepted,
    });
    assert.deepStrictEqual(decide({ durableTerminals }), { action: Decision.keepDurable, id, terminal: accepted });
    // Duplicate delegate completion/relaunch sees the same one durable terminal; no new POST decision exists.
    assert.deepStrictEqual(decide({ durableTerminals: [{ ...durableTerminals[0], notifiedAt: 51 }], waiterIDs: new Set([id]) }), {
      action: Decision.keepDurable, id, terminal: accepted,
    });
  });

  it('does not report acceptance or allow resubmission when terminal persistence fails', () => {
    assert.strictEqual(
      terminalPersistenceDecision(false),
      TerminalPersistenceDecision.retainUnknownAndWakeWaiter,
    );
    assert.strictEqual(
      terminalPersistenceDecision(true),
      TerminalPersistenceDecision.publishDurableTerminal,
    );
    assert.strictEqual(shouldRecordTerminal(false), true);
    assert.strictEqual(shouldRecordTerminal(true), false);
    assert.strictEqual(shouldNotifyDurableUpdate(false, false), false);
    assert.strictEqual(shouldNotifyDurableUpdate(true, true), false);
    assert.strictEqual(shouldNotifyDurableUpdate(true, false), true);
    const failedWriteRecord = pending({ state: 'submitting', bodyFilePath: '/support/upload.multipart' });
    assert.deepStrictEqual(decide({ pendingRecords: [failedWriteRecord] }), {
      action: Decision.retainUnknown,
      id,
    });
    assert.strictEqual(failedWriteRecord.audioFilePath, '/audio.wav');
    assert.strictEqual(failedWriteRecord.bodyFilePath, '/support/upload.multipart');
  });

  it('settles timeout, cancellation, replacement, and completion races exactly once', () => {
    assert.strictEqual(TERMINAL_WAITER_TIMEOUT_MS, 600_000);
    const resolve = (events) => events.reduce((result, event) => {
      const nextState = transitionWaiter(result.state, event);
      return {
        state: nextState,
        callbacks: result.callbacks + (nextState === WaiterState.terminal && result.state !== WaiterState.terminal ? 1 : 0),
      };
    }, { state: WaiterState.waiting, callbacks: 0 });
    assert.deepStrictEqual(
      resolve([WaiterEvent.terminal, WaiterEvent.timeout, WaiterEvent.terminal]),
      { state: WaiterState.terminal, callbacks: 1 },
    );
    assert.deepStrictEqual(
      resolve([WaiterEvent.cancel, WaiterEvent.terminal, WaiterEvent.timeout]),
      { state: WaiterState.cancelled, callbacks: 0 },
    );
    assert.deepStrictEqual(
      resolve([WaiterEvent.timeout, WaiterEvent.cancel, WaiterEvent.terminal]),
      { state: WaiterState.timedOut, callbacks: 0 },
    );
    assert.deepStrictEqual(
      resolve([WaiterEvent.replace, WaiterEvent.terminal]),
      { state: WaiterState.replaced, callbacks: 0 },
    );
    assert.strictEqual(
      transitionWaiter(WaiterState.pendingRegistration, WaiterEvent.cancel),
      WaiterState.cancelled,
    );
  });

  it('does not lose a completion racing task reconciliation when the terminal is already durable', () => {
    assert.strictEqual(decide({ liveTaskIDs: new Set([id]), durableTerminals: [{ id, terminal: accepted, recordedAt: 1, notifiedAt: null }] }).action, Decision.awaitTerminal);
    assert.strictEqual(decide({ durableTerminals: [{ id, terminal: accepted, recordedAt: 1, notifiedAt: null }], waiterIDs: new Set([id]) }).action, Decision.notifyWaiter);
  });

  it('routes durable failures to saved audio, never silently resubmits', () => {
    const failure = classifyResponse(422, '{}');
    assert.deepStrictEqual(decide({ durableTerminals: [{ id, terminal: failure, recordedAt: 2, notifiedAt: null }] }), {
      action: Decision.routeSavedAudioRetry, id, reason: 'terminal upload failure',
    });
  });

  it('treats 404 as ambiguous through the 600s server TTL and routes recovery after it', () => {
    const status404IDs = new Set([id]);
    assert.deepStrictEqual(decide({ status404IDs, now: SERVER_TTL_MS }), { action: Decision.retainUnknown, id });
    assert.deepStrictEqual(decide({ status404IDs, now: SERVER_TTL_MS + 1 }), {
      action: Decision.routeSavedAudioRetry, id, reason: '404 after server TTL',
    });
  });

  it('keeps idempotency replay expiry independent and uses original submission time', () => {
    assert.strictEqual(isWithinIdempotencyTTL(100, 100 + IDEMPOTENCY_TTL_MS), true);
    assert.strictEqual(isWithinIdempotencyTTL(100, 101 + IDEMPOTENCY_TTL_MS), false);
  });

  it('preserves unknown outcome policy across interruption boundaries', () => {
    // Mapping persisted but task not resumed, resumed but no response, and 202 received
    // before terminal persistence all reconcile as unknown; only durable terminal enables notify.
    for (const checkpoint of ['mapping-before-resume', 'resumed-before-response', 'response-before-terminal-write', 'force-quit-task-gone']) {
      assert.deepStrictEqual(decide({ pendingRecords: [pending({ checkpoint })] }), { action: Decision.retainUnknown, id });
    }
    const afterTerminalWrite = decide({ durableTerminals: [{ id, terminal: accepted, recordedAt: 30, notifiedAt: null }], waiterIDs: new Set([id]) });
    assert.strictEqual(afterTerminalWrite.action, Decision.notifyWaiter);
  });
});
