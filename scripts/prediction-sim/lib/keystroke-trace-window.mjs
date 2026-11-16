import { TextDecoder } from 'node:util';
import {
  TRACE_LIVE_FILE_NAME,
  TRACE_ROTATED_FILE_NAME,
  TRACE_SCHEMA_VERSION,
  TRACE_SEGMENT_CAPACITY_BYTES,
  TRACE_TOTAL_DISK_CAPACITY_BYTES,
  completeTraceLines,
} from './keystroke-trace.mjs';

export const TRACE_EXPORT_WINDOW_MILLISECONDS = 5 * 60 * 1_000;

const VALID_EVENT_TYPES = new Set(['key', 'suggestion', 'decision', 'state', 'meta']);
const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

function validateSegment(segment, name) {
  if (!Buffer.isBuffer(segment)) {
    throw new TypeError(`${name} must be a Buffer`);
  }
  if (segment.length > TRACE_SEGMENT_CAPACITY_BYTES) {
    throw new RangeError(`${name} exceeds the trace segment byte budget`);
  }
  return segment;
}

function decodeTraceRecord(line) {
  let text;
  let record;
  try {
    text = utf8Decoder.decode(line);
    record = JSON.parse(text);
  } catch {
    return null;
  }

  if (record === null
      || typeof record !== 'object'
      || Array.isArray(record)
      || record.schemaVersion !== TRACE_SCHEMA_VERSION
      || typeof record.timestamp !== 'string'
      || record.event === null
      || typeof record.event !== 'object'
      || Array.isArray(record.event)
      || !VALID_EVENT_TYPES.has(record.event.type)
      || record.event.payload === null
      || typeof record.event.payload !== 'object'
      || Array.isArray(record.event.payload)) {
    return null;
  }

  const timestampMilliseconds = Date.parse(record.timestamp);
  if (!Number.isFinite(timestampMilliseconds)) return null;

  return {
    text,
    timestampMilliseconds,
  };
}

/**
 * Selects complete schema-v1 records from the rotated then live segment.
 * Returned lines retain their stored JSON bytes and have one LF terminator.
 */
export function selectKeystrokeTraceWindow({
  rotatedSegment = Buffer.alloc(0),
  liveSegment = Buffer.alloc(0),
  nowMilliseconds = Date.now(),
} = {}) {
  if (!Number.isSafeInteger(nowMilliseconds) || nowMilliseconds < 0) {
    throw new RangeError('The trace export time must be a non-negative safe integer');
  }

  validateSegment(rotatedSegment, TRACE_ROTATED_FILE_NAME);
  validateSegment(liveSegment, TRACE_LIVE_FILE_NAME);
  if (rotatedSegment.length + liveSegment.length > TRACE_TOTAL_DISK_CAPACITY_BYTES) {
    throw new RangeError('Trace segments exceed the combined byte budget');
  }

  const windowStart = nowMilliseconds - TRACE_EXPORT_WINDOW_MILLISECONDS;
  const selectedLines = [];
  let oldestRetainedTimestamp = null;

  for (const segment of [rotatedSegment, liveSegment]) {
    for (const line of completeTraceLines(segment)) {
      const record = decodeTraceRecord(line);
      if (!record || record.timestampMilliseconds > nowMilliseconds) continue;

      if (oldestRetainedTimestamp === null
          || record.timestampMilliseconds < oldestRetainedTimestamp) {
        oldestRetainedTimestamp = record.timestampMilliseconds;
      }
      if (record.timestampMilliseconds >= windowStart) {
        selectedLines.push(record.text);
      }
    }
  }

  const hasFullWindowCoverage = oldestRetainedTimestamp !== null
    && oldestRetainedTimestamp <= windowStart;
  const coverageDurationMilliseconds = oldestRetainedTimestamp === null
    ? 0
    : Math.min(
      TRACE_EXPORT_WINDOW_MILLISECONDS,
      Math.max(0, nowMilliseconds - oldestRetainedTimestamp)
    );

  return {
    contents: selectedLines.length > 0 ? `${selectedLines.join('\n')}\n` : '',
    recordCount: selectedLines.length,
    capturedAtMilliseconds: nowMilliseconds,
    oldestRetainedTimestamp,
    coverageDurationMilliseconds,
    hasFullWindowCoverage,
  };
}
