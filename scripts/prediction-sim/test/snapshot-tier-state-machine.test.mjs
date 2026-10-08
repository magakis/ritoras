import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  SnapshotThresholds,
  SnapshotTierStateMachine,
} from '../lib/snapshot-tier-state-machine.mjs';

const sessionID = 'active-session';
const recordingSnapshot = (revision = 1, id = sessionID) => ({
  id,
  revision,
  status: 'recording',
});

describe('SnapshotTierStateMachine (JS port)', () => {
  it('does not escalate a steady recording after 300 unchanged-revision polls', () => {
    const machine = new SnapshotTierStateMachine({
      sessionID,
      lastSeenSnapshotRevision: 0,
    });
    const snapshot = recordingSnapshot(1);

    for (let tick = 0; tick < 301; tick += 1) {
      machine.refreshFromSharedState({
        appGroupSnapshot: snapshot,
        localhostResponse: { kind: 'payload', payload: snapshot },
        nowSeconds: tick * SnapshotThresholds.snapshotPollIntervalSeconds,
      });
    }

    assert.strictEqual(machine.serverPollWorkItem, false);
    assert.strictEqual(machine.serverPollCount, 0);
    assert.strictEqual(machine.pendingRequestId, sessionID);
    assert.strictEqual(machine.state, 'recording');
    assert.strictEqual(machine.teardownReason, null);
  });

  it('uses stale matching localhost state as liveness and de-escalates /jobs', () => {
    const machine = new SnapshotTierStateMachine({
      sessionID,
      lastSeenSnapshotRevision: 8,
    });

    for (let miss = 0; miss < SnapshotThresholds.serverPollMisses; miss += 1) {
      machine.refreshFromSharedState({
        localhostResponse: { kind: 'malformed' },
        nowSeconds: 30,
      });
    }
    assert.strictEqual(machine.serverPollWorkItem, true);
    machine.serverPollUnresponsiveCount = 17;

    const response = {
      kind: 'payload',
      payload: recordingSnapshot(8),
    };
    assert.strictEqual(machine.refreshFromSharedState({
      localhostResponse: response,
      nowSeconds: 31,
    }), 'localhost-liveness');
    assert.strictEqual(machine.consecutiveSnapshotMisses, 0);
    assert.strictEqual(machine.consecutiveSessionEvidenceMiss, 0);
    assert.strictEqual(machine.serverPollWorkItem, false);
    assert.strictEqual(machine.serverPollUnresponsiveCount, 0);
    assert.strictEqual(machine.lastSeenSnapshotRevision, 8);

    for (let tick = 0; tick < 20; tick += 1) {
      machine.refreshFromSharedState({
        localhostResponse: response,
        nowSeconds: 32 + tick,
      });
    }
    assert.strictEqual(machine.serverPollWorkItem, false);
    assert.strictEqual(machine.serverPollCount, 0);
    assert.strictEqual(machine.state, 'recording');
  });

  it('still cancels recording after sustained no-session or unreachable evidence', () => {
    for (const kind of ['noSession', 'unreachable']) {
      const machine = new SnapshotTierStateMachine({ startedAtSeconds: 0 });
      for (let miss = 0; miss < SnapshotThresholds.sessionLostMisses; miss += 1) {
        machine.refreshFromSharedState({
          localhostResponse: { kind },
          nowSeconds: 30 + miss,
        });
      }

      assert.strictEqual(machine.pendingRequestId, null);
      assert.strictEqual(machine.dictationTargetDocId, null);
      assert.strictEqual(machine.state, 'idle');
      assert.strictEqual(machine.teardownReason, 'session-lost');
      assert.strictEqual(machine.serverPollWorkItem, false);
    }
  });

  it('still tears down with an error after 120 unresponsive /jobs cycles', () => {
    const machine = new SnapshotTierStateMachine({ state: 'waiting' });
    for (let miss = 0; miss < SnapshotThresholds.serverPollMisses; miss += 1) {
      machine.refreshFromSharedState({
        localhostResponse: { kind: 'malformed' },
        nowSeconds: 30,
      });
    }
    assert.strictEqual(machine.serverPollWorkItem, true);
    assert.strictEqual(machine.serverPollUnresponsiveCount, 0);
    assert.strictEqual(machine.nextServerPollIntervalSeconds,
      SnapshotThresholds.serverPollFastIntervalSeconds);

    for (let cycle = 1; cycle < SnapshotThresholds.serverPollExhaustionCycles; cycle += 1) {
      assert.strictEqual(machine.processServerPollCycle(), 'poll');
      machine.receiveServerPollStatus('404');
    }
    assert.strictEqual(machine.serverPollUnresponsiveCount, 119);
    assert.strictEqual(machine.nextServerPollIntervalSeconds,
      SnapshotThresholds.serverPollSlowIntervalSeconds);
    assert.strictEqual(machine.processServerPollCycle(), 'exhausted');

    assert.strictEqual(machine.serverPollUnresponsiveCount, 120);
    assert.strictEqual(machine.serverPollWorkItem, false);
    assert.strictEqual(machine.pendingRequestId, null);
    assert.strictEqual(machine.dictationTargetDocId, null);
    assert.strictEqual(machine.state, 'error');
    assert.strictEqual(machine.teardownReason, 'jobs-exhausted');
  });

  it('resets unresponsive cycles only for pending and transcribing responses', () => {
    const machine = new SnapshotTierStateMachine();
    machine.startServerPolling();
    machine.serverPollUnresponsiveCount = 12;
    machine.receiveServerPollStatus('404');
    assert.strictEqual(machine.serverPollUnresponsiveCount, 12);

    machine.receiveServerPollStatus('pending');
    assert.strictEqual(machine.serverPollUnresponsiveCount, 0);
    machine.serverPollUnresponsiveCount = 7;
    machine.receiveServerPollStatus('transcribing');
    assert.strictEqual(machine.serverPollUnresponsiveCount, 0);
  });
});
