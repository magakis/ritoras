// Pure-logic mirror of shared/KeystrokeTraceCore.swift.

import fs from 'node:fs';
import path from 'node:path';

export const TRACE_SCHEMA_VERSION = 1;
export const TRACE_CONTEXT_WINDOW_CHARACTERS = 128;
export const TRACE_DECISION_TEXT_CHARACTERS = 64;
export const TRACE_DECISION_PATHS = Object.freeze(['inline', 'retro']);
export const TRACE_RING_CAPACITY_BYTES = 256 * 1024;
export const TRACE_SEGMENT_CAPACITY_BYTES = 2 * 1024 * 1024;
export const TRACE_TOTAL_DISK_CAPACITY_BYTES = 4 * 1024 * 1024;
export const TRACE_LIVE_FILE_NAME = 'ritoras-trace.log';
export const TRACE_ROTATED_FILE_NAME = 'ritoras-trace.log.1';

// Keep these ordered values stable and aligned with KeystrokeTraceReasonCode in Swift.
export const TRACE_REASON_CODES = Object.freeze([
  'autocorrect-setting-disabled',
  'autocorrect-traits-blocked',
  'autocorrect-origin-not-typing',
  'autocorrect-extraction-failed',
  'autocorrect-current-word-lookup-word-mismatch',
  'autocorrect-empty-input',
  'autocorrect-engine-not-ready',
  'autocorrect-spellcheck-pass',
  'autocorrect-learned-word',
  'autocorrect-first-letter-mismatch',
  'autocorrect-pool-empty-after-filters',
  'autocorrect-language-model-floor',
  'autocorrect-contraction-margin',
  'autocorrect-score-below-threshold',
  'autocorrect-same-word',
  'autocorrect-length-out-of-bounds',
  'deferred-apply-epoch-changed',
  'deferred-apply-context-token-changed',
  'deferred-apply-document-identity-changed',
  'deferred-apply-keyboard-not-live',
  'deferred-apply-host-target-gone',
  'deferred-apply-live-context-mismatch',
  'autocorrect-apply-target-mismatch',
  'autocorrect-applied',
  'autocorrect-retro-queued',
  'host-text-did-change-epoch-bump',
  'host-selection-change-epoch-bump',
  'host-ring-cleared',
]);

const TRACE_EVENT_TYPES = new Set(['key', 'suggestion', 'decision', 'state', 'meta']);
const TRACE_FLUSH_BOUNDARIES = new Set(['highWaterMark', 'idle', 'triggerKey']);
const TRACE_REASON_CODE_SET = new Set(TRACE_REASON_CODES);
const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function boundedPrefix(value, maximumCharacters) {
  const selected = [];
  for (const { segment } of graphemeSegmenter.segment(value)) {
    selected.push(segment);
    if (selected.length === maximumCharacters) break;
  }
  return selected.join('');
}

function boundedSuffix(value, maximumCharacters) {
  const selected = [];
  for (const { segment } of graphemeSegmenter.segment(value)) {
    if (selected.length === maximumCharacters) selected.shift();
    selected.push(segment);
  }
  return selected.join('');
}

function omitUndefinedFields(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([, fieldValue]) => fieldValue !== undefined)
  );
}

function roundTraceNumber(value) {
  const roundedMagnitude = Math.round(Math.abs(value) * 1_000);
  return Math.sign(value) * roundedMagnitude / 1_000;
}

function stableStringify(value) {
  if (value === null || typeof value !== 'object') {
    if (typeof value === 'number' && !Number.isFinite(value)) {
      throw new TypeError('Trace JSON numbers must be finite');
    }
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item) ?? 'null').join(',')}]`;
  }

  const fields = Object.keys(value)
    .filter((key) => value[key] !== undefined)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
  return `{${fields.join(',')}}`;
}

function validateEvent(event) {
  if (!event
      || !TRACE_EVENT_TYPES.has(event.type)
      || !event.payload
      || typeof event.payload !== 'object') {
    throw new TypeError('A trace event must have a supported type and payload');
  }
}

/** `caretPosition` is the UTF-16 length of the full before-context before clipping. */
export function makeKeyEvent({
  action,
  keyValue,
  epoch,
  caretPosition,
  contextBefore,
  contextAfter,
  deleteCount,
  liveContextSuffix,
}) {
  const redacted = action === 'redacted';
  return {
    type: 'key',
    payload: omitUndefinedFields({
      action,
      keyValue: redacted ? undefined : keyValue,
      epoch,
      caretPosition: redacted ? undefined : caretPosition,
      contextBefore: redacted || contextBefore === undefined
        ? undefined
        : boundedSuffix(contextBefore, TRACE_CONTEXT_WINDOW_CHARACTERS),
      contextAfter: redacted || contextAfter === undefined
        ? undefined
        : boundedPrefix(contextAfter, TRACE_CONTEXT_WINDOW_CHARACTERS),
      deleteCount: redacted ? undefined : deleteCount,
      liveContextSuffix: redacted || liveContextSuffix === undefined
        ? undefined
        : boundedSuffix(liveContextSuffix, TRACE_CONTEXT_WINDOW_CHARACTERS),
    }),
  };
}

export function makeSuggestionEvent({
  currentWord,
  lookupWord,
  previousWord,
  previousWord2,
  candidates,
  displayedCandidates,
  epoch,
  contextToken,
  documentContextLength,
  documentContextSuffix,
}) {
  return {
    type: 'suggestion',
    payload: omitUndefinedFields({
      currentWord,
      lookupWord,
      previousWord,
      previousWord2,
      candidates,
      displayedCandidates,
      epoch,
      contextToken,
      documentContextLength,
      documentContextSuffix: boundedSuffix(
        documentContextSuffix,
        TRACE_CONTEXT_WINDOW_CHARACTERS
      ),
    }),
  };
}

export function makeDecisionEvent(decision) {
  if (!decision || !['apply', 'queued', 'skip'].includes(decision.outcome)) {
    throw new TypeError('A trace decision outcome must be apply, queued, or skip');
  }
  if (!TRACE_REASON_CODE_SET.has(decision.reasonCode)) {
    throw new TypeError(`Unknown trace reason code: ${decision.reasonCode}`);
  }
  if (decision.outcome !== 'queued'
      && decision.path != null
      && !TRACE_DECISION_PATHS.includes(decision.path)) {
    throw new TypeError('A trace decision path must be inline or retro');
  }
  for (const field of ['candidate', 'checkedWord', 'expectedWindow', 'foundWindow']) {
    if (decision[field] !== undefined && decision[field] !== null
        && typeof decision[field] !== 'string') {
      throw new TypeError(`A trace decision ${field} must be a string`);
    }
  }
  for (const field of [
    'fusedScore',
    'rawLMLogProb',
    'typedLiteralRawLMLogProb',
    'typedLiteralLogProbMargin',
    'absoluteLogProbFloor',
  ]) {
    if (decision[field] !== undefined && decision[field] !== null
        && (typeof decision[field] !== 'number' || !Number.isFinite(decision[field]))) {
      throw new TypeError(`A trace decision ${field} must be a finite number`);
    }
  }
  if (decision.outcome === 'apply') {
    for (const field of ['beforeText', 'afterText']) {
      if (typeof decision[field] !== 'string') {
        throw new TypeError(`An applied decision requires ${field}`);
      }
    }
    for (const field of ['deleteCount', 'insertCount']) {
      if (!Number.isInteger(decision[field])) {
        throw new TypeError(`An applied decision requires integer ${field}`);
      }
    }
    return {
      type: 'decision',
      payload: omitUndefinedFields({
        outcome: 'apply',
        reasonCode: decision.reasonCode,
        path: decision.path ?? undefined,
        rawLMLogProb: decision.rawLMLogProb == null
          ? undefined
          : roundTraceNumber(decision.rawLMLogProb),
        typedLiteralRawLMLogProb: decision.typedLiteralRawLMLogProb == null
          ? undefined
          : roundTraceNumber(decision.typedLiteralRawLMLogProb),
        beforeText: decision.beforeText,
        afterText: decision.afterText,
        deleteCount: decision.deleteCount,
        insertCount: decision.insertCount,
      }),
    };
  }
  if (decision.outcome === 'queued') {
    if (decision.reasonCode !== 'autocorrect-retro-queued') {
      throw new TypeError('A queued decision requires autocorrect-retro-queued');
    }
    for (const field of ['candidate', 'checkedWord']) {
      if (typeof decision[field] !== 'string') {
        throw new TypeError(`A queued decision requires ${field}`);
      }
    }
    return {
      type: 'decision',
      payload: {
        outcome: 'queued',
        reasonCode: decision.reasonCode,
        candidate: boundedPrefix(decision.candidate, TRACE_DECISION_TEXT_CHARACTERS),
        checkedWord: boundedPrefix(decision.checkedWord, TRACE_DECISION_TEXT_CHARACTERS),
      },
    };
  }
  return {
    type: 'decision',
    payload: omitUndefinedFields({
      outcome: 'skip',
      reasonCode: decision.reasonCode,
      path: decision.path ?? undefined,
      candidate: decision.candidate == null
        ? undefined
        : boundedPrefix(decision.candidate, TRACE_DECISION_TEXT_CHARACTERS),
      fusedScore: decision.fusedScore == null
        ? undefined
        : roundTraceNumber(decision.fusedScore),
      rawLMLogProb: decision.rawLMLogProb == null
        ? undefined
        : roundTraceNumber(decision.rawLMLogProb),
      typedLiteralRawLMLogProb: decision.typedLiteralRawLMLogProb == null
        ? undefined
        : roundTraceNumber(decision.typedLiteralRawLMLogProb),
      typedLiteralLogProbMargin: decision.typedLiteralLogProbMargin == null
        ? undefined
        : roundTraceNumber(decision.typedLiteralLogProbMargin),
      absoluteLogProbFloor: decision.absoluteLogProbFloor == null
        ? undefined
        : roundTraceNumber(decision.absoluteLogProbFloor),
      checkedWord: decision.checkedWord == null
        ? undefined
        : boundedPrefix(decision.checkedWord, TRACE_DECISION_TEXT_CHARACTERS),
      expectedWindow: decision.expectedWindow == null
        ? undefined
        : boundedPrefix(decision.expectedWindow, TRACE_DECISION_TEXT_CHARACTERS),
      foundWindow: decision.foundWindow == null
        ? undefined
        : boundedPrefix(decision.foundWindow, TRACE_DECISION_TEXT_CHARACTERS),
    }),
  };
}

export function makeStateEvent({
  action,
  epoch,
  reasonCode,
  model,
  detail,
}) {
  return {
    type: 'state',
    payload: omitUndefinedFields({ action, epoch, reasonCode, model, detail }),
  };
}

export function makeMetaEvent({ action, sessionID, attributes }) {
  return {
    type: 'meta',
    payload: omitUndefinedFields({ action, sessionID, attributes }),
  };
}

export function encodeTraceRecord(event, timestamp = new Date().toISOString()) {
  validateEvent(event);
  const record = {
    schemaVersion: TRACE_SCHEMA_VERSION,
    timestamp,
    event,
  };
  return Buffer.from(`${stableStringify(record)}\n`, 'utf8');
}

/** Fixed-capacity byte ring that evicts oldest complete lines as needed. */
export class TraceByteRing {
  constructor(capacityBytes = TRACE_RING_CAPACITY_BYTES) {
    if (!Number.isInteger(capacityBytes)
        || capacityBytes < 1
        || capacityBytes > TRACE_RING_CAPACITY_BYTES) {
      throw new RangeError(`Invalid trace ring capacity: ${capacityBytes}`);
    }
    this.capacityBytes = capacityBytes;
    this.storage = Buffer.alloc(capacityBytes);
    this.readIndex = 0;
    this.writeIndex = 0;
    this.byteCount = 0;
  }

  get shouldFlushAtHighWaterMark() {
    return this.byteCount >= Math.floor(this.capacityBytes * 3 / 4);
  }

  appendLine(line) {
    const bytes = Buffer.isBuffer(line) ? line : Buffer.from(line, 'utf8');
    if (bytes.length === 0 || bytes.at(-1) !== 0x0a) {
      throw new TypeError('Trace ring lines must end with LF');
    }
    if (bytes.length > this.capacityBytes) {
      return { accepted: false, evictedByteCount: 0 };
    }

    let evictedByteCount = 0;
    while (this.capacityBytes - this.byteCount < bytes.length) {
      const discarded = this.discardFirstLine();
      if (discarded === 0) {
        throw new Error('Trace ring lost its complete-line invariant');
      }
      evictedByteCount += discarded;
    }

    const firstCount = Math.min(bytes.length, this.capacityBytes - this.writeIndex);
    bytes.copy(this.storage, this.writeIndex, 0, firstCount);
    if (firstCount < bytes.length) {
      bytes.copy(this.storage, 0, firstCount);
    }
    this.writeIndex = (this.writeIndex + bytes.length) % this.capacityBytes;
    this.byteCount += bytes.length;
    return { accepted: true, evictedByteCount };
  }

  firstLine() {
    const lineLength = this.firstLineLength();
    if (lineLength === 0) return null;
    const line = Buffer.allocUnsafe(lineLength);
    for (let offset = 0; offset < lineLength; offset += 1) {
      line[offset] = this.byteAt(offset);
    }
    return line;
  }

  discardFirstLine() {
    const lineLength = this.firstLineLength();
    if (lineLength === 0) return 0;
    for (let offset = 0; offset < lineLength; offset += 1) {
      this.storage[(this.readIndex + offset) % this.capacityBytes] = 0;
    }
    this.readIndex = (this.readIndex + lineLength) % this.capacityBytes;
    this.byteCount -= lineLength;
    return lineLength;
  }

  clear() {
    this.storage.fill(0);
    this.readIndex = 0;
    this.writeIndex = 0;
    this.byteCount = 0;
  }

  firstLineLength() {
    for (let offset = 0; offset < this.byteCount; offset += 1) {
      if (this.byteAt(offset) === 0x0a) return offset + 1;
    }
    return 0;
  }

  byteAt(offset) {
    return this.storage[(this.readIndex + offset) % this.capacityBytes];
  }
}

class TraceSegmentStore {
  constructor(directoryPath) {
    this.directoryPath = path.resolve(directoryPath);
    fs.mkdirSync(this.directoryPath, { recursive: true });
    this.liveFilePath = path.join(this.directoryPath, TRACE_LIVE_FILE_NAME);
    this.rotatedFilePath = path.join(this.directoryPath, TRACE_ROTATED_FILE_NAME);
    this.liveByteCount = this.existingSegmentByteCount(this.liveFilePath);
    this.liveEndsWithLineFeed = this.segmentEndsWithLineFeed(
      this.liveFilePath,
      this.liveByteCount
    );
    this.rotatedByteCount = this.existingSegmentByteCount(this.rotatedFilePath);
    this.onSegmentRoll = undefined;
  }

  get totalByteCount() {
    return this.liveByteCount + this.rotatedByteCount;
  }

  append(line) {
    if (line.length > TRACE_SEGMENT_CAPACITY_BYTES || line.at(-1) !== 0x0a) {
      throw new RangeError(`Invalid trace segment line size: ${line.length}`);
    }
    this.reconcileMissingSegments();
    let segmentRoll = null;
    if (!this.liveEndsWithLineFeed && fs.existsSync(this.liveFilePath)) {
      segmentRoll = this.rotate();
    }
    if (this.liveByteCount + line.length > TRACE_SEGMENT_CAPACITY_BYTES) {
      segmentRoll = this.rotate() ?? segmentRoll;
    }
    if (!fs.existsSync(this.liveFilePath)) {
      this.liveByteCount = 0;
      this.liveEndsWithLineFeed = true;
    }
    this.liveEndsWithLineFeed = false;
    fs.writeFileSync(this.liveFilePath, line, { flag: 'a' });
    this.liveByteCount += line.length;
    this.liveEndsWithLineFeed = true;
    return segmentRoll;
  }

  removeAll() {
    if (fs.existsSync(this.liveFilePath)) fs.unlinkSync(this.liveFilePath);
    this.liveByteCount = 0;
    this.liveEndsWithLineFeed = true;
    if (fs.existsSync(this.rotatedFilePath)) fs.unlinkSync(this.rotatedFilePath);
    this.rotatedByteCount = 0;
  }

  existingSegmentByteCount(filePath) {
    if (!fs.existsSync(filePath)) return 0;
    const byteCount = fs.statSync(filePath).size;
    if (byteCount > TRACE_SEGMENT_CAPACITY_BYTES) {
      fs.unlinkSync(filePath);
      return 0;
    }
    return byteCount;
  }

  segmentEndsWithLineFeed(filePath, byteCount) {
    if (byteCount === 0) return true;
    const descriptor = fs.openSync(filePath, 'r');
    const lastByte = Buffer.allocUnsafe(1);
    try {
      const bytesRead = fs.readSync(descriptor, lastByte, 0, 1, byteCount - 1);
      return bytesRead === 1 && lastByte[0] === 0x0a;
    } finally {
      fs.closeSync(descriptor);
    }
  }

  rotate() {
    this.reconcileMissingSegments();
    if (!fs.existsSync(this.liveFilePath)) return null;

    const discardedBytes = this.rotatedByteCount;
    if (fs.existsSync(this.rotatedFilePath)) fs.unlinkSync(this.rotatedFilePath);
    this.rotatedByteCount = 0;

    if (this.liveByteCount > 0) {
      try {
        fs.renameSync(this.liveFilePath, this.rotatedFilePath);
      } catch (error) {
        if (fs.existsSync(this.liveFilePath)) throw error;
        this.liveByteCount = 0;
        this.liveEndsWithLineFeed = true;
        return null;
      }
      this.rotatedByteCount = this.liveByteCount;
      this.liveByteCount = 0;
    } else if (fs.existsSync(this.liveFilePath)) {
      fs.unlinkSync(this.liveFilePath);
    }
    this.liveEndsWithLineFeed = true;

    const segmentRoll = {
      archivedBytes: this.rotatedByteCount,
      discardedBytes,
      totalBytesAfterRoll: this.totalByteCount,
    };
    this.onSegmentRoll?.(segmentRoll);
    return segmentRoll;
  }

  reconcileMissingSegments() {
    if (!fs.existsSync(this.liveFilePath)) {
      this.liveByteCount = 0;
      this.liveEndsWithLineFeed = true;
    }
    if (!fs.existsSync(this.rotatedFilePath)) this.rotatedByteCount = 0;
  }
}

/** Bounded recorder mirror; all disk writes happen only at explicit flush boundaries. */
export class KeystrokeTraceRecorder {
  constructor(directoryPath, { ringCapacityBytes = TRACE_RING_CAPACITY_BYTES } = {}) {
    if (!Number.isInteger(ringCapacityBytes)
        || ringCapacityBytes < 1
        || ringCapacityBytes > TRACE_RING_CAPACITY_BYTES) {
      throw new RangeError(`Invalid trace ring capacity: ${ringCapacityBytes}`);
    }
    this.ringCapacityBytes = ringCapacityBytes;
    this.segmentStore = new TraceSegmentStore(directoryPath);
    this.ring = null;
  }

  get unflushedByteCount() {
    return this.ring?.byteCount ?? 0;
  }

  get shouldFlushAtHighWaterMark() {
    return this.ring?.shouldFlushAtHighWaterMark ?? false;
  }

  get liveFilePath() {
    return this.segmentStore.liveFilePath;
  }

  get rotatedFilePath() {
    return this.segmentStore.rotatedFilePath;
  }

  get onDiskByteCount() {
    return this.segmentStore.totalByteCount;
  }

  set onSegmentRoll(callback) {
    this.segmentStore.onSegmentRoll = callback;
  }

  append(event, timestamp) {
    if (this.ring === null) this.ring = new TraceByteRing(this.ringCapacityBytes);

    const line = encodeTraceRecord(event, timestamp ?? new Date().toISOString());
    if (line.length > this.ring.capacityBytes) {
      return {
        status: 'event-exceeds-ring-capacity',
        encodedByteCount: line.length,
        capacity: this.ring.capacityBytes,
      };
    }
    const appendResult = this.ring.appendLine(line);
    return {
      status: 'appended',
      encodedByteCount: line.length,
      evictedByteCount: appendResult.evictedByteCount,
      shouldFlushAtHighWaterMark: this.ring.shouldFlushAtHighWaterMark,
    };
  }

  flush(boundary) {
    if (!TRACE_FLUSH_BOUNDARIES.has(boundary)) {
      throw new TypeError(`Unknown trace flush boundary: ${boundary}`);
    }
    if (this.ring === null) {
      return {
        boundary,
        bytesWritten: 0,
        eventsWritten: 0,
        remainingByteCount: 0,
      };
    }

    let bytesWritten = 0;
    let eventsWritten = 0;
    let pendingSegmentRolls = [];
    while (true) {
      let line;
      while ((line = this.ring.firstLine()) !== null) {
        const segmentRoll = this.segmentStore.append(line);
        if (segmentRoll !== null) pendingSegmentRolls.push(segmentRoll);
        bytesWritten += this.ring.discardFirstLine();
        eventsWritten += 1;
      }

      if (pendingSegmentRolls.length === 0) break;
      const completedSegmentRolls = pendingSegmentRolls;
      pendingSegmentRolls = [];
      for (const segmentRoll of completedSegmentRolls) {
        const detail = `archivedBytes=${segmentRoll.archivedBytes};`
          + `discardedBytes=${segmentRoll.discardedBytes};`
          + `totalBytesAfterRoll=${segmentRoll.totalBytesAfterRoll}`;
        const line = encodeTraceRecord(makeStateEvent({
          action: 'segmentRolled',
          detail,
        }));
        const subsequentRoll = this.segmentStore.append(line);
        if (subsequentRoll !== null) pendingSegmentRolls.push(subsequentRoll);
        bytesWritten += line.length;
        eventsWritten += 1;
      }
    }
    return {
      boundary,
      bytesWritten,
      eventsWritten,
      remainingByteCount: this.ring.byteCount,
    };
  }

  appendLineAlignedData(data) {
    const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (bytes.length === 0 || bytes.at(-1) !== 0x0a) {
      throw new TypeError('Trace data must contain complete LF-terminated lines');
    }

    let lineStart = 0;
    for (let index = 0; index < bytes.length; index += 1) {
      if (bytes[index] !== 0x0a) continue;
      if (index === lineStart) {
        throw new TypeError('Trace data must not contain empty lines');
      }
      const lineLength = index + 1 - lineStart;
      if (lineLength > TRACE_SEGMENT_CAPACITY_BYTES) {
        throw new RangeError(`Invalid trace segment line size: ${lineLength}`);
      }
      lineStart = index + 1;
    }
    if (lineStart !== bytes.length) {
      throw new TypeError('Trace data must contain complete LF-terminated lines');
    }

    lineStart = 0;
    for (let index = 0; index < bytes.length; index += 1) {
      if (bytes[index] !== 0x0a) continue;
      const lineEnd = index + 1;
      this.segmentStore.append(bytes.subarray(lineStart, lineEnd));
      lineStart = lineEnd;
    }
  }

  clear() {
    this.ring?.clear();
    this.segmentStore.removeAll();
  }
}

/** Splits complete LF-terminated records and ignores a possibly torn trailing line. */
export function completeTraceLines(data) {
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const lines = [];
  let lineStart = 0;
  for (let offset = 0; offset < bytes.length; offset += 1) {
    if (bytes[offset] !== 0x0a) continue;
    if (offset > lineStart) lines.push(bytes.subarray(lineStart, offset));
    lineStart = offset + 1;
  }
  return lines;
}

export function readCompleteTraceLines(filePath) {
  return completeTraceLines(fs.readFileSync(filePath));
}
