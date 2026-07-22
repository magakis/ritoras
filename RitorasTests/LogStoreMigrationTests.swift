import XCTest
@testable import Ritoras

final class LogStoreMigrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear LogStore and UserDefaults migration flags so each test starts clean
        LogStore.shared.clear()
        UserDefaults.standard.removeObject(forKey: "ritoras.logstore.migratedV1")
        UserDefaults.standard.removeObject(forKey: "ritoras.logstore.migratedV1.lastFile")

        // Clean up any stale flat files and archive dirs from prior runs
        if let dir = resolveTestDir() {
            cleanFlatFiles(in: dir)
            cleanArchiveDirs(in: dir)
        }
    }

    override func tearDown() {
        if let dir = resolveTestDir() {
            cleanFlatFiles(in: dir)
            cleanArchiveDirs(in: dir)
        }
        UserDefaults.standard.removeObject(forKey: "ritoras.logstore.migratedV1")
        UserDefaults.standard.removeObject(forKey: "ritoras.logstore.migratedV1.lastFile")
        super.tearDown()
    }

    // MARK: - Helpers

    /// Resolves the flat-file directory using the same logic as
    /// `LogStoreMigration.resolveDir()` (app-group container first, then Documents).
    private func resolveTestDir() -> URL? {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) {
            return container
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Writes an array of JSON-line strings to a flat file.
    private func writeFlatFile(_ url: URL, lines: [String]) throws {
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes all ritoras-debug.log flat files and temp files from a directory.
    private func cleanFlatFiles(in dir: URL) {
        let fm = FileManager.default
        let base = "ritoras-debug.log"
        // Remove .log.6 .. .log.1
        for i in 1...6 {
            let url = dir.appendingPathComponent("\(base).\(i)")
            try? fm.removeItem(at: url)
        }
        // Remove .log
        let url = dir.appendingPathComponent(base)
        try? fm.removeItem(at: url)
        // Remove temp file
        let tmp = dir.appendingPathComponent(".ritoras-debug-log.tmp")
        try? fm.removeItem(at: tmp)
    }

    /// Removes all archive directories matching `ritoras-debug.archived-*`.
    private func cleanArchiveDirs(in dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("ritoras-debug.archived-") {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Import

    func test_import() throws {
        guard let dir = resolveTestDir() else {
            XCTFail("No writable directory found")
            return
        }

        // Write .log.1 (older rolled file)
        let log1 = dir.appendingPathComponent("ritoras-debug.log.1")
        let log1Lines = [
            "{\"ts\":\"2026-07-22T10:00:00.000Z\",\"level\":\"info\",\"cat\":\"App\",\"msg\":\"older entry\"}",
            "{\"ts\":\"2026-07-22T10:00:01.000Z\",\"level\":\"warn\",\"cat\":\"Audio\",\"msg\":\"warning in audio\"}"
        ]
        try writeFlatFile(log1, lines: log1Lines)

        // Write .log (active file, newer)
        let log = dir.appendingPathComponent("ritoras-debug.log")
        let logLines = [
            "{\"ts\":\"2026-07-22T11:00:00.000Z\",\"level\":\"error\",\"cat\":\"Network\",\"msg\":\"connection lost\"}",
            "{\"ts\":\"2026-07-22T11:00:01.000Z\",\"level\":\"info\",\"cat\":\"Keyboard\",\"msg\":\"key pressed\",\"payload\":{\"key\":\"a\"}}"
        ]
        try writeFlatFile(log, lines: logLines)

        // Run migration
        LogStoreMigration.runIfNeeded()

        // Verify imported data (newest first = .log entries, then .log.1 entries)
        let lines = LogStore.shared.recent(limit: 10)
        XCTAssertEqual(lines.count, 4, "All 4 lines should be imported")

        // .log entries (newer) come first
        XCTAssertEqual(lines[0].message, "key pressed", "Line 0 should be from .log")
        XCTAssertEqual(lines[0].component, .keyboard)
        XCTAssertEqual(lines[0].level, .info)
        XCTAssertTrue(lines[0].raw.contains("key pressed"), "Raw column should contain original JSON line")

        XCTAssertEqual(lines[1].message, "connection lost", "Line 1 should be from .log")
        XCTAssertEqual(lines[1].component, .network)
        XCTAssertEqual(lines[1].level, .error)

        // .log.1 entries (older) come second
        XCTAssertEqual(lines[2].message, "warning in audio", "Line 2 should be from .log.1")
        XCTAssertEqual(lines[2].component, .audio)
        XCTAssertEqual(lines[2].level, .warn)

        XCTAssertEqual(lines[3].message, "older entry", "Line 3 should be from .log.1")
        XCTAssertEqual(lines[3].component, .app)
        XCTAssertEqual(lines[3].level, .info)
    }

    // MARK: - Idempotency

    func test_idempotency() throws {
        guard let dir = resolveTestDir() else {
            XCTFail("No writable directory found")
            return
        }

        let log = dir.appendingPathComponent("ritoras-debug.log")
        try writeFlatFile(log, lines: [
            "{\"ts\":\"2026-07-22T10:00:00.000Z\",\"level\":\"info\",\"cat\":\"App\",\"msg\":\"test\"}"
        ])

        // First run — should import
        LogStoreMigration.runIfNeeded()
        XCTAssertEqual(LogStore.shared.count(), 1, "First run should import the entry")

        // Second run — should be a no-op (migrated flag is set)
        LogStoreMigration.runIfNeeded()
        XCTAssertEqual(LogStore.shared.count(), 1, "Second run should not duplicate entries")
    }

    // MARK: - Resume after partial completion

    func test_resume_after_partial_completion() throws {
        guard let dir = resolveTestDir() else {
            XCTFail("No writable directory found")
            return
        }

        // Simulate a partially-completed migration: .log.2 was already imported
        // in a prior run, and now the migration resumes from .log.1.
        let log2 = dir.appendingPathComponent("ritoras-debug.log.2")
        try writeFlatFile(log2, lines: [
            "{\"ts\":\"2026-07-22T09:00:00.000Z\",\"level\":\"info\",\"cat\":\"App\",\"msg\":\"from log.2\"}"
        ])

        let log1 = dir.appendingPathComponent("ritoras-debug.log.1")
        try writeFlatFile(log1, lines: [
            "{\"ts\":\"2026-07-22T10:00:00.000Z\",\"level\":\"info\",\"cat\":\"App\",\"msg\":\"from log.1\"}"
        ])

        // Set lastFile flag so the migration skips .log.2
        UserDefaults.standard.set("ritoras-debug.log.2", forKey: "ritoras.logstore.migratedV1.lastFile")

        // Run migration — should start from .log.1 (after .log.2)
        LogStoreMigration.runIfNeeded()

        // Verify: only .log.1 entries were imported (.log.2 was skipped)
        let lines = LogStore.shared.recent(limit: 10)
        XCTAssertEqual(lines.count, 1, "Only .log.1 entries should be imported")
        XCTAssertEqual(lines.first?.message, "from log.1",
                       "Skipped .log.2, only imported .log.1")

        // Verify the migrated flag was set (successful completion)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ritoras.logstore.migratedV1"),
                       "Migrated flag should be set after successful completion")
    }

    // MARK: - Archival

    func test_archival() throws {
        guard let dir = resolveTestDir() else {
            XCTFail("No writable directory")
            return
        }

        let log = dir.appendingPathComponent("ritoras-debug.log")
        try writeFlatFile(log, lines: [
            "{\"ts\":\"2026-07-22T10:00:00.000Z\",\"level\":\"info\",\"cat\":\"App\",\"msg\":\"test\"}"
        ])

        // Verify file exists before migration
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "Flat file should exist before migration")

        LogStoreMigration.runIfNeeded()

        // Verify file no longer at original location
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path),
                       "Flat file should be removed after migration")

        // Verify it was moved to an archive directory
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let archiveDirs = contents.filter { $0.lastPathComponent.hasPrefix("ritoras-debug.archived-") }
        XCTAssertFalse(archiveDirs.isEmpty, "Archive directory should exist after migration")

        let archivedFile = archiveDirs[0].appendingPathComponent("ritoras-debug.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedFile.path),
                      "Log file should be present in the archive directory")
    }
}
