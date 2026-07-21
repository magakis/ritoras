import Foundation

/// Manages recording audio files in the app-group container.
///
/// Files are stored at `{app-group}/Shared/recordings/{jobId}.m4a`.
/// The directory is created lazily on first access.
final class RecordingStore {
    static let shared = RecordingStore()
    private init() {}

    /// The recordings directory URL, created lazily. Returns nil if the
    /// app-group container is unavailable (misconfigured entitlement or
    /// SideStore edge case).
    var directoryURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else {
            FileLogger.shared.warn(.audio, "RecordingStore: app-group container unavailable")
            return nil
        }
        let dir = container.appendingPathComponent(SharedConfig.Recording.directoryName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the expected file URL for the given job ID, or nil if the
    /// directory is unavailable.
    func url(for jobId: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(jobId.uuidString).m4a")
    }

    /// Returns true if a recording file exists for the given job ID.
    func exists(jobId: UUID) -> Bool {
        guard let url = url(for: jobId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletes the recording file for the given job ID. No-op if the file
    /// does not exist or the directory is unavailable.
    func delete(jobId: UUID) {
        guard let url = url(for: jobId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes recording files whose modification time is older than the
    /// specified interval relative to `referenceDate`.
    func pruneOlderThan(_ interval: TimeInterval, relativeTo referenceDate: Date = Date()) {
        guard let dir = directoryURL else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = referenceDate.addingTimeInterval(-interval)

        for case let fileURL as URL in enumerator {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
