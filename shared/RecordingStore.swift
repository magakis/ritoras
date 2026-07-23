import Foundation

/// Manages recording audio files in the Application Support directory.
///
/// Files are stored at `{application-support}/Recordings/{jobId}.m4a`.
/// The directory is created lazily on first access. Application Support is
/// persistent (survives app suspension and process death) and works under
/// all installation methods (App Store, SideStore, AltStore, Simulator).
final class RecordingStore {
    static let shared = RecordingStore()
    private init() {}

    /// The recordings directory URL, created lazily. Uses Application Support
    /// (always available on iOS, no entitlement needed, survives process death).
    /// Returns nil only if the Application Support directory itself is unavailable
    /// (should never happen in practice).
    var directoryURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            FileLogger.shared.error(.audio, "RecordingStore: Application Support unavailable (should never happen)")
            return nil
        }
        let dir = appSupport.appendingPathComponent("Recordings")
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

    /// Returns the expected WAV stream file URL for the given job ID, or nil
    /// if the directory is unavailable.
    func streamWavURL(for jobId: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(jobId.uuidString).stream.wav")
    }

    /// Deletes the WAV stream file for the given job ID. No-op if the file
    /// does not exist or the directory is unavailable.
    func deleteStreamWav(for jobId: UUID) {
        guard let url = streamWavURL(for: jobId) else { return }
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
