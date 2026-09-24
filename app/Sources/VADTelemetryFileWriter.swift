import Foundation

final class VADTelemetryFileWriter: @unchecked Sendable, VADTelemetrySink, VADTelemetryFlushable {
    // 20 one-minute recordings at ~50 frames/s × ~180 B (~7.5 KB/s)
    // stay under ~10 MB; app-target Application Support only.
    private static let maxFiles = 20
    private static let flushByteLimit = 64 * 1024
    private static let flushInterval: TimeInterval = 1.0

    private let fileManager = FileManager.default
    private let url: URL
    private let lock = NSLock()
    private var pendingLines: [String] = []
    private var pendingBytes = 0
    private var eventFlushRequested = false
    private var lastFlushAt = Date()

    init(url: URL, jobId: UUID) {
        self.url = url
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var metadata: [String: Any] = [
            "t": "meta",
            "jobId": jobId.uuidString,
            "startedAt": formatter.string(from: Date())
        ]
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            metadata["appVersion"] = appVersion
        }
        if let line = serialize(metadata) {
            pendingLines.append(line)
            pendingBytes += line.utf8.count
            flush(force: true)
        }
        rotateFiles()
    }

    func frame(_ record: VADTelemetryFrame) {
        guard let line = jsonLine(for: record) else { return }
        lock.lock()
        defer { lock.unlock() }
        pendingLines.append(line)
        pendingBytes += line.utf8.count
    }

    func event(_ record: VADTelemetryEvent) {
        guard let line = jsonLine(for: record) else { return }
        lock.lock()
        defer { lock.unlock() }
        pendingLines.append(line)
        pendingBytes += line.utf8.count
        eventFlushRequested = true
    }

    func recordOutcome(_ outcome: String) {
        event(VADTelemetryEvent(kind: .outcome, reason: outcome))
        flush(force: true)
    }

    func flushIfNeeded() {
        flush(force: false)
    }

    func flush() {
        flush(force: true)
    }

    private func flush(force: Bool) {
        let batch: (lines: [String], data: Data)?
        lock.lock()
        let shouldFlush = force
            || eventFlushRequested
            || pendingBytes >= Self.flushByteLimit
            || Date().timeIntervalSince(lastFlushAt) >= Self.flushInterval
        if shouldFlush, !pendingLines.isEmpty {
            let lines = pendingLines
            pendingLines.removeAll(keepingCapacity: true)
            pendingBytes = 0
            eventFlushRequested = false
            lastFlushAt = Date()
            let output = lines.joined()
            batch = (lines, Data(output.utf8))
        } else {
            batch = nil
        }
        lock.unlock()

        guard let batch else { return }
        guard append(batch.data) else {
            lock.lock()
            pendingLines.insert(contentsOf: batch.lines, at: 0)
            pendingBytes += batch.data.count
            eventFlushRequested = true
            lock.unlock()
            return
        }
    }

    private func append(_ data: Data) -> Bool {
        do {
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil) else {
                    return false
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func rotateFiles() {
        let directory = url.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let telemetryFiles = entries.filter { $0.lastPathComponent.hasSuffix("-vad.jsonl") }
        func modificationDate(for url: URL) -> Date {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return .distantPast }
            return date
        }
        let newest = telemetryFiles.sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }

        for file in newest.dropFirst(Self.maxFiles) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func jsonLine(for record: VADTelemetryFrame) -> String? {
        var object: [String: Any] = [
            "t": "f",
            "q": Int(record.seq),
            "dt": record.frameDuration,
            "db": record.frameDb,
            "e": record.evidence,
            "sp": record.isSpeech,
            "th": record.strongThresholdDb,
            "ct": record.continuationThresholdDb,
            "st": record.silenceThresholdDb,
            "ps": record.endpointPreviousState,
            "es": record.endpointState,
            "d": record.endpointDecision,
            "ss": record.decisionSilenceSamples,
            "us": record.utteranceDurationSamples,
            "ls": record.latchStreakMs,
            "ll": record.latchLatched
        ]
        if let floorDb = record.floorDb {
            object["fl"] = floorDb
        }
        if let dynamicsSpreadDb = record.dynamicsSpreadDb {
            object["dy"] = dynamicsSpreadDb
        }
        return serialize(object)
    }

    private func jsonLine(for record: VADTelemetryEvent) -> String? {
        var object: [String: Any] = [
            "t": "ev",
            "k": record.kind.rawValue
        ]
        if let chunkId = record.chunkId {
            object["id"] = Int(chunkId)
        }
        if let samples = record.samples {
            object["n"] = samples
        }
        if let reason = record.reason {
            object["r"] = reason
        }
        if let speechMs = record.speechMs {
            object["sm"] = speechMs
        }
        if let totalMs = record.totalMs {
            object["tm"] = totalMs
        }
        if let config = record.config {
            object["c"] = config
        }
        if let startMs = record.startMs {
            object["s0"] = startMs
        }
        if let endMs = record.endMs {
            object["s1"] = endMs
        }
        if let endpointState = record.endpointState {
            object["es"] = endpointState
        }
        if let latencyMs = record.latencyMs {
            object["lat"] = latencyMs
        }
        if let chars = record.chars {
            object["ch"] = chars
        }
        return serialize(object)
    }

    private func serialize(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line + "\n"
    }
}
