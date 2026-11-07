import Foundation

/// Versioned runtime pin state shared by the app and keyboard extension.
struct KeyboardServicesPinSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: UInt64
    let pinnedServer: String?
    let rankedFallbackServers: [String]
    let slotAvailabilityByServer: [String: KeyboardServicesSlotAvailability]

    /// Creates a version-1 snapshot containing runtime state only, never server configuration.
    init(
        revision: UInt64,
        pinnedServer: String?,
        rankedFallbackServers: [String],
        slotAvailabilityByServer: [String: KeyboardServicesSlotAvailability]
    ) {
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            revision: revision,
            pinnedServer: pinnedServer,
            rankedFallbackServers: rankedFallbackServers,
            slotAvailabilityByServer: slotAvailabilityByServer
        )
    }

    private init(
        schemaVersion: Int,
        revision: UInt64,
        pinnedServer: String?,
        rankedFallbackServers: [String],
        slotAvailabilityByServer: [String: KeyboardServicesSlotAvailability]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.pinnedServer = pinnedServer
        self.rankedFallbackServers = rankedFallbackServers
        self.slotAvailabilityByServer = slotAvailabilityByServer
    }

    fileprivate func replacingRevision(_ revision: UInt64) -> KeyboardServicesPinSnapshot {
        KeyboardServicesPinSnapshot(
            schemaVersion: schemaVersion,
            revision: revision,
            pinnedServer: pinnedServer,
            rankedFallbackServers: rankedFallbackServers,
            slotAvailabilityByServer: slotAvailabilityByServer
        )
    }
}

/// Errors that prevent publishing a pin snapshot through the App Group channel.
enum KeyboardServicesPinSnapshotStoreError: Error {
    case appGroupUnavailable
    case unsupportedSchemaVersion(Int)
    case revisionExhausted
}

/// App Group snapshot channel for keyboard-services pins.
enum KeyboardServicesPinSnapshotStore {
    private static let publicationLock = NSLock()
    private static let fileDirectoryName = "KeyboardServicesPin"
    private static let fileName = "snapshot-v1.json"

    /// Reads the atomic file fast path first, then the App Group defaults snapshot.
    static func snapshot() -> KeyboardServicesPinSnapshot? {
        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) else {
            return nil
        }
        return readSnapshot(from: defaults)
    }

    /// Publishes with a strictly increasing revision: atomic file, App Group
    /// defaults, then notification. No `synchronize()` is used; cross-process
    /// defaults reads rely on `cfprefsd` visibility.
    @discardableResult
    static func publish(
        _ snapshot: KeyboardServicesPinSnapshot
    ) throws -> KeyboardServicesPinSnapshot {
        publicationLock.lock()
        defer { publicationLock.unlock() }

        guard snapshot.schemaVersion == KeyboardServicesPinSnapshot.currentSchemaVersion else {
            throw KeyboardServicesPinSnapshotStoreError.unsupportedSchemaVersion(
                snapshot.schemaVersion
            )
        }
        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) else {
            throw KeyboardServicesPinSnapshotStoreError.appGroupUnavailable
        }

        let previousRevision = readSnapshot(from: defaults)?.revision ?? 0
        let (nextRevision, overflow) = previousRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw KeyboardServicesPinSnapshotStoreError.revisionExhausted
        }
        let publication = snapshot.replacingRevision(max(snapshot.revision, nextRevision))
        let data = try JSONEncoder().encode(publication)

        if let fileURL = try snapshotFileURLForWriting() {
            try data.write(to: fileURL, options: .atomic)
        }
        defaults.set(data, forKey: SharedConfig.Defaults.keyboardServicesPinSnapshotKey)
        DarwinNotifier.post(SharedConfig.Defaults.darwinKeyboardServicesPinChangedNotificationName)
        return publication
    }

    private static func readSnapshot(from defaults: UserDefaults) -> KeyboardServicesPinSnapshot? {
        if let fileURL = snapshotFileURL(),
           let data = try? Data(contentsOf: fileURL),
           let snapshot = decodeSnapshot(data) {
            return snapshot
        }
        guard let data = defaults.data(
            forKey: SharedConfig.Defaults.keyboardServicesPinSnapshotKey
        ) else {
            return nil
        }
        return decodeSnapshot(data)
    }

    private static func decodeSnapshot(_ data: Data) -> KeyboardServicesPinSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(
            KeyboardServicesPinSnapshot.self,
            from: data
        ),
              snapshot.schemaVersion == KeyboardServicesPinSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    private static func snapshotFileURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else {
            return nil
        }
        return container
            .appendingPathComponent(fileDirectoryName)
            .appendingPathComponent(fileName)
    }

    private static func snapshotFileURLForWriting() throws -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else {
            return nil
        }
        let directory = container.appendingPathComponent(fileDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
}
