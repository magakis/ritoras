import assert from 'node:assert/strict';
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it } from 'node:test';
import {
  KeystrokeTraceRecorder,
  TRACE_CONTEXT_WINDOW_CHARACTERS,
  TRACE_DECISION_TEXT_CHARACTERS,
  TRACE_REASON_CODES,
  TRACE_RING_CAPACITY_BYTES,
  TRACE_SCHEMA_VERSION,
  TRACE_SEGMENT_CAPACITY_BYTES,
  TRACE_TOTAL_DISK_CAPACITY_BYTES,
  TraceByteRing,
  completeTraceLines,
  encodeTraceRecord,
  makeDecisionEvent,
  makeKeyEvent,
  makeMetaEvent,
  makeStateEvent,
  makeSuggestionEvent,
  readCompleteTraceLines,
} from '../lib/keystroke-trace.mjs';

function temporaryTraceDirectory(testContext) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'ritoras-trace-'));
  testContext.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

describe('keystroke trace core mirror', () => {
  it('evicts oldest complete lines without exceeding the fixed ring capacity', () => {
    assert.throws(
      () => new TraceByteRing(TRACE_RING_CAPACITY_BYTES + 1),
      RangeError
    );
    const ring = new TraceByteRing(16);
    const first = Buffer.from('{"n":1}\n');
    const second = Buffer.from('{"n":2}\n');
    const third = Buffer.from('{"n":3}\n');

    assert.deepStrictEqual(ring.appendLine(first), {
      accepted: true,
      evictedByteCount: 0,
    });
    ring.appendLine(second);
    const appendResult = ring.appendLine(third);

    assert.strictEqual(appendResult.evictedByteCount, first.length);
    assert.strictEqual(ring.byteCount, 16);
    assert.ok(ring.byteCount <= ring.capacityBytes);
    assert.deepStrictEqual(ring.firstLine(), second);
    ring.discardFirstLine();
    assert.deepStrictEqual(ring.firstLine(), third);
  });

  it('keeps the Swift reason-code vocabulary distinct and stable', () => {
    const expected = [
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
      'autocorrect-applied',
      'host-text-did-change-epoch-bump',
      'host-selection-change-epoch-bump',
      'host-ring-cleared',
    ];

    assert.deepStrictEqual(TRACE_REASON_CODES, expected);
    assert.strictEqual(new Set(TRACE_REASON_CODES).size, expected.length);
  });

  it('bounds caret context to 128 grapheme characters per side', () => {
    const combinedCharacter = 'e\u0301';
    const keyEvent = makeKeyEvent({
      action: 'insert',
      epoch: 3,
      contextBefore: `${'a'.repeat(TRACE_CONTEXT_WINDOW_CHARACTERS)}z`,
      contextAfter: `z${'b'.repeat(TRACE_CONTEXT_WINDOW_CHARACTERS)}`,
      liveContextSuffix: combinedCharacter.repeat(TRACE_CONTEXT_WINDOW_CHARACTERS + 1),
    });

    assert.strictEqual(
      Array.from(keyEvent.payload.contextBefore).length,
      TRACE_CONTEXT_WINDOW_CHARACTERS
    );
    assert.strictEqual(
      Array.from(keyEvent.payload.contextAfter).length,
      TRACE_CONTEXT_WINDOW_CHARACTERS
    );
    assert.strictEqual(
      keyEvent.payload.liveContextSuffix,
      combinedCharacter.repeat(TRACE_CONTEXT_WINDOW_CHARACTERS)
    );
  });

  it('records caret positions as UTF-16 offsets before context clipping', () => {
    const contextBefore = '😀'.repeat(130);
    const event = makeKeyEvent({
      action: 'insert',
      epoch: 3,
      caretPosition: contextBefore.length,
      contextBefore,
    });

    assert.strictEqual(event.payload.caretPosition, 260);
    assert.strictEqual(
      Array.from(event.payload.contextBefore).length,
      TRACE_CONTEXT_WINDOW_CHARACTERS
    );
  });

  it('keeps redacted key markers free of key and context content', () => {
    const event = makeKeyEvent({
      action: 'redacted',
      keyValue: 'secret',
      epoch: 3,
      caretPosition: 6,
      contextBefore: 'private text',
      contextAfter: 'more private text',
      deleteCount: 6,
      liveContextSuffix: 'private suffix',
    });

    assert.deepStrictEqual(event, {
      type: 'key',
      payload: {
        action: 'redacted',
        epoch: 3,
      },
    });
  });

  it('round-trips key, suggestion, apply, skip, state, and meta event payloads', () => {
    const events = [
      makeKeyEvent({
        action: 'suggestionTap',
        keyValue: 'their',
        epoch: 9,
        caretPosition: 21,
        contextBefore: 'I saw thier',
        contextAfter: ' yesterday',
        deleteCount: 5,
        liveContextSuffix: 'their yesterday',
      }),
      makeSuggestionEvent({
        currentWord: 'thier',
        lookupWord: 'thier',
        previousWord: 'saw',
        previousWord2: 'I',
        candidates: [
          { candidate: 'their', scoreComponents: { apple: 2.5, kenlm: -0.75 } },
          { candidate: 'there', scoreComponents: { apple: 1.5, kenlm: -1.25 } },
        ],
        displayedCandidates: ['their'],
        epoch: 9,
        contextToken: 'token-9',
        documentContextLength: 21,
        documentContextSuffix: 'I saw thier yesterday',
      }),
      makeDecisionEvent({
        outcome: 'apply',
        reasonCode: 'autocorrect-applied',
        beforeText: 'I saw thier yesterday',
        afterText: 'I saw their yesterday',
        deleteCount: 5,
        insertCount: 5,
      }),
      makeDecisionEvent({
        outcome: 'skip',
        reasonCode: 'autocorrect-language-model-floor',
        candidate: 'with',
        fusedScore: 1.0004,
        rawLMLogProb: -8.0006,
        typedLiteralRawLMLogProb: -10.0004,
        typedLiteralLogProbMargin: 2.0004,
        absoluteLogProbFloor: -8.0004,
        checkedWord: 'wiyh',
      }),
      makeStateEvent({
        action: 'epochBump',
        epoch: 10,
        reasonCode: 'host-text-did-change-epoch-bump',
      }),
      makeStateEvent({
        action: 'modelUnloaded',
        model: 'symspell',
        detail: 'memory pressure',
      }),
      makeMetaEvent({
        action: 'schemaVersion',
        attributes: { version: String(TRACE_SCHEMA_VERSION) },
      }),
      makeMetaEvent({
        action: 'sessionStarted',
        sessionID: 'session-1',
        attributes: { source: 'keyboard' },
      }),
    ];

    for (const event of events) {
      const encoded = encodeTraceRecord(event, '2026-11-14T12:00:00.000Z');
      const decoded = JSON.parse(encoded.toString('utf8'));
      assert.strictEqual(decoded.schemaVersion, TRACE_SCHEMA_VERSION);
      assert.deepStrictEqual(decoded.event, event);
    }
  });

  it('bounds skip words and rounds numeric operands before recording them', () => {
    const candidate = 'x'.repeat(TRACE_DECISION_TEXT_CHARACTERS + 1);
    const checkedWord = 'y'.repeat(TRACE_DECISION_TEXT_CHARACTERS + 1);
    const event = makeDecisionEvent({
      outcome: 'skip',
      reasonCode: 'autocorrect-score-below-threshold',
      candidate,
      fusedScore: 0.65456,
      rawLMLogProb: -8.12356,
      typedLiteralRawLMLogProb: -10.98765,
      typedLiteralLogProbMargin: 2.00056,
      absoluteLogProbFloor: -8.00056,
      checkedWord,
    });

    assert.strictEqual(event.payload.candidate.length, TRACE_DECISION_TEXT_CHARACTERS);
    assert.strictEqual(event.payload.checkedWord.length, TRACE_DECISION_TEXT_CHARACTERS);
    assert.strictEqual(event.payload.fusedScore, 0.655);
    assert.strictEqual(event.payload.rawLMLogProb, -8.124);
    assert.strictEqual(event.payload.typedLiteralRawLMLogProb, -10.988);
    assert.strictEqual(event.payload.typedLiteralLogProbMargin, 2.001);
    assert.strictEqual(event.payload.absoluteLogProbFloor, -8.001);
  });

  it('captures immediately without an enable gate and flushes encoded UTF-8 bytes', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const recorder = new KeystrokeTraceRecorder(directory, { ringCapacityBytes: 512 });
    const event = makeKeyEvent({
      action: 'insert',
      keyValue: 'é',
      epoch: 1,
      contextBefore: 'café',
    });
    const timestamp = '2026-11-14T12:00:00.000Z';
    const expectedLine = encodeTraceRecord(event, timestamp);

    const appendResult = recorder.append(event, timestamp);

    assert.strictEqual(appendResult.status, 'appended');
    assert.strictEqual(appendResult.encodedByteCount, expectedLine.length);
    assert.strictEqual(recorder.unflushedByteCount, expectedLine.length);
    const flushResult = recorder.flush('triggerKey');
    assert.strictEqual(flushResult.bytesWritten, expectedLine.length);
    assert.strictEqual(flushResult.eventsWritten, 1);
    assert.strictEqual(recorder.unflushedByteCount, 0);
    assert.strictEqual(statSync(recorder.liveFilePath).size, expectedLine.length);
    assert.strictEqual(recorder.onDiskByteCount, expectedLine.length);
  });

  it('clears buffered keys after Delete All without recreating either segment', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const livePath = path.join(directory, 'ritoras-trace.log');
    const rotatedPath = path.join(directory, 'ritoras-trace.log.1');
    const fullLiveSegment = Buffer.alloc(TRACE_SEGMENT_CAPACITY_BYTES, 0x78);
    fullLiveSegment[fullLiveSegment.length - 1] = 0x0a;
    writeFileSync(livePath, fullLiveSegment);
    writeFileSync(rotatedPath, '{"old":true}\n');
    const recorder = new KeystrokeTraceRecorder(directory);
    const typedEvent = makeKeyEvent({
      action: 'insert',
      keyValue: 'x',
      epoch: 1,
      contextBefore: 'typed before deletion',
    });
    recorder.append(typedEvent, '2026-11-14T12:00:00.000Z');

    // The app removes both shared files while the keyboard is warm.
    unlinkSync(livePath);
    unlinkSync(rotatedPath);
    assert.doesNotThrow(() => recorder.clear());

    assert.strictEqual(recorder.unflushedByteCount, 0);
    assert.strictEqual(existsSync(livePath), false);
    assert.strictEqual(existsSync(rotatedPath), false);
    assert.deepStrictEqual(readdirSync(directory), []);
  });

  it('treats a deleted live segment as empty before the next capture flush', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const livePath = path.join(directory, 'ritoras-trace.log');
    const fullLiveSegment = Buffer.alloc(TRACE_SEGMENT_CAPACITY_BYTES, 0x78);
    fullLiveSegment[fullLiveSegment.length - 1] = 0x0a;
    writeFileSync(livePath, fullLiveSegment);
    const recorder = new KeystrokeTraceRecorder(directory);
    const newEvent = makeKeyEvent({
      action: 'insert',
      keyValue: 'new',
      epoch: 1,
      contextBefore: '',
    });
    recorder.append(newEvent, '2026-11-14T12:00:00.000Z');

    unlinkSync(livePath);
    assert.doesNotThrow(() => recorder.flush('idle'));

    const records = readCompleteTraceLines(livePath)
      .map((line) => JSON.parse(line.toString('utf8')));
    assert.strictEqual(records.length, 1);
    assert.strictEqual(records[0].event.payload.keyValue, 'new');
    assert.strictEqual(recorder.onDiskByteCount, statSync(livePath).size);
  });

  it('appends raw line-aligned data without re-encoding and rotates bounded segments', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const recorder = new KeystrokeTraceRecorder(directory);
    const payload = Buffer.alloc(Math.floor(TRACE_SEGMENT_CAPACITY_BYTES / 2), 0x78);
    const firstLine = Buffer.concat([
      Buffer.from('{ "raw" : "'),
      payload,
      Buffer.from('" }\n'),
    ]);
    const secondLine = Buffer.concat([
      Buffer.from('{"raw":"'),
      payload,
      Buffer.from('"}\n'),
    ]);

    assert.throws(
      () => recorder.appendLineAlignedData(Buffer.from('{"invalid":true}\n\n')),
      TypeError
    );
    assert.throws(
      () => recorder.appendLineAlignedData(Buffer.from('{"incomplete":true}')),
      TypeError
    );
    const oversizedLine = Buffer.alloc(TRACE_SEGMENT_CAPACITY_BYTES + 1, 0x78);
    oversizedLine[oversizedLine.length - 1] = 0x0a;
    assert.throws(
      () => recorder.appendLineAlignedData(oversizedLine),
      RangeError
    );
    assert.strictEqual(recorder.onDiskByteCount, 0);

    recorder.appendLineAlignedData(Buffer.concat([firstLine, secondLine]));

    assert.deepStrictEqual(readFileSync(recorder.rotatedFilePath), firstLine);
    assert.deepStrictEqual(readFileSync(recorder.liveFilePath), secondLine);
    const liveBytes = statSync(recorder.liveFilePath).size;
    const rotatedBytes = statSync(recorder.rotatedFilePath).size;
    assert.ok(liveBytes <= TRACE_SEGMENT_CAPACITY_BYTES);
    assert.ok(rotatedBytes <= TRACE_SEGMENT_CAPACITY_BYTES);
    assert.strictEqual(recorder.onDiskByteCount, liveBytes + rotatedBytes);
    assert.ok(recorder.onDiskByteCount <= TRACE_TOTAL_DISK_CAPACITY_BYTES);
  });

  it('rotates bounded disk segments and never exceeds the 4 MB total ceiling', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const recorder = new KeystrokeTraceRecorder(directory);
    const largeValue = 'x'.repeat(180_000);
    let rollCount = 0;
    recorder.onSegmentRoll = () => {
      rollCount += 1;
    };

    for (let index = 0; index < 30; index += 1) {
      const event = makeMetaEvent({
        action: 'sessionStarted',
        sessionID: `session-${index}`,
        attributes: { payload: largeValue },
      });
      const appendResult = recorder.append(event, '2026-11-14T12:00:00.000Z');
      assert.strictEqual(appendResult.status, 'appended');
      recorder.flush('idle');

      const liveBytes = statSync(recorder.liveFilePath).size;
      const rotatedBytes = existsSync(recorder.rotatedFilePath)
        ? statSync(recorder.rotatedFilePath).size
        : 0;
      assert.ok(liveBytes <= TRACE_SEGMENT_CAPACITY_BYTES);
      assert.ok(rotatedBytes <= TRACE_SEGMENT_CAPACITY_BYTES);
      assert.strictEqual(recorder.onDiskByteCount, liveBytes + rotatedBytes);
      assert.ok(recorder.onDiskByteCount <= TRACE_TOTAL_DISK_CAPACITY_BYTES);
    }

    assert.ok(rollCount > 0);
    const segmentRollRecords = [recorder.liveFilePath, recorder.rotatedFilePath]
      .filter(existsSync)
      .flatMap((filePath) => readCompleteTraceLines(filePath))
      .map((line) => JSON.parse(line.toString('utf8')))
      .filter((record) => record.event.type === 'state'
        && record.event.payload.action === 'segmentRolled');
    assert.ok(segmentRollRecords.length > 0);
    assert.match(segmentRollRecords[0].event.payload.detail, /archivedBytes=/);
    assert.deepStrictEqual(
      readdirSync(directory).sort(),
      ['ritoras-trace.log', 'ritoras-trace.log.1']
    );
    assert.strictEqual(TRACE_RING_CAPACITY_BYTES, 256 * 1024);
  });

  it('ignores an incomplete trailing segment line', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const segmentPath = path.join(directory, 'ritoras-trace.log');
    writeFileSync(segmentPath, '{"complete":true}\n{"partial":');

    const lines = readCompleteTraceLines(segmentPath);
    assert.strictEqual(lines.length, 1);
    assert.deepStrictEqual(JSON.parse(lines[0].toString('utf8')), { complete: true });
    assert.strictEqual(
      completeTraceLines(Buffer.from('{"complete":true}\n{"partial":')).length,
      1
    );
  });

  it('keeps a recovered partial tail at the end of the rotated segment', (testContext) => {
    const directory = temporaryTraceDirectory(testContext);
    const livePath = path.join(directory, 'ritoras-trace.log');
    writeFileSync(livePath, '{"complete":true}\n{"partial":');
    const recorder = new KeystrokeTraceRecorder(directory);
    let rollCount = 0;
    recorder.onSegmentRoll = () => {
      rollCount += 1;
    };
    recorder.append(makeMetaEvent({ action: 'sessionStarted', sessionID: 'recovered' }));
    recorder.flush('idle');

    assert.strictEqual(rollCount, 1);
    assert.strictEqual(readCompleteTraceLines(recorder.rotatedFilePath).length, 1);
    const liveRecords = readCompleteTraceLines(recorder.liveFilePath)
      .map((line) => JSON.parse(line.toString('utf8')));
    assert.strictEqual(liveRecords.filter((record) => record.event.type === 'meta').length, 1);
    assert.strictEqual(liveRecords.filter((record) => record.event.type === 'state'
      && record.event.payload.action === 'segmentRolled').length, 1);
  });
});
