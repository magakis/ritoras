import Foundation
import SQLite3

/// Tells sqlite3_bind_text to copy the bound string (safe under ARC).
/// SQLITE_STATIC (nil) would assume the pointer stays valid until step/reset,
/// but ARC may release the source NSString before sqlite3_step reads it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

        // ── Pragmas ──────────────────────────────────────────────
        exec("PRAGMA journal_mode=WAL;")       // persists in DB header, set once
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("PRAGMA foreign_keys=ON;")
        exec("PRAGMA mmap_size=268435456;")    // 256 MB — reader only (mmap is read-only in SQLite)

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

        bindAndStepInsert(stmt: stmt, level: level, component: component,
                          message: message, payload: payload, raw: raw)

        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            recordDiagnostic("insert commit failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func _insertBatch(_ entries: [(LogLevel, LogComponent, String, [String: Any]?, String)]) {
        ensureOpen()
        guard let db = db, let stmt = insertStmt else { return }

        if sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) != SQLITE_OK {
            recordDiagnostic("batch begin failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        for entry in entries {
            bindAndStepInsert(stmt: stmt, level: entry.0, component: entry.1,
                              message: entry.2, payload: entry.3, raw: entry.4)
        }

        if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
            recordDiagnostic("batch commit failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        applyFileProtection()
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
                afterId: Int64? = nil,
                search: String? = nil) -> [LogLine] {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return _recent(limit: limit, beforeId: beforeId, levels: levels,
                           components: components, sinceNs: sinceNs,
                           afterId: afterId, search: search)
        } else {
            return queue.sync {
                self._recent(limit: limit, beforeId: beforeId, levels: levels,
                             components: components, sinceNs: sinceNs,
                             afterId: afterId, search: search)
            }
        }
    }

    private func _recent(limit: Int, beforeId: Int64? = nil,
                         levels: Set<LogLevel>? = nil,
                         components: Set<LogComponent>? = nil,
                         sinceNs: Int64? = nil,
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
        if let search = search, !search.isEmpty {
            let sanitized = sanitizeFTS5(search)
            sql += " AND id IN (SELECT rowid FROM log_fts WHERE message MATCH ?)"
            params.append(.text(sanitized))
        }

        sql += " ORDER BY id DESC LIMIT ?"
        params.append(.int(Int32(limit)))

        return executeRecentQuery(db: db, sql: sql, params: params)
    }

    /// Executes the built SQL and returns LogLine objects.
    private func executeRecentQuery(db: OpaquePointer, sql: String,
                                    params: [QueryParam]) -> [LogLine] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("recent prepare failed: \(String(cString: sqlite3_errmsg(db)))")
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

            results.append(LogLine(
                id: Int(rowId),
                raw: raw,
                level: level,
                component: component,
                timestamp: timestamp,
                message: message,
                payload: payload,
                rowId: rowId
            ))
        }

        return results
    }

    // MARK: - Query: Count

    /// Returns the number of matching log entries.
    func count(levels: Set<LogLevel>? = nil,
               components: Set<LogComponent>? = nil,
               sinceNs: Int64? = nil,
               search: String? = nil) -> Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return _count(levels: levels, components: components,
                          sinceNs: sinceNs, search: search)
        } else {
            return queue.sync {
                self._count(levels: levels, components: components,
                            sinceNs: sinceNs, search: search)
            }
        }
    }

    private func _count(levels: Set<LogLevel>? = nil,
                        components: Set<LogComponent>? = nil,
                        sinceNs: Int64? = nil,
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

    // MARK: - Clear

    /// Deletes all rows from the log table and rebuilds the FTS5 index.
    func clear() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            _clear()
        } else {
            queue.sync { self._clear() }
        }
    }

    private func _clear() {
        ensureOpen()
        guard let db = db else { return }
        exec("DELETE FROM log_fts;")
        exec("DELETE FROM log;")
    }

    // MARK: - Rotate

    /// If the log table has more than 100,000 rows, deletes the oldest
    /// excess rows and runs a passive WAL checkpoint.
    func rotateIfNeeded() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            _rotateIfNeeded()
        } else {
            queue.sync { self._rotateIfNeeded() }
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
                        search: String? = nil) -> Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return _deleteFiltered(levels: levels, components: components,
                                   sinceNs: sinceNs, search: search)
        } else {
            return queue.sync {
                self._deleteFiltered(levels: levels, components: components,
                                     sinceNs: sinceNs, search: search)
            }
        }
    }

    private func _deleteFiltered(levels: Set<LogLevel>? = nil,
                                  components: Set<LogComponent>? = nil,
                                  sinceNs: Int64? = nil,
                                  search: String? = nil) -> Int {
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
        if let search = search, !search.isEmpty {
            let sanitized = sanitizeFTS5(search)
            sql += " AND id IN (SELECT rowid FROM log_fts WHERE message MATCH ?)"
            params.append(.text(sanitized))
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("deleteFiltered prepare failed: \(String(cString: sqlite3_errmsg(db)))")
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

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            recordDiagnostic("deleteFiltered step failed: \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }

        let count = Int(sqlite3_changes(db))
        exec("PRAGMA wal_checkpoint(PASSIVE);")
        return count
    }

    /// Deletes rows with ts_ns older than the given cutoff. Returns count deleted.
    func deleteOlderThan(tsNs: Int64) -> Int {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return _deleteOlderThan(tsNs: tsNs)
        } else {
            return queue.sync {
                self._deleteOlderThan(tsNs: tsNs)
            }
        }
    }

    private func _deleteOlderThan(tsNs: Int64) -> Int {
        ensureOpen()
        guard let db = db else { return 0 }

        let sql = "DELETE FROM log WHERE ts_ns < ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            recordDiagnostic("deleteOlderThan prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, tsNs)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            recordDiagnostic("deleteOlderThan step failed: \(String(cString: sqlite3_errmsg(db)))")
            return 0
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
