import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { DictationDeliveryState, DeliveryPhase } from '../lib/dictation-delivery-state.mjs';
import { Decision, TerminalStatus, decideFollowMeDelivery } from '../lib/follow-me-delivery-gate.mjs';

describe('DictationDeliveryState', () => {
  it('records ACK, insertion intent, and clear in forward-only order', () => {
    const state = new DictationDeliveryState();
    state.advance('id-1', 100, DeliveryPhase.claimed);
    state.advance('id-1', 200, DeliveryPhase.insertionIntent);
    state.advance('id-1', 300, DeliveryPhase.cleared);
    state.advance('id-1', 400, DeliveryPhase.claimed);
    assert.deepStrictEqual(state.recordFor('id-1'), {
      id: 'id-1', originalTimestamp: 100, phase: DeliveryPhase.cleared,
    });
  });

  it('keeps a claim without creating insertion intent when interrupted before the call', () => {
    const state = new DictationDeliveryState();
    state.advance('id-1', 100, DeliveryPhase.claimed);
    assert.strictEqual(state.recordFor('id-1').phase, DeliveryPhase.claimed);
    assert.strictEqual(decideFollowMeDelivery({
      id: 'id-1', status: TerminalStatus.completed, terminalAt: 100, now: 200,
      windowSeconds: 120, consumedIDs: ['id-1'], matchesPendingRequest: true, hasRealField: true,
    }), Decision.dropConsumed);
  });

  it('keeps an attempted-but-unknown insertion consumed rather than retrying it', () => {
    const state = new DictationDeliveryState();
    state.advance('id-1', 100, DeliveryPhase.claimed);
    state.advance('id-1', 100, DeliveryPhase.insertionIntent);
    assert.strictEqual(state.recordFor('id-1').phase, DeliveryPhase.insertionIntent);
    assert.strictEqual(decideFollowMeDelivery({
      id: 'id-1', status: TerminalStatus.completed, terminalAt: 100, now: 200,
      windowSeconds: 120, consumedIDs: ['id-1'], matchesPendingRequest: true, hasRealField: true,
    }), Decision.dropConsumed);
  });

  it('keeps recovery eligibility bounded by the original delivery timestamp', () => {
    const state = new DictationDeliveryState();
    state.advance('id-1', 100, DeliveryPhase.claimed);
    assert.strictEqual(decideFollowMeDelivery({
      id: 'id-2', status: TerminalStatus.completed, terminalAt: 100, now: 120_101,
      windowSeconds: 120, consumedIDs: [], matchesPendingRequest: false, hasRealField: true,
    }), Decision.dropExpired);
    assert.strictEqual(state.recordFor('id-1').originalTimestamp, 100);
  });

  it('retains only the four newest IDs and their original timestamps', () => {
    const state = new DictationDeliveryState();
    for (let id = 1; id <= 5; id += 1) state.advance(`id-${id}`, id * 100, DeliveryPhase.claimed);
    assert.deepStrictEqual(state.records.map(record => record.id), ['id-2', 'id-3', 'id-4', 'id-5']);
    assert.strictEqual(state.recordFor('id-5').originalTimestamp, 500);
  });
});
