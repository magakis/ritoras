import Foundation

/// Thread-safe, idempotent, file-based inbox for transcription records, shared
/// between the keyboard extension and the container app via the app-group container.
///
/// ## Memory footprint
/// Each `TranscriptionInbox` instance holds one serial `DispatchQueue` (~KB) and
/// a few URL strings. No in-memory cache of inbox records — all state lives on
/// disk. Combined with `InboxWatcher`, the total overhead is <5 KB per instance.
/// This is critical because the keyboard extension operates under a 48 MB Jetsam
/// cap.
///
/// ## File layout
/// ```
/// <appGroup>/
///   Shared/
///     inbox/
///       <jobId>.json               — TranscriptionRecord
///       <jobId>.consumed-kb         — keyboard consumed this record
///       <jobId>.consumed-app        — container app consumed this record
///     archive/
///       <jobId>.json               — both consumers done, moved here by gcArchive
///     state/
///       last-revision              — monotonic counter (plain text integer)
/// ```
///
/// ## Important: file presenters prohibited
/// All file operations use `Data.write(to:options:.atomic)` or one-shot
/// `Data(contentsOf:)` reads. Do NOT keep an `NSFilePresenter` alive — the
/// keyboard extension may be terminated to prevent deadlock if backgrounded
/// with an active file presenter.
///
/// ## Thread safety
/// Every public mutating method serializes through the instance's private
/// `DispatchQueue` labeled `com.ritoras.transcription-inbox.<consumer>`.
/// Read-only methods also serialize to avoid observing partial cross-thread
/// writes (file-level atomicity only protects cross-process reads).

/// Identifies which consumer of the inbox is performing an operation.
///
/// Each consumer (keyboard extension or container app) tracks its own consumed
/// markers independently. Marker files encode the consumer name so the two
/// never conflict.
public enum TranscriptionConsumer: String, CaseIterable {
    case keyboard = "kb"
    case containerApp = "app"
}

public final class TranscriptionInbox {
    /// Errors specific to inbox operations.
    public enum Error: Swift.Error, LocalizedError {
        case recordNotFound(UUID)
        case containerUnavailable

        public var errorDescription: String? {
            switch self {
            case .recordNotFound(let id):
                return "TranscriptionRecord \(id) not found in inbox"
            case .containerUnavailable:
                return "App group container is not available"
            }
        }
    }

    // MARK: - Properties

    private let consumer: TranscriptionConsumer
    private let rootURL: URL
    private let queue: DispatchQueue

    // MARK: - Public accessors

    /// The inbox subdirectory (`Shared/inbox`) under the root URL.
    public var inboxDirectoryURL: URL {
        rootURL.appendingPathComponent(SharedConfig.Inbox.directoryName)
    }

    private var archiveDirectoryURL: URL {
        rootURL.appendingPathComponent(SharedConfig.Inbox.archiveDirectoryName)
    }

    private var stateDirectoryURL: URL {
        rootURL.appendingPathComponent(SharedConfig.Inbox.stateDirectoryName)
    }

    private var lastRevisionURL: URL {
        stateDirectoryURL.appendingPathComponent(SharedConfig.Inbox.lastRevisionFileName)
    }

    // MARK: - Initializers

    /// Creates an inbox backed by the app-group shared container.
    ///
    /// In production both targets use `group.com.ritoras.app`. If the container
    /// is unavailable (e.g. no entitlements in a test host), the init logs an
    /// error and falls back to a temporary directory so the instance can still
    /// be created without crashing. All subsequent file operations will fail at
    /// the I/O level.
    public convenience init(consumer: TranscriptionConsumer) {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) {
            self.init(consumer: consumer, rootURL: container)
        } else {
            FileLogger.shared.error(.transcription, "app group container unavailable — using temporary fallback directory")
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("ritoras-inbox-\(UUID().uuidString)")
            self.init(consumer: consumer, rootURL: fallback)
        }
    }

    /// Internal initializer that accepts an arbitrary root URL (for testing).
    ///
    /// Tests use this with a per-test temp directory. The public `init(consumer:)`
    /// delegates to this after resolving the app-group container URL.
    public init(consumer: TranscriptionConsumer, rootURL: URL) {
        self.consumer = consumer
        self.rootURL = rootURL
        self.queue = DispatchQueue(
            label: "com.ritoras.transcription-inbox.\(consumer.rawValue)",
            qos: .utility
        )

        // Ensure directory tree exists.
        let fm = FileManager.default
        for dir in [inboxDirectoryURL, archiveDirectoryURL, stateDirectoryURL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Writers

    /// Writes (or overwrites) a record in the inbox directory.
    ///
    /// - Parameter record: The record to persist. Its `jobId` determines the filename.
    /// - Throws: File I/O errors from `JSONEncoder` or `Data.write(to:options:.atomic)`.
    public func upsert(_ record: TranscriptionRecord) throws {
        try queue.sync {
            try self._upsert(record)
        }
    }

    /// Transitions a record to a new status, optionally setting text and error.
    ///
    /// - Parameters:
    ///   - jobId: Identifies the record to update.
    ///   - status: The new status.
    ///   - text: Transcription text (nullable).
    ///   - errorMessage: Error description (nullable).
    /// - Returns: The updated record, as persisted.
    /// - Throws: `Error.recordNotFound` if no record exists for `jobId`, or file I/O errors.
    @discardableResult
    public func transition(
        jobId: UUID,
        to status: TranscriptionStatus,
        text: String?,
        errorMessage: String?
    ) throws -> TranscriptionRecord {
        try queue.sync {
            guard var record = self._read(jobId: jobId) else {
                throw Error.recordNotFound(jobId)
            }
            record.status = status
            record.text = text
            record.errorMessage = errorMessage
            record.updatedAt = Date()
            if status.isTerminal {
                record.completedAt = record.updatedAt
            }
            try self._upsert(record)
            return record
        }
    }

    /// Creates a new record in `.requested` status with the next available revision.
    ///
    /// - Parameter jobId: The unique identifier for this transcription job.
    /// - Returns: The newly created record.
    /// - Throws: File I/O errors.
    @discardableResult
    public func createRequested(jobId: UUID) throws -> TranscriptionRecord {
        try queue.sync {
            let revision = self._nextRevision()
            let now = Date()
            let record = TranscriptionRecord(
                jobId: jobId,
                revision: revision,
                status: .requested,
                text: nil,
                errorMessage: nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            )
            try self._upsert(record)
            FileLogger.shared.info(.transcription, "createRequested jobId=\(jobId) revision=\(revision)")
            return record
        }
    }

    // MARK: - Readers

    /// Reads a single record from the inbox directory.
    ///
    /// - Parameter jobId: The record identifier.
    /// - Returns: The deserialized record, or `nil` if the file does not exist or is corrupt.
    public func read(jobId: UUID) -> TranscriptionRecord? {
        queue.sync {
            self._read(jobId: jobId)
        }
    }

    /// Returns all terminal records that have not been consumed by this consumer.
    public func listUnconsumed() -> [TranscriptionRecord] {
        queue.sync {
            self._listUnconsumed()
        }
    }

    /// Returns all records whose status is non-terminal (in-flight).
    public func listInFlight() -> [TranscriptionRecord] {
        queue.sync {
            self._listInFlight()
        }
    }

    /// Returns the unconsumed terminal record with the highest revision, or `nil`.
    ///
    /// This is the primary read path for the keyboard extension to discover new
    /// completed transcriptions.
    public func latestTerminal() -> TranscriptionRecord? {
        queue.sync {
            self._listUnconsumed().max { $0.revision < $1.revision }
        }
    }

    // MARK: - Consumed Markers (idempotent)

    /// Marks the record consumed by this inbox's consumer.
    ///
    /// Creates a zero-byte marker file `<jobId>.consumed-<consumer>` in the
    /// inbox directory. The operation is **idempotent** — calling it multiple
    /// times produces exactly one marker file.
    ///
    /// - Parameter jobId: The record to mark.
    /// - Throws: File I/O errors from `Data.write(to:options:.atomic)`.
    public func markConsumed(jobId: UUID) throws {
        try queue.sync {
            try self._markConsumed(jobId: jobId)
        }
    }

    /// Returns whether this consumer has already consumed the given record.
    ///
    /// - Parameter jobId: The record to check.
    /// - Returns: `true` if the marker file exists.
    public func isConsumed(jobId: UUID) -> Bool {
        queue.sync {
            self._isConsumed(jobId: jobId)
        }
    }

    // MARK: - Maintenance

    /// Transitions any in-flight record whose `updatedAt` is older than `ttl`
    /// seconds to `.failed` with a descriptive error message.
    ///
    /// This handles the case where the container app is killed mid-transcription
    /// — the inbox record would otherwise be stuck in `recording` / `transcribing`
    /// forever.
    ///
    /// - Parameter ttl: Age threshold in seconds.
    /// - Throws: File I/O errors.
    public func markStale(olderThan ttl: TimeInterval) throws {
        try queue.sync {
            let cutoff = Date().addingTimeInterval(-ttl)
            let inFlight = self._listInFlight()
            for var record in inFlight where record.updatedAt < cutoff {
                FileLogger.shared.warn(.transcription, "markStale jobId=\(record.jobId) updatedAt=\(record.updatedAt)")
                record.status = .failed
                record.errorMessage = "Stale: no update for \(Int(ttl)) seconds"
                record.updatedAt = Date()
                record.completedAt = record.updatedAt
                try self._upsert(record)
            }
        }
    }

    /// Moves the record JSON file from `inbox/` to `archive/` if both consumers
    /// have marked it consumed. Removes the consumed marker files on success.
    ///
    /// - Parameter jobId: The record to archive.
    /// - Throws: File I/O errors from `FileManager.moveItem`.
    public func archiveIfBothConsumed(jobId: UUID) throws {
        try queue.sync {
            try self._archiveIfBothConsumed(jobId: jobId)
        }
    }

    /// Deletes archived records beyond the `n` most recent (by revision).
    ///
    /// Designed to be called by the container app on launch.
    ///
    /// - Parameter n: Number of most-recent records to retain.
    /// - Throws: File I/O errors.
    public func gcArchive(keepingLast n: Int) throws {
        try queue.sync {
            try self._gcArchive(keepingLast: n)
        }
    }

    // MARK: - Watermark

    /// Atomically reads, increments, and writes the `state/last-revision` counter.
    ///
    /// The revision starts at 1 when the file does not exist. This value is used
    /// as a monotonic high-water mark for stale detection across process restarts.
    ///
    /// - Returns: The new revision value (incremented from the prior value on disk).
    public func nextRevision() -> Int {
        queue.sync {
            self._nextRevision()
        }
    }
}

// MARK: - Internal (call on queue)

extension TranscriptionInbox {
    private func _upsert(_ record: TranscriptionRecord) throws {
        let url = inboxDirectoryURL.appendingPathComponent("\(record.jobId.uuidString).json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    private func _read(jobId: UUID) -> TranscriptionRecord? {
        let url = inboxDirectoryURL.appendingPathComponent("\(jobId.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptionRecord.self, from: data)
    }

    private func _listUnconsumed() -> [TranscriptionRecord] {
        let jsonFiles = _inboxJSONFiles()
        return jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(TranscriptionRecord.self, from: data),
                  record.status.isTerminal,
                  !self._isConsumed(jobId: record.jobId)
            else { return nil }
            return record
        }
    }

    private func _listInFlight() -> [TranscriptionRecord] {
        let jsonFiles = _inboxJSONFiles()
        return jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(TranscriptionRecord.self, from: data),
                  record.status.isInFlight
            else { return nil }
            return record
        }
    }

    private func _inboxJSONFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: inboxDirectoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    private func _consumedMarkerURL(jobId: UUID) -> URL {
        inboxDirectoryURL.appendingPathComponent(
            "\(jobId.uuidString).consumed-\(consumer.rawValue)"
        )
    }

    private func _consumedMarkerURL(jobId: UUID, for otherConsumer: TranscriptionConsumer) -> URL {
        inboxDirectoryURL.appendingPathComponent(
            "\(jobId.uuidString).consumed-\(otherConsumer.rawValue)"
        )
    }

    private func _markConsumed(jobId: UUID) throws {
        let url = _consumedMarkerURL(jobId: jobId)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Data().write(to: url, options: .atomic)
    }

    private func _isConsumed(jobId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: _consumedMarkerURL(jobId: jobId).path)
    }

    private func _nextRevision() -> Int {
        let url = lastRevisionURL
        let current: Int
        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8),
           let value = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            current = value
        } else {
            current = 0
        }
        let next = current + 1
        try? "\(next)".write(to: url, atomically: true, encoding: .utf8)
        return next
    }

    private func _archiveIfBothConsumed(jobId: UUID) throws {
        let kbMarker = _consumedMarkerURL(jobId: jobId, for: .keyboard)
        let appMarker = _consumedMarkerURL(jobId: jobId, for: .containerApp)

        guard FileManager.default.fileExists(atPath: kbMarker.path),
              FileManager.default.fileExists(atPath: appMarker.path)
        else { return }

        let sourceURL = inboxDirectoryURL.appendingPathComponent("\(jobId.uuidString).json")
        let destURL = archiveDirectoryURL.appendingPathComponent("\(jobId.uuidString).json")

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        }

        try? FileManager.default.removeItem(at: kbMarker)
        try? FileManager.default.removeItem(at: appMarker)
    }

    private func _gcArchive(keepingLast n: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: archiveDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let records: [(URL, TranscriptionRecord)] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(TranscriptionRecord.self, from: data)
            else { return nil }
            return (url, record)
        }

        let sorted = records.sorted { $0.1.revision > $1.1.revision }
        guard sorted.count > n else { return }

        for (url, _) in sorted[n...] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
