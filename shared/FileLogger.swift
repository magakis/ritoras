import Foundation

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
    private static let maxBytes: Int64 = 262_144           // 256 KB soft cap
    private static let rolledFileName = "ritoras-debug.log.1"

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
    private let diagnosticsCapacity = 32
    private static let queueKey = DispatchSpecificKey<Bool>()

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
            if diagnostics.count > diagnosticsCapacity {
                diagnostics.removeFirst(diagnostics.count - diagnosticsCapacity)
            }
        } else {
            queue.sync {
                self.diagnostics.append(entry)
                if self.diagnostics.count > self.diagnosticsCapacity {
                    self.diagnostics.removeFirst(self.diagnostics.count - self.diagnosticsCapacity)
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
        var line = "\(ts) [\(level.rawValue.uppercased())] [\(component.rawValue)] \(message)"
        if let payload = payload,
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            line += " \(json)"
        }
        line += "\n"
        queue.async { Self.append(line) }
    }

    static func clear() {
        shared.queue.sync {
            guard let url = shared.resolvedURL else { return }
            let rolled = url.deletingLastPathComponent().appendingPathComponent(rolledFileName)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                    shared.recordDiagnostic("clear remove failed: \(error)")
                }
            }
            do {
                try FileManager.default.removeItem(at: rolled)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                    shared.recordDiagnostic("clear remove rolled failed: \(error)")
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
        return lines.enumerated().map { (index, line) in
            let raw = String(line)
            let level: LogLevel?
            if raw.contains(" [DEBUG] ") { level = .debug }
            else if raw.contains(" [INFO] ") { level = .info }
            else if raw.contains(" [WARN] ") { level = .warn }
            else if raw.contains(" [ERROR] ") { level = .error }
            else { level = nil }
            return LogLine(id: index, raw: raw, level: level)
        }
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

        // Write the line
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer {
                do { try handle.close() }
                catch { shared.recordDiagnostic("handle close failed: \(error)") }
            }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        } catch {
            // File doesn't exist or can't be opened for writing — create it
            do {
                try line.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                shared.recordDiagnostic("write failed: \(error)")
            }
        }
    }

    private static func rotate(url: URL) {
        let rolled = url.deletingLastPathComponent().appendingPathComponent(rolledFileName)
        do {
            try FileManager.default.removeItem(at: rolled)
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                shared.recordDiagnostic("rotate remove failed: \(error)")
            }
        }
        do {
            try FileManager.default.moveItem(at: url, to: rolled)
        } catch {
            shared.recordDiagnostic("rotate move failed: \(error)")
        }
    }
}

// MARK: - LogLine

struct LogLine: Identifiable, Hashable {
    let id: Int
    let raw: String
    let level: LogLevel?
}

// MARK: - Convenience extensions

extension FileLogger {
    func debug(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.debug, c, m, payload: payload) }
    func info (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.info,  c, m, payload: payload) }
    func warn (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.warn,  c, m, payload: payload) }
    func error(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.error, c, m, payload: payload) }
}
