export const BackgroundUploadTerminal = Object.freeze({
  accepted: 'accepted',
  transportFailure: 'transportFailure',
  httpFailure: 'httpFailure',
  malformedResponse: 'malformedResponse',
  responseTooLarge: 'responseTooLarge',
});

export const ReconcileDecision = Object.freeze({
  awaitTerminal: 'awaitTerminal',
  keepDurable: 'keepDurable',
  notifyWaiter: 'notifyWaiter',
  routeSavedAudioRetry: 'routeSavedAudioRetry',
  dropExpired: 'dropExpired',
  retainUnknown: 'retainUnknown',
});

export const TerminalPersistenceDecision = Object.freeze({
  publishDurableTerminal: 'publishDurableTerminal',
  retainUnknownAndWakeWaiter: 'retainUnknownAndWakeWaiter',
});

export const WaiterState = Object.freeze({
  pendingRegistration: 'pendingRegistration',
  waiting: 'waiting',
  terminal: 'terminal',
  timedOut: 'timedOut',
  cancelled: 'cancelled',
  replaced: 'replaced',
});

export const WaiterEvent = Object.freeze({
  register: 'register',
  terminal: 'terminal',
  timeout: 'timeout',
  cancel: 'cancel',
  replace: 'replace',
});

export const MAX_RESPONSE_BYTES = 64 * 1024;
export const SERVER_TTL_MS = 600_000;
export const IDEMPOTENCY_TTL_MS = 600_000;
export const TERMINAL_WAITER_TIMEOUT_MS = 600_000;

export function mapHTTPFailure(status) {
  if (status === 401) return { kind: 'unauthorized' };
  if (status === 404) return { kind: 'asyncUnsupported' };
  return { kind: 'httpError', status };
}

export function classifyResponse(status, body) {
  const bytes = Buffer.isBuffer(body) ? body : Buffer.from(body);
  if (bytes.length > MAX_RESPONSE_BYTES) return { kind: BackgroundUploadTerminal.responseTooLarge };
  if (status !== 202) return { kind: BackgroundUploadTerminal.httpFailure, status };
  try {
    const parsed = JSON.parse(bytes.toString('utf8'));
    if (typeof parsed.job_id !== 'string' || !parsed.job_id ||
        typeof parsed.status_endpoint !== 'string' || !parsed.status_endpoint) {
      return { kind: BackgroundUploadTerminal.malformedResponse };
    }
    return { kind: BackgroundUploadTerminal.accepted, jobID: parsed.job_id, statusEndpoint: parsed.status_endpoint };
  } catch {
    return { kind: BackgroundUploadTerminal.malformedResponse };
  }
}

export function classifyTransportFailure(reason) {
  return { kind: BackgroundUploadTerminal.transportFailure, reason };
}

export function terminalPersistenceDecision(didPersist) {
  return didPersist
    ? TerminalPersistenceDecision.publishDurableTerminal
    : TerminalPersistenceDecision.retainUnknownAndWakeWaiter;
}

export function shouldRecordTerminal(existingTerminal) {
  return !existingTerminal;
}

export function shouldNotifyDurableUpdate(didPersist, existingTerminal) {
  return didPersist && !existingTerminal;
}

export function transitionWaiter(state, event) {
  if (state === WaiterState.pendingRegistration && event === WaiterEvent.register) return WaiterState.waiting;
  if ((state === WaiterState.pendingRegistration || state === WaiterState.waiting) && event === WaiterEvent.cancel) {
    return WaiterState.cancelled;
  }
  if (state !== WaiterState.waiting) return state;
  switch (event) {
    case WaiterEvent.terminal: return WaiterState.terminal;
    case WaiterEvent.timeout: return WaiterState.timedOut;
    case WaiterEvent.replace: return WaiterState.replaced;
    default: return state;
  }
}

export function isWithinIdempotencyTTL(submittedAt, now) {
  return now - submittedAt <= IDEMPOTENCY_TTL_MS;
}

export function reconcile({ pendingRecords, liveTaskIDs, durableTerminals, waiterIDs, status404IDs = new Set(), now }) {
  const terminals = new Map(durableTerminals.map((terminal) => [terminal.id, terminal]));
  return pendingRecords.map((record) => {
    if (liveTaskIDs.has(record.id)) return { action: ReconcileDecision.awaitTerminal, id: record.id };
    const durable = terminals.get(record.id);
    if (durable) {
      if (durable.terminal.kind === BackgroundUploadTerminal.accepted) {
        return {
          action: waiterIDs.has(record.id) && durable.notifiedAt == null
            ? ReconcileDecision.notifyWaiter : ReconcileDecision.keepDurable,
          id: record.id,
          terminal: durable.terminal,
        };
      }
      return { action: ReconcileDecision.routeSavedAudioRetry, id: record.id, reason: 'terminal upload failure' };
    }
    if (status404IDs.has(record.id) && record.submittedAt !== null && record.submittedAt !== undefined &&
        now - record.submittedAt > SERVER_TTL_MS) {
      return { action: ReconcileDecision.routeSavedAudioRetry, id: record.id, reason: '404 after server TTL' };
    }
    return { action: ReconcileDecision.retainUnknown, id: record.id };
  });
}
