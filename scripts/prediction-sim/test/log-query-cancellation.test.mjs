import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  isCurrentQueryEpoch,
  isQuerySuperseded,
} from '../lib/log-query-cancellation.mjs';

describe('LogQueryEpochDecision mirror', () => {
  it('runs a query only while its captured epoch matches the current epoch', () => {
    assert.equal(isCurrentQueryEpoch(4, 4), true);
    assert.equal(isQuerySuperseded(4, 4), false);
    assert.equal(isCurrentQueryEpoch(3, 4), false);
    assert.equal(isQuerySuperseded(3, 4), true);
    assert.equal(isCurrentQueryEpoch(5, 4), false);
    assert.equal(isQuerySuperseded(5, 4), true);
  });
});
