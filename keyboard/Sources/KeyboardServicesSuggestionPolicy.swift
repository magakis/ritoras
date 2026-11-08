import Foundation

/// Keyboard-service endpoints consumed after local suggestions are displayed.
enum KeyboardServicesSuggestionEndpoint: String, CaseIterable, Hashable, Sendable {
    case spelling
    case vocabulary
    case prediction
}

/// Small server result sets kept only to merge the current displayed bar.
struct KeyboardServicesSuggestionResults {
    var spelling: [String] = []
    var vocabulary: [String] = []
    var prediction: [String] = []

    mutating func set(_ candidates: [String], for endpoint: KeyboardServicesSuggestionEndpoint) {
        switch endpoint {
        case .spelling:
            spelling = candidates
        case .vocabulary:
            vocabulary = candidates
        case .prediction:
            prediction = candidates
        }
    }
}

/// Pure display-only merge policy for local and server-ranked suggestion strings.
enum KeyboardServicesSuggestionPolicy {
    static let maximumDisplayedCandidates = 3
    static let maximumCandidateScalars = 128

    /// Merges cached server results only when they belong to the current render context.
    static func mergeForDisplay(
        localCandidates: [String],
        serverResults: KeyboardServicesSuggestionResults?,
        localContextToken: UInt64,
        serverContextToken: UInt64?,
        serverRevisionMatches: Bool,
        isEmptyPrefix: Bool,
        localEpoch: UInt64? = nil,
        serverEpoch: UInt64? = nil,
        strictRemoteOnly: Bool = false
    ) -> [String] {
        guard serverRevisionMatches,
              !strictRemoteOnly || (localEpoch != nil && serverEpoch == localEpoch),
              localContextToken != 0,
              serverContextToken == localContextToken,
              let serverResults else {
            if strictRemoteOnly { return [] }
            return Array(localCandidates.prefix(maximumDisplayedCandidates))
        }
        return merge(
            localCandidates: localCandidates,
            serverResults: serverResults,
            isEmptyPrefix: isEmptyPrefix,
            strictRemoteOnly: strictRemoteOnly
        )
    }

    /// Reorders/adds candidates only in the bar; the prediction engine never sees these values.
    static func merge(
        localCandidates: [String],
        serverResults: KeyboardServicesSuggestionResults,
        isEmptyPrefix: Bool,
        strictRemoteOnly: Bool = false
    ) -> [String] {
        let orderedCandidates: [String]
        if strictRemoteOnly {
            // Prediction rank only reorders client-supplied candidates; filtering local
            // overlap would make every strict next-word bar empty and mislead diagnosis.
            orderedCandidates = isEmptyPrefix
                ? serverResults.prediction
                : serverResults.spelling + serverResults.vocabulary
        } else if isEmptyPrefix {
            let localByFoldedText = Set(localCandidates.map { $0.lowercased() })
            let rankedLocal = serverResults.prediction.filter {
                localByFoldedText.contains($0.lowercased())
            }
            orderedCandidates = rankedLocal + localCandidates
        } else {
            orderedCandidates = serverResults.spelling
                + serverResults.vocabulary
                + localCandidates
        }

        var seen: Set<String> = []
        return orderedCandidates.filter { candidate in
            seen.insert(candidate.lowercased()).inserted
        }.prefix(maximumDisplayedCandidates).map { $0 }
    }
}

/// State for consuming one pinned server and its ordered fallback list.
struct KeyboardServicesSuggestionFailover {
    private(set) var revision: UInt64? = nil
    private(set) var pinnedServer: String? = nil
    private(set) var fallbackServers: [String] = []
    private(set) var activeFallbackIndex = 0
    private(set) var consecutiveFailuresByServer: [String: Int] = [:]

    private var slotAvailabilityByServer: [String: KeyboardServicesSlotAvailability] = [:]
    private var disabledEndpointsByServer: [String: Set<KeyboardServicesSuggestionEndpoint>] = [:]
    private var skippedServers: Set<String> = []
    private var unauthorizedServers: Set<String> = []

    private let failureThreshold = SharedConfig.Defaults.keyboardServicesFailureTelemetryThreshold

    /// Applies a snapshot only when its pin is still present in the configured server list.
    /// A new revision resets all process-local failure and capability latches.
    @discardableResult
    mutating func update(
        snapshot: KeyboardServicesPinSnapshot?,
        configuredServers: [String]
    ) -> Bool {
        let oldRevision = revision
        let oldPinnedServer = pinnedServer
        let oldFallbackServers = fallbackServers
        let oldAvailability = slotAvailabilityByServer
        let oldActiveServer = activeFallbackServer

        let configured = Set(configuredServers
            .prefix(KeyboardServicesFailureTelemetrySnapshot.maximumServerCount)
            .map(Self.normalizeServer)
            .filter {
                !$0.isEmpty
                    && $0.utf8.count
                        <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength
            })
        let nextRevision = snapshot?.revision
        let revisionChanged = nextRevision != nil && nextRevision != revision
        if revisionChanged {
            activeFallbackIndex = 0
            consecutiveFailuresByServer.removeAll(keepingCapacity: true)
            disabledEndpointsByServer.removeAll(keepingCapacity: true)
            skippedServers.removeAll(keepingCapacity: true)
            unauthorizedServers.removeAll(keepingCapacity: true)
        }
        revision = nextRevision

        guard let snapshot,
              snapshot.schemaVersion == KeyboardServicesPinSnapshot.currentSchemaVersion,
              snapshot.revision > 0,
              let pin = snapshot.pinnedServer.map(Self.normalizeServer),
              !pin.isEmpty,
              pin.utf8.count
                <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength,
              configured.contains(pin),
              snapshot.rankedFallbackServers.count
                <= KeyboardServicesFailureTelemetrySnapshot.maximumServerCount,
              snapshot.rankedFallbackServers.allSatisfy({
                  $0.utf8.count <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength
              }),
              snapshot.slotAvailabilityByServer.count
                <= KeyboardServicesFailureTelemetrySnapshot.maximumServerCount,
              snapshot.slotAvailabilityByServer.keys.allSatisfy({
                  $0.utf8.count <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength
              }) else {
            pinnedServer = nil
            fallbackServers = []
            slotAvailabilityByServer = [:]
            activeFallbackIndex = 0
            return revisionChanged
                || oldPinnedServer != nil
                || !oldFallbackServers.isEmpty
                || !oldAvailability.isEmpty
        }

        let normalizedFallbacks = Self.uniqueServers(snapshot.rankedFallbackServers)
        guard normalizedFallbacks.first == pin else {
            pinnedServer = nil
            fallbackServers = []
            slotAvailabilityByServer = [:]
            activeFallbackIndex = 0
            return revisionChanged
                || oldPinnedServer != nil
                || !oldFallbackServers.isEmpty
                || !oldAvailability.isEmpty
        }

        let nextFallbackServers = normalizedFallbacks.filter(configured.contains)
        guard nextFallbackServers.first == pin else {
            pinnedServer = nil
            fallbackServers = []
            slotAvailabilityByServer = [:]
            activeFallbackIndex = 0
            return revisionChanged
                || oldPinnedServer != nil
                || !oldFallbackServers.isEmpty
                || !oldAvailability.isEmpty
        }

        var nextAvailability: [String: KeyboardServicesSlotAvailability] = [:]
        for (server, availability) in snapshot.slotAvailabilityByServer {
            let normalizedServer = Self.normalizeServer(server)
            guard configured.contains(normalizedServer) else { continue }
            nextAvailability[normalizedServer] = availability
        }

        if !revisionChanged {
            if let oldActiveServer,
               let newIndex = nextFallbackServers.firstIndex(of: oldActiveServer) {
                activeFallbackIndex = newIndex
            } else {
                activeFallbackIndex = min(activeFallbackIndex, nextFallbackServers.count)
            }
        }
        pinnedServer = pin
        fallbackServers = nextFallbackServers
        slotAvailabilityByServer = nextAvailability

        return revisionChanged
            || oldRevision != revision
            || oldPinnedServer != pinnedServer
            || oldFallbackServers != fallbackServers
            || oldAvailability != slotAvailabilityByServer
    }

    /// Returns the first fallback at or after the active index that offers this endpoint.
    func server(for endpoint: KeyboardServicesSuggestionEndpoint) -> String? {
        guard activeFallbackIndex < fallbackServers.count else { return nil }
        for server in fallbackServers[activeFallbackIndex...] {
            guard !skippedServers.contains(server),
                  !unauthorizedServers.contains(server),
                  disabledEndpointsByServer[server]?.contains(endpoint) != true,
                  let availability = slotAvailabilityByServer[server],
                  Self.isAvailable(endpoint, in: availability) else {
                continue
            }
            return server
        }
        return nil
    }

    /// Resets local consecutive failures after a successful endpoint response.
    mutating func recordSuccess(for server: String) {
        let normalizedServer = Self.normalizeServer(server)
        consecutiveFailuresByServer[normalizedServer] = 0
        skippedServers.remove(normalizedServer)
    }

    /// Advances past a server after repeated failures and reports whether the threshold was reached.
    mutating func recordFailure(for server: String) -> (count: Int, didReachThreshold: Bool) {
        let normalizedServer = Self.normalizeServer(server)
        let nextCount = min(
            (consecutiveFailuresByServer[normalizedServer] ?? 0) + 1,
            KeyboardServicesFailureTelemetrySnapshot.maximumConsecutiveFailures
        )
        consecutiveFailuresByServer[normalizedServer] = nextCount
        let didReachThreshold = nextCount >= failureThreshold
            && !skippedServers.contains(normalizedServer)
        if nextCount >= failureThreshold {
            skippedServers.insert(normalizedServer)
            advancePastServer(normalizedServer)
        }
        return (nextCount, didReachThreshold)
    }

    /// Skips an unauthorized server until a new snapshot revision arrives.
    mutating func recordUnauthorized(for server: String) -> Int {
        let normalizedServer = Self.normalizeServer(server)
        let nextCount = min(
            (consecutiveFailuresByServer[normalizedServer] ?? 0) + 1,
            KeyboardServicesFailureTelemetrySnapshot.maximumConsecutiveFailures
        )
        consecutiveFailuresByServer[normalizedServer] = nextCount
        unauthorizedServers.insert(normalizedServer)
        advancePastServer(normalizedServer)
        return nextCount
    }

    /// Latches a server-reported disabled slot until the next snapshot revision.
    mutating func recordDisabled(
        endpoint: KeyboardServicesSuggestionEndpoint,
        for server: String
    ) {
        let normalizedServer = Self.normalizeServer(server)
        disabledEndpointsByServer[normalizedServer, default: []].insert(endpoint)
    }

    private var activeFallbackServer: String? {
        guard activeFallbackIndex < fallbackServers.count else { return nil }
        return fallbackServers[activeFallbackIndex]
    }

    private mutating func advancePastServer(_ server: String) {
        guard let index = fallbackServers.firstIndex(of: server),
              index == activeFallbackIndex else { return }
        activeFallbackIndex = index + 1
    }

    private static func isAvailable(
        _ endpoint: KeyboardServicesSuggestionEndpoint,
        in availability: KeyboardServicesSlotAvailability
    ) -> Bool {
        switch endpoint {
        case .spelling: return availability.spelling
        case .vocabulary: return availability.vocabulary
        case .prediction: return availability.prediction
        }
    }

    private static func normalizeServer(_ server: String) -> String {
        server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func uniqueServers(_ servers: [String]) -> [String] {
        var seen: Set<String> = []
        return servers.compactMap { server in
            let normalized = normalizeServer(server)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
