import Foundation
import os

public enum LogLevel: String { case debug, info, warn, error }

public enum LogComponent: String {
    case keyboard = "Keyboard"
    case app = "ContainerApp"
    case transcription = "Transcription"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case prediction = "Prediction"
    case network = "Network"
    case settings = "Settings"
    case lifecycle = "Lifecycle"
}

final class FileLogger {
    static let shared = FileLogger()
    private init() {
        let (url, fallback) = Self.resolveURL()
        self.resolvedURL = url
        self.usingFallbackDir = fallback

        queue.setSpecific(key: Self.queueKey, value: true)

        if url == nil {
            recordDiagnostic("all log destinations unavailable")
        } else if fallback {
            recordDiagnostic("containerURL nil — falling back to documents directory (logs will not merge across targets)")
        }

        let urlDesc = url?.path ?? "nil"
        queue.async { Self.append("[init] resolvedURL=\(urlDesc) fallback=\(fallback)", durable: false) }
    }

    private static let fileName = "ritoras-debug.log"
    private static let maxBytes: Int64 = 1_048_576         // 1 MB soft cap
    private static let maxRolledFiles = 6

    // ── os.Logger probe (Phase 3a) ───────────────────────────────────
    private static let probeLogger = Logger(subsystem: "com.ritoras.app", category: "probe")
    private static let probeQueue = DispatchQueue(label: "ritoras.filelogger.probe")
    private static var probeEmitted = false

    private let resolvedURL: URL?
    private let usingFallbackDir: Bool
    private var writeHandle: FileHandle?
    private var currentBytes: Int64 = 0
    private var isRotating = false

    /// Optional broadcast hook invoked on every log call. Set by keyboard targets
    /// to ship logs to the container app's DebugLogView via LocalhostServer.
    /// MUST remain nil in the container app to prevent infinite loops
    /// (server-received logs are written via this same FileLogger).
    public static var broadcast: ((LogLevel, LogComponent, String, [String: Any]?) -> Void)?

    /// TEST-ONLY: do not use in production. When set, forces `isKeyboardExtension`
    /// to return true so that tests can exercise the flat-file write path regardless
    /// of the test target's bundle identifier.
    internal static var forceKeyboardModeForTesting = false

    /// True when running inside the keyboard extension process.
    /// Used to skip LogStore writes (48 MB Jetsam cap).
    /// Overridden by `forceKeyboardModeForTesting` during tests.
    private static var isKeyboardExtension: Bool {
        forceKeyboardModeForTesting || Bundle.main.bundleIdentifier?.hasSuffix(".keyboard") ?? false
    }

    private static func resolveURL() -> (url: URL?, usingFallback: Bool) {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) {
            return (container.appendingPathComponent(fileName), false)
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return (docs.appendingPathComponent(fileName), true)
        }
        return (nil, false)
    }

    // ── Diagnostic ring buffer ──────────────────────────────────────

    private var diagnostics: [String] = []
    private static var diagnosticsCapacity = 64
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// Configures the ring buffer capacity. Call before any logging occurs.
    static func configure(diagnosticsCapacity: Int) {
        Self.diagnosticsCapacity = diagnosticsCapacity
    }

    /// Records an in-memory diagnostic entry. Safe to call from any thread.
    /// Uses a dispatch_get_specific deadlock guard to avoid re-entering the
    /// serial queue when already running on it (e.g. from append's catch handler).
    /// Does NOT perform file I/O — only mutates the in-memory diagnostics array.
    private func recordDiagnostic(_ message: String) {
        let ts = dateFormatter.string(from: Date())
        let entry = "\(ts) [DIAG] \(message)"

        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            // Already on the serial queue — mutate directly to avoid deadlock.
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

    // ── Serial queue & formatter ────────────────────────────────────

    private let queue = DispatchQueue(label: "ritoras.filelogger", qos: .utility)
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // ── Public API ──────────────────────────────────────────────────

    func log(_ level: LogLevel, _ component: LogComponent,
             _ message: String, payload: [String: Any]? = nil) {
        if level == .debug, !SharedConfig.verboseLoggingEnabled() { return }
        let ts = dateFormatter.string(from: Date())

        var dict: [String: Any] = [
            "ts": ts,
            "level": level.rawValue,
            "cat": component.rawValue,
            "msg": message
        ]

        if let payload = payload {
            if JSONSerialization.isValidJSONObject(payload) {
                dict["payload"] = payload
            } else {
                recordDiagnostic("payload serialization failed: \(message)")
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            recordDiagnostic("JSON serialization failed for log line")
            return
        }

        let line = jsonString + "\n"

        // Phase 4: container app writes to LogStore ONLY.
        // Keyboard extension writes flat-file ONLY.
        // DB stores originals unscrubbed. Scrubbing happens at export (copy/share)
        // in DebugLogView, controlled by the scrubPII toggle.
        if !Self.isKeyboardExtension {
            LogStore.shared.insert(level, component, message, payload: payload, raw: jsonString)
        } else {
            // Keyboard: flat-file write only.
            let write = { Self.append(line, durable: (level == .warn || level == .error)) }

            switch level {
            case .warn, .error:
                // Sync write for crash survivability.  Reuse the deadlock guard
                // pattern from rotation: if already on the serial queue, execute
                // inline to avoid deadlock.
                if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
                    write()
                } else {
                    queue.sync(execute: write)
                }
            case .debug, .info:
                queue.async(execute: write)
            }
        }

        // Phase 3a: emit os.Logger probe exactly once per process lifetime.
        if level == .warn || level == .error {
            Self.probeQueue.sync {
                if !Self.probeEmitted {
                    Self.probeEmitted = true
                    Self.probeLogger.notice("ritoras probe: \(level.rawValue, privacy: .public) path reached for component \(component.rawValue, privacy: .public)")
                }
            }
        }

        // Broadcast hook (used by keyboard to ship logs to container app via localhost).
        Self.broadcast?(level, component, message, payload)
    }

    /// Batch-logs multiple entries in a single database transaction.
    /// Used by LocalhostServer.handlePostLogs to avoid per-entry transaction overhead.
    /// Only writes in the container app (keyboard uses flat-file writes).
    func logBatch(_ entries: [(LogLevel, LogComponent, String, [String: Any]?)]) {
        guard !Self.isKeyboardExtension else { return }

        var batch: [(LogLevel, LogComponent, String, [String: Any]?, String)] = []

        for (level, component, message, payload) in entries {
            if level == .debug, !SharedConfig.verboseLoggingEnabled() { continue }

            let ts = dateFormatter.string(from: Date())
            var dict: [String: Any] = [
                "ts": ts,
                "level": level.rawValue,
                "cat": component.rawValue,
                "msg": message
            ]
            if let payload = payload {
                if JSONSerialization.isValidJSONObject(payload) {
                    dict["payload"] = payload
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                  let jsonString = String(data: data, encoding: .utf8) else { continue }

            batch.append((level, component, message, payload, jsonString))
        }

        if !batch.isEmpty {
            LogStore.shared.insertBatch(batch)
        }
    }

    static func clear() {
        if Self.isKeyboardExtension {
            shared.queue.sync {
                try? shared.writeHandle?.close()
                shared.writeHandle = nil
                shared.currentBytes = 0

                guard let url = shared.resolvedURL else { return }
                let dir = url.deletingLastPathComponent()
                let base = Self.fileName

                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                        shared.recordDiagnostic("clear remove failed: \(error)")
                    }
                }

                for i in 1...Self.maxRolledFiles {
                    let rolledURL = dir.appendingPathComponent("\(base).\(i)")
                    do {
                        try FileManager.default.removeItem(at: rolledURL)
                    } catch {
                        let nsError = error as NSError
                        if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                            shared.recordDiagnostic("clear remove .\(i) failed: \(error)")
                        }
                    }
                }
            }
        } else {
            try? LogStore.shared.clear()
        }
    }

    static func contents() -> String? {
        shared.queue.sync {
            guard let url = shared.resolvedURL else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    static func fileURL() -> URL? {
        if Self.isKeyboardExtension {
            return shared.resolvedURL
        } else {
            return LogStore.databaseURL
        }
    }

    static func parsedLines() -> [LogLine] {
        guard let content = contents() else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { parseLine(String($0.element), id: $0.offset) }
    }

    static func parseLine(_ raw: String, id: Int) -> LogLine {
        // Try JSON-first — decodes the new JSON-lines format.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let level = (obj["level"] as? String).flatMap { LogLevel(rawValue: $0) }
            let component = (obj["cat"] as? String).flatMap { LogComponent(rawValue: $0) }

            let timestamp: Date?
            if let tsStr = obj["ts"] as? String {
                timestamp = Self.shared.dateFormatter.date(from: tsStr)
            } else {
                timestamp = nil
            }

            let message = obj["msg"] as? String
            let payload = obj["payload"] as? [String: Any]

            return LogLine(id: id, raw: raw, level: level, component: component,
                           timestamp: timestamp, message: message, payload: payload,
                           rowId: nil)
        }

        // Fallback: plain-text substring extraction (legacy format and init lines).
        let level: LogLevel?
        if raw.contains(" [DEBUG] ") { level = .debug }
        else if raw.contains(" [INFO] ") { level = .info }
        else if raw.contains(" [WARN] ") { level = .warn }
        else if raw.contains(" [ERROR] ") { level = .error }
        else { level = nil }

        let component: LogComponent?
        if raw.contains(" [Keyboard] ") { component = .keyboard }
        else if raw.contains(" [ContainerApp] ") { component = .app }
        else if raw.contains(" [Transcription] ") { component = .transcription }
        else if raw.contains(" [Audio] ") { component = .audio }
        else if raw.contains(" [Dictionary] ") { component = .dictionary }
        else if raw.contains(" [Network] ") { component = .network }
        else if raw.contains(" [Settings] ") { component = .settings }
        else if raw.contains(" [Lifecycle] ") { component = .lifecycle }
        else { component = nil }

        let timestamp: Date?
        if let spaceIdx = raw.firstIndex(of: " ") {
            let tsStr = String(raw[..<spaceIdx])
            timestamp = Self.shared.dateFormatter.date(from: tsStr)
        } else {
            timestamp = nil
        }

        return LogLine(id: id, raw: raw, level: level, component: component,
                       timestamp: timestamp, message: nil, payload: nil,
                       rowId: nil)
    }

    // ── File I/O ────────────────────────────────────────────────────

    /// Opens (or returns the cached) write handle to the active log file.
    /// Must be called on the serial queue.  Creates the file if missing,
    /// seeks to end, and initializes `currentBytes` from the file's actual size.
    private func ensureWriteHandle() -> FileHandle? {
        if let handle = writeHandle { return handle }
        guard let url = resolvedURL else {
            recordDiagnostic("ensureWriteHandle failed: no URL")
            return nil
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            writeHandle = handle
            currentBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return handle
        } catch {
            recordDiagnostic("ensureWriteHandle failed: \(error)")
            return nil
        }
    }

    private static func append(_ line: String, durable: Bool) {
        guard !shared.isRotating else { return }
        guard let url = shared.resolvedURL else {
            shared.recordDiagnostic("append skipped: no URL")
            return
        }

        // Check available disk space before attempting write
        let parentDir = url.deletingLastPathComponent()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: parentDir.path),
           let free = attrs[.systemFreeSize] as? NSNumber,
           free.int64Value < 1_000_000 {
            shared.recordDiagnostic("skipping log write — disk space low: \(free.int64Value) bytes free")
            return
        }

        // Ensure write handle is open — populates currentBytes from actual file size
        guard shared.ensureWriteHandle() != nil else {
            shared.recordDiagnostic("append write failed: no handle")
            return
        }

        // Check size using cached currentBytes and rotate if needed
        if shared.currentBytes > maxBytes {
            rotate(url: url)
            // Rotation closed the handle; re-acquire for the active file
            guard shared.ensureWriteHandle() != nil else {
                shared.recordDiagnostic("append write failed: no handle after rotation")
                return
            }
        }

        guard let handle = shared.writeHandle else {
            shared.recordDiagnostic("append write failed: handle nil before write")
            return
        }

        do {
            let data = Data(line.utf8)
            try handle.write(contentsOf: data)
            shared.currentBytes &+= Int64(data.count)
            if durable {
                try handle.synchronize()
            }
        } catch {
            shared.recordDiagnostic("append write failed: \(error)")
        }
    }

    private static func rotate(url: URL) {
        let work = {
            shared.isRotating = true
            try? shared.writeHandle?.close()
            shared.writeHandle = nil
            shared.currentBytes = 0

            let dir = url.deletingLastPathComponent()
            let base = Self.fileName

            func rolled(_ n: Int) -> URL {
                dir.appendingPathComponent("\(base).\(n)")
            }

            // Remove the oldest rolled file — it will be evicted
            let maxURL = rolled(Self.maxRolledFiles)
            do {
                try FileManager.default.removeItem(at: maxURL)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                    shared.recordDiagnostic("rotate remove .\(Self.maxRolledFiles) failed: \(error)")
                }
            }

            // Shift existing rolled files up: .log.(i-1) → .log.(i)
            for i in (2...Self.maxRolledFiles).reversed() {
                let src = rolled(i - 1)
                let dst = rolled(i)
                do {
                    try FileManager.default.moveItem(at: src, to: dst)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                        shared.recordDiagnostic("rotate move .\(i-1) → .\(i) failed: \(error)")
                    }
                }
            }

            // Move active .log → .log.1 — atomic on APFS, crash-safe
            let dst1 = rolled(1)
            do {
                _ = try FileManager.default.replaceItemAt(dst1, withItemAt: url,
                                                           backupItemName: nil,
                                                           options: [])
            } catch {
                shared.recordDiagnostic("rotate move .log → .1 failed: \(error)")
            }

            shared.recordDiagnostic("rotated: .log → .1, .\(Self.maxRolledFiles) evicted")
            shared.isRotating = false
        }

        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            shared.queue.sync(execute: work)
        }
    }
}

// MARK: - LogLine

struct LogLine: Identifiable, Hashable {
    let id: Int
    let raw: String
    let level: LogLevel?
    let component: LogComponent?
    let timestamp: Date?
    let message: String?
    let payload: [String: Any]?
    /// SQLite row ID, populated by LogStore queries. FileLogger sets this to nil.
    let rowId: Int64?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(raw)
    }

    static func == (lhs: LogLine, rhs: LogLine) -> Bool {
        lhs.id == rhs.id && lhs.raw == rhs.raw
    }
}

// MARK: - Convenience extensions

extension FileLogger {
    func debug(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.debug, c, m, payload: payload) }
    func info (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.info,  c, m, payload: payload) }
    func warn (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.warn,  c, m, payload: payload) }
    func error(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.error, c, m, payload: payload) }
}
