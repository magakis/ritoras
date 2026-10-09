import Foundation
import SQLite3

/// Tells sqlite3_bind_text to copy the bound string (safe under ARC).
/// SQLITE_STATIC (nil) would assume the pointer stays valid until step/reset,
/// but ARC may release the source NSString before sqlite3_step reads it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Error type

enum LogStoreError: Error {
    case openFailed(String)
    case executeFailed(String)
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted on the main queue after any INSERT/UPDATE/DELETE to the log table.
    static let logStoreDidChange = Notification.Name("ritoras.logStoreDidChange")
}

// MARK: - LogStore

/// SQLite-backed log storage with WAL mode, FTS5 full-text search, and a
/// serial-queue deadlock-guard pattern mirroring FileLogger.
///
/// This class is compiled into both the container app and the keyboard extension
/// via the `shared/` glob, but the keyboard never opens the database at runtime
/// (48 MB Jetsam cap). All database methods are safe to call from any thread.
///
/// ## LogLine.id mapping
///
/// `LogLine.id` is `Int`. LogStore sets it to `Int(sqliteRowId)` — lossless on
/// 64-bit iOS where `Int == Int64`. FileLogger uses `LogLine.id` as a line-offset
/// index; the two interpretations never collide because LogStore is dead code
/// during Phase 1.
final class LogStore {

    // MARK: - Singleton

    static let shared = LogStore()

    // MARK: - Serial queue & deadlock guard

    private static let queueKey = DispatchSpecificKey<Bool>()
    private let queue = DispatchQueue(label: "ritoras.logstore.write", qos: .utility)

    // MARK: - Database state

    private var db: OpaquePointer?
    private let dbURL: URL?
    /// Set `true` after one corruption-recovery attempt to prevent infinite loops.
    private var didAttemptRecovery = false
    /// Set `true` after WAL/SHM files have been protected (one-shot guard).
    private var didApplyProtectionToWalShm = false
    /// Enabled by the post-migration launch pass so imports are never pruned mid-migration.
    private var automaticRotationChecksEnabled = false
    /// One check per 10,000 inserted rows limits retention lag to one-tenth of the cap
    /// without running a row count for every log entry.
    private static let rotationCheckInterval = 10_000
    private var insertsSinceRotationCheck = 0

    // MARK: - Cached prepared statements (finalized in deinit)

    private var insertStmt: OpaquePointer?

    // MARK: - Diagnostics ring buffer

    private var diagnostics: [String] = []
    private static let diagnosticsCapacity = 64

    // MARK: - Init / Deinit

    private init() {
        queue.setSpecific(key: Self.queueKey, value: true)
        dbURL = Self.resolveURL()

        if dbURL == nil {
            recordDiagnostic("all database destinations unavailable")
        }
    }

    deinit {
        // Finalize cached statements and close the database handle.
        // This runs on whatever thread deinits the singleton (usually main).
        if let stmt = insertStmt {
            sqlite3_finalize(stmt)
        }
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - URL resolution

    /// Resolves the database path, preferring the app-group container over
    /// the per-process Documents directory (mirrors FileLogger.resolveURL).
    private static func resolveURL() -> URL? {
        let fileName = "ritoras-debug.sqlite"
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) {
            return container.appendingPathComponent(fileName)
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent(fileName)
        }
        return nil
    }

    /// The resolved database URL, or nil if no writable directory was found.
    static var databaseURL: URL? { shared.dbURL }

    // MARK: - Diagnostics

    /// Records an in-memory diagnostic entry using the deadlock-guard pattern.
    private func recordDiagnostic(_ message: String) {
        let entry = "[LogStore] \(message)"
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            diagnostics.append(entry)
            if diagnostics.count > Self.diagnosticsCapacity {
                diagnostics.removeFirst(diagnostics.count - Self.diagnosticsCapacity)
            }
        } else {
            queue.sync {
                self.diagnostics.append(entry)
                if self.diagnostics.count > Self.diagnosticsCapacity {
                    self.diagnostics.removeFirst(self.diagnostics.count - Self.diagnosticsCapacity)
                }
            }
        }
    }

    /// Returns a copy of recent diagnostic entries. Thread-safe.
    func recentDiagnostics() -> [String] {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return Array(diagnostics)
        } else {
            return queue.sync { Array(diagnostics) }
        }
    }

    // MARK: - Lazy open

    /// Opens (or re-opens) the database, runs pragmas and DDL, and installs
    /// the update hook. No-op after the first successful open.
    private func ensureOpen() {
        guard db == nil else { return }
        guard let url = dbURL else { return }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, db != nil else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            recordDiagnostic("open failed (\(rc)): \(msg)")
            db = nil
            return
        }

        // ── Corruption check ────────────────────────────────────
        if !didAttemptRecovery, !quickCheckIsOk() {
            nukeAndRebuild()
            didAttemptRecovery = true

            // Re-open — SQLITE_OPEN_CREATE will recreate the file
            let rc2 = sqlite3_open_v2(url.path, &db, flags, nil)
            guard rc2 == SQLITE_OK, db != nil else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                recordDiagnostic("reopen after recovery failed (\(rc2)): \(msg)")
                db = nil
                return
            }
        }

        // ── Pragmas ──────────────────────────────────────────────
        exec("PRAGMA journal_mode=WAL;")       // persists in DB header, set once
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("PRAGMA foreign_keys=ON;")
        exec("PRAGMA mmap_size=0;")          // disabled — iOS can revoke mmap'd regions in app-group containers under memory pressure, producing malformed-page reads

        // ── DDL ──────────────────────────────────────────────────
        let createLog = """
        CREATE TABLE IF NOT EXISTS log (
          id INTEGER PRIMARY KEY,
          ts_ns INTEGER NOT NULL,
          level INTEGER NOT NULL,
          component TEXT NOT NULL,
          message TEXT NOT NULL,
          payload_json TEXT,
          raw TEXT NOT NULL
        );
        """
        guard exec(createLog) else { return }

        exec("CREATE INDEX IF NOT EXISTS idx_log_ts ON log(ts_ns DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_log_level_component_ts ON log(level, component, ts_ns DESC);")

        let createFts = """
        CREATE VIRTUAL TABLE IF NOT EXISTS log_fts USING fts5(
          message, content='log', content_rowid='id', tokenize='porter unicode61'
        );
        """
        guard exec(createFts) else { return }

        exec("""
        CREATE TRIGGER IF NOT EXISTS log_ai AFTER INSERT ON log BEGIN
          INSERT INTO log_fts(rowid, message) VALUES (new.id, new.message);
        END;
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS log_ad AFTER DELETE ON log BEGIN
          INSERT INTO log_fts(log_fts, rowid, message) VALUES('delete', old.id, old.message);
        END;
        """)

        // ── Update hook ──────────────────────────────────────────
        sqlite3_update_hook(db, Self._updateHookCallback, nil)

        // ── Prepared statements ──────────────────────────────────
        let insertSQL = """
        INSERT INTO log (ts_ns, level, component, message, payload_json, raw)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)

        // ── File protection ──────────────────────────────────────
        applyFileProtection()
    }

    // MARK: - SQL helper

    /// Executes a one-shot SQL statement. Returns true on success.
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = db else { return false }
        var errMsg: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "unknown error"
            recordDiagnostic("exec failed: \(msg)")
            if let errMsg = errMsg { sqlite3_free(errMsg) }

            // Reactive corruption recovery — single retry, no loop
            if !didAttemptRecovery {
                let lower = msg.lowercased()
                if lower.contains("malformed") || lower.contains("database disk image") {
                    nukeAndRebuild()
                    didAttemptRecovery = true

                    self.db = nil            // force ensureOpen() to do full re-init
                    ensureOpen()             // rebuilds schema + triggers + FTS + prepared statements + pragmas + file protection
                    guard let db = self.db else { return false }

                    // Single retry of the original SQL
                    var retryErr: UnsafeMutablePointer<Int8>?
                    let retryRC = sqlite3_exec(db, sql, nil, nil, &retryErr)
                    if retryRC != SQLITE_OK {
                        if let retryErr = retryErr { sqlite3_free(retryErr) }
                    }
                    return retryRC == SQLITE_OK
                }
            }

            return false
        }
        return true
    }

    // MARK: - File protection

    /// Sets `completeUntilFirstUserAuthentication` on the database and its
    /// companion files (WAL, SHM). Called after CREATE DDL and after the
    /// first write (when WAL/SHM first appear).
    private func applyFileProtection() {
        guard let url = dbURL else { return }
        let attrs: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        for ext in ["-wal", "-shm"] {
            let path = url.path + ext
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
            }
        }
    }

    // MARK: - Corruption detection & recovery

    /// Runs `PRAGMA quick_check` and returns `true` only when the result row
    /// equals `"ok"`. Uses prepare/step/read (not `exec`) because `sqlite3_exec`
    /// may report `SQLITE_OK` even when corruption is present.
    /// - Note: Caller must guarantee `db` is non-nil.
    private func quickCheckIsOk() -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: cStr) == "ok"
    }

    /// Destructive recovery: finalizes cached statements, closes the database
    /// handle, deletes `.sqlite`/`-wal`/`-shm` files, and records a diagnostic.
    /// The caller is responsible for re-opening via `sqlite3_open_v2`.
    private func nukeAndRebuild() {
        if let stmt = insertStmt {
            sqlite3_finalize(stmt)
            insertStmt = nil
        }
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
        guard let url = dbURL else { return }
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        recordDiagnostic("recovered from corruption — DB rebuilt")
    }

    // MARK: - Update hook callback

    private static let _updateHookCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<Int8>?,
        UnsafePointer<Int8>?,
        Int64
    ) -> Void = { _, _, _, _, _ in
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .logStoreDidChange, object: nil)
        }
    }

    // MARK: - LogLevel mapping

    private static func intFromLevel(_ level: LogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        }
    }

    private static func levelFromInt(_ value: Int32) -> LogLevel {
        switch value {
        case 0: return .debug
        case 1: return .info
        case 2: return .warn
        case 3: return .error
        default: return .debug
        }
    }

    // MARK: - FTS5 query sanitization

    /// Converts each whitespace-separated token into a prefix query for FTS5.
    /// Strips FTS5 syntax characters and lowercases to prevent operator injection.
    /// Example: "Whis client" → "whis* client*" (both must match as prefixes).
    private func sanitizeFTS5(_ query: String) -> String {
        query.split(separator: " ").map { token in
            let clean = token.lowercased()
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
            guard !clean.isEmpty else { return "" }
            return "\(clean)*"
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Insert

    /// Inserts a single log entry wrapped in an explicit BEGIN/COMMIT.
    func insert(_ level: LogLevel, _ component: LogComponent,
                _ message: String, payload: [String: Any]?, raw: String) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            _insert(level: level, component: component, message: message,
                    payload: payload, raw: raw)
        } else {
            queue.sync {
                self._insert(level: level, component: component, message: message,
                             payload: payload, raw: raw)
            }
        }
    }

    /// Inserts a batch of log entries in a single transaction.
    func insertBatch(_ entries: [(LogLevel, LogComponent, String, [String: Any]?, String)]) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            _insertBatch(entries)
        } else {
            queue.sync {
                self._insertBatch(entries)
            }
        }
    }

    // MARK: - Insert (internal)

    private func _insert(level: LogLevel, component: LogComponent,
                         message: String, payload: [String: Any]?, raw: String) {
        ensureOpen()
        guard let db = db, let stmt = insertStmt else { return }

        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) != SQLITE_OK {
            recordDiagnostic("insert begin failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        let insertResult = bindAndStepInsert(stmt: stmt, level: level, component: component,
                                             message: message, payload: payload, raw: raw)

        let commitResult = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if commitResult != SQLITE_OK {
            recordDiagnostic("insert commit failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        if insertResult == SQLITE_DONE && commitResult == SQLITE_OK {
            noteInsertedEntries(1)
        }

        if !didApplyProtectionToWalShm {
            applyFileProtection()
            didApplyProtectionToWalShm = true
        }
    }

    private func _insertBatch(_ entries: [(LogLevel, LogComponent, String, [String: Any]?, String)]) {
        ensureOpen()
        guard let db = db, let stmt = insertStmt else { return }

        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) != SQLITE_OK {
            recordDiagnostic("batch begin failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        var insertedCount = 0
        for entry in entries {
            let result = bindAndStepInsert(stmt: stmt, level: entry.0, component: entry.1,
                                           message: entry.2, payload: entry.3, raw: entry.4)
            if result == SQLITE_DONE {
                insertedCount += 1
            }
        }

        let commitResult = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if commitResult != SQLITE_OK {
            recordDiagnostic("batch commit failed: \(String(cString: sqlite3_errmsg(db)))")
        } else {
            noteInsertedEntries(insertedCount)
        }

        if !didApplyProtectionToWalShm {
            applyFileProtection()
            didApplyProtectionToWalShm = true
        }
    }

    /// Counts committed rows and appends a rotation pass to the serial queue.
    /// Called only from that queue, so existing database requests stay ahead of maintenance.
    private func noteInsertedEntries(_ count: Int) {
        guard automaticRotationChecksEnabled, count > 0 else { return }

        insertsSinceRotationCheck += count
        guard insertsSinceRotationCheck >= Self.rotationCheckInterval else { return }
        insertsSinceRotationCheck %= Self.rotationCheckInterval
        queue.async { self._rotateIfNeeded() }
    }

    /// Binds parameters, steps, resets, and clears. Returns SQLITE_OK on
    /// success, or the error code on failure.
    private func bindAndStepInsert(stmt: OpaquePointer?,
                                   level: LogLevel, component: LogComponent,
                                   message: String, payload: [String: Any]?,
                                   raw: String) -> Int32 {
        guard let stmt = stmt else { return SQLITE_MISUSE }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        let tsNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let levelInt = Int32(Self.intFromLevel(level))

        sqlite3_bind_int64(stmt, 1, tsNs)
        sqlite3_bind_int(stmt, 2, levelInt)

        let componentNS = component.rawValue as NSString
        let messageNS = message as NSString
        let rawNS = raw as NSString

        sqlite3_bind_text(stmt, 3, componentNS.utf8String, -1, SQLITE_TRANSIENT)  // SQLITE_TRANSIENT
        sqlite3_bind_text(stmt, 4, messageNS.utf8String, -1, SQLITE_TRANSIENT)    // SQLITE_TRANSIENT

        if let payload = payload,
           JSONSerialization.isValidJSONObject(payload),
           let payloadData = try? JSONSerialization.data(withJSONObject: payload,
                                                          options: [.sortedKeys]),
           let payloadStr = String(data: payloadData, encoding: .utf8) {
            let payloadNS = payloadStr as NSString
            sqlite3_bind_text(stmt, 5, payloadNS.utf8String, -1, SQLITE_TRANSIENT)  // SQLITE_TRANSIENT
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        sqlite3_bind_text(stmt, 6, rawNS.utf8String, -1, SQLITE_TRANSIENT)  // SQLITE_TRANSIENT

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            recordDiagnostic("insert step failed: \(rc)")
        }
        return rc
    }

    // MARK: - Query: Recent

    /// Returns recent log lines matching the given filters, ordered by
    /// row ID descending (newest first).
    func recent(limit: Int, beforeId: Int64? = nil,
                levels: Set<LogLevel>? = nil,
                components: Set<LogComponent>? = nil,
                sinceNs: Int64? = nil,
                untilNs: Int64? = nil,
                afterId: Int64? = nil,
                search: String? = nil) -> [LogLine] {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return _recent(limit: limit, beforeId: beforeId, levels: levels,
                           components: components, sinceNs: sinceNs, untilNs: untilNs,
                           afterId: afterId, search: search)
        } else {
            return queue.sync {
                self._recent(limit: limit, beforeId: beforeId, levels: levels,
                             components: components, sinceNs: sinceNs, untilNs: untilNs,
                             afterId: afterId, search: search)
            }
        }
    }

    private func _recent(limit: Int, beforeId: Int64? = nil,
                         levels: Set<LogLevel>? = nil,
                         components: Set<LogComponent>? = nil,
                         sinceNs: Int64? = nil,
                         untilNs: Int64? = nil,
                         afterId: Int64? = nil,
                         search: String? = nil) -> [LogLine] {
        ensureOpen()
        guard let db = db else { return [] }

        // Build SQL
        var sql = """
        SELECT id, ts_ns, level, component, message, payload_json, raw
        FROM log WHERE 1=1
        """
        var params: [QueryParam] = []

        if let beforeId = beforeId {
            sql += " AND id < ?"
            params.append(.int64(beforeId))
        }
        if let afterId = afterId {
            sql += " AND id > ?"
            params.append(.int64(afterId))
        }
        if let levels = levels, !levels.isEmpty {
            let placeholders = levels.map { _ in "?" }.joined(separator: ",")
            sql += " AND level IN (\(placeholders))"
            for level in levels {
                params.append(.int(Int32(Self.intFromLevel(level))))
            }
        }
        if let components = components, !components.isEmpty {
            let placeholders = components.map { _ in "?" }.joined(separator: ",")
            sql += " AND component IN (\(placeholders))"
            for comp in components {
                params.append(.text(comp.rawValue))
            }
        }
        if let sinceNs = sinceNs {
            sql += " AND ts_ns >= ?"
            params.append(.int64(sinceNs))
        }
        if let untilNs = untilNs {
            sql += " AND ts_ns <= ?"
            params.append(.int64(untilNs))
        }
        if let search = search, !search.isEmpty {
            let sanitized = sanitizeFTS5(search)
            sql += " AND id IN (SELECT rowid FROM log_fts WHERE message MATCH ?)"
            params.append(.text(sanitized))
        }

        sql += " ORDER BY id DESC LIMIT ?"
        params.append(.int(Int32(limit)))

        return executeLogLineQuery(db: db, sql: sql, params: params)
    }

    /// Executes the built SQL and returns LogLine objects.
    private func executeLogLineQuery(db: OpaquePointer, sql: String,
                                     params: [QueryParam]) -> [LogLine] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("log query prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        // Bind parameters
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .int(let val):
                sqlite3_bind_int(stmt, idx, val)
            case .int64(let val):
                sqlite3_bind_int64(stmt, idx, val)
            case .text(let val):
                let ns = val as NSString
                sqlite3_bind_text(stmt, idx, ns.utf8String, -1, SQLITE_TRANSIENT)   // SQLITE_TRANSIENT
            }
        }

        // Collect results
        var results: [LogLine] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(logLine(from: stmt))
        }

        return results
    }

    private func logLine(from stmt: OpaquePointer) -> LogLine {
        let rowId = sqlite3_column_int64(stmt, 0)
        let tsNs = sqlite3_column_int64(stmt, 1)
        let levelInt = sqlite3_column_int(stmt, 2)
        let componentStr: String = {
            guard let cStr = sqlite3_column_text(stmt, 3) else { return "" }
            return String(cString: cStr)
        }()
        let message: String = {
            guard let cStr = sqlite3_column_text(stmt, 4) else { return "" }
            return String(cString: cStr)
        }()
        let payloadStr: String? = {
            guard sqlite3_column_type(stmt, 5) != SQLITE_NULL,
                  let cStr = sqlite3_column_text(stmt, 5) else { return nil }
            return String(cString: cStr)
        }()
        let raw: String = {
            guard let cStr = sqlite3_column_text(stmt, 6) else { return "" }
            return String(cString: cStr)
        }()

        let level = Self.levelFromInt(levelInt)
        let component = LogComponent(rawValue: componentStr)
        let timestamp = Date(timeIntervalSince1970: TimeInterval(tsNs) / 1_000_000_000)

        let payload: [String: Any]? = payloadStr.flatMap { str in
            guard let data = str.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        return LogLine(
            id: Int(rowId),
            raw: raw,
            level: level,
            component: component,
            timestamp: timestamp,
            message: message,
            payload: payload,
            rowId: rowId
        )
    }

    /// Returns every log line in the inclusive timestamp range, oldest first.
    func exportRange(sinceNs: Int64, untilNs: Int64) throws -> [LogLine] {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try _exportRange(sinceNs: sinceNs, untilNs: untilNs)
        } else {
            return try queue.sync {
                try self._exportRange(sinceNs: sinceNs, untilNs: untilNs)
            }
        }
    }

    private func _exportRange(sinceNs: Int64, untilNs: Int64) throws -> [LogLine] {
        ensureOpen()
        guard let db = db else {
            throw LogStoreError.openFailed("SQLite database connection is unavailable")
        }

        let sql = """
        SELECT id, ts_ns, level, component, message, payload_json, raw
        FROM log
        WHERE ts_ns >= ? AND ts_ns <= ?
        ORDER BY ts_ns ASC, id ASC
        """
        var stmt: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareCode == SQLITE_OK, let preparedStatement = stmt else {
            let error = exportQueryError("range export prepare", db: db, code: prepareCode)
            if let stmt { sqlite3_finalize(stmt) }
            throw error
        }
        defer { sqlite3_finalize(preparedStatement) }

        try bindExportRange(sinceNs: sinceNs, untilNs: untilNs,
                            to: preparedStatement, db: db)

        var results: [LogLine] = []
        while true {
            let stepCode = sqlite3_step(preparedStatement)
            if stepCode == SQLITE_ROW {
                results.append(logLine(from: preparedStatement))
            } else if stepCode == SQLITE_DONE {
                return results
            } else {
                throw exportQueryError("range export step", db: db, code: stepCode)
            }
        }
    }

    // MARK: - Query: Count

    /// Returns the number of matching log entries.
    func count(levels: Set<LogLevel>? = nil,
               components: Set<LogComponent>? = nil,
               sinceNs: Int64? = nil,
               untilNs: Int64? = nil,
               search: String? = nil) -> Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return _count(levels: levels, components: components,
                          sinceNs: sinceNs, untilNs: untilNs, search: search)
        } else {
            return queue.sync {
                self._count(levels: levels, components: components,
                            sinceNs: sinceNs, untilNs: untilNs, search: search)
            }
        }
    }

    private func _count(levels: Set<LogLevel>? = nil,
                        components: Set<LogComponent>? = nil,
                        sinceNs: Int64? = nil,
                        untilNs: Int64? = nil,
                        search: String? = nil) -> Int {
        ensureOpen()
        guard let db = db else { return 0 }

        var sql = "SELECT COUNT(*) FROM log WHERE 1=1"
        var params: [QueryParam] = []

        if let levels = levels, !levels.isEmpty {
            let placeholders = levels.map { _ in "?" }.joined(separator: ",")
            sql += " AND level IN (\(placeholders))"
            for level in levels {
                params.append(.int(Int32(Self.intFromLevel(level))))
            }
        }
        if let components = components, !components.isEmpty {
            let placeholders = components.map { _ in "?" }.joined(separator: ",")
            sql += " AND component IN (\(placeholders))"
            for comp in components {
                params.append(.text(comp.rawValue))
            }
        }
        if let sinceNs = sinceNs {
            sql += " AND ts_ns >= ?"
            params.append(.int64(sinceNs))
        }
        if let untilNs = untilNs {
            sql += " AND ts_ns <= ?"
            params.append(.int64(untilNs))
        }
        if let search = search, !search.isEmpty {
            let sanitized = sanitizeFTS5(search)
            sql += " AND id IN (SELECT rowid FROM log_fts WHERE message MATCH ?)"
            params.append(.text(sanitized))
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("count prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .int(let val):
                sqlite3_bind_int(stmt, idx, val)
            case .int64(let val):
                sqlite3_bind_int64(stmt, idx, val)
            case .text(let val):
                let ns = val as NSString
                sqlite3_bind_text(stmt, idx, ns.utf8String, -1, SQLITE_TRANSIENT)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Returns the entry count and summed raw-line UTF-8 bytes for an inclusive range.
    func rangeCountAndRawBytes(sinceNs: Int64,
                               untilNs: Int64) throws -> (count: Int, estimatedBytes: Int64) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try _rangeCountAndRawBytes(sinceNs: sinceNs, untilNs: untilNs)
        } else {
            return try queue.sync {
                try self._rangeCountAndRawBytes(sinceNs: sinceNs, untilNs: untilNs)
            }
        }
    }

    private func _rangeCountAndRawBytes(sinceNs: Int64,
                                        untilNs: Int64) throws -> (count: Int, estimatedBytes: Int64) {
        ensureOpen()
        guard let db = db else {
            throw LogStoreError.openFailed("SQLite database connection is unavailable")
        }

        let sql = """
        SELECT COUNT(*), COALESCE(SUM(LENGTH(CAST(raw AS BLOB))), 0)
        FROM log
        WHERE ts_ns >= ? AND ts_ns <= ?
        """
        var stmt: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareCode == SQLITE_OK, let preparedStatement = stmt else {
            let error = exportQueryError("range count prepare", db: db, code: prepareCode)
            if let stmt { sqlite3_finalize(stmt) }
            throw error
        }
        defer { sqlite3_finalize(preparedStatement) }

        try bindExportRange(sinceNs: sinceNs, untilNs: untilNs,
                            to: preparedStatement, db: db)

        let rowCode = sqlite3_step(preparedStatement)
        guard rowCode == SQLITE_ROW else {
            throw exportQueryError("range count step", db: db, code: rowCode)
        }
        let result = (
            count: Int(sqlite3_column_int64(preparedStatement, 0)),
            estimatedBytes: sqlite3_column_int64(preparedStatement, 1)
        )
        let completionCode = sqlite3_step(preparedStatement)
        guard completionCode == SQLITE_DONE else {
            throw exportQueryError("range count completion", db: db, code: completionCode)
        }
        return result
    }

    private func bindExportRange(sinceNs: Int64,
                                 untilNs: Int64,
                                 to stmt: OpaquePointer,
                                 db: OpaquePointer) throws {
        let lowerBoundCode = sqlite3_bind_int64(stmt, 1, sinceNs)
        guard lowerBoundCode == SQLITE_OK else {
            throw exportQueryError("range lower-bound bind", db: db, code: lowerBoundCode)
        }
        let upperBoundCode = sqlite3_bind_int64(stmt, 2, untilNs)
        guard upperBoundCode == SQLITE_OK else {
            throw exportQueryError("range upper-bound bind", db: db, code: upperBoundCode)
        }
    }

    private func exportQueryError(_ operation: String,
                                  db: OpaquePointer,
                                  code: Int32) -> LogStoreError {
        LogStoreError.executeFailed(
            "\(operation) failed (\(code)): \(String(cString: sqlite3_errmsg(db)))"
        )
    }

    // MARK: - Clear

    /// Deletes all rows from the log table and rebuilds the FTS5 index.
    func clear() throws {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            try _clear()
        } else {
            try queue.sync { try self._clear() }
        }
    }

    private func _clear() throws {
        ensureOpen()
        guard let db = db else { return }
        guard exec("DELETE FROM log;") else {
            throw LogStoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard exec("INSERT INTO log_fts(log_fts) VALUES('rebuild');") else {
            throw LogStoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Rotate

    /// If the log table has more than 100,000 rows, deletes the oldest
    /// excess rows and runs a passive WAL checkpoint. The first call also
    /// enables asynchronous in-session checks; call it after migration completes.
    func rotateIfNeeded() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            _rotateIfNeeded()
            automaticRotationChecksEnabled = true
        } else {
            queue.sync {
                self._rotateIfNeeded()
                self.automaticRotationChecksEnabled = true
            }
        }
    }

    private func _rotateIfNeeded() {
        ensureOpen()
        guard let db = db else { return }

        // Count rows
        var countStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM log", -1, &countStmt, nil) == SQLITE_OK,
              let countStmt = countStmt else {
            recordDiagnostic("rotate count failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(countStmt) }

        guard sqlite3_step(countStmt) == SQLITE_ROW else { return }
        let rowCount = sqlite3_column_int64(countStmt, 0)

        guard rowCount > 100_000 else { return }

        // Delete oldest rows beyond the 100,000 most recent
        let deleteSQL = """
        DELETE FROM log WHERE id <= (
            SELECT id FROM log ORDER BY id DESC LIMIT 1 OFFSET 100000
        )
        """
        guard exec(deleteSQL) else { return }

        // Passive checkpoint
        exec("PRAGMA wal_checkpoint(PASSIVE);")
    }

    // MARK: - Delete

    /// Deletes rows matching the given filters. Returns the number of rows deleted.
    /// Uses the same filter logic as `recent()` — pass the same parameters to target the "visible" set.
    func deleteFiltered(levels: Set<LogLevel>? = nil,
                        components: Set<LogComponent>? = nil,
                        sinceNs: Int64? = nil,
                        untilNs: Int64? = nil,
                        search: String? = nil) throws -> Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try _deleteFiltered(levels: levels, components: components,
                                       sinceNs: sinceNs, untilNs: untilNs, search: search)
        } else {
            return try queue.sync {
                try self._deleteFiltered(levels: levels, components: components,
                                         sinceNs: sinceNs, untilNs: untilNs, search: search)
            }
        }
    }

    private func _deleteFiltered(levels: Set<LogLevel>? = nil,
                                  components: Set<LogComponent>? = nil,
                                  sinceNs: Int64? = nil,
                                  untilNs: Int64? = nil,
                                  search: String? = nil) throws -> Int {
        ensureOpen()
        guard let db = db else { return 0 }

        var sql = "DELETE FROM log WHERE 1=1"
        var params: [QueryParam] = []

        if let levels = levels, !levels.isEmpty {
            let placeholders = levels.map { _ in "?" }.joined(separator: ",")
            sql += " AND level IN (\(placeholders))"
            for level in levels {
                params.append(.int(Int32(Self.intFromLevel(level))))
            }
        }
        if let components = components, !components.isEmpty {
            let placeholders = components.map { _ in "?" }.joined(separator: ",")
            sql += " AND component IN (\(placeholders))"
            for comp in components {
                params.append(.text(comp.rawValue))
            }
        }
        if let sinceNs = sinceNs {
            sql += " AND ts_ns >= ?"
            params.append(.int64(sinceNs))
        }
        if let untilNs = untilNs {
            sql += " AND ts_ns <= ?"
            params.append(.int64(untilNs))
        }
        if let search = search, !search.isEmpty {
            let sanitized = sanitizeFTS5(search)
            sql += " AND id IN (SELECT rowid FROM log_fts WHERE message MATCH ?)"
            params.append(.text(sanitized))
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("deleteFiltered prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            throw LogStoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .int(let val):
                sqlite3_bind_int(stmt, idx, val)
            case .int64(let val):
                sqlite3_bind_int64(stmt, idx, val)
            case .text(let val):
                let ns = val as NSString
                sqlite3_bind_text(stmt, idx, ns.utf8String, -1, SQLITE_TRANSIENT)
            }
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            recordDiagnostic("deleteFiltered step failed: \(String(cString: sqlite3_errmsg(db)))")
            throw LogStoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }

        let count = Int(sqlite3_changes(db))
        exec("PRAGMA wal_checkpoint(PASSIVE);")
        return count
    }

    /// Deletes rows with ts_ns older than the given cutoff. Returns count deleted.
    func deleteOlderThan(tsNs: Int64) throws -> Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try _deleteOlderThan(tsNs: tsNs)
        } else {
            return try queue.sync {
                try self._deleteOlderThan(tsNs: tsNs)
            }
        }
    }

    private func _deleteOlderThan(tsNs: Int64) throws -> Int {
        ensureOpen()
        guard let db = db else { return 0 }

        let sql = "DELETE FROM log WHERE ts_ns < ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("deleteOlderThan prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            throw LogStoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, tsNs)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            recordDiagnostic("deleteOlderThan step failed: \(String(cString: sqlite3_errmsg(db)))")
            throw LogStoreError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }

        let count = Int(sqlite3_changes(db))
        exec("PRAGMA wal_checkpoint(PASSIVE);")
        return count
    }
}

// MARK: - Query parameter enum (internal)

private enum QueryParam {
    case int(Int32)
    case int64(Int64)
    case text(String)
}
