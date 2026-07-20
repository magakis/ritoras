import Foundation
import os

enum LogLevel: String { case debug, info, warn, error }

enum LogComponent: String {
    case keyboard = "Keyboard"
    case app = "ContainerApp"
    case transcription = "Transcription"
    case audio = "Audio"
    case dictionary = "Dictionary"
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
        queue.async { Self.append("[init] resolvedURL=\(urlDesc) fallback=\(fallback)") }
    }

    private static let fileName = "ritoras-debug.log"
    private static let maxBytes: Int64 = 524_288           // 512 KB soft cap
    private static let maxRolledFiles = 4

    // ── os.Logger probe (Phase 3a) ───────────────────────────────────
    private static let probeLogger = Logger(subsystem: "com.ritoras.app", category: "probe")
    private static var probeEmitted = false

    private let resolvedURL: URL?
    private let usingFallbackDir: Bool

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

        let write = { Self.append(line) }

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

            // Phase 3a: emit os.Logger probe exactly once per process lifetime.
            if !Self.probeEmitted {
                Self.probeEmitted = true
                Self.probeLogger.notice("ritoras probe: \(level.rawValue, privacy: .public) path reached for component \(component.rawValue, privacy: .public)")
            }
        case .debug, .info:
            queue.async(execute: write)
        }
    }

    static func clear() {
        shared.queue.sync {
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
    }

    static func contents() -> String? {
        shared.queue.sync {
            guard let url = shared.resolvedURL else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    static func fileURL() -> URL? { shared.resolvedURL }

    static func parsedLines() -> [LogLine] {
        guard let content = contents() else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { parseLine(String($0.element), id: $0.offset) }
    }

    static func parsedLinesAllFiles() -> [LogLine] {
        guard let dir = shared.resolvedURL?.deletingLastPathComponent() else { return [] }
        let base = Self.fileName

        var allLines: [String] = []

        // Iterate oldest first: .log.4 → .log.3 → .log.2 → .log.1 → .log
        for i in (1...Self.maxRolledFiles).reversed() {
            let url = dir.appendingPathComponent("\(base).\(i)")
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fileLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            allLines.append(contentsOf: fileLines.map(String.init))
        }

        // Active file
        if let url = shared.resolvedURL,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let fileLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            allLines.append(contentsOf: fileLines.map(String.init))
        }

        return allLines.enumerated().map { parseLine($0.element, id: $0.offset) }
    }

    private static func parseLine(_ raw: String, id: Int) -> LogLine {
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
                           timestamp: timestamp, message: message, payload: payload)
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
                       timestamp: timestamp, message: nil, payload: nil)
    }

    // ── File I/O ────────────────────────────────────────────────────

    private static func append(_ line: String) {
        guard let url = shared.resolvedURL else {
            shared.recordDiagnostic("append skipped: no URL")
            return
        }

        // Check size and rotate if needed
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int64, size > maxBytes {
                rotate(url: url)
            }
        } catch {
            // File doesn't exist yet — first write is expected; no diagnostic needed.
        }

        // Atomic append: write to temp file then replace into place.
        // This guarantees the active file is never left in a partially-written
        // state after a crash.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".ritoras-debug-log.tmp")

        do {
            var data = (try? Data(contentsOf: url)) ?? Data()
            if let newData = line.data(using: .utf8) {
                data.append(newData)
            }
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL,
                                                       backupItemName: nil,
                                                       options: [])
        } catch {
            shared.recordDiagnostic("append atomic write failed: \(error)")
            // Best-effort temp file cleanup
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private static func rotate(url: URL) {
        let work = {
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LogLine, rhs: LogLine) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Convenience extensions

extension FileLogger {
    func debug(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.debug, c, m, payload: payload) }
    func info (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.info,  c, m, payload: payload) }
    func warn (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.warn,  c, m, payload: payload) }
    func error(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.error, c, m, payload: payload) }
}
