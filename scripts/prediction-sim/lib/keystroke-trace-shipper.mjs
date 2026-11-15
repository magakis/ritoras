export const TRACE_UPLOAD_ROUTE = '/trace';
export const TRACE_UPLOAD_MAX_BODY_BYTES = 60 * 1024;
export const TRACE_SHIPPER_CADENCE_MS = 2_000;
export const TRACE_UPLOAD_ROTATED_FILE_NAME = 'ritoras-trace.log.1';
export const TRACE_UPLOAD_LIVE_FILE_NAME = 'ritoras-trace.log';

const base64ByteCount = byteCount => 4 * Math.ceil(byteCount / 3);

function estimatedRequestBodyByteCount(fixedBodyByteCount, payloadByteCount) {
  return fixedBodyByteCount + base64ByteCount(payloadByteCount);
}

function validateState(state) {
  if (!state
      || !Number.isSafeInteger(state.epoch)
      || state.epoch < 0
      || !state.cursors
      || typeof state.cursors !== 'object'
      || Array.isArray(state.cursors)) {
    throw new TypeError('A trace ship state needs an epoch and cursor map');
  }
}

function validateSegment(segment) {
  if (!segment
      || typeof segment.name !== 'string'
      || typeof segment.identity !== 'string'
      || !Buffer.isBuffer(segment.bytes)) {
    throw new TypeError('A trace segment needs a name, identity, and Buffer');
  }
}

function orderedSegments(segments) {
  const priority = new Map([
    [TRACE_UPLOAD_ROTATED_FILE_NAME, 0],
    [TRACE_UPLOAD_LIVE_FILE_NAME, 1],
  ]);
  return [...segments].sort(
    (left, right) => (priority.get(left.name) ?? 2) - (priority.get(right.name) ?? 2)
  );
}

function requestFor(segment, offset, epoch, payload) {
  return {
    segmentName: segment.name,
    segmentIdentity: segment.identity,
    offset,
    epoch,
    payload: payload.toString('base64'),
  };
}

function encodeChunk(segment, offset, epoch, lines) {
  const payloadByteCount = lines.reduce((total, line) => total + line.length, 0);
  const payload = Buffer.concat(lines, payloadByteCount);
  const request = requestFor(segment, offset, epoch, payload);
  const body = Buffer.from(JSON.stringify(request));
  return {
    request,
    body,
    payload,
    nextOffset: offset + payload.length,
  };
}

function completeLines(bytes, offset) {
  const remaining = bytes.subarray(offset);
  const lines = [];
  let start = 0;
  for (let index = 0; index < remaining.length; index += 1) {
    if (remaining[index] !== 0x0a) continue;
    lines.push(remaining.subarray(start, index + 1));
    start = index + 1;
  }
  return lines;
}

export function createInitialTraceShipState(epoch = 0) {
  if (!Number.isSafeInteger(epoch) || epoch < 0) {
    throw new RangeError('A trace epoch must be a non-negative safe integer');
  }
  return { epoch, cursors: {} };
}

function validateTraceCaptureState(state) {
  if (!state
      || typeof state.enabledPreference !== 'boolean'
      || typeof state.recorderEnabled !== 'boolean'
      || typeof state.idleFlushTimerActive !== 'boolean'
      || typeof state.didLogFailure !== 'boolean') {
    throw new TypeError('A trace capture state needs preference, recorder, timer, and failure flags');
  }
}

export function toggleTraceCapture(state, { flushSucceeded = true } = {}) {
  validateTraceCaptureState(state);
  if (typeof flushSucceeded !== 'boolean') {
    throw new TypeError('The trace idle-flush result must be boolean');
  }

  const shouldEnable = !state.enabledPreference;
  const nextState = { ...state };
  const actions = [];
  let shouldLogFailure = false;

  if (!shouldEnable && state.recorderEnabled) {
    actions.push('flush-idle');
    if (!flushSucceeded) {
      nextState.recorderEnabled = false;
      nextState.idleFlushTimerActive = false;
      shouldLogFailure = !nextState.didLogFailure;
      nextState.didLogFailure = true;
      if (shouldLogFailure) actions.push('log-failure');
    }
  }

  nextState.enabledPreference = shouldEnable;
  actions.push('persist-preference');
  return { state: nextState, actions, shouldLogFailure };
}

/**
 * Removes cursors for segments evicted by rotation and rewinds invalid offsets
 * so a surviving segment is replayed rather than skipped.
 */
export function reconcileTraceShipState(state, segments) {
  validateState(state);
  for (const segment of segments) validateSegment(segment);

  const byIdentity = new Map(segments.map(segment => [segment.identity, segment]));
  const cursors = {};
  const evictedIdentities = [];
  const resetIdentities = [];

  for (const [identity, offset] of Object.entries(state.cursors)) {
    const segment = byIdentity.get(identity);
    if (!segment) {
      evictedIdentities.push(identity);
      continue;
    }
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > segment.bytes.length) {
      cursors[identity] = 0;
      resetIdentities.push(identity);
      continue;
    }
    if (offset > 0 && segment.bytes[offset - 1] !== 0x0a) {
      cursors[identity] = 0;
      resetIdentities.push(identity);
      continue;
    }
    cursors[identity] = offset;
  }

  return {
    state: { epoch: state.epoch, cursors },
    evictedIdentities,
    resetIdentities,
  };
}

/**
 * Selects one oldest-first, line-aligned upload whose actual JSON body fits the
 * configured budget. Incomplete trailing lines are left pending.
 */
export function nextTraceUploadChunk(
  state,
  segments,
  maximumBodyBytes = TRACE_UPLOAD_MAX_BODY_BYTES,
  options = {}
) {
  validateState(state);
  if (!Number.isSafeInteger(maximumBodyBytes) || maximumBodyBytes < 1) {
    throw new RangeError('The trace request body limit must be a positive integer');
  }
  // Tests can inject estimator drift while actual JSON bytes remain authoritative.
  const { estimateBodyBytes = estimatedRequestBodyByteCount } = options;
  if (typeof estimateBodyBytes !== 'function') {
    throw new TypeError('The trace body-size estimator must be a function');
  }
  for (const segment of segments) validateSegment(segment);

  const reconciled = reconcileTraceShipState(state, segments);
  for (const segment of orderedSegments(segments)) {
    const offset = reconciled.state.cursors[segment.identity] ?? 0;
    if (offset >= segment.bytes.length) continue;

    const emptyRequest = requestFor(segment, offset, state.epoch, Buffer.alloc(0));
    const fixedBodyBytes = Buffer.byteLength(JSON.stringify(emptyRequest)) - 2;
    const payloadLines = [];
    let candidatePayloadByteCount = 0;

    for (const line of completeLines(segment.bytes, offset)) {
      const nextByteCount = candidatePayloadByteCount + line.length;
      if (estimateBodyBytes(fixedBodyBytes, nextByteCount) > maximumBodyBytes) {
        if (payloadLines.length === 0) {
          payloadLines.push(line);
          candidatePayloadByteCount = nextByteCount;
        }
        break;
      }
      payloadLines.push(line);
      candidatePayloadByteCount = nextByteCount;
    }

    if (payloadLines.length === 0) {
      continue;
    }

    let chunk = encodeChunk(segment, offset, state.epoch, payloadLines);
    let shouldDropOneTrailingLine = true;
    while (chunk.body.length > maximumBodyBytes) {
      if (payloadLines.length === 1) return { ...reconciled, chunk: null };

      const retainedLineCount = shouldDropOneTrailingLine
        ? payloadLines.length - 1
        : Math.max(1, Math.floor(payloadLines.length / 2));
      payloadLines.length = retainedLineCount;
      chunk = encodeChunk(segment, offset, state.epoch, payloadLines);
      shouldDropOneTrailingLine = false;
    }
    return { ...reconciled, chunk };
  }
  return { ...reconciled, chunk: null };
}

/**
 * Advances only an acknowledged cursor. A changed epoch requests a local wipe;
 * the old epoch remains active until that wipe succeeds.
 */
export function applyTraceUploadResponse(
  state,
  chunk,
  response,
  { didWipeLocalData = false } = {}
) {
  validateState(state);
  if (!chunk
      || !chunk.request
      || typeof response?.acknowledged !== 'boolean'
      || !Number.isSafeInteger(response.epoch)
      || response.epoch < 0) {
    throw new TypeError('A trace upload response needs an acknowledgment and epoch');
  }
  if (typeof didWipeLocalData !== 'boolean') {
    throw new TypeError('The local trace wipe result must be boolean');
  }

  if (response.epoch !== state.epoch) {
    return {
      state: didWipeLocalData ? createInitialTraceShipState(response.epoch) : state,
      shouldWipeLocalData: true,
      advanced: false,
    };
  }
  if (!response.acknowledged) {
    return { state, shouldWipeLocalData: false, advanced: false };
  }

  const identity = chunk.request.segmentIdentity;
  const currentOffset = state.cursors[identity] ?? 0;
  if (currentOffset !== chunk.request.offset) {
    return { state, shouldWipeLocalData: false, advanced: false };
  }

  return {
    state: {
      epoch: state.epoch,
      cursors: { ...state.cursors, [identity]: chunk.nextOffset },
    },
    shouldWipeLocalData: false,
    advanced: true,
  };
}

export function keepTraceShipStateAfterFailure(state) {
  validateState(state);
  return state;
}
