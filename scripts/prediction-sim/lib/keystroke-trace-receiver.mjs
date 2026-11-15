import { createHash } from 'node:crypto';

export const TRACE_RECEIVER_MAX_BODY_BYTES = 60 * 1024;
export const TRACE_RECEIVER_MAX_REMEMBERED_HASHES = 1_024;
export const TRACE_RECEIVER_SCHEMA_VERSION = 1;

const segmentNames = new Set([
  'ritoras-trace.log.1',
  'ritoras-trace.log',
]);
const eventTypes = new Set(['key', 'suggestion', 'decision', 'state', 'meta']);

function validateState(state) {
  if (!state
      || !Number.isSafeInteger(state.epoch)
      || state.epoch < 0
      || !Array.isArray(state.contentHashes)
      || state.contentHashes.length > TRACE_RECEIVER_MAX_REMEMBERED_HASHES
      || state.contentHashes.some(hash => !/^[a-f0-9]{64}$/.test(hash))
      || typeof state.hasScannedStoreForUnknownChunk !== 'boolean'
      || (state.lastDeliveryAt !== null
        && (!Number.isSafeInteger(state.lastDeliveryAt) || state.lastDeliveryAt < 0))) {
    throw new TypeError('A trace receiver state needs a valid epoch and bounded hash history');
  }
}

function encodedRequestByteCount(request) {
  let encodedRequest;
  try {
    encodedRequest = JSON.stringify(request);
  } catch {
    return null;
  }
  return typeof encodedRequest === 'string'
    ? Buffer.byteLength(encodedRequest, 'utf8')
    : null;
}

function decodePayload(request, maximumBodyBytes) {
  if (!request
      || typeof request !== 'object'
      || Array.isArray(request)
      || typeof request.segmentName !== 'string'
      || !segmentNames.has(request.segmentName)
      || typeof request.segmentIdentity !== 'string'
      || Buffer.byteLength(request.segmentIdentity, 'utf8') < 1
      || Buffer.byteLength(request.segmentIdentity, 'utf8') > 256
      || !Number.isSafeInteger(request.offset)
      || request.offset < 0
      || !Number.isSafeInteger(request.epoch)
      || request.epoch < 0
      || typeof request.payload !== 'string') {
    return { payload: null, statusCode: 400 };
  }

  const payload = Buffer.from(request.payload, 'base64');
  if (payload.length === 0
      || payload.length > maximumBodyBytes
      || payload.toString('base64') !== request.payload) {
    return { payload: null, statusCode: 400 };
  }
  return {
    payload,
    statusCode: null,
  };
}

function hasUnsupportedSchemaVersion(payload) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let lineStart = 0;
  for (let index = 0; index <= payload.length; index += 1) {
    if (index < payload.length && payload[index] !== 0x0a) continue;
    const line = payload.subarray(lineStart, index);
    lineStart = index + 1;
    if (line.length === 0) continue;

    try {
      const record = JSON.parse(decoder.decode(line));
      if (record !== null
          && typeof record === 'object'
          && !Array.isArray(record)
          && Object.prototype.hasOwnProperty.call(record, 'schemaVersion')
          && record.schemaVersion !== TRACE_RECEIVER_SCHEMA_VERSION) {
        return true;
      }
    } catch {
      // Malformed lines are validated after the epoch check.
    }
  }
  return false;
}

function isValidTracePayload(payload) {
  if (payload.length === 0 || payload[payload.length - 1] !== 0x0a) return false;

  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(payload);
  } catch {
    return false;
  }

  const lines = text.split('\n');
  lines.pop();
  return lines.length > 0 && lines.every(line => {
    if (line.length === 0) return false;
    try {
      const record = JSON.parse(line);
      return record?.schemaVersion === TRACE_RECEIVER_SCHEMA_VERSION
        && typeof record.timestamp === 'string'
        && record.event !== null
        && typeof record.event === 'object'
        && !Array.isArray(record.event)
        && eventTypes.has(record.event.type)
        && record.event.payload !== null
        && typeof record.event.payload === 'object'
        && !Array.isArray(record.event.payload);
    } catch {
      return false;
    }
  });
}

function contentHash(payload) {
  return createHash('sha256').update(payload).digest('hex');
}

function rememberHash(hashes, hash) {
  const updated = hashes.filter(value => value !== hash);
  updated.push(hash);
  if (updated.length > TRACE_RECEIVER_MAX_REMEMBERED_HASHES) {
    updated.splice(0, updated.length - TRACE_RECEIVER_MAX_REMEMBERED_HASHES);
  }
  return updated;
}

function containsLineAlignedPayload(storedData, payload) {
  let searchFrom = 0;
  while (searchFrom <= storedData.length - payload.length) {
    const matchIndex = storedData.indexOf(payload, searchFrom);
    if (matchIndex < 0) return false;
    if (matchIndex === 0 || storedData[matchIndex - 1] === 0x0a) return true;
    searchFrom = matchIndex + 1;
  }
  return false;
}

export function createInitialTraceReceiverState(epoch = 0) {
  if (!Number.isSafeInteger(epoch) || epoch < 0) {
    throw new RangeError('A trace receiver epoch must be a non-negative safe integer');
  }
  return {
    epoch,
    contentHashes: [],
    lastDeliveryAt: null,
    hasScannedStoreForUnknownChunk: false,
    pendingAppend: null,
  };
}

/**
 * Mirrors the authenticated receiver's validation and content-hash decision.
 * New chunks remain pending until the app-store append succeeds.
 */
export function planTraceReceive(state, request, {
  maximumBodyBytes = TRACE_RECEIVER_MAX_BODY_BYTES,
  now = Date.now(),
  storedSegments = [],
} = {}) {
  validateState(state);
  if (!Number.isSafeInteger(maximumBodyBytes) || maximumBodyBytes < 1) {
    throw new RangeError('The trace request body limit must be a positive integer');
  }
  if (!Number.isSafeInteger(now) || now < 0) {
    throw new RangeError('A trace delivery time must be a non-negative integer');
  }
  if (!Array.isArray(storedSegments)
      || storedSegments.some(segment => !Buffer.isBuffer(segment))) {
    throw new TypeError('Stored trace segments must be Buffers ordered oldest-first');
  }

  const requestByteCount = encodedRequestByteCount(request);
  if (requestByteCount === null) {
    return {
      state,
      statusCode: 400,
      acknowledged: false,
      shouldAppend: false,
    };
  }
  if (requestByteCount > maximumBodyBytes) {
    return {
      state,
      statusCode: 413,
      acknowledged: false,
      shouldAppend: false,
    };
  }
  if (!request
      || typeof request !== 'object'
      || Array.isArray(request)
      || !Number.isSafeInteger(request.epoch)
      || request.epoch < 0) {
    return {
      state,
      statusCode: 400,
      acknowledged: false,
      shouldAppend: false,
    };
  }

  const schemaProbePayload = typeof request.payload === 'string'
    ? Buffer.from(request.payload, 'base64')
    : null;
  const hasCanonicalPayloadEncoding = schemaProbePayload !== null
    && schemaProbePayload.toString('base64') === request.payload;
  // An explicit schema mismatch takes precedence over the stale-epoch response.
  if (hasCanonicalPayloadEncoding && hasUnsupportedSchemaVersion(schemaProbePayload)) {
    return {
      state,
      statusCode: 400,
      acknowledged: false,
      shouldAppend: false,
    };
  }
  if (request.epoch !== state.epoch) {
    return {
      state,
      statusCode: 200,
      acknowledged: false,
      shouldAppend: false,
    };
  }

  const decoded = decodePayload(request, maximumBodyBytes);
  if (decoded.statusCode !== null) {
    return {
      state,
      statusCode: decoded.statusCode,
      acknowledged: false,
      shouldAppend: false,
    };
  }

  if (!isValidTracePayload(decoded.payload)) {
    return {
      state,
      statusCode: 400,
      acknowledged: false,
      shouldAppend: false,
    };
  }
  if (state.pendingAppend) {
    return {
      state,
      statusCode: 503,
      acknowledged: false,
      shouldAppend: false,
    };
  }

  const hash = contentHash(decoded.payload);
  if (state.contentHashes.includes(hash)) {
    const storedData = Buffer.concat(storedSegments);
    if (containsLineAlignedPayload(storedData, decoded.payload)) {
      return {
        state: { ...state, lastDeliveryAt: now },
        statusCode: 200,
        acknowledged: true,
        shouldAppend: false,
      };
    }
    state = {
      ...state,
      contentHashes: state.contentHashes.filter(value => value !== hash),
      hasScannedStoreForUnknownChunk: true,
    };
  }

  if (!state.hasScannedStoreForUnknownChunk) {
    state = { ...state, hasScannedStoreForUnknownChunk: true };
    if (containsLineAlignedPayload(Buffer.concat(storedSegments), decoded.payload)) {
      return {
        state: {
          ...state,
          contentHashes: rememberHash(state.contentHashes, hash),
          lastDeliveryAt: now,
        },
        statusCode: 200,
        acknowledged: true,
        shouldAppend: false,
      };
    }
  }

  return {
    state: {
      ...state,
      pendingAppend: {
        hash,
        payload: decoded.payload,
        receivedAt: now,
      },
    },
    statusCode: 200,
    acknowledged: false,
    shouldAppend: true,
  };
}

export function commitTraceReceiveAppend(state) {
  validateState(state);
  if (!state.pendingAppend) {
    throw new TypeError('A trace append must be pending before it can be committed');
  }

  return {
    ...state,
    contentHashes: rememberHash(state.contentHashes, state.pendingAppend.hash),
    lastDeliveryAt: state.pendingAppend.receivedAt,
    pendingAppend: null,
  };
}

export function deleteAllTraceReceiverState(state) {
  validateState(state);
  if (state.epoch === Number.MAX_SAFE_INTEGER) {
    throw new RangeError('The trace receiver epoch cannot be incremented safely');
  }
  return {
    ...createInitialTraceReceiverState(state.epoch + 1),
    hasScannedStoreForUnknownChunk: true,
  };
}
