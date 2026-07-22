import XCTest
@testable import Ritoras

final class FileLoggerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear LogStore for container-app path tests
        LogStore.shared.clear()

        // Clean flat files for keyboard-mode tests
        FileLogger.forceKeyboardModeForTesting = true
        FileLogger.clear()
        if let dir = FileLogger.fileURL()?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(".ritoras-debug-log.tmp"))
        }
        FileLogger.forceKeyboardModeForTesting = false
    }

    override func tearDown() {
        FileLogger.forceKeyboardModeForTesting = false
        super.tearDown()
    }

    // MARK: - Container-app facade (LogStore path)

    func test_logStore_path_writes_record() {
        let payload: [String: Any] = ["key": "value"]
        FileLogger.shared.log(.warn, .audio, "facade test message", payload: payload)

        let lines = LogStore.shared.recent(limit: 10)
        let match = lines.first { $0.message == "facade test message" }
        XCTAssertNotNil(match, "Message should be stored in LogStore via FileLogger facade")
        XCTAssertEqual(match?.level, .warn)
        XCTAssertEqual(match?.component, .audio)
        XCTAssertEqual(match?.payload?["key"] as? String, "value")
    }

    // MARK: - Rotation

    func test_rotation_triggers_at_threshold() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping rotation test")

        let dir = FileLogger.fileURL()!.deletingLastPathComponent()
        let base = "ritoras-debug.log"
        let rolled1 = dir.appendingPathComponent("\(base).1")

        // Remove any pre-existing rolled file
        try? FileManager.default.removeItem(at: rolled1)

        // Each line with a 10_000-char message is ~10 KB.
        // 1 MB / 10 KB ≈ 104 lines to exceed rotation threshold.  Write 150 to be safe.
        let msg = String(repeating: "x", count: 10_000)
        for _ in 0..<150 {
            FileLogger.shared.log(.info, .keyboard, msg)
        }

        // Sync point — wait for all async writes to complete
        _ = FileLogger.contents()

        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled1.path),
                      "After writing enough data, .log.1 should exist (rotation triggered)")
    }

    func test_multi_file_shift_chain() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping rotation test")

        let dir = FileLogger.fileURL()!.deletingLastPathComponent()
        let base = "ritoras-debug.log"

        // Clean up existing rolled files
        for i in 1...7 {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).\(i)"))
        }

        // ~104 lines per rotation → 5 rotations = ~520 lines.  Write 700 for safety.
        let msg = String(repeating: "x", count: 10_000)
        for _ in 0..<700 {
            FileLogger.shared.log(.info, .keyboard, msg)
        }

        // Sync point
        _ = FileLogger.contents()

        let rolled5 = dir.appendingPathComponent("\(base).5")
        let rolled6 = dir.appendingPathComponent("\(base).6")
        let rolled7 = dir.appendingPathComponent("\(base).7")

        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled5.path),
                      ".log.5 should exist after 5+ rotations")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled6.path),
                      ".log.6 should exist and be the oldest retained file (maxRolledFiles = 6)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolled7.path),
                       ".log.7 should NOT exist (maxRolledFiles = 6)")
    }

    // MARK: - JSON round-trip

    func test_json_line_round_trip() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping round-trip test")

        FileLogger.clear()

        let payload: [String: Any] = ["key1": "value1", "key2": 42]
        FileLogger.shared.log(.warn, .audio, "test message", payload: payload)

        // Sync point (warn is sync, but contents() also syncs the queue)
        _ = FileLogger.contents()

        let lines = FileLogger.parsedLines()
        XCTAssertFalse(lines.isEmpty, "Should have parsed at least one line")

        let lastLine = lines.last!
        XCTAssertEqual(lastLine.message, "test message")
        XCTAssertEqual(lastLine.component, .audio)
        XCTAssertEqual(lastLine.level, .warn)

        if let parsedPayload = lastLine.payload {
            XCTAssertEqual(parsedPayload["key1"] as? String, "value1")
            XCTAssertEqual(parsedPayload["key2"] as? Int, 42)
        } else {
            XCTFail("Payload should be present in parsed line")
        }
    }

    // MARK: - Plain-text back-compat

    func test_plain_text_back_compat() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping back-compat test")

        FileLogger.clear()

        // Write a synthetic plain-text line directly to the file (bypassing the
        // JSON-lines writer) to test the fallback parser.
        let url = FileLogger.fileURL()!
        let plainTextLine = "2026-07-20T12:34:56.789Z [WARN] [Audio] test message\n"
        try plainTextLine.write(to: url, atomically: true, encoding: .utf8)

        let lines = FileLogger.parsedLines()
        XCTAssertFalse(lines.isEmpty, "Should have parsed at least one line")

        let line = lines.first!
        XCTAssertEqual(line.level, .warn,
                       "Fallback parser should extract level from plain text")
        XCTAssertNil(line.message,
                     "message should be nil for plain text fallback")
        XCTAssertNil(line.payload,
                     "payload should be nil for plain text fallback")
    }

    // MARK: - PII Scrubbing

    func test_pii_scrub_email_redaction() {
        let result = LogScrubber.scrub("contact user@example.com today")
        XCTAssertTrue(result.contains("[REDACTED:email]"),
                      "Email should be replaced with [REDACTED:email]")
        XCTAssertFalse(result.contains("user@example.com"),
                       "Email value should not appear in scrubbed output")
    }

    func test_pii_scrub_url_strips_query() {
        let result = LogScrubber.scrub(
            "see https://whisper.example.com/transcribe?token=secret123")
        XCTAssertTrue(result.contains("https://whisper.example.com/transcribe[?]"),
                      "URL query should be replaced with [?]")
        XCTAssertFalse(result.contains("token=secret123"),
                       "Query parameter should not appear in scrubbed output")
    }

    // MARK: - Level filter

    func test_level_filter() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping level filter test")

        FileLogger.clear()

        FileLogger.shared.log(.info, .keyboard, "info message")
        FileLogger.shared.log(.warn, .keyboard, "warn message")
        FileLogger.shared.log(.error, .keyboard, "error message")

        // Sync point
        _ = FileLogger.contents()

        let lines = FileLogger.parsedLines()
        let warnLines = lines.filter { $0.level == .warn }

        XCTAssertEqual(warnLines.count, 1, "Should find exactly 1 warn line")
        XCTAssertEqual(warnLines.first?.message, "warn message")
    }

    // MARK: - Append-only regression tests

    func test_append_after_rotation_writes_to_active_file() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping test")

        FileLogger.clear()

        let dir = FileLogger.fileURL()!.deletingLastPathComponent()
        let base = "ritoras-debug.log"
        let rolled1 = dir.appendingPathComponent("\(base).1")

        // Remove any pre-existing rolled file
        try? FileManager.default.removeItem(at: rolled1)

        // Write enough data to trigger rotation (~1 MB)
        let msg = String(repeating: "x", count: 10_000)
        for _ in 0..<150 {
            FileLogger.shared.log(.info, .keyboard, msg)
        }

        // Sync point
        _ = FileLogger.contents()

        XCTAssertTrue(FileManager.default.fileExists(atPath: rolled1.path),
                      "Rotation should have created .log.1")

        // Append one fresh identifiable line
        FileLogger.shared.log(.info, .keyboard, "FRESH_LINE_AFTER_ROTATION")
        _ = FileLogger.contents()

        // The fresh line MUST be in the active file
        let content = FileLogger.contents() ?? ""
        XCTAssertTrue(content.contains("FRESH_LINE_AFTER_ROTATION"),
                      "Fresh line should appear in active log after rotation")

        // The fresh line MUST NOT be in .log.1 (pre-rotation snapshot)
        if FileManager.default.fileExists(atPath: rolled1.path) {
            let rolledContent = try String(contentsOf: rolled1, encoding: .utf8)
            XCTAssertFalse(rolledContent.contains("FRESH_LINE_AFTER_ROTATION"),
                           "Fresh line should NOT appear in .log.1")
        }
    }

    func test_append_is_additive_not_full_rewrite() throws {
        FileLogger.forceKeyboardModeForTesting = true
        defer { FileLogger.forceKeyboardModeForTesting = false }

        try XCTSkipIf(FileLogger.fileURL() == nil,
                      "No app group container available — skipping test")

        FileLogger.clear()

        // Write a large base (~500 KB)
        let baseMsg = String(repeating: "y", count: 500_000)
        FileLogger.shared.log(.info, .keyboard, baseMsg)
        _ = FileLogger.contents() // sync point

        let url = FileLogger.fileURL()!
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        let sizeBefore = attrsBefore[.size] as! Int64

        // Append one short line
        FileLogger.shared.log(.info, .keyboard, "additive_test")
        _ = FileLogger.contents() // sync point

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        let sizeAfter = attrsAfter[.size] as! Int64

        let growth = sizeAfter - sizeBefore
        // Growth must be small (one log line ~100 bytes), not ~500 KB (full rewrite)
        XCTAssertLessThan(growth, 1_000, "Growth should be roughly one log line (~100 bytes), not ~500 KB")
        XCTAssertGreaterThan(growth, 0, "File size must increase after append")
        // Crucially: new size must not be ~2× base (which would indicate full-rewrite)
        XCTAssertLessThan(sizeAfter, sizeBefore * 2, "New size must not double (would indicate full-rewrite)")
    }
}
