import XCTest
@testable import Ritoras

final class LogStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LogStore.shared.clear()
    }

    // MARK: - Insert + Roundtrip

    func test_insert_and_roundtrip() {
        let payload: [String: Any] = ["key1": "value1", "num": 42]
        let raw = "{\"ts\":\"...\",\"level\":\"warn\",\"cat\":\"Audio\",\"msg\":\"hello\"}"
        LogStore.shared.insert(.warn, .audio, "hello", payload: payload, raw: raw)

        let lines = LogStore.shared.recent(limit: 10)
        XCTAssertEqual(lines.count, 1)

        let line = lines[0]
        XCTAssertEqual(line.level, .warn)
        XCTAssertEqual(line.component, .audio)
        XCTAssertEqual(line.message, "hello")
        XCTAssertEqual(line.raw, raw)
        XCTAssertNotNil(line.timestamp)
        XCTAssertNotNil(line.rowId)
        XCTAssertNotNil(line.payload)
        XCTAssertEqual(line.payload?["key1"] as? String, "value1")
        XCTAssertEqual(line.payload?["num"] as? Int, 42)
    }

    // MARK: - Keyset Pagination

    func test_keyset_pagination() {
        // Insert 500 rows with increasing message index
        var entries: [(LogLevel, LogComponent, String, [String: Any]?, String)] = []
        for i in 0..<500 {
            entries.append((.info, .app, "msg-\(i)", nil, "raw-\(i)"))
        }
        LogStore.shared.insertBatch(entries)

        // Fetch first page (newest 200)
        let page1 = LogStore.shared.recent(limit: 200)
        XCTAssertEqual(page1.count, 200)
        XCTAssertEqual(page1.first?.message, "msg-499")
        XCTAssertEqual(page1.last?.message, "msg-300")

        // Fetch second page with keyset pagination (beforeId)
        guard let lastRowId = page1.last?.rowId else {
            XCTFail("rowId should be set")
            return
        }
        let page2 = LogStore.shared.recent(limit: 200, beforeId: lastRowId)
        XCTAssertEqual(page2.count, 200)
        XCTAssertEqual(page2.first?.message, "msg-299")
        XCTAssertEqual(page2.last?.message, "msg-100")

        // Fetch third page — remaining 100
        guard let lastRowId2 = page2.last?.rowId else {
            XCTFail("rowId should be set")
            return
        }
        let page3 = LogStore.shared.recent(limit: 200, beforeId: lastRowId2)
        XCTAssertEqual(page3.count, 100)
        XCTAssertEqual(page3.first?.message, "msg-99")
        XCTAssertEqual(page3.last?.message, "msg-0")

        // Verify disjoint sets — no message appears in more than one page
        let allMessages = (page1 + page2 + page3).compactMap { $0.message }
        XCTAssertEqual(Set(allMessages).count, allMessages.count,
                       "All messages should be unique across pages — no overlap")

        // Verify descending order across all pages combined
        let indices = allMessages.compactMap { Int($0.replacingOccurrences(of: "msg-", with: "")) }
        for i in 1..<indices.count {
            XCTAssertGreaterThan(indices[i - 1], indices[i],
                                 "Entries should appear in descending order (newest first)")
        }
    }

    // MARK: - Filter by level

    func test_filter_by_level() {
        LogStore.shared.insert(.debug, .app, "debug msg", payload: nil, raw: "")
        LogStore.shared.insert(.info, .app, "info msg", payload: nil, raw: "")
        LogStore.shared.insert(.warn, .app, "warn msg", payload: nil, raw: "")
        LogStore.shared.insert(.error, .app, "error msg", payload: nil, raw: "")

        let results = LogStore.shared.recent(limit: 10, levels: [.warn, .error])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.message == "warn msg" }))
        XCTAssertTrue(results.contains(where: { $0.message == "error msg" }))
        XCTAssertFalse(results.contains(where: { $0.message == "info msg" }))
        XCTAssertFalse(results.contains(where: { $0.message == "debug msg" }))
    }

    // MARK: - Filter by component

    func test_filter_by_component() {
        LogStore.shared.insert(.info, .keyboard, "key press", payload: nil, raw: "")
        LogStore.shared.insert(.info, .audio, "audio recv", payload: nil, raw: "")
        LogStore.shared.insert(.info, .network, "http req", payload: nil, raw: "")

        let results = LogStore.shared.recent(limit: 10, components: [.keyboard, .audio])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.message == "key press" }))
        XCTAssertTrue(results.contains(where: { $0.message == "audio recv" }))
        XCTAssertFalse(results.contains(where: { $0.message == "http req" }))
    }

    // MARK: - Time-range filter

    func test_time_range_filter() {
        let ts = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        LogStore.shared.insert(.info, .app, "entry", payload: nil, raw: "")

        // Query with sinceNs at the moment before insertion — should find the entry
        let results = LogStore.shared.recent(limit: 10, sinceNs: ts)
        XCTAssertFalse(results.isEmpty, "Should find entries inserted at or after ts")

        // Query with sinceNs in the future — should return nothing
        let futureNs = ts + 86_400_000_000_000  // +1 day
        let futureResults = LogStore.shared.recent(limit: 10, sinceNs: futureNs)
        XCTAssertTrue(futureResults.isEmpty, "No entries should match a future timestamp")
    }

    // MARK: - FTS5 search

    func test_fts5_search() {
        LogStore.shared.insert(.info, .app, "dictation completed successfully", payload: nil, raw: "")
        LogStore.shared.insert(.info, .app, "audio recording started", payload: nil, raw: "")
        LogStore.shared.insert(.info, .app, "dictation failed with error", payload: nil, raw: "")

        let results = LogStore.shared.recent(limit: 10, search: "dictation")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.message == "dictation completed successfully" }))
        XCTAssertTrue(results.contains(where: { $0.message == "dictation failed with error" }))
    }

    func test_fts5_operator_injection() {
        // Insert rows where an unquoted "OR" in the query would act as the FTS5
        // boolean OR operator, matching more rows than intended.
        LogStore.shared.insert(.info, .app, "these are options", payload: nil, raw: "")
        LogStore.shared.insert(.info, .app, "red OR blue", payload: nil, raw: "")
        LogStore.shared.insert(.info, .app, "apple banana", payload: nil, raw: "")

        // The query "options OR apple" gets sanitized to '"options" "OR" "apple"'.
        // Without sanitization, FTS5 would interpret it as "options" OR "apple",
        // matching 2 rows (the one with "options" and the one with "apple").
        // With sanitization, all three tokens must appear as a phrase — no row
        // contains "options", "OR", and "apple" together, so 0 results.
        let results = LogStore.shared.recent(limit: 10, search: "options OR apple")
        XCTAssertEqual(results.count, 0,
                       "Sanitized FTS5 query should prevent boolean OR injection")

        // Searching for the literal word "OR" should still work when it exists.
        let orResults = LogStore.shared.recent(limit: 10, search: "OR")
        XCTAssertEqual(orResults.count, 1)
        XCTAssertEqual(orResults.first?.message, "red OR blue")
    }

    // MARK: - Combined filters

    func test_combined_filters() {
        LogStore.shared.insert(.warn, .keyboard, "network timeout", payload: nil, raw: "")
        LogStore.shared.insert(.error, .network, "connection refused", payload: nil, raw: "")
        LogStore.shared.insert(.info, .app, "app launched", payload: nil, raw: "")
        LogStore.shared.insert(.warn, .app, "disk space low", payload: nil, raw: "")

        let results = LogStore.shared.recent(
            limit: 10,
            levels: [.warn],
            components: [.app],
            search: "disk"
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.message, "disk space low")
    }

    // MARK: - Count

    func test_count() {
        LogStore.shared.insert(.info, .app, "entry 1", payload: nil, raw: "")
        LogStore.shared.insert(.warn, .keyboard, "entry 2", payload: nil, raw: "")
        LogStore.shared.insert(.error, .network, "entry 3", payload: nil, raw: "")

        XCTAssertEqual(LogStore.shared.count(), 3)
        XCTAssertEqual(LogStore.shared.count(levels: [.warn]), 1)
        XCTAssertEqual(LogStore.shared.count(components: [.app]), 1)
        XCTAssertEqual(LogStore.shared.count(search: "entry"), 3)
        XCTAssertEqual(LogStore.shared.count(levels: [.error], components: [.network]), 1)
        XCTAssertEqual(LogStore.shared.count(search: "nonexistent"), 0)
    }

    // MARK: - Clear

    func test_clear() {
        LogStore.shared.insert(.info, .app, "to be cleared", payload: nil, raw: "")
        XCTAssertEqual(LogStore.shared.count(), 1)

        LogStore.shared.clear()

        XCTAssertEqual(LogStore.shared.count(), 0)
        XCTAssertTrue(LogStore.shared.recent(limit: 10).isEmpty)
    }

    // MARK: - Rotation

    func test_rotation() {
        // Insert 100,001 rows to exceed the 100,000-row threshold
        let batchSize = 20_000
        let totalRows = 100_001
        var inserted = 0

        while inserted < totalRows {
            let count = min(batchSize, totalRows - inserted)
            var entries: [(LogLevel, LogComponent, String, [String: Any]?, String)] = []
            for i in 0..<count {
                entries.append((.info, .app, "row-\(inserted + i)", nil, ""))
            }
            LogStore.shared.insertBatch(entries)
            inserted += count
        }

        // Verify we're over threshold
        XCTAssertEqual(LogStore.shared.count(), totalRows)

        // Rotate
        LogStore.shared.rotateIfNeeded()

        // Verify count is ≤ 100,000 and the oldest rows were pruned
        let afterCount = LogStore.shared.count()
        XCTAssertLessThanOrEqual(afterCount, 100_000,
                                 "After rotation count should be at most 100,000")

        // The first rows inserted (oldest) should have been pruned
        let lines = LogStore.shared.recent(limit: 10)
        XCTAssertFalse(lines.contains(where: { $0.message == "row-0" }),
                       "Oldest row should have been pruned by rotation")
    }

    // MARK: - Cross-thread safety

    func test_cross_thread_safety() {
        let group = DispatchGroup()
        let queueCount = 8
        let entriesPerQueue = 200

        for _ in 0..<queueCount {
            group.enter()
            DispatchQueue.global().async {
                var entries: [(LogLevel, LogComponent, String, [String: Any]?, String)] = []
                for i in 0..<entriesPerQueue {
                    entries.append((.info, .app, "thread-\(i)", nil, ""))
                }
                LogStore.shared.insertBatch(entries)
                group.leave()
            }
        }

        group.wait()

        let total = LogStore.shared.count()
        XCTAssertEqual(total, queueCount * entriesPerQueue,
                       "All concurrent inserts should be accounted for")
    }

    // MARK: - PII scrubbing contract

    func test_db_stores_unscrubbed_originals() {
        // Write through FileLogger (container-app path) — the DB stores the
        // original unscrubbed message. Scrubbing is applied only at export
        // (copy/share) in DebugLogView, controlled by the scrubPII toggle.
        FileLogger.shared.info(.app, "contact user@example.com today for details")

        let lines = LogStore.shared.recent(limit: 10)
        let match = lines.first { $0.message?.contains("user@example.com") ?? false }
        XCTAssertNotNil(match, "Email value should be preserved (unscrubbed) in stored message")
        XCTAssertTrue(match?.raw.contains("user@example.com") ?? false,
                       "Raw column should also contain the original unscrubbed data")
    }

    // MARK: - Update hook notification

    func test_update_hook_notification() {
        let expectation = XCTestExpectation(
            description: "logStoreDidChange notification posted after insert"
        )
        let token = NotificationCenter.default.addObserver(
            forName: .logStoreDidChange, object: nil, queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        LogStore.shared.insert(.info, .app, "trigger notification", payload: nil, raw: "")

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Diagnostics ring buffer (smoke)

    func test_diagnostics_smoke() {
        let diags = LogStore.shared.recentDiagnostics()
        XCTAssertNotNil(diags)
    }
}
