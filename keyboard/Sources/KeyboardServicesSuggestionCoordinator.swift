import Foundation

/// Coalesces background telemetry work so typing cannot grow an unbounded dispatch backlog.
private final class KeyboardServicesFailureTelemetryReporter: @unchecked Sendable {
    private enum PendingChange {
        case failures(Int, resetBeforeIncrement: Bool)
        case recovered
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.ritoras.keyboard.services.telemetry",
        qos: .utility
    )
    private var pendingByServer: [String: PendingChange] = [:]
    private var pendingServerOrder: [String] = []
    private var droppedUpdateCount = 0
    private var drainScheduled = false

    func recordFailure(for server: String) {
        enqueue(server: server) { current in
            switch current {
            case .some(.failures(let count, let resetBeforeIncrement)):
                return .failures(
                    min(
                        count + 1,
                        KeyboardServicesFailureTelemetrySnapshot.maximumConsecutiveFailures
                    ),
                    resetBeforeIncrement: resetBeforeIncrement
                )
            case .some(.recovered):
                return .failures(1, resetBeforeIncrement: true)
            case .none:
                return .failures(1, resetBeforeIncrement: false)
            }
        }
    }

    func recordSuccess(for server: String) {
        enqueue(server: server) { _ in .recovered }
    }

    private func enqueue(
        server: String,
        update: (PendingChange?) -> PendingChange
    ) {
        guard !server.isEmpty,
              server.utf8.count
                <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength else {
            return
        }

        lock.lock()
        if pendingByServer[server] == nil {
            if pendingByServer.count >= KeyboardServicesFailureTelemetrySnapshot.maximumServerCount {
                let oldestServer = pendingServerOrder.removeFirst()
                pendingByServer.removeValue(forKey: oldestServer)
                droppedUpdateCount = min(droppedUpdateCount + 1, 255)
            }
            pendingServerOrder.append(server)
        }
        pendingByServer[server] = update(pendingByServer[server])
        let shouldStartDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if shouldStartDrain {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pendingByServer.isEmpty else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let batch = pendingByServer
            let droppedCount = droppedUpdateCount
            pendingByServer.removeAll(keepingCapacity: true)
            pendingServerOrder.removeAll(keepingCapacity: true)
            droppedUpdateCount = 0
            lock.unlock()

            if droppedCount > 0 {
                FileLogger.shared.warn(.keyboard, "keyboard service telemetry updates dropped",
                    payload: ["count": droppedCount])
            }

            for (server, change) in batch {
                do {
                    switch change {
                    case .failures(let count, let resetBeforeIncrement):
                        try KeyboardServicesFailureTelemetryStore.recordFailures(
                            for: server,
                            incrementBy: count,
                            resetBeforeIncrement: resetBeforeIncrement
                        )
                    case .recovered:
                        try KeyboardServicesFailureTelemetryStore.recordSuccess(for: server)
                    }
                } catch {
                    FileLogger.shared.debug(
                        .keyboard,
                        "keyboard service telemetry write failed",
                        payload: ["reason": Self.telemetryErrorTag(error)]
                    )
                }
            }
        }
    }

    private static func telemetryErrorTag(_ error: Error) -> String {
        guard let telemetryError = error as? KeyboardServicesFailureTelemetryStoreError else {
            return "encoding"
        }
        switch telemetryError {
        case .appGroupUnavailable: return "appGroupUnavailable"
        case .invalidServer: return "invalidServer"
        case .revisionExhausted: return "revisionExhausted"
        case .invalidSnapshot: return "invalidSnapshot"
        }
    }
}

/// Runs passive-pin requests only after a local suggestion bar render.
///
/// Extension memory accounting against the 48 MB Jetsam cap and the known
/// ~90 MB `phys_footprint` issue:
/// - Applied display augmentation holds at most 3 endpoints × 3 strings × 128
///   Unicode scalars per string; the existing tap/display cache holds at most
///   the same 3 visible strings.
/// - The local-candidate mirror holds at most 3 strings × 128 scalars each.
/// - Pending telemetry coalesces at most 64 server entries; its order list and
///   the single active drain batch are each bounded to the same count.
/// - Each streamed response is capped at 16 KiB (at most three endpoint
///   requests can overlap), and decoded response data is transient.
/// - Failover lists, maps, and sets are bounded by the configured-server count
///   (at most 64, with server keys capped at 512 UTF-8 bytes); in-flight
///   request/task tracking is bounded by 3 endpoints, each capturing at most
///   512 context scalars.
///
/// These small-string caches are replaced, drained, or revision-bounded; none
/// grows across keyboard cycles. No new indexes, mmaps, or large buffers are
/// added; server candidates remain display-only and do not enter synchronous
/// prediction or autocorrect queues.
@MainActor
final class KeyboardServicesSuggestionCoordinator {
    private let telemetryReporter = KeyboardServicesFailureTelemetryReporter()
    private var failover = KeyboardServicesSuggestionFailover()
    private var inFlightEndpoints: Set<KeyboardServicesSuggestionEndpoint> = []
    private var requestTasks: [KeyboardServicesSuggestionEndpoint: Task<Void, Never>] = [:]

    var activeSnapshotRevision: UInt64? {
        failover.pinnedServer == nil ? nil : failover.revision
    }

    var onCandidates: (
        (KeyboardServicesSuggestionEndpoint, [String], UInt64, UInt64, UInt64) -> Void
    )?
    var onAugmentationInvalidated: (() -> Void)?

    /// Updates passive state and cancels requests belonging to a changed snapshot/configuration.
    @discardableResult
    func updateSnapshot(
        _ snapshot: KeyboardServicesPinSnapshot?,
        configuredServers: [String]
    ) -> Bool {
        let changed = failover.update(snapshot: snapshot, configuredServers: configuredServers)
        if changed {
            requestTasks.values.forEach { $0.cancel() }
        }
        return changed
    }

    /// Starts non-blocking endpoint requests after the caller has rendered local candidates.
    func requestSuggestions(
        input: SuggestionInputSnapshot,
        localCandidates: [String],
        language: KeyboardLanguage,
        epoch: UInt64,
        contextToken: UInt64,
        settings: KeyboardServerSuggestionSettings
    ) {
        guard settings.enabled,
              contextToken != 0,
              let revision = activeSnapshotRevision else {
            return
        }

        let endpoints: [KeyboardServicesSuggestionEndpoint]
        let requestInput: KeyboardServicesSuggestionRequestInput
        if input.currentWord.isEmpty {
            guard language == .english,
                  settings.capabilityEnabled(.prediction) else {
                return
            }
            endpoints = [.prediction]
            requestInput = KeyboardServicesSuggestionRequestInput(
                typedWord: "",
                previousWord: "",
                context: input.context
            )
        } else {
            guard input.lookupWord.unicodeScalars.count
                    <= KeyboardServicesSuggestionPolicy.maximumCandidateScalars,
                  (input.previousWord?.unicodeScalars.count ?? 0)
                    <= KeyboardServicesSuggestionPolicy.maximumCandidateScalars else {
                return
            }
            endpoints = [.spelling, .vocabulary].filter {
                settings.capabilityEnabled($0)
            }
            guard !endpoints.isEmpty else { return }
            requestInput = KeyboardServicesSuggestionRequestInput(
                typedWord: input.lookupWord,
                previousWord: input.previousWord ?? "",
                context: ""
            )
        }

        for endpoint in endpoints {
            guard !inFlightEndpoints.contains(endpoint),
                  let server = failover.server(for: endpoint) else {
                continue
            }
            startRequest(
                endpoint: endpoint,
                server: server,
                revision: revision,
                input: requestInput,
                localCandidates: localCandidates,
                language: language,
                epoch: epoch,
                contextToken: contextToken
            )
        }
    }

    /// Cancels outstanding requests when the keyboard is hidden or torn down.
    func cancelPendingRequests() {
        requestTasks.values.forEach { $0.cancel() }
    }

    private func startRequest(
        endpoint: KeyboardServicesSuggestionEndpoint,
        server: String,
        revision: UInt64,
        input: KeyboardServicesSuggestionRequestInput,
        localCandidates: [String],
        language: KeyboardLanguage,
        epoch: UInt64,
        contextToken: UInt64
    ) {
        inFlightEndpoints.insert(endpoint)
        requestTasks[endpoint] = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await KeyboardServicesSuggestionClient.request(
                endpoint: endpoint,
                server: server,
                input: input,
                localCandidates: localCandidates,
                language: language
            )
            await self?.complete(
                outcome,
                endpoint: endpoint,
                server: server,
                revision: revision,
                epoch: epoch,
                contextToken: contextToken
            )
        }
    }

    private func complete(
        _ outcome: KeyboardServicesSuggestionRequestOutcome,
        endpoint: KeyboardServicesSuggestionEndpoint,
        server: String,
        revision: UInt64,
        epoch: UInt64,
        contextToken: UInt64
    ) {
        inFlightEndpoints.remove(endpoint)
        requestTasks.removeValue(forKey: endpoint)

        switch outcome {
        case .candidates(let candidates):
            persistRecoveryIfNeeded(for: server)
            guard failover.revision == revision,
                  failover.pinnedServer != nil else { return }
            failover.recordSuccess(for: server)
            onCandidates?(endpoint, candidates, revision, epoch, contextToken)

        case .failure:
            persistFailure(for: server)
            guard failover.revision == revision,
                  failover.pinnedServer != nil else { return }
            let transition = failover.recordFailure(for: server)
            if transition.didReachThreshold {
                onAugmentationInvalidated?()
                logFailure(
                    .warn,
                    message: "keyboard service fallback advanced",
                    endpoint: endpoint,
                    failureCount: transition.count
                )
            } else if transition.count == 1 {
                logFailure(
                    .debug,
                    message: "keyboard service request failed",
                    endpoint: endpoint,
                    failureCount: transition.count
                )
            }

        case .unauthorized:
            persistFailure(for: server)
            guard failover.revision == revision,
                  failover.pinnedServer != nil else { return }
            let failureCount = failover.recordUnauthorized(for: server)
            onAugmentationInvalidated?()
            logFailure(
                .warn,
                message: "keyboard service server skipped after auth rejection",
                endpoint: endpoint,
                failureCount: failureCount
            )

        case .disabled:
            guard failover.revision == revision else { return }
            failover.recordDisabled(endpoint: endpoint, for: server)
            onAugmentationInvalidated?()

        case .tolerated, .cancelled:
            break
        }
    }

    private func persistFailure(for server: String) {
        telemetryReporter.recordFailure(for: server)
    }

    private func persistRecoveryIfNeeded(for server: String) {
        telemetryReporter.recordSuccess(for: server)
    }

    private func logFailure(
        _ level: LogLevel,
        message: String,
        endpoint: KeyboardServicesSuggestionEndpoint,
        failureCount: Int
    ) {
        let isWarning: Bool
        switch level {
        case .warn: isWarning = true
        case .debug, .info, .error: isWarning = false
        }
        let endpointName = endpoint.rawValue
        DispatchQueue.global(qos: .utility).async {
            let payload: [String: Any] = [
                "endpoint": endpointName,
                "consecutiveFailures": failureCount
            ]
            if isWarning {
                FileLogger.shared.warn(.network, message, payload: payload)
            } else {
                FileLogger.shared.debug(.network, message, payload: payload)
            }
        }
    }
}
