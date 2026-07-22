import Foundation

// MARK: - LogStoreMigration

/// One-time migration that imports existing flat-file logs into LogStore
/// on the container app's first launch after this code ships.
///
/// Flat files are archived (moved to a timestamped subdirectory) after
/// successful import — they are NOT deleted outright.
enum LogStoreMigration {

    private static let migratedKey = "ritoras.logstore.migratedV1"
    private static let lastFileKey = "ritoras.logstore.migratedV1.lastFile"

    /// Runs the migration once. Idempotent: gates on UserDefaults flag.
    /// Safe to call from any thread. On partial failure, flat files are
    /// left in place and the flag is cleared so the migration retries on
    /// the next launch.
    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }

        guard let dir = resolveDir() else {
            FileLogger.shared.error(.app, "LogStoreMigration: cannot resolve flat-file directory")
            return
        }

        let fileManager = FileManager.default

        // Enumerate flat files oldest-first: .log.6 → .log.5 → … → .log
        var files: [URL] = []
        let base = "ritoras-debug.log"
        for i in (1...6).reversed() {
            let url = dir.appendingPathComponent("\(base).\(i)")
            if fileManager.fileExists(atPath: url.path) {
                files.append(url)
            }
        }
        let activeURL = dir.appendingPathComponent(base)
        if fileManager.fileExists(atPath: activeURL.path) {
            files.append(activeURL)
        }

        guard !files.isEmpty else {
            UserDefaults.standard.set(true, forKey: migratedKey)
            FileLogger.shared.info(.app, "LogStoreMigration: no flat files found — marking complete")
            return
        }

        // Resume support: skip files that were fully imported in a prior attempt
        let lastCompleted = UserDefaults.standard.string(forKey: lastFileKey)
        let startIndex: Int
        if let last = lastCompleted,
           let idx = files.firstIndex(where: { $0.lastPathComponent == last }) {
            startIndex = idx + 1
        } else {
            startIndex = 0
        }

        var imported: [URL] = []

        for i in startIndex..<files.count {
            let url = files[i]
            do {
                try importFile(url)
                imported.append(url)
                UserDefaults.standard.set(url.lastPathComponent, forKey: lastFileKey)
            } catch {
                FileLogger.shared.error(.app, "LogStoreMigration: failed to import \(url.lastPathComponent): \(error.localizedDescription)")
                // Leave flat files in place, clear flags for retry on next launch
                UserDefaults.standard.removeObject(forKey: migratedKey)
                UserDefaults.standard.removeObject(forKey: lastFileKey)
                return
            }
        }

        // All files imported successfully — archive them
        do {
            try archiveFiles(imported, in: dir)
            UserDefaults.standard.set(true, forKey: migratedKey)
            UserDefaults.standard.removeObject(forKey: lastFileKey)
            FileLogger.shared.info(.app, "LogStoreMigration: completed — \(imported.count) file(s) archived")
        } catch {
            // Import succeeded but archiving failed — still mark complete
            FileLogger.shared.error(.app, "LogStoreMigration: archive failed: \(error.localizedDescription)")
            UserDefaults.standard.set(true, forKey: migratedKey)
            UserDefaults.standard.removeObject(forKey: lastFileKey)
        }
    }

    // MARK: - Directory resolution

    /// Resolves the flat-file directory, preferring the app-group container
    /// over the per-process Documents directory (mirrors FileLogger.resolveURL).
    private static func resolveDir() -> URL? {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) {
            return container
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs
        }
        return nil
    }

    // MARK: - Import (streaming, not slurping)

    /// Reads a flat file line-by-line, parses each line via FileLogger.parseLine,
    /// and batch-inserts the entries into LogStore.
    private static func importFile(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var entries: [(LogLevel, LogComponent, String, [String: Any]?, String)] = []
        var remainder = ""
        var lineId = 0
        let chunkSize = 65536

        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            guard let chunk = String(data: data, encoding: .utf8) else { continue }

            let full = remainder + chunk
            var lines = full.split(separator: "\n", omittingEmptySubsequences: false)
            // The last element may be an incomplete line — keep as remainder
            remainder = lines.popLast().map(String.init) ?? ""

            for line in lines where !line.isEmpty {
                let str = String(line)
                let parsed = FileLogger.parseLine(str, id: lineId)
                lineId += 1
                let level = parsed.level ?? .debug
                let component = parsed.component ?? .app
                let message = parsed.message ?? str
                entries.append((level, component, message, parsed.payload, parsed.raw))
            }
        }

        // Flush remainder (last line without trailing newline)
        if !remainder.isEmpty {
            let parsed = FileLogger.parseLine(remainder, id: lineId)
            let level = parsed.level ?? .debug
            let component = parsed.component ?? .app
            let message = parsed.message ?? remainder
            entries.append((level, component, message, parsed.payload, parsed.raw))
        }

        guard !entries.isEmpty else { return }
        LogStore.shared.insertBatch(entries)
    }

    // MARK: - Archive

    /// Moves imported flat files into a timestamped subdirectory so the
    /// user can verify the database before deleting them manually.
    private static func archiveFiles(_ files: [URL], in dir: URL) throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        let archiveDir = dir.appendingPathComponent("ritoras-debug.archived-\(timestamp)")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        for url in files {
            let dest = archiveDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
        }
        FileLogger.shared.info(.app, "LogStoreMigration: files archived to \(archiveDir.lastPathComponent)")
    }
}
