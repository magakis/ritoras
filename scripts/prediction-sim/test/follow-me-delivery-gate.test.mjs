import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  Decision,
  FollowMeConsumedIDRing,
  TerminalStatus,
  decideFollowMeDelivery,
} from '../lib/follow-me-delivery-gate.mjs';

const input = (overrides = {}) => ({
  id: 'payload-1',
  status: TerminalStatus.completed,
  terminalAt: 10_000,
  now: 15_000,
  windowSeconds: 10,
  consumedIDs: [],
  matchesPendingRequest: false,
  hasRealField: true,
  ...overrides,
});

describe('FollowMeDeliveryGate (JS port)', () => {
  it('delivers within the window when a real field is focused', () => {
    assert.strictEqual(decideFollowMeDelivery(input()), Decision.deliver);
  });

  it('delivers at the exact window boundary and expires strictly after it', () => {
    assert.strictEqual(decideFollowMeDelivery(input({ now: 20_000 })), Decision.deliver);
    assert.strictEqual(decideFollowMeDelivery(input({ now: 20_001 })), Decision.dropExpired);
  });

  it('delivers an unconsumed pending match beyond the window', () => {
    assert.strictEqual(decideFollowMeDelivery(input({
      now: 30_001,
      matchesPendingRequest: true,
    })), Decision.deliver);
  });

  it('expires an out-of-window payload without a pending match', () => {
    assert.strictEqual(decideFollowMeDelivery(input({ now: 20_001 })), Decision.dropExpired);
  });

  it('delivers at the exact window edge and drops a consumed pending match', () => {
    assert.strictEqual(decideFollowMeDelivery(input({ now: 20_000 })), Decision.deliver);
    assert.strictEqual(decideFollowMeDelivery(input({
      now: 30_001,
      matchesPendingRequest: true,
      consumedIDs: ['payload-1'],
    })), Decision.dropConsumed);
  });

  it('drops an already consumed id, including a legacy-seeded id', () => {
    assert.strictEqual(decideFollowMeDelivery(input({ consumedIDs: ['payload-1'] })), Decision.dropConsumed);
    const ring = FollowMeConsumedIDRing.legacySeed('payload-1');
    assert.strictEqual(ring.contains('payload-1'), true);
    assert.strictEqual(decideFollowMeDelivery(input({ consumedIDs: ring.ids })), Decision.dropConsumed);
  });

  it('evicts the oldest id and keeps the newest four', () => {
    const ring = new FollowMeConsumedIDRing();
    for (const id of ['one', 'two', 'three', 'four', 'five']) ring.append(id);
    assert.deepStrictEqual(ring.ids, ['two', 'three', 'four', 'five']);
    assert.strictEqual(ring.contains('one'), false);
    assert.strictEqual(ring.contains('five'), true);
  });

  it('waits when no real field is focused', () => {
    assert.strictEqual(decideFollowMeDelivery(input({ hasRealField: false })), Decision.waitNoField);
  });

  it('uses the same delivery decision path for error and cancelled statuses', () => {
    for (const status of [TerminalStatus.error, TerminalStatus.cancelled]) {
      assert.strictEqual(decideFollowMeDelivery(input({ status })), Decision.deliver);
    }
  });
});
