import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  canTransition,
  DELIVERY_WINDOW_MS,
  IDEMPOTENCY_TTL_MS,
  manualRetryDecision,
  ManualRetryDecision,
  mayRemoveFailedRecordAfterRecoveredResult,
  mayRemovePendingAudioAfterRecoveredResult,
  mayClaimCompletion,
  mayStartLateReconciliation,
  PendingJobState,
  RecoveryAction,
  recoveryAction,
  SERVER_TTL_MS,
  statusEndpoint,
  visibleRecoveryIDs,
} from '../lib/pending-job-recovery.mjs';

const createdAt = 1_000_000;
const decide = (overrides = {}) => recoveryAction({
  state: PendingJobState.accepted,
  createdAt,
  now: createdAt + 1,
  ...overrides,
});

describe('PendingJobRecoveryRules mirror', () => {
  it('keeps recorded-before-submit and ambiguous submit for manual recovery, never auto-resubmits', () => {
    for (const state of [PendingJobState.recorded, PendingJobState.submitting, PendingJobState.syncFallback]) {
      assert.deepStrictEqual(decide({ state }), { action: RecoveryAction.retainForManualRecovery });
    }
  });

  it('polls accepted jobs until the created-at TTL boundary, then offers saved audio', () => {
    assert.strictEqual(decide({ now: createdAt + SERVER_TTL_MS }).action, RecoveryAction.poll);
    assert.strictEqual(decide({ now: createdAt + SERVER_TTL_MS + 1 }).action, RecoveryAction.savedAudioRetry);
  });

  it('treats 404 inside the TTL as uncertain and outside it as saved-audio recovery', () => {
    assert.strictEqual(decide({ statusWas404: true }).action, RecoveryAction.poll);
    assert.strictEqual(decide({ statusWas404: true, now: createdAt + SERVER_TTL_MS + 1 }).action, RecoveryAction.savedAudioRetry);
  });

  it('uses terminal TTL for GET recovery independently of idempotency expiry', () => {
    const terminalAt = createdAt + 100;
    const now = createdAt + IDEMPOTENCY_TTL_MS + 100;
    assert.strictEqual(now - createdAt > IDEMPOTENCY_TTL_MS, true);
    assert.strictEqual(now - terminalAt, SERVER_TTL_MS);
    assert.strictEqual(decide({ terminalAt, now }).action, RecoveryAction.poll);
    assert.strictEqual(decide({ terminalAt, now: now + 1 }).action, RecoveryAction.savedAudioRetry);
  });

  it('bounds a nonterminal job from created-at when no terminal timestamp exists', () => {
    assert.strictEqual(decide({ terminalAt: null, now: createdAt + SERVER_TTL_MS }).action, RecoveryAction.poll);
    assert.strictEqual(decide({ terminalAt: null, now: createdAt + SERVER_TTL_MS + 1 }).action, RecoveryAction.savedAudioRetry);
  });

  it('preserves original terminal time for delivery eligibility and routes expiry to history only', () => {
    const terminalAt = createdAt;
    assert.deepStrictEqual(decide({ state: PendingJobState.ready, terminalAt, now: terminalAt + DELIVERY_WINDOW_MS }), {
      action: RecoveryAction.publishReady, deliveryEligible: true,
    });
    assert.deepStrictEqual(decide({ state: PendingJobState.ready, terminalAt, now: terminalAt + DELIVERY_WINDOW_MS + 1 }), {
      action: RecoveryAction.historyOnly,
    });
  });

  it('routes failed results to saved audio and accepts only forward lifecycle transitions', () => {
    assert.strictEqual(decide({ state: PendingJobState.failed }).action, RecoveryAction.savedAudioRetry);
    assert.strictEqual(canTransition(PendingJobState.recorded, PendingJobState.submitting), true);
    assert.strictEqual(canTransition(PendingJobState.submitting, PendingJobState.accepted), true);
    assert.strictEqual(canTransition(PendingJobState.submitting, PendingJobState.syncFallback), true);
    assert.strictEqual(canTransition(PendingJobState.accepted, PendingJobState.ready), true);
    assert.strictEqual(canTransition(PendingJobState.accepted, PendingJobState.submitting), false);
  });

  it('exposes pending jobs and only enables retry after safe server/task decisions', () => {
    const visible = visibleRecoveryIDs(['failed-1', 'shared'], ['recorded-1', 'accepted-1', 'shared']);
    assert.deepStrictEqual(visible, ['recorded-1', 'accepted-1', 'shared', 'failed-1']);
    assert.deepStrictEqual(manualRetryDecision({ state: PendingJobState.recorded, hasLiveUpload: false }), {
      action: ManualRetryDecision.retry,
    });
    assert.deepStrictEqual(manualRetryDecision({ state: PendingJobState.accepted, hasLiveUpload: false }), {
      action: ManualRetryDecision.checkStatus,
    });
    assert.strictEqual(manualRetryDecision({
      state: PendingJobState.accepted, hasLiveUpload: true, serverStatus: 'missing',
    }).action, ManualRetryDecision.wait);
    assert.strictEqual(manualRetryDecision({
      state: PendingJobState.accepted, hasLiveUpload: false, serverStatus: 'ready',
    }).action, ManualRetryDecision.recoverReady);
    assert.strictEqual(manualRetryDecision({
      state: PendingJobState.accepted, hasLiveUpload: false, serverStatus: 'pending',
    }).action, ManualRetryDecision.wait);
    assert.strictEqual(manualRetryDecision({
      state: PendingJobState.accepted, hasLiveUpload: false, serverStatus: 'missing',
    }).action, ManualRetryDecision.retry);
    assert.strictEqual(manualRetryDecision({
      state: PendingJobState.accepted, hasLiveUpload: false, serverStatus: 'unavailable',
    }).action, ManualRetryDecision.wait);
    assert.strictEqual(manualRetryDecision({
      state: PendingJobState.syncFallback, hasLiveUpload: false, serverStatus: 'missing',
    }).action, ManualRetryDecision.wait);
  });

  it('allows one completion owner and rejects late racing finalizers', () => {
    assert.strictEqual(mayClaimCompletion(false), true);
    assert.strictEqual(mayClaimCompletion(true), false);
    assert.strictEqual(mayStartLateReconciliation({ hasForegroundWaiter: true, alreadyReconciling: false }), false);
    assert.strictEqual(mayStartLateReconciliation({ hasForegroundWaiter: false, alreadyReconciling: true }), false);
    assert.strictEqual(mayStartLateReconciliation({ hasForegroundWaiter: false, alreadyReconciling: false }), true);
  });

  it('uses the lowercase idempotency key in synthesized server endpoints', () => {
    const mixedCaseID = 'A1B2c3D4-1234-ABCD-9876-0123456789Ef';
    assert.strictEqual(statusEndpoint(mixedCaseID), '/jobs/a1b2c3d4-1234-abcd-9876-0123456789ef');
  });

  it('clears a completed failed row only after history ownership and durable cleanup are safe', () => {
    assert.strictEqual(mayRemoveFailedRecordAfterRecoveredResult({
      historyOwned: true, ownsCompletion: true,
    }), true);
    assert.strictEqual(mayRemoveFailedRecordAfterRecoveredResult({
      historyOwned: false, ownsCompletion: true,
    }), false);
    assert.strictEqual(mayRemoveFailedRecordAfterRecoveredResult({
      historyOwned: true, ownsCompletion: false,
    }), false);
    assert.strictEqual(mayRemovePendingAudioAfterRecoveredResult({
      historyOwned: true, failedRecordRemovalPersisted: false, ownsCompletion: true,
    }), false);
    assert.strictEqual(mayRemovePendingAudioAfterRecoveredResult({
      historyOwned: true, failedRecordRemovalPersisted: true, ownsCompletion: true,
    }), true);
    const completedID = 'completed-id';
    assert.deepStrictEqual(visibleRecoveryIDs([completedID], [completedID]), [completedID]);
    const historyOwnsResult = true;
    const finalizerOwnsJob = true;
    const failedRemovalPersisted = mayRemoveFailedRecordAfterRecoveredResult({
      historyOwned: historyOwnsResult, ownsCompletion: finalizerOwnsJob,
    });
    const pendingAudioCanBeRemoved = mayRemovePendingAudioAfterRecoveredResult({
      historyOwned: historyOwnsResult,
      failedRecordRemovalPersisted: failedRemovalPersisted,
      ownsCompletion: finalizerOwnsJob,
    });
    assert.strictEqual(pendingAudioCanBeRemoved, true);
    assert.deepStrictEqual(visibleRecoveryIDs([], []), []);
  });
});
