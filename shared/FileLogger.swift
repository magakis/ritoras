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
    private init() {}

    private static let fileName = "ritoras-debug.log"
    private static let maxBytes: Int64 = 1_000_000           // 1 MB soft cap
    private static let rolledFileName = "ritoras-debug.log.1"

    private static var logFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else { return nil }
        return container.appendingPathComponent(fileName)
    }

    private let queue = DispatchQueue(label: "ritoras.filelogger", qos: .utility)
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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
        guard let url = logFileURL else { return }
        let rolled = url.deletingLastPathComponent().appendingPathComponent(rolledFileName)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rolled)
    }

    static func contents() -> String? {
        guard let url = logFileURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func fileURL() -> URL? { logFileURL }

    private static func append(_ line: String) {
        guard let url = logFileURL else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
           size > maxBytes {
            rotate(url: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) { handle.write(data) }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func rotate(url: URL) {
        let rolled = url.deletingLastPathComponent().appendingPathComponent(rolledFileName)
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: url, to: rolled)
    }
}

extension FileLogger {
    func debug(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.debug, c, m, payload: payload) }
    func info (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.info,  c, m, payload: payload) }
    func warn (_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.warn,  c, m, payload: payload) }
    func error(_ c: LogComponent, _ m: String, payload: [String: Any]? = nil) { log(.error, c, m, payload: payload) }
}
