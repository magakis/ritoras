import XCTest
@testable import Ritoras

final class RecordingStoreTests: XCTestCase {
    private let store = RecordingStore.shared

    override func tearDown() {
        super.tearDown()
        // Clean up any test files created during tests
        if let dir = store.directoryURL {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    /// Writes a small valid audio file at the given URL so exists() returns true.
    private func placeFile(for jobId: UUID) {
        guard let url = store.url(for: jobId) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write at least 1 byte so the file is "present"
        FileManager.default.createFile(atPath: url.path, contents: Data("test".utf8))
    }

    /// Sets the modification date of a file so pruneOlderThan can test age.
    private func setModificationDate(for jobId: UUID, to date: Date) {
        guard let url = store.url(for: jobId) else { return }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Directory Creation

    func test_directory_created_lazily_on_first_access() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping directory creation test")

        let dir = try XCTUnwrap(store.directoryURL)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, "Directory should exist")
        XCTAssertTrue(isDir.boolValue, "Path should be a directory")
    }

    // MARK: - URL Resolution

    func test_url_for_returns_expected_path() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping URL test")

        let jobId = UUID()
        let url = try XCTUnwrap(store.url(for: jobId))
        XCTAssertEqual(url.lastPathComponent, "\(jobId.uuidString).m4a")
        // Verify it's under the recordings directory
        let dir = try XCTUnwrap(store.directoryURL)
        XCTAssertTrue(url.path.hasPrefix(dir.path))
    }

    // MARK: - Existence

    func test_exists_returns_false_for_unknown_jobId() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping exists test")

        let unknownId = UUID()
        XCTAssertFalse(store.exists(jobId: unknownId))
    }

    func test_exists_returns_true_after_placement() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping exists test")

        let jobId = UUID()
        placeFile(for: jobId)
        XCTAssertTrue(store.exists(jobId: jobId))
    }

    // MARK: - Delete

    func test_delete_no_op_for_missing_jobId() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping delete test")

        let missingId = UUID()
        // Should not throw or crash
        store.delete(jobId: missingId)
        XCTAssertFalse(store.exists(jobId: missingId))
    }

    func test_delete_removes_existing_file() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping delete test")

        let jobId = UUID()
        placeFile(for: jobId)
        XCTAssertTrue(store.exists(jobId: jobId))

        store.delete(jobId: jobId)
        XCTAssertFalse(store.exists(jobId: jobId))
    }

    // MARK: - Prune

    func test_prune_older_than_removes_old_files() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping prune test")

        let oldId = UUID()
        let recentId = UUID()

        placeFile(for: oldId)
        placeFile(for: recentId)

        let now = Date()
        // Set old file to 2 days ago
        setModificationDate(for: oldId, to: now.addingTimeInterval(-172_800))
        // Set recent file to 1 hour ago
        setModificationDate(for: recentId, to: now.addingTimeInterval(-3600))

        // Prune files older than 24 hours
        store.pruneOlderThan(86_400, relativeTo: now)

        XCTAssertFalse(store.exists(jobId: oldId), "Old file should have been pruned")
        XCTAssertTrue(store.exists(jobId: recentId), "Recent file should be preserved")
    }

    func test_prune_older_than_preserves_recent_files() throws {
        try XCTSkipIf(store.directoryURL == nil,
                      "No app-group container available — skipping prune test")

        let recentId = UUID()
        placeFile(for: recentId)

        let now = Date()
        // 1 minute ago is definitely recent
        setModificationDate(for: recentId, to: now.addingTimeInterval(-60))

        store.pruneOlderThan(3600, relativeTo: now)
        XCTAssertTrue(store.exists(jobId: recentId), "File 1 minute old should not be pruned with 1h cutoff")
    }
}
