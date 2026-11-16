import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  TRACE_EXPORT_WINDOW_MILLISECONDS,
  selectKeystrokeTraceWindow,
} from '../lib/keystroke-trace-window.mjs';

const NOW = Date.parse('2026-11-16T12:00:00.000Z');

function traceLine(timestampMilliseconds, action = 'sessionStarted') {
  return Buffer.from(`${JSON.stringify({
    schemaVersion: 1,
    timestamp: new Date(timestampMilliseconds).toISOString(),
    event: {
      type: 'meta',
      payload: { action },
    },
  })}\n`);
}

describe('keystroke trace export window mirror', () => {
  it('returns an empty result for an empty store', () => {
    const selection = selectKeystrokeTraceWindow({
      rotatedSegment: Buffer.alloc(0),
      liveSegment: Buffer.alloc(0),
      nowMilliseconds: NOW,
    });

    assert.strictEqual(selection.contents, '');
    assert.strictEqual(selection.recordCount, 0);
    assert.strictEqual(selection.capturedAtMilliseconds, NOW);
    assert.strictEqual(selection.oldestRetainedTimestamp, null);
    assert.strictEqual(selection.coverageDurationMilliseconds, 0);
    assert.strictEqual(selection.hasFullWindowCoverage, false);
  });

  it('does not export records older than the five-minute window', () => {
    const oldTimestamp = NOW - TRACE_EXPORT_WINDOW_MILLISECONDS - 1;
    const selection = selectKeystrokeTraceWindow({
      liveSegment: traceLine(oldTimestamp),
      nowMilliseconds: NOW,
    });

    assert.strictEqual(selection.contents, '');
    assert.strictEqual(selection.recordCount, 0);
    assert.strictEqual(selection.oldestRetainedTimestamp, oldTimestamp);
    assert.strictEqual(selection.coverageDurationMilliseconds, TRACE_EXPORT_WINDOW_MILLISECONDS);
    assert.strictEqual(selection.hasFullWindowCoverage, true);
  });

  it('includes both exact window boundaries and excludes records just outside', () => {
    const cutoff = NOW - TRACE_EXPORT_WINDOW_MILLISECONDS;
    const selectedBefore = traceLine(cutoff, 'cutoff');
    const selectedAtNow = traceLine(NOW, 'now');
    const selection = selectKeystrokeTraceWindow({
      liveSegment: Buffer.concat([
        traceLine(cutoff - 1, 'too-old'),
        selectedBefore,
        selectedAtNow,
        traceLine(NOW + 1, 'future'),
      ]),
      nowMilliseconds: NOW,
    });

    assert.strictEqual(selection.contents, Buffer.concat([selectedBefore, selectedAtNow]).toString());
    assert.strictEqual(selection.recordCount, 2);
    assert.strictEqual(selection.coverageDurationMilliseconds, TRACE_EXPORT_WINDOW_MILLISECONDS);
    assert.strictEqual(selection.hasFullWindowCoverage, true);
  });

  it('keeps the rotated segment before the live segment when a window spans rotation', () => {
    const rotatedLine = traceLine(NOW - 90_000, 'rotated');
    const liveLine = traceLine(NOW - 1_000, 'live');
    const selection = selectKeystrokeTraceWindow({
      rotatedSegment: rotatedLine,
      liveSegment: liveLine,
      nowMilliseconds: NOW,
    });

    assert.strictEqual(selection.contents, Buffer.concat([rotatedLine, liveLine]).toString());
    assert.strictEqual(selection.recordCount, 2);
  });

  it('skips malformed records and ignores an incomplete trailing line', () => {
    const validLine = traceLine(NOW - 1_000, 'valid');
    const wrongSchema = traceLine(NOW - 2_000).toString()
      .replace('"schemaVersion":1', '"schemaVersion":2');
    const invalidTimestamp = traceLine(NOW - 3_000).toString()
      .replace(new Date(NOW - 3_000).toISOString(), 'not-a-timestamp');
    const incompleteTail = traceLine(NOW - 4_000).subarray(0, -1);
    const selection = selectKeystrokeTraceWindow({
      liveSegment: Buffer.concat([
        validLine,
        Buffer.from('{"schemaVersion":1,broken}\n'),
        Buffer.from(wrongSchema),
        Buffer.from(invalidTimestamp),
        Buffer.from([0xff, 0xfe, 0x0a]),
        incompleteTail,
      ]),
      nowMilliseconds: NOW,
    });

    assert.strictEqual(selection.contents, validLine.toString());
    assert.strictEqual(selection.recordCount, 1);
  });

  it('reports the actual oldest retained timestamp when coverage is shorter than five minutes', () => {
    const oldestTimestamp = NOW - 2 * 60_000 - 3_000;
    const oldestLine = traceLine(oldestTimestamp, 'oldest');
    const recentLine = traceLine(NOW - 1_000, 'recent');
    const selection = selectKeystrokeTraceWindow({
      liveSegment: Buffer.concat([oldestLine, recentLine]),
      nowMilliseconds: NOW,
    });

    assert.strictEqual(selection.recordCount, 2);
    assert.strictEqual(selection.oldestRetainedTimestamp, oldestTimestamp);
    assert.strictEqual(selection.coverageDurationMilliseconds, 2 * 60_000 + 3_000);
    assert.strictEqual(selection.hasFullWindowCoverage, false);
  });

  it('rejects segments larger than the retained byte budget instead of truncating', () => {
    assert.throws(
      () => selectKeystrokeTraceWindow({
        liveSegment: Buffer.alloc(2 * 1024 * 1024 + 1),
        nowMilliseconds: NOW,
      }),
      RangeError
    );
  });
});
