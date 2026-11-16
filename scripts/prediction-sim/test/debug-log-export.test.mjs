import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { buildDebugLogExport } from '../lib/debug-log-export.mjs';

describe('debug log range export formatting and accounting', () => {
  it('formats payloads in key order and joins entries without a trailing newline', () => {
    const result = buildDebugLogExport([
      {
        timestamp: '2026-11-15T20:00:00.123Z',
        level: 'info',
        component: 'app',
        message: 'copied',
        raw: 'raw é',
        payload: {
          z: true,
          nested: { b: 2, a: 'é' },
          a: [false, null],
        },
      },
      {
        timestamp: null,
        level: null,
        component: null,
        message: '',
        raw: 'fallback',
        payload: null,
      },
    ]);

    const expectedText = [
      '2026-11-15T20:00:00.123Z [INFO] [app] copied',
      '  a: [false, null]',
      '  nested: {a: é, b: 2}',
      '  z: true',
      '— [—] [—] fallback',
    ].join('\n');
    assert.equal(result.text, expectedText);
    assert.equal(result.entryCount, 2);
    assert.equal(result.byteCount, Buffer.byteLength(expectedText, 'utf8'));
    assert.equal(
      result.estimatedRawBytes,
      Buffer.byteLength('raw é', 'utf8') + Buffer.byteLength('fallback', 'utf8')
    );
  });

  it('applies the scrubber only when requested and accounts for copied UTF-8 bytes', () => {
    const entries = [{
      timestamp: '2026-11-15T20:00:00.123Z',
      level: 'warn',
      component: 'network',
      message: 'email=a@example.com',
      raw: 'raw a@example.com',
      payload: null,
    }];
    let scrubCalls = 0;
    const scrub = text => {
      scrubCalls += 1;
      return text.replace('a@example.com', '[redacted]');
    };

    const unsanitized = buildDebugLogExport(entries, { scrubPII: false, scrub });
    assert.equal(scrubCalls, 0);
    assert.match(unsanitized.text, /a@example\.com/);

    const scrubbed = buildDebugLogExport(entries, { scrubPII: true, scrub });
    assert.equal(scrubCalls, 1);
    assert.doesNotMatch(scrubbed.text, /a@example\.com/);
    assert.equal(scrubbed.byteCount, Buffer.byteLength(scrubbed.text, 'utf8'));
  });

  it('returns empty text and zero byte counts for an empty range', () => {
    assert.deepEqual(buildDebugLogExport([]), {
      text: '',
      entryCount: 0,
      byteCount: 0,
      estimatedRawBytes: 0,
    });
  });

  it('requires a scrubber when PII scrubbing is enabled', () => {
    assert.throws(
      () => buildDebugLogExport([], { scrubPII: true }),
      /scrub must be provided/
    );
  });
});
