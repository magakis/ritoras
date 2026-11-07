import Foundation

/// One server's last-known `/slots` catalog and the time it was observed.
struct PersistedServerSlotsCatalogEntry: Codable, Equatable, Sendable {
    let server: String
    let catalog: ServerSlotCatalog?
    let catalogTimestamp: Date?
    let lastProbeTimestamp: Date?
}

/// App-local versioned catalog retained for later Settings capability badges.
struct PersistedServerSlotsCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let timestamp: Date
    let entries: [PersistedServerSlotsCatalogEntry]

    /// Creates a version-1 catalog in current configured-server order.
    init(timestamp: Date, entries: [PersistedServerSlotsCatalogEntry]) {
        schemaVersion = Self.currentSchemaVersion
        self.timestamp = timestamp
        self.entries = entries
    }

    /// Rejects unsupported or ambiguous catalog state before Settings consumes it.
    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && Set(entries.map(\.server)).count == entries.count
            && entries.allSatisfy { entry in
                !entry.server.isEmpty
                    && (entry.catalog == nil || entry.catalogTimestamp != nil)
            }
    }
}

/// Pure result of one app-side keyboard-services pin recomputation.
struct KeyboardServicesPinRoundUpdate {
    let snapshot: KeyboardServicesPinSnapshot
    let shouldPublishSnapshot: Bool
    let persistedCatalog: PersistedServerSlotsCatalog
}

/// Recomputes keyboard-service state independently from the dictation ranking.
enum KeyboardServicesPinRoundIntegrator {
    /// Combines timely slot probes, breaker state, and extension failures into a new snapshot.
    static func recompute(
        configuredServers: [String],
        slotOutcomesByServer: [String: ServerSlotsProbeOutcome],
        breakerOpenServers: Set<String>,
        failureTelemetry: KeyboardServicesFailureTelemetrySnapshot?,
        previousSnapshot: KeyboardServicesPinSnapshot?,
        previousCatalog: PersistedServerSlotsCatalog?,
        timestamp: Date
    ) -> KeyboardServicesPinRoundUpdate {
        let servers = normalizedUniqueServers(configuredServers)
        var configuredIndexes: [String: Int] = [:]
        for (index, server) in servers.enumerated() {
            configuredIndexes[server] = index
        }

        let availabilityByServer = Dictionary(
            uniqueKeysWithValues: servers.map { server in
                (
                    server,
                    slotOutcomesByServer[server]?.keyboardServicesAvailability ?? .unavailable
                )
            }
        )
        let candidates = servers.compactMap { server -> KeyboardServicesPinCandidate? in
            guard let outcome = slotOutcomesByServer[server],
                  let configuredIndex = configuredIndexes[server] else {
                return nil
            }
            return KeyboardServicesPinCandidate(
                outcome: outcome,
                configuredIndex: configuredIndex,
                circuitBreakerOpen: breakerOpenServers.contains(server)
            )
        }
        let eligibleSelection = KeyboardServicesPinSelector.select(candidates: candidates)
        let preferredFallbackServers = eligibleSelection.rankedFallbackServers.filter { server in
            guard let failureTelemetry else { return true }
            return failureTelemetry.consecutiveFailures(for: server)
                < SharedConfig.Defaults.keyboardServicesFailureTelemetryThreshold
        }
        let telemetryDemotedServers = eligibleSelection.rankedFallbackServers.filter { server in
            guard let failureTelemetry else { return false }
            return failureTelemetry.consecutiveFailures(for: server)
                >= SharedConfig.Defaults.keyboardServicesFailureTelemetryThreshold
        }
        // Keep flagged servers in the tail so a fallback success can report recovery.
        // If all breaker-eligible capable servers are flagged, keep the best one
        // pinned: the passive extension requires the pin first to consume anything.
        let rankedFallbackServers = preferredFallbackServers + telemetryDemotedServers
        let selection = KeyboardServicesPinSelectionResult(
            pinnedServer: preferredFallbackServers.first ?? telemetryDemotedServers.first,
            rankedFallbackServers: rankedFallbackServers,
            slotAvailabilityByServer: availabilityByServer
        )
        let snapshot = KeyboardServicesPinSnapshot(
            revision: previousSnapshot?.revision ?? 0,
            pinnedServer: selection.pinnedServer,
            rankedFallbackServers: selection.rankedFallbackServers,
            slotAvailabilityByServer: selection.slotAvailabilityByServer
        )

        let persistedCatalog = mergePersistedCatalog(
            configuredServers: servers,
            slotOutcomesByServer: slotOutcomesByServer,
            previousCatalog: previousCatalog,
            timestamp: timestamp
        )
        let serverListChanged = didConfiguredServerListChange(
            currentServers: servers,
            previousSnapshot: previousSnapshot,
            previousCatalog: previousCatalog
        )
        let shouldPublishSnapshot = previousSnapshot == nil
            || serverListChanged
            || previousSnapshot?.pinnedServer != snapshot.pinnedServer
            || previousSnapshot?.rankedFallbackServers != snapshot.rankedFallbackServers
            || previousSnapshot?.slotAvailabilityByServer != snapshot.slotAvailabilityByServer

        return KeyboardServicesPinRoundUpdate(
            snapshot: snapshot,
            shouldPublishSnapshot: shouldPublishSnapshot,
            persistedCatalog: persistedCatalog
        )
    }

    private static func mergePersistedCatalog(
        configuredServers: [String],
        slotOutcomesByServer: [String: ServerSlotsProbeOutcome],
        previousCatalog: PersistedServerSlotsCatalog?,
        timestamp: Date
    ) -> PersistedServerSlotsCatalog {
        let previousEntries = Dictionary(
            uniqueKeysWithValues: (previousCatalog?.entries ?? []).map { ($0.server, $0) }
        )
        let entries = configuredServers.map { server in
            let previous = previousEntries[server]
            let outcome = slotOutcomesByServer[server]
            let successfulCatalog = outcome?.statusCode == 200 ? outcome?.catalog : nil

            return PersistedServerSlotsCatalogEntry(
                server: server,
                catalog: successfulCatalog ?? previous?.catalog,
                catalogTimestamp: successfulCatalog == nil
                    ? previous?.catalogTimestamp
                    : timestamp,
                lastProbeTimestamp: outcome == nil
                    ? previous?.lastProbeTimestamp
                    : timestamp
            )
        }
        return PersistedServerSlotsCatalog(timestamp: timestamp, entries: entries)
    }

    private static func didConfiguredServerListChange(
        currentServers: [String],
        previousSnapshot: KeyboardServicesPinSnapshot?,
        previousCatalog: PersistedServerSlotsCatalog?
    ) -> Bool {
        if let previousCatalog {
            return previousCatalog.entries.map(\.server) != currentServers
        }
        guard let previousSnapshot else { return true }
        return Set(previousSnapshot.slotAvailabilityByServer.keys) != Set(currentServers)
    }

    private static func normalizedUniqueServers(_ servers: [String]) -> [String] {
        var seen: Set<String> = []
        return servers.compactMap { server in
            let normalized = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
