import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { DeferredFlushGate } from '../lib/deferred-flush-gate.mjs';

describe('DeferredFlushGate (JS port)', () => {
  it('stable field: same non-nil id suppresses another attempt', () => {
    const gate = new DeferredFlushGate();
    gate.record('A');
    assert.strictEqual(gate.shouldAttempt('A'), false);
  });

  it('field switch: a different non-nil id allows another attempt', () => {
    const gate = new DeferredFlushGate();
    gate.record('A');
    assert.strictEqual(gate.shouldAttempt('B'), true);
  });

  it('regression: recording a nil id never suppresses a nil retry', () => {
    const gate = new DeferredFlushGate();
    gate.record(null);
    assert.strictEqual(gate.shouldAttempt(null), true);
  });

  it('a recorded nil id allows an attempt after identity attaches', () => {
    const gate = new DeferredFlushGate();
    gate.record(null);
    assert.strictEqual(gate.shouldAttempt('A'), true);
  });

  it('reset clears stable-field suppression', () => {
    const gate = new DeferredFlushGate();
    gate.record('A');
    gate.reset();
    assert.strictEqual(gate.shouldAttempt('A'), true);
  });

  it('fresh gate allows an attempt with a nil id', () => {
    const gate = new DeferredFlushGate();
    assert.strictEqual(gate.shouldAttempt(null), true);
  });
});
