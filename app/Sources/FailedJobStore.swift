import Foundation

// MARK: - Failed Job Record

struct FailedJobRecord: Codable, Equatable {
    let jobId: UUID
    let audioFilePath: String
    let errorMessage: String
    let recordedDurationSeconds: Double
    let createdAt: Date
    var retryCount: Int
    var lastRetriedAt: Date?

    enum CodingKeys: String, CodingKey {
        case jobId, audioFilePath, errorMessage, recordedDurationSeconds, createdAt, retryCount, lastRetriedAt
    }
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

    /// Increments the retry count and sets `lastRetriedAt` to now.
    func incrementRetry(jobId: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.jobId == jobId }) else { return }
        records[index].retryCount += 1
        records[index].lastRetriedAt = Date()
        persist()
    }

    /// Removes records older than the given interval, along with their
    /// associated audio files via `RecordingStore`.
    func pruneOlderThan(_ interval: TimeInterval, relativeTo referenceDate: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = referenceDate.addingTimeInterval(-interval)
        let (kept, removed) = records.filteredSplit { $0.createdAt >= cutoff }
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
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            FileLogger.shared.error(.app, "FailedJobStore: persist failed",
                                    payload: ["error": error.localizedDescription])
        }
    }

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([FailedJobRecord].self, from: data)
        else {
            records = []
            return
        }
        records = decoded
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
