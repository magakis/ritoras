export const PendingJobState = Object.freeze({
  recorded: 'recorded',
  submitting: 'submitting',
  accepted: 'accepted',
  syncFallback: 'syncFallback',
  ready: 'ready',
  failed: 'failed',
});

export const RecoveryAction = Object.freeze({
  poll: 'poll',
  savedAudioRetry: 'savedAudioRetry',
  publishReady: 'publishReady',
  historyOnly: 'historyOnly',
  retainForManualRecovery: 'retainForManualRecovery',
});

export const ManualRetryDecision = Object.freeze({
  retry: 'retry',
  checkStatus: 'checkStatus',
  recoverReady: 'recoverReady',
  wait: 'wait',
});

export function manualRetryDecision({ state, hasLiveUpload, serverStatus = null }) {
  if (hasLiveUpload) {
    return { action: ManualRetryDecision.wait, reason: 'An upload is still running; its result will be checked before retrying.' };
  }
  if (serverStatus !== null) {
    switch (serverStatus) {
      case 'ready': return { action: ManualRetryDecision.recoverReady };
      case 'pending': return { action: ManualRetryDecision.wait, reason: 'The server is still processing this transcription.' };
      case 'failed': return { action: ManualRetryDecision.retry };
      case 'missing':
        return state === PendingJobState.syncFallback
          ? { action: ManualRetryDecision.wait, reason: 'No async job exists, but the synchronous request may still finish; retry remains blocked.' }
          : { action: ManualRetryDecision.retry };
      case 'unavailable': return { action: ManualRetryDecision.wait, reason: 'Server status is unknown. Check status again before retrying.' };
      default: return { action: ManualRetryDecision.wait, reason: 'Server status is unknown. Check status again before retrying.' };
    }
  }
  switch (state) {
    case PendingJobState.recorded:
    case PendingJobState.failed: return { action: ManualRetryDecision.retry };
    case PendingJobState.submitting:
    case PendingJobState.accepted: return { action: ManualRetryDecision.checkStatus };
    case PendingJobState.syncFallback: return { action: ManualRetryDecision.checkStatus };
    case PendingJobState.ready: return { action: ManualRetryDecision.checkStatus };
    default: return { action: ManualRetryDecision.wait, reason: 'Server status is unknown. Check status again before retrying.' };
  }
}

export function mayClaimCompletion(alreadyFinalizing) {
  return !alreadyFinalizing;
}

export function mayStartLateReconciliation({ hasForegroundWaiter, alreadyReconciling }) {
  return !hasForegroundWaiter && !alreadyReconciling;
}

export function visibleRecoveryIDs(failedIDs, pendingIDs) {
  return [...new Set([...pendingIDs, ...failedIDs])];
}

export function statusEndpoint(jobID) {
  return `/jobs/${jobID.toLowerCase()}`;
}

export function mayRemoveFailedRecordAfterRecoveredResult({ historyOwned, ownsCompletion }) {
  return historyOwned && ownsCompletion;
}

export function mayRemovePendingAudioAfterRecoveredResult({
  historyOwned,
  failedRecordRemovalPersisted,
  ownsCompletion,
}) {
  return historyOwned && failedRecordRemovalPersisted && ownsCompletion;
}

export const SERVER_TTL_MS = 600_000;
export const IDEMPOTENCY_TTL_MS = 600_000;
export const DELIVERY_WINDOW_MS = 120_000;

const transitions = new Set([
  'recorded:submitting', 'recorded:failed',
  'submitting:accepted', 'submitting:syncFallback', 'submitting:ready', 'submitting:failed',
  'accepted:ready', 'accepted:failed', 'accepted:syncFallback',
  'syncFallback:ready', 'syncFallback:failed',
]);

export function canTransition(current, next) {
  return transitions.has(`${current}:${next}`);
}

export function recoveryAction({ state, createdAt, terminalAt = null, now, statusWas404 = false }) {
  // Active jobs are bounded from creation; terminal jobs use their independent
  // completion-based retention window.
  const recoveryReference = terminalAt ?? createdAt;
  const withinServerTTL = now - recoveryReference <= SERVER_TTL_MS;

  if (state === PendingJobState.ready) {
    if (terminalAt === null) return { action: RecoveryAction.retainForManualRecovery };
    if (now - terminalAt <= DELIVERY_WINDOW_MS) {
      return { action: RecoveryAction.publishReady, deliveryEligible: true };
    }
    return { action: RecoveryAction.historyOnly };
  }
  if (state === PendingJobState.failed) return { action: RecoveryAction.savedAudioRetry };
  if (statusWas404) {
    return { action: withinServerTTL ? RecoveryAction.poll : RecoveryAction.savedAudioRetry };
  }
  if (state === PendingJobState.accepted) {
    // GET observes existing jobs; idempotency expiry only constrains POST replay.
    return { action: withinServerTTL ? RecoveryAction.poll : RecoveryAction.savedAudioRetry };
  }
  return { action: RecoveryAction.retainForManualRecovery };
}
