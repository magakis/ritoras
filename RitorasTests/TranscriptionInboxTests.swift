import XCTest
@testable import Ritoras

final class TranscriptionInboxTests: XCTestCase {

    private var tempDir: URL!
    private var inbox: TranscriptionInbox!
    private var appInbox: TranscriptionInbox!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        inbox = TranscriptionInbox(consumer: .keyboard, rootURL: tempDir)
        appInbox = TranscriptionInbox(consumer: .containerApp, rootURL: tempDir)
    }

    override func tearDown() {
        inbox = nil
        appInbox = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - 1. Create Requested

    func testCreateRequestedAssignsRevisionOne() throws {
        let id = UUID()
        let record = try inbox.createRequested(jobId: id)
        XCTAssertEqual(record.revision, 1)
        XCTAssertEqual(record.status, .requested)
        XCTAssertNil(record.completedAt)
    }

    func testCreateWithExplicitStatusReturnsThatStatus() throws {
        let id = UUID()
        let record = try inbox.create(jobId: id, status: .recording)
        XCTAssertEqual(record.status, .recording)
        XCTAssertEqual(record.revision, 1)
        XCTAssertNil(record.completedAt)
        XCTAssertEqual(record.createdAt.timeIntervalSince1970,
                       record.updatedAt.timeIntervalSince1970,
                       accuracy: 0.1)
        let fileURL = inbox.inboxDirectoryURL
            .appendingPathComponent("\(id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Record file should exist in the inbox directory")
    }

    // MARK: - 2. Monotonic Revision Across Instances

    func testNextRevisionMonotonicAcrossInstances() throws {
        let id1 = UUID(); _ = try inbox.createRequested(jobId: id1)
        let id2 = UUID(); _ = try inbox.createRequested(jobId: id2)
        let id3 = UUID(); _ = try inbox.createRequested(jobId: id3)

        // A separate instance backed by the same directory
        let secondInbox = TranscriptionInbox(consumer: .containerApp, rootURL: tempDir)
        XCTAssertEqual(secondInbox.nextRevision(), 4)
    }

    // MARK: - 3. Transition Updates Status And Text

    func testTransitionUpdatesStatusAndText() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)

        let r1 = try inbox.transition(jobId: id, to: .recording, text: nil, errorMessage: nil)
        XCTAssertEqual(r1.status, .recording)
        XCTAssertNil(r1.text)

        let r2 = try inbox.transition(jobId: id, to: .transcribing, text: nil, errorMessage: nil)
        XCTAssertEqual(r2.status, .transcribing)

        let r3 = try inbox.transition(jobId: id, to: .ready, text: "hello world", errorMessage: nil)
        XCTAssertEqual(r3.status, .ready)
        XCTAssertEqual(r3.text, "hello world")
        XCTAssertGreaterThan(r3.updatedAt, r2.updatedAt)
    }

    // MARK: - 4. Transition To Ready Sets CompletedAt

    func testTransitionToReadySetsCompletedAt() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)

        // Non-terminal transition — completedAt stays nil
        let r1 = try inbox.transition(jobId: id, to: .recording, text: nil, errorMessage: nil)
        XCTAssertNil(r1.completedAt)

        // Terminal transition — completedAt is set
        let r2 = try inbox.transition(jobId: id, to: .ready, text: "done", errorMessage: nil)
        XCTAssertNotNil(r2.completedAt)
        XCTAssertEqual(r2.completedAt, r2.updatedAt)

        // A fresh requested record should also have nil completedAt
        let id2 = UUID()
        let fresh = try inbox.createRequested(jobId: id2)
        XCTAssertNil(fresh.completedAt)
    }

    // MARK: - 5. Upsert Atomic Replace By JobId

    func testUpsertAtomicReplaceByJobId() throws {
        let id = UUID()
        var record = try inbox.createRequested(jobId: id)
        XCTAssertEqual(record.revision, 1)

        record.revision = 2
        record.text = "updated"
        try inbox.upsert(record)

        let loaded = inbox.read(jobId: id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.revision, 2)
        XCTAssertEqual(loaded?.text, "updated")
    }

    // MARK: - 6. List Unconsumed Excludes Self Consumed

    func testListUnconsumedExcludesSelfConsumed() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)
        _ = try inbox.transition(jobId: id, to: .ready, text: "data", errorMessage: nil)

        XCTAssertEqual(inbox.listUnconsumed().count, 1)

        try inbox.markConsumed(jobId: id)
        XCTAssertEqual(inbox.listUnconsumed().count, 0)
    }

    // MARK: - 7. Consumed Markers Are Per Consumer

    func testConsumedMarkersArePerConsumer() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)
        _ = try inbox.transition(jobId: id, to: .ready, text: "shared", errorMessage: nil)

        // Keyboard marks consumed
        try inbox.markConsumed(jobId: id)
        XCTAssertTrue(inbox.isConsumed(jobId: id))

        // Keyboard's list should exclude it
        XCTAssertTrue(inbox.listUnconsumed().isEmpty)

        // Container-app consumer's list should still include it
        let appUnconsumed = appInbox.listUnconsumed()
        XCTAssertEqual(appUnconsumed.count, 1)
        XCTAssertEqual(appUnconsumed[0].jobId, id)
    }

    // MARK: - 8. List In Flight Excludes Terminal Statuses

    func testListInFlightExcludesTerminalStatuses() throws {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        _ = try inbox.createRequested(jobId: id1)          // .requested — in-flight
        _ = try inbox.createRequested(jobId: id2)          // .requested — in-flight
        _ = try inbox.createRequested(jobId: id3)
        _ = try inbox.transition(jobId: id3, to: .ready, text: "term", errorMessage: nil)  // terminal

        let inFlight = inbox.listInFlight()
        let ids = Set(inFlight.map(\.jobId))
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
        XCTAssertFalse(ids.contains(id3))

        // Only terminal + non-terminal records in listInFlight
        for record in inFlight {
            XCTAssertTrue(record.status.isInFlight)
        }
    }

    // MARK: - 9. Latest Terminal Returns Highest Revision

    func testLatestTerminalReturnsHighestRevision() throws {
        let id1 = UUID(); _ = try inbox.createRequested(jobId: id1)
        _ = try inbox.transition(jobId: id1, to: .ready, text: "first", errorMessage: nil)

        let id2 = UUID(); _ = try inbox.createRequested(jobId: id2)
        _ = try inbox.transition(jobId: id2, to: .ready, text: "second", errorMessage: nil)

        let id3 = UUID(); _ = try inbox.createRequested(jobId: id3)  // revision 3
        _ = try inbox.transition(jobId: id3, to: .ready, text: "third", errorMessage: nil)

        let latest = inbox.latestTerminal()
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.revision, 3)
        XCTAssertEqual(latest?.text, "third")
    }

    // MARK: - 10. Mark Stale Transitions Old In-Flight To Failed

    func testMarkStaleTransitionsOldInFlightToFailed() throws {
        let id = UUID()
        // Create a record timestamped 10 minutes in the past
        let oldDate = Date().addingTimeInterval(-600)
        let staleRecord = TranscriptionRecord(
            jobId: id,
            revision: 1,
            status: .recording,
            text: nil,
            errorMessage: nil,
            createdAt: oldDate,
            updatedAt: oldDate,
            completedAt: nil
        )
        try inbox.upsert(staleRecord)

        try inbox.markStale(olderThan: 300) // 5-minute TTL

        let record = inbox.read(jobId: id)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.status, .failed)
        XCTAssertEqual(record?.errorMessage, "Stale: no update for 300 seconds")
        XCTAssertNotNil(record?.completedAt)
    }

    // MARK: - 11. Mark Stale Leaves Fresh In-Flight Alone

    func testMarkStaleLeavesFreshInFlightAlone() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id) // updatedAt = now

        try inbox.markStale(olderThan: 300) // 5-minute TTL

        let record = inbox.read(jobId: id)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.status, .requested) // unchanged
        XCTAssertNil(record?.errorMessage)
    }

    func testMarkStaleDetectsAbandonedRequestedRecord() throws {
        let id = UUID()
        // Create a record in .requested that was never transitioned.
        // Both createdAt and updatedAt are set to 10 minutes ago.
        let oldDate = Date().addingTimeInterval(-600)
        let abandonedRecord = TranscriptionRecord(
            jobId: id,
            revision: 1,
            status: .requested,
            text: nil,
            errorMessage: nil,
            createdAt: oldDate,
            updatedAt: oldDate,
            completedAt: nil
        )
        try inbox.upsert(abandonedRecord)

        try inbox.markStale(olderThan: 300) // 5-minute TTL

        let record = inbox.read(jobId: id)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.status, .failed,
                       "Abandoned .requested record should be marked as stale")
        XCTAssertEqual(record?.errorMessage, "Stale: no update for 300 seconds")
        XCTAssertNotNil(record?.completedAt)
    }

    // MARK: - 12. Archive If Both Consumed Moves File

    func testArchiveIfBothConsumedMovesFile() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)
        _ = try inbox.transition(jobId: id, to: .ready, text: "archive-me", errorMessage: nil)

        // Mark consumed by keyboard
        try inbox.markConsumed(jobId: id)
        // Mark consumed by app
        try appInbox.markConsumed(jobId: id)

        // Archive
        try inbox.archiveIfBothConsumed(jobId: id)

        let archivePath = tempDir
            .appendingPathComponent("Shared/archive")
            .appendingPathComponent("\(id.uuidString).json")
        let inboxPath = inbox.inboxDirectoryURL
            .appendingPathComponent("\(id.uuidString).json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath.path),
                      "Record should be in archive directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxPath.path),
                       "Record should NOT remain in inbox directory")
    }

    // MARK: - 13. Gc Archive Keeps Last N

    func testGcArchiveKeepsLastN() throws {
        // Create 10 records, consume, archive
        for i in 0..<10 {
            let id = UUID()
            _ = try inbox.createRequested(jobId: id)
            _ = try inbox.transition(jobId: id, to: .ready, text: "r\(i)", errorMessage: nil)
            try inbox.markConsumed(jobId: id)
            try appInbox.markConsumed(jobId: id)
            try inbox.archiveIfBothConsumed(jobId: id)
        }

        try inbox.gcArchive(keepingLast: 3)

        let archiveDir = tempDir
            .appendingPathComponent("Shared/archive")
        let remaining = try FileManager.default.contentsOfDirectory(
            at: archiveDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        XCTAssertEqual(remaining.count, 3,
                       "gcArchive should keep only the 3 most recent records by revision")
    }

    // MARK: - 14. Idempotent Mark Consumed

    func testIdempotentMarkConsumed() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)
        _ = try inbox.transition(jobId: id, to: .ready, text: "dup", errorMessage: nil)

        // First call
        try inbox.markConsumed(jobId: id)
        XCTAssertTrue(inbox.isConsumed(jobId: id))

        // Second call — should not throw, marker should still exist exactly once
        try inbox.markConsumed(jobId: id)
        XCTAssertTrue(inbox.isConsumed(jobId: id))
        XCTAssertTrue(inbox.listUnconsumed().isEmpty)
    }

    // MARK: - 15. Concurrent Upsert Same JobId Last Write Wins

    func testConcurrentUpsertSameJobIdLastWriteWins() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)

        // Read the base record once, then create two revisions to upsert
        guard let base = inbox.read(jobId: id) else {
            XCTFail("Failed to read initial record")
            return
        }
        var record10 = base; record10.revision = 10
        var record20 = base; record20.revision = 20

        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 {
                try! self.inbox.upsert(record10)
            } else {
                try! self.inbox.upsert(record20)
            }
        }

        // The file should contain exactly one intact record
        let finalRecord = inbox.read(jobId: id)
        XCTAssertNotNil(finalRecord, "Record should not be corrupted by concurrent writes")
        XCTAssertTrue(finalRecord!.revision == 10 || finalRecord!.revision == 20,
                      "Final revision should be either 10 or 20, got \(finalRecord!.revision)")
    }

    // MARK: - 16. Inbox Survives Instance Restart

    func testInboxSurvivesInstanceRestart() throws {
        let id = UUID()
        _ = try inbox.createRequested(jobId: id)
        _ = try inbox.transition(jobId: id, to: .ready, text: "persist", errorMessage: nil)

        // Dispose and recreate pointing at the same directory
        inbox = nil
        inbox = TranscriptionInbox(consumer: .keyboard, rootURL: tempDir)

        let loaded = inbox.read(jobId: id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.text, "persist")
        XCTAssertEqual(loaded?.status, .ready)
    }

    // MARK: - 17. Dispatch Source Fires On Atomic Write

    func testDispatchSourceFiresOnAtomicWrite() throws {
        let exp = expectation(description: "InboxWatcher callback fires on atomic write")
        var callbackFired = false

        let watcher = InboxWatcher(directoryURL: inbox.inboxDirectoryURL) {
            // Guard against over-fulfillment: directory writes may coalesce
            // (e.g. temp file creation + rename) and fire the source more
            // than once for a single logical write.
            if !callbackFired {
                callbackFired = true
                exp.fulfill()
            }
        }
        watcher.start()

        // Perform a write on a background queue so the watcher can observe it
        DispatchQueue.global().async {
            try! self.inbox.createRequested(jobId: UUID())
        }

        wait(for: [exp], timeout: 2.0)
        watcher.stop()
    }
}
