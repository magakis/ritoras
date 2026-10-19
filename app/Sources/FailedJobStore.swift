import Foundation

// MARK: - Failed Job Record

struct FailedJobRecord: Codable, Equatable {
    let jobId: UUID
    let audioFilePath: String
    var errorMessage: String
    let recordedDurationSeconds: Double
    let createdAt: Date
    var retryCount: Int
    var lastRetriedAt: Date?
    var server: String?

    enum CodingKeys: String, CodingKey {
        case jobId, audioFilePath, errorMessage, recordedDurationSeconds, createdAt, retryCount, lastRetriedAt, server
    }
}

enum PendingJobState: String, Codable {
    case recorded
    case submitting
    case accepted
    case syncFallback
    case ready
    case failed
}

struct PendingJobRecord: Codable, Equatable {
    let jobId: UUID
    let audioFilePath: String
    var candidateServer: String?
    var resolvedServer: String?
    let createdAt: Date
    var submittedAt: Date?
    var acceptedAt: Date?
    var terminalAt: Date?
    var state: PendingJobState
    var serverJobId: String?
    var statusEndpoint: String?
    var uploadBodyFilePath: String? = nil
    var uploadTerminalKind: String? = nil
    var uploadTerminalStatus: Int? = nil
    var uploadTerminalReason: String? = nil
    var uploadTerminalRecordedAt: Date? = nil
    var uploadTerminalNotifiedAt: Date? = nil
}

// Custom decoder for backward compatibility with old `audioFileName` key.
extension FailedJobRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decode(UUID.self, forKey: .jobId)
        audioFilePath = try container.decodeIfPresent(String.self, forKey: .audioFilePath) ?? ""
        errorMessage = try container.decode(String.self, forKey: .errorMessage)
        recordedDurationSeconds = try container.decode(Double.self, forKey: .recordedDurationSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        lastRetriedAt = try container.decodeIfPresent(Date.self, forKey: .lastRetriedAt)
        server = try container.decodeIfPresent(String.self, forKey: .server)
    }
}

// MARK: - FailedJobStore

/// Container-app-local store of transcription jobs that failed but have
/// audio preserved on disk for retry. Read on demand — no observers, no IPC.
///
/// Thread-safe via internal NSLock. Writes atomically to a single JSON file
/// at `{application-support}/failed-jobs.json`. Uses Application Support
/// (persistent, no entitlement needed, works under all installation methods).
///
/// This type MUST live in `app/Sources/` (not `shared/`) so the keyboard
/// target cannot link it — zero additional memory pressure on the extension.
final class FailedJobStore: @unchecked Sendable {
    static let shared = FailedJobStore()
    private let lock = NSLock()
    private var records: [FailedJobRecord] = []
    private var pendingRecords: [PendingJobRecord] = []

    private init() {
        load()
    }

    // MARK: - File URL

    private var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            FileLogger.shared.error(.app, "FailedJobStore: Application Support unavailable (should never happen)")
            return nil
        }
        return appSupport.appendingPathComponent("failed-jobs.json")
    }

    private var pendingFileURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent("pending-jobs.json")
    }

    // MARK: - Public API

    /// Appends a failed-job record. Deduplicates by `jobId` — if a record
    /// with the same `jobId` already exists, it is replaced.
    func append(_ record: FailedJobRecord) {
        lock.lock(); defer { lock.unlock() }
        if let index = records.firstIndex(where: { $0.jobId == record.jobId }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    /// Returns all stored failed-job records.
    func list() -> [FailedJobRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    /// Removes the record for the given `jobId`. No-op if not found.
    func remove(jobId: UUID) {
        lock.lock(); defer { lock.unlock() }
        records.removeAll(where: { $0.jobId == jobId })
        persist()
    }

    /// Removes a failed record only when that removal is durable. Unlike
    /// `remove`, this leaves the in-memory record intact if persistence fails.
    @discardableResult
    func removePersisted(jobId: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.jobId == jobId }) else { return true }
        let record = records.remove(at: index)
        guard persistRecords() else {
            records.insert(record, at: index)
            return false
        }
        return true
    }

    /// Increments the retry count and sets `lastRetriedAt` to now.
    func incrementRetry(jobId: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.jobId == jobId }) else { return }
        records[index].retryCount += 1
        records[index].lastRetriedAt = Date()
        persist()
    }

    /// Updates the error message for the given `jobId`. No-op if not found.
    func updateErrorMessage(jobId: UUID, message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.jobId == jobId }) else { return }
        records[index].errorMessage = message
        persist()
    }

    /// Updates the pinned server for the given job. No-op if the record is absent.
    func updateServer(jobId: UUID, server: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.jobId == jobId }) else { return }
        records[index].server = server
        persist()
    }

    /// Adds or replaces a pending job, keyed by its dictation UUID.
    @discardableResult
    func upsertPending(_ record: PendingJobRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let index = pendingRecords.firstIndex(where: { $0.jobId == record.jobId }) {
            let previous = pendingRecords[index]
            pendingRecords[index] = record
            guard persistPending() else {
                pendingRecords[index] = previous
                return false
            }
        } else {
            pendingRecords.append(record)
            guard persistPending() else {
                pendingRecords.removeLast()
                return false
            }
        }
        return true
    }

    /// Returns pending jobs. Active records are never subject to failed-job pruning.
    func listPending() -> [PendingJobRecord] {
        lock.lock(); defer { lock.unlock() }
        return pendingRecords
    }

    /// Replaces an existing pending job. Returns false if absent or persistence fails.
    @discardableResult
    func updatePending(_ record: PendingJobRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = pendingRecords.firstIndex(where: { $0.jobId == record.jobId }) else { return false }
        let previous = pendingRecords[index]
        pendingRecords[index] = record
        guard persistPending() else {
            pendingRecords[index] = previous
            return false
        }
        return true
    }

    /// Removes the durable recovery marker before optionally deleting its audio.
    /// Audio is retained if the updated pending file cannot be persisted.
    @discardableResult
    func removePending(jobId: UUID, deleteAudio: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = pendingRecords.firstIndex(where: { $0.jobId == jobId }) else { return false }
        let record = pendingRecords.remove(at: index)
        guard persistPending() else {
            pendingRecords.insert(record, at: index)
            return false
        }
        if deleteAudio {
            do {
                try FileManager.default.removeItem(atPath: record.audioFilePath)
            } catch {
                FileLogger.shared.error(.app, "FailedJobStore: pending audio deletion failed",
                                        payload: ["error": error.localizedDescription])
            }
        }
        return true
    }

    /// Removes records older than the given interval, along with their
    /// associated audio files via `RecordingStore`.
    func pruneOlderThan(_ interval: TimeInterval, relativeTo referenceDate: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = referenceDate.addingTimeInterval(-interval)
        let protectedAudioPaths = Set(pendingRecords.map(\.audioFilePath))
        let (kept, removed) = records.filteredSplit {
            $0.createdAt >= cutoff || protectedAudioPaths.contains($0.audioFilePath)
        }
        records = kept
        for record in removed {
            RecordingStore.shared.delete(jobId: record.jobId)
        }
        FileLogger.shared.debug(.app, "FailedJobStore: pruned \(removed.count) records",
                                payload: ["cutoff": cutoff, "remaining": kept.count])
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        _ = persistRecords()
    }

    @discardableResult
    private func persistRecords() -> Bool {
        guard let url = fileURL else { return false }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            FileLogger.shared.error(.app, "FailedJobStore: persist failed",
                                    payload: ["error": error.localizedDescription])
            return false
        }
    }

    @discardableResult
    private func persistPending() -> Bool {
        guard let url = pendingFileURL else { return false }
        do {
            let data = try JSONEncoder().encode(pendingRecords)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            FileLogger.shared.error(.app, "FailedJobStore: pending persist failed",
                                    payload: ["error": error.localizedDescription])
            return false
        }
    }

    private func load() {
        if let url = fileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([FailedJobRecord].self, from: data) {
            records = decoded
        }
        if let pendingURL = pendingFileURL,
           FileManager.default.fileExists(atPath: pendingURL.path),
           let pendingData = try? Data(contentsOf: pendingURL),
           let decodedPending = try? JSONDecoder().decode([PendingJobRecord].self, from: pendingData) {
            pendingRecords = decodedPending
        }
    }
}

// MARK: - Array Helper

private extension Array {
    /// Splits the array into two: elements matching the predicate (kept)
    /// and elements not matching (removed).
    func filteredSplit(_ isKept: (Element) throws -> Bool) rethrows -> (kept: [Element], removed: [Element]) {
        var kept: [Element] = []
        var removed: [Element] = []
        for element in self {
            if try isKept(element) {
                kept.append(element)
            } else {
                removed.append(element)
            }
        }
        return (kept, removed)
    }
}
