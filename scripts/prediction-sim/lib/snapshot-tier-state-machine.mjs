// Pure-logic JS mirror of KeyboardViewController's snapshot fallback tiers.

export const SnapshotThresholds = Object.freeze({
  localhostFallbackMisses: 1,
  serverPollMisses: 6,
  sessionLostMisses: 6,
  sessionLostMinimumAgeSeconds: 20,
  snapshotPollInitialDelaySeconds: 0.2,
  snapshotPollIntervalSeconds: 0.5,
  serverPollFastIntervalSeconds: 0.3,
  serverPollFastPollCount: 5,
  serverPollSlowIntervalSeconds: 1.2,
  serverPollExhaustionCycles: 120,
});

export class SnapshotTierStateMachine {
  constructor({
    sessionID = 'session-1',
    state = 'recording',
    startedAtSeconds = 0,
    lastSeenSnapshotRevision = 0,
    dictationTargetDocId = 'document-1',
  } = {}) {
    this.pendingRequestId = sessionID;
    this.state = state;
    this.startedAtSeconds = startedAtSeconds;
    this.lastSeenSnapshotRevision = lastSeenSnapshotRevision;
    this.dictationTargetDocId = dictationTargetDocId;

    this.consecutiveSnapshotMisses = 0;
    this.consecutiveSessionEvidenceMiss = 0;
    this.serverPollCount = 0;
    this.serverPollUnresponsiveCount = 0;
    this.serverPollWorkItem = false;
    this.teardownReason = null;
  }

  get nextServerPollIntervalSeconds() {
    return this.serverPollCount < SnapshotThresholds.serverPollFastPollCount
      ? SnapshotThresholds.serverPollFastIntervalSeconds
      : SnapshotThresholds.serverPollSlowIntervalSeconds;
  }

  refreshFromSharedState({
    appGroupSnapshot = null,
    localhostResponse = { kind: 'noSession' },
    nowSeconds = this.startedAtSeconds,
  } = {}) {
    if (this.pendingRequestId == null) return 'inactive';

    if (this.isFreshSnapshotForPendingSession(appGroupSnapshot)) {
      this.lastSeenSnapshotRevision = appGroupSnapshot.revision ?? 0;
      this.applySnapshotPayload(appGroupSnapshot);
      return 'app-group-snapshot';
    }

    this.consecutiveSnapshotMisses += 1;
    if (this.consecutiveSnapshotMisses >= SnapshotThresholds.localhostFallbackMisses) {
      const localhostAction = this.processLocalhostResponse(localhostResponse, nowSeconds);
      if (localhostAction !== null) return localhostAction;
    }

    if (this.consecutiveSnapshotMisses >= SnapshotThresholds.serverPollMisses
        && !this.serverPollWorkItem) {
      this.startServerPolling();
      return 'server-poll-started';
    }
    return 'snapshot-miss';
  }

  processServerPollCycle() {
    if (!this.serverPollWorkItem || this.pendingRequestId == null) return 'inactive';

    this.serverPollCount += 1;
    this.serverPollUnresponsiveCount += 1;
    if (this.serverPollUnresponsiveCount >= SnapshotThresholds.serverPollExhaustionCycles) {
      this.exhaustServerPolling();
      return 'exhausted';
    }
    return 'poll';
  }

  receiveServerPollStatus(status) {
    if (status === 'pending' || status === 'transcribing') {
      this.serverPollUnresponsiveCount = 0;
    }
  }

  isFreshSnapshotForPendingSession(snapshot) {
    return snapshot != null
      && snapshot.id === this.pendingRequestId
      && (snapshot.revision ?? 0) > this.lastSeenSnapshotRevision;
  }

  processLocalhostResponse(response, nowSeconds) {
    switch (response.kind) {
      case 'payload':
        if (response.payload.id !== this.pendingRequestId) return null;

        this.consecutiveSnapshotMisses = 0;
        this.consecutiveSessionEvidenceMiss = 0;
        if (this.serverPollWorkItem) {
          this.serverPollWorkItem = false;
          this.serverPollUnresponsiveCount = 0;
        }

        if ((response.payload.revision ?? 0) > this.lastSeenSnapshotRevision) {
          this.lastSeenSnapshotRevision = response.payload.revision ?? 0;
          this.applySnapshotPayload(response.payload);
          return 'localhost-snapshot';
        }
        return 'localhost-liveness';

      case 'malformed':
        return null;

      case 'noSession':
      case 'unreachable':
        this.consecutiveSessionEvidenceMiss += 1;
        if (this.resetIfSessionLost(nowSeconds)) return 'session-lost';
        return null;

      default:
        throw new Error(`Unknown localhost response kind: ${response.kind}`);
    }
  }

  applySnapshotPayload(payload) {
    if (payload.id !== this.pendingRequestId) return false;

    if (payload.status === 'cancelled') {
      this.stopDictationTransports();
      this.pendingRequestId = null;
      this.dictationTargetDocId = null;
      this.state = 'idle';
    } else if (payload.status === 'recording') {
      this.state = 'recording';
    } else if (payload.status === 'transcribing') {
      this.state = 'waiting';
    }

    this.consecutiveSnapshotMisses = 0;
    this.consecutiveSessionEvidenceMiss = 0;
    return true;
  }

  resetIfSessionLost(nowSeconds) {
    if (this.state !== 'recording'
        || this.consecutiveSessionEvidenceMiss < SnapshotThresholds.sessionLostMisses) {
      return false;
    }
    const sessionAgeSeconds = nowSeconds - this.startedAtSeconds;
    if (sessionAgeSeconds <= SnapshotThresholds.sessionLostMinimumAgeSeconds) return false;

    this.stopDictationTransports();
    this.pendingRequestId = null;
    this.dictationTargetDocId = null;
    this.state = 'idle';
    this.teardownReason = 'session-lost';
    return true;
  }

  startServerPolling() {
    this.serverPollCount = 0;
    this.serverPollUnresponsiveCount = 0;
    this.serverPollWorkItem = true;
  }

  stopDictationTransports() {
    this.serverPollWorkItem = false;
  }

  exhaustServerPolling() {
    this.stopDictationTransports();
    this.pendingRequestId = null;
    this.dictationTargetDocId = null;
    this.state = 'error';
    this.teardownReason = 'jobs-exhausted';
  }
}
