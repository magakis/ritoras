import Foundation

enum FullRecordingUploadStageOutcome: String, Sendable {
    case notReached = "not_reached"
    case uploadDisabled = "upload_disabled"
    case missingToken = "missing_token"
    case finalTextEmpty = "final_text_empty"
    case sourceUnavailable = "source_unavailable"
    case stagingFailed = "staging_failed"
    case staged
    case cancelled
}

struct FullRecordingUploadTelemetry: Sendable {
    var uploadEnabled: Bool
    var tokenPresent: Bool
    var finalTextNonempty: Bool
    var streamWavPresent: Bool
    var stageOutcome: FullRecordingUploadStageOutcome
    var uploadAttempted: Bool
    var uploadCompleted: Bool
    var httpStatus: Int?
    var errorDomain: String?
}

final class ChunkSplitterTelemetryFileWriter: @unchecked Sendable, VADTelemetrySink, VADTelemetryFlushable {
    // Retain at most 20 telemetry files in app-target Application Support.
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
            "startedAt": formatter.string(from: Date()),
            "schema_version": 2,
            "retention": ["policy": "stratified_tail", "historical_limit": 1_500,
                          "tail_limit": 500, "payload_budget_bytes": 768 * 1024]
        ]
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            metadata["appVersion"] = appVersion
        }
        if let appBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            metadata["appBuildNumber"] = appBuildNumber
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

    func recordFullRecordingUploadOutcome(_ outcome: FullRecordingUploadTelemetry) {
        var metadata: [String: Any] = [
            "uploadEnabled": outcome.uploadEnabled,
            "tokenPresent": outcome.tokenPresent,
            "finalTextNonempty": outcome.finalTextNonempty,
            "streamWavPresent": outcome.streamWavPresent,
            "stageOutcome": outcome.stageOutcome.rawValue,
            "uploadAttempted": outcome.uploadAttempted,
            "uploadCompleted": outcome.uploadCompleted
        ]
        if let httpStatus = outcome.httpStatus {
            metadata["httpStatus"] = httpStatus
        }
        if let errorDomain = outcome.errorDomain {
            metadata["errorDomain"] = errorDomain
        }
        event(VADTelemetryEvent(kind: .fullRecordingUpload, metadata: metadata))
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
            "sourceStartSample": record.sourceStartSample,
            "sourceEndSample": record.sourceEndSample,
            "dt": record.frameDuration,
            "db": record.frameDb,
            "e": record.evidence,
            "sp": record.isSpeech,
            "ps": record.endpointPreviousState,
            "es": record.endpointState,
            "d": record.endpointDecision,
            "ss": record.decisionSilenceSamples,
            "us": record.utteranceDurationSamples
        ]
        if let floorConverged = record.floorConverged {
            object["fc"] = floorConverged
        }
        if let speechShaped = record.speechShaped {
            object["sh"] = speechShaped
        }
        if let threshold = record.strongThresholdDb {
            object["th"] = threshold
        }
        if let threshold = record.continuationThresholdDb {
            object["ct"] = threshold
        }
        if let threshold = record.silenceThresholdDb {
            object["st"] = threshold
        }
        if let floorDb = record.floorDb {
            object["fl"] = floorDb
        }
        if let dynamicsSpreadDb = record.dynamicsSpreadDb {
            object["dy"] = dynamicsSpreadDb
        }
        if let shortSpreadDb = record.shortSpreadDb {
            object["sdy"] = shortSpreadDb
        }
        if let highBandRatioDb = record.highBandRatioDb {
            object["hbr"] = highBandRatioDb
        }
        if record.isLoudRegime == true {
            object["lr"] = true
        }
        if let referenceDb = record.utteranceLevelReferenceDb {
            object["ur"] = referenceDb
        }
        if let qualification = record.utteranceLevelQualification {
            object["uq"] = qualification
        }
        object["ar"] = record.ambiguousRunSamples
        object["ac"] = record.ambiguousFrameCreditSamples
        object["wc"] = record.weightedSilenceCreditSamples
        object["ts"] = record.physicalTrailingSilenceSamples
        if let probability = record.sileroRawProbability {
            object["pr"] = probability
        }
        if let probability = record.sileroSmoothedProbability {
            object["pm"] = probability
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
        if let timestampMs = record.timestampMs {
            object["timestampMs"] = timestampMs
        }
        if let wallTimestampMs = record.wallTimestampMs {
            object["wallTimestampMs"] = wallTimestampMs
        }
        if let sourceStartSample = record.sourceStartSample {
            object["sourceStartSample"] = sourceStartSample
        }
        if let sourceEndSample = record.sourceEndSample {
            object["sourceEndSample"] = sourceEndSample
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
        if let metadata = record.metadata {
            object.merge(metadata) { _, new in new }
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
