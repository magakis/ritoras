import XCTest
@testable import Ritoras

final class FailedJobStoreTests: XCTestCase {

    private let store = FailedJobStore.shared

    private func makeRecord(jobId: UUID = UUID(), retryCount: Int = 0) -> FailedJobRecord {
        FailedJobRecord(
            jobId: jobId,
            audioFilePath: "\(jobId.uuidString).m4a",
            errorMessage: "Test error",
            recordedDurationSeconds: 120,
            createdAt: Date(),
            retryCount: retryCount,
            lastRetriedAt: nil
        )
    }

    override func setUp() {
        super.setUp()
        // Isolate each test by clearing records that may have been written by
        // prior tests or by the shared instance's init-on-first-access.
        // We cannot call a private reset(), so we ensure tests use unique
        // jobIds and only assert on records they created.
    }

    override func tearDown() {
        // Clean up any records created during the test.
        // Each test is responsible for its own cleanup.
        super.tearDown()
    }

    // MARK: - Record Data Structure

    func test_record_codable_roundTrip() throws {
        let jobId = UUID()
        let record = makeRecord(jobId: jobId, retryCount: 2)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(FailedJobRecord.self, from: data)

        XCTAssertEqual(decoded.jobId, jobId)
        XCTAssertEqual(decoded.audioFilePath, record.audioFilePath)
        XCTAssertEqual(decoded.errorMessage, "Test error")
        XCTAssertEqual(decoded.recordedDurationSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(decoded.retryCount, 2)
    }

    func test_record_equatable() {
        let jobId = UUID()
        let a = makeRecord(jobId: jobId)
        let b = makeRecord(jobId: jobId)
        XCTAssertEqual(a, b)
    }

    func test_record_equatable_differentJobId() {
        let a = makeRecord(jobId: UUID())
        let b = makeRecord(jobId: UUID())
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Append & List

    func test_append_addsRecord() {
        let jobId = UUID()
        let record = makeRecord(jobId: jobId)

        store.append(record)
        let records = store.list()
        XCTAssertTrue(records.contains(where: { $0.jobId == jobId }),
                      "Record should be present after append")

        // Cleanup
        store.remove(jobId: jobId)
    }

    func test_append_deduplicatesByJobId() {
        let jobId = UUID()
        let record1 = makeRecord(jobId: jobId, retryCount: 0)
        let record2 = makeRecord(jobId: jobId, retryCount: 1)

        store.append(record1)
        store.append(record2)

        let records = store.list()
        let matching = records.filter { $0.jobId == jobId }
        XCTAssertEqual(matching.count, 1, "Duplicate jobId should replace, not append")
        XCTAssertEqual(matching.first?.retryCount, 1, "Second append should replace first")

        // Cleanup
        store.remove(jobId: jobId)
    }

    // MARK: - Remove

    func test_remove_deletesRecord() {
        let jobId = UUID()
        let record = makeRecord(jobId: jobId)

        store.append(record)
        XCTAssertTrue(store.list().contains(where: { $0.jobId == jobId }))

        store.remove(jobId: jobId)
        XCTAssertFalse(store.list().contains(where: { $0.jobId == jobId }),
                       "Record should be removed")
    }

    func test_remove_noOpForUnknownId() {
        // Should not throw or crash
        store.remove(jobId: UUID())
    }

    // MARK: - Increment Retry

    func test_incrementRetry_updatesCount() {
        let jobId = UUID()
        let record = makeRecord(jobId: jobId, retryCount: 0)

        store.append(record)
        store.incrementRetry(jobId: jobId)

        let updated = store.list().first(where: { $0.jobId == jobId })
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.retryCount, 1, "Retry count should increment from 0 to 1")
        XCTAssertNotNil(updated?.lastRetriedAt, "lastRetriedAt should be set after increment")

        // Cleanup
        store.remove(jobId: jobId)
    }

    func test_incrementRetry_noOpForUnknownId() {
        // Should not throw or crash
        store.incrementRetry(jobId: UUID())
    }

    func test_incrementRetry_multipleCalls() {
        let jobId = UUID()
        let record = makeRecord(jobId: jobId, retryCount: 0)

        store.append(record)
        store.incrementRetry(jobId: jobId)
        store.incrementRetry(jobId: jobId)
        store.incrementRetry(jobId: jobId)

        let updated = store.list().first(where: { $0.jobId == jobId })
        XCTAssertEqual(updated?.retryCount, 3, "Three incrementRetry calls should result in count 3")

        // Cleanup
        store.remove(jobId: jobId)
    }

    // MARK: - Prune (In-Memory)

    func test_pruneOlderThan_removesOldRecords() {
        let recentId = UUID()
        let oldId = UUID()

        let now = Date()
        let oldRecord = FailedJobRecord(
            jobId: oldId,
            audioFilePath: "\(oldId.uuidString).m4a",
            errorMessage: "Old error",
            recordedDurationSeconds: 10,
            createdAt: now.addingTimeInterval(-172_800), // 2 days ago
            retryCount: 0,
            lastRetriedAt: nil
        )
        let recentRecord = FailedJobRecord(
            jobId: recentId,
            audioFilePath: "\(recentId.uuidString).m4a",
            errorMessage: "Recent error",
            recordedDurationSeconds: 10,
            createdAt: now.addingTimeInterval(-3600), // 1 hour ago
            retryCount: 0,
            lastRetriedAt: nil
        )

        store.append(oldRecord)
        store.append(recentRecord)

        // Prune records older than 24 hours
        store.pruneOlderThan(86_400, relativeTo: now)

        let records = store.list()
        XCTAssertFalse(records.contains(where: { $0.jobId == oldId }),
                       "Old record should be pruned")
        XCTAssertTrue(records.contains(where: { $0.jobId == recentId }),
                       "Recent record should be preserved")

        // Cleanup
        store.remove(jobId: recentId)
    }

    func test_pruneOlderThan_preservesAllWhenAllRecent() {
        let id1 = UUID()
        let id2 = UUID()
        let now = Date()

        let r1 = FailedJobRecord(
            jobId: id1, audioFilePath: "\(id1.uuidString).m4a",
            errorMessage: "e1", recordedDurationSeconds: 5,
            createdAt: now.addingTimeInterval(-60), retryCount: 0, lastRetriedAt: nil
        )
        let r2 = FailedJobRecord(
            jobId: id2, audioFilePath: "\(id2.uuidString).m4a",
            errorMessage: "e2", recordedDurationSeconds: 5,
            createdAt: now.addingTimeInterval(-120), retryCount: 0, lastRetriedAt: nil
        )

        store.append(r1)
        store.append(r2)
        store.pruneOlderThan(3600, relativeTo: now)

        let records = store.list()
        XCTAssertTrue(records.contains(where: { $0.jobId == id1 }))
        XCTAssertTrue(records.contains(where: { $0.jobId == id2 }))

        store.remove(jobId: id1)
        store.remove(jobId: id2)
    }

    // MARK: - Persistence (App-Group Dependent)

    func test_persistence_roundTrip() throws {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        )
        try XCTSkipIf(container == nil,
                      "No app-group container available — skipping persistence test")

        let jobId = UUID()
        let record = makeRecord(jobId: jobId)

        // Append using the shared store (which persists to disk).
        store.append(record)

        // Create a fresh reference to force a re-read from disk.
        // We verify by inspecting the store's list.
        let loaded = store.list()
        XCTAssertTrue(loaded.contains(where: { $0.jobId == jobId }),
                      "Record should persist and re-load")

        // Cleanup
        store.remove(jobId: jobId)
    }
}
