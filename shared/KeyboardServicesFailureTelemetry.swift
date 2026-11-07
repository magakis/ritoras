import Foundation

/// App Group telemetry written by the keyboard extension and read by app ranking.
/// Writers increment `revision` for every update, cap this server map, and reset a
/// server's failure count after a successful keyboard-service request.
struct KeyboardServicesFailureTelemetrySnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumServerCount = 64
    static let maximumServerURLLength = 512
    static let maximumConsecutiveFailures = 255

    let schemaVersion: Int
    let revision: UInt64
    let consecutiveFailuresByServer: [String: Int]

    /// Creates a version-1 telemetry snapshot with a caller-managed monotonic revision.
    init(revision: UInt64, consecutiveFailuresByServer: [String: Int]) {
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.consecutiveFailuresByServer = consecutiveFailuresByServer
    }

    /// Returns true only for a supported, bounded snapshot with a positive revision.
    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && revision > 0
            && consecutiveFailuresByServer.count <= Self.maximumServerCount
            && consecutiveFailuresByServer.allSatisfy { server, failures in
                !server.isEmpty
                    && failures >= 0
                    && failures <= Self.maximumConsecutiveFailures
            }
    }

    /// Returns the latest reported consecutive failures for a normalized server URL.
    func consecutiveFailures(for server: String) -> Int {
        consecutiveFailuresByServer[server] ?? 0
    }

    /// Computes a strictly increasing revision, returning nil rather than wrapping.
    static func nextRevision(after revision: UInt64) -> UInt64? {
        let (nextRevision, overflow) = revision.addingReportingOverflow(1)
        return overflow ? nil : nextRevision
    }
}

/// Bounded App Group writer for keyboard-service failure and recovery reports.
enum KeyboardServicesFailureTelemetryStore {
    private static let lock = NSLock()

    /// Increments one server's persisted consecutive-failure count.
    @discardableResult
    static func recordFailure(
        for server: String
    ) throws -> KeyboardServicesFailureTelemetrySnapshot {
        return try recordFailures(for: server, incrementBy: 1)
    }

    /// Applies a bounded batch of consecutive failures as one App Group update.
    @discardableResult
    static func recordFailures(
        for server: String,
        incrementBy: Int,
        resetBeforeIncrement: Bool = false
    ) throws -> KeyboardServicesFailureTelemetrySnapshot {
        guard incrementBy > 0,
              incrementBy <= KeyboardServicesFailureTelemetrySnapshot.maximumConsecutiveFailures,
              let snapshot = try update(
                server: server,
                failureIncrement: incrementBy,
                resetBeforeFailure: resetBeforeIncrement
              ) else {
            throw KeyboardServicesFailureTelemetryStoreError.invalidSnapshot
        }
        return snapshot
    }

    /// Resets a persisted failure count after a successful keyboard-service request.
    /// Returns nil when no recovery update is needed.
    @discardableResult
    static func recordSuccess(
        for server: String
    ) throws -> KeyboardServicesFailureTelemetrySnapshot? {
        try update(server: server, failureIncrement: nil, resetBeforeFailure: false)
    }

    private static func update(
        server: String,
        failureIncrement: Int?,
        resetBeforeFailure: Bool
    ) throws -> KeyboardServicesFailureTelemetrySnapshot? {
        let normalizedServer = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedServer.isEmpty,
              normalizedServer.utf8.count
                <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength else {
            throw KeyboardServicesFailureTelemetryStoreError.invalidServer
        }

        lock.lock()
        defer { lock.unlock() }

        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) else {
            throw KeyboardServicesFailureTelemetryStoreError.appGroupUnavailable
        }
        let previous = readSnapshot(from: defaults)
        var failuresByServer: [String: Int] = [:]
        for (storedServer, failures) in previous?.consecutiveFailuresByServer ?? [:]
            where storedServer.utf8.count
                <= KeyboardServicesFailureTelemetrySnapshot.maximumServerURLLength {
            failuresByServer[storedServer] = failures
        }
        let previousFailures = resetBeforeFailure
            ? 0
            : failuresByServer[normalizedServer] ?? 0
        guard failureIncrement != nil || previousFailures > 0 else { return nil }

        if let failureIncrement {
            if failuresByServer[normalizedServer] == nil,
               failuresByServer.count >= KeyboardServicesFailureTelemetrySnapshot.maximumServerCount {
                let leastRelevantServer = failuresByServer.min { left, right in
                    if left.value != right.value { return left.value < right.value }
                    return left.key < right.key
                }?.key
                if let leastRelevantServer {
                    failuresByServer.removeValue(forKey: leastRelevantServer)
                }
            }
            failuresByServer[normalizedServer] = min(
                previousFailures + failureIncrement,
                KeyboardServicesFailureTelemetrySnapshot.maximumConsecutiveFailures
            )
        } else {
            failuresByServer[normalizedServer] = 0
        }

        guard let revision = KeyboardServicesFailureTelemetrySnapshot.nextRevision(
            after: previous?.revision ?? 0
        ) else {
            throw KeyboardServicesFailureTelemetryStoreError.revisionExhausted
        }
        let snapshot = KeyboardServicesFailureTelemetrySnapshot(
            revision: revision,
            consecutiveFailuresByServer: failuresByServer
        )
        guard snapshot.isValid else {
            throw KeyboardServicesFailureTelemetryStoreError.invalidSnapshot
        }
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: SharedConfig.Defaults.keyboardServicesFailureTelemetryKey)
        return snapshot
    }

    private static func readSnapshot(
        from defaults: UserDefaults
    ) -> KeyboardServicesFailureTelemetrySnapshot? {
        guard let data = defaults.data(
            forKey: SharedConfig.Defaults.keyboardServicesFailureTelemetryKey
        ),
              let snapshot = try? JSONDecoder().decode(
                KeyboardServicesFailureTelemetrySnapshot.self,
                from: data
              ),
              snapshot.isValid else {
            return nil
        }
        return snapshot
    }
}

/// Errors returned when a bounded keyboard telemetry update cannot be persisted.
enum KeyboardServicesFailureTelemetryStoreError: Error {
    case appGroupUnavailable
    case invalidServer
    case revisionExhausted
    case invalidSnapshot
}
