import Foundation

enum PendingJobRecoveryRules {
    enum ManualRetryDecision: Equatable {
        case retry
        case checkStatus
        case recoverReady
        case wait(reason: String)
    }

    enum ServerStatus: Equatable {
        case ready
        case pending
        case failed
        case missing
        case unavailable
    }

    enum Action: Equatable {
        case poll
        case savedAudioRetry
        case publishReady(deliveryEligible: Bool)
        case historyOnly
        case retainForManualRecovery
    }

    static let serverTTL: TimeInterval = 600
    /// Idempotency-key replay retention; this does not bound GET polling.
    static let idempotencyTTL: TimeInterval = 600
    static let deliveryWindow: TimeInterval = 120

    static func manualRetryDecision(
        state: PendingJobState,
        hasLiveUpload: Bool,
        serverStatus: ServerStatus? = nil
    ) -> ManualRetryDecision {
        if hasLiveUpload {
            return .wait(reason: "An upload is still running; its result will be checked before retrying.")
        }
        if let serverStatus {
            switch serverStatus {
            case .ready:
                return .recoverReady
            case .pending:
                return .wait(reason: "The server is still processing this transcription.")
            case .failed:
                return .retry
            case .missing:
                return state == .syncFallback
                    ? .wait(reason: "No async job exists, but the synchronous request may still finish; retry remains blocked.")
                    : .retry
            case .unavailable:
                return .wait(reason: "Server status is unknown. Check status again before retrying.")
            }
        }
        switch state {
        case .recorded, .failed:
            return .retry
        case .submitting, .accepted, .ready:
            return .checkStatus
        case .syncFallback:
            return .checkStatus
        }
    }

    static func mayClaimCompletion(alreadyFinalizing: Bool) -> Bool {
        !alreadyFinalizing
    }

    static func statusEndpoint(for jobID: UUID) -> String {
        "/jobs/\(jobID.uuidString.lowercased())"
    }

    static func mayRemoveFailedRecordAfterRecoveredResult(
        historyOwned: Bool,
        ownsCompletion: Bool
    ) -> Bool {
        historyOwned && ownsCompletion
    }

    static func mayRemovePendingAudioAfterRecoveredResult(
        historyOwned: Bool,
        failedRecordRemovalPersisted: Bool,
        ownsCompletion: Bool
    ) -> Bool {
        historyOwned && failedRecordRemovalPersisted && ownsCompletion
    }

    static func mayStartLateReconciliation(hasForegroundWaiter: Bool, alreadyReconciling: Bool) -> Bool {
        !hasForegroundWaiter && !alreadyReconciling
    }

    static func visibleRecoveryIDs(failedIDs: [UUID], pendingIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return (pendingIDs + failedIDs).filter { seen.insert($0).inserted }
    }

    static func canTransition(from current: PendingJobState, to next: PendingJobState) -> Bool {
        switch (current, next) {
        case (.recorded, .submitting), (.recorded, .failed),
             (.submitting, .accepted), (.submitting, .syncFallback), (.submitting, .ready), (.submitting, .failed),
             (.accepted, .ready), (.accepted, .failed), (.accepted, .syncFallback),
             (.syncFallback, .ready), (.syncFallback, .failed):
            return true
        default:
            return false
        }
    }

    static func recoveryAction(
        state: PendingJobState,
        createdAt: Date,
        terminalAt: Date?,
        now: Date,
        statusWas404: Bool = false
    ) -> Action {
        // Active jobs are bounded from creation; terminal jobs use their
        // independent completion-based retention window.
        let recoveryReference = terminalAt ?? createdAt
        let withinServerTTL = now.timeIntervalSince(recoveryReference) <= serverTTL

        if state == .ready {
            guard let terminalAt else { return .retainForManualRecovery }
            return now.timeIntervalSince(terminalAt) <= deliveryWindow
                ? .publishReady(deliveryEligible: true)
                : .historyOnly
        }
        if state == .failed { return .savedAudioRetry }

        if statusWas404 {
            return withinServerTTL ? .poll : .savedAudioRetry
        }
        switch state {
        case .accepted:
            // GET only observes existing jobs. Idempotency expiry constrains safe
            // POST replay, not retrieval; never resubmit from reconciliation.
            return withinServerTTL ? .poll : .savedAudioRetry
        case .recorded, .submitting, .syncFallback:
            return .retainForManualRecovery
        case .ready, .failed:
            return .retainForManualRecovery
        }
    }
}
