import Foundation

final class StreamingVADTelemetry: @unchecked Sendable, VADTelemetrySink, VADTelemetryFlushable {
    private let writer: VADTelemetryFileWriter?
    private let lock = NSLock()
    private var frames: [VADTelemetryFrame] = []
    private var droppedFrames = 0
    private var configuration: [String: Any] = [:]
    private var emissions = 0
    private var decisions: [String: Int] = [:]
    private var speechFrames = 0
    private var silenceFrames = 0
    private var ambiguousFrames = 0
    private var speechMs = 0.0
    private var silenceMs = 0.0
    private var ambiguousMs = 0.0
    private var finalFloorDb: Double?
    private var floorConverged = false

    // At most 2,000 frames × a conservative 350 UTF-8 bytes/frame = 700 KB;
    // metadata is bounded well below the remaining ~348 KB of the 1 MiB limit.
    private static let maxFrames = 2_000

    init(writer: VADTelemetryFileWriter?) { self.writer = writer }

    func flushIfNeeded() { writer?.flushIfNeeded() }

    func flush() { writer?.flush() }

    func frame(_ record: VADTelemetryFrame) {
        writer?.frame(record)
        lock.lock()
        defer { lock.unlock() }
        if frames.count < Self.maxFrames { frames.append(record) } else { droppedFrames += 1 }
        if record.isSpeech { speechFrames += 1; speechMs += record.frameDuration * 1000 }
        else if record.evidence == "silence" { silenceFrames += 1; silenceMs += record.frameDuration * 1000 }
        else { ambiguousFrames += 1; ambiguousMs += record.frameDuration * 1000 }
        finalFloorDb = record.floorDb ?? finalFloorDb
        floorConverged = record.floorConverged
        decisions[record.endpointDecision, default: 0] += 1
    }

    func event(_ record: VADTelemetryEvent) {
        writer?.event(record)
        lock.lock()
        if record.kind == .sessionStart { configuration = record.config ?? [:] }
        if record.kind == .emit { emissions += 1 }
        lock.unlock()
    }

    func payload(jobId: UUID, startedAt: Date, duration: TimeInterval, now: Date = Date()) -> Data? {
        writer?.flush()
        lock.lock()
        let keptFrames = frames
        let droppedFramesAtSnapshot = droppedFrames
        var metadata: [String: Any] = [
            "schema_version": 1,
            "type": "TELEMETRY",
            "jobId": jobId.uuidString,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "client_timestamp": ISO8601DateFormatter().string(from: now),
            "timezone": TimeZone.current.identifier,
            "duration_seconds": duration,
            "sample_rate": 16_000,
            "vad_config": configuration,
            "summary": ["frame_count": speechFrames + silenceFrames + ambiguousFrames,
                        "speech_frames": speechFrames, "silence_frames": silenceFrames,
                        "ambiguous_frames": ambiguousFrames, "speech_ms": speechMs,
                        "silence_ms": silenceMs, "ambiguous_ms": ambiguousMs,
                        "final_noise_floor_db": finalFloorDb as Any? ?? NSNull(),
                        "floor_converged": floorConverged, "emission_count": emissions,
                        "endpoint_decisions": decisions, "frames_dropped": droppedFramesAtSnapshot],
            "frames": keptFrames.map { frame in
                var item: [String: Any] = ["q": frame.seq, "dt": frame.frameDuration, "db": frame.frameDb,
                    "e": frame.evidence, "sp": frame.isSpeech, "fc": frame.floorConverged,
                    "th": frame.strongThresholdDb, "ct": frame.continuationThresholdDb,
                    "st": frame.silenceThresholdDb, "ps": frame.endpointPreviousState,
                    "es": frame.endpointState, "d": frame.endpointDecision,
                    "ss": frame.decisionSilenceSamples, "us": frame.utteranceDurationSamples,
                    "ls": frame.latchStreakMs, "ll": frame.latchLatched, "lr": frame.isLoudRegime]
                if let floorDb = frame.floorDb { item["fl"] = floorDb }
                if let spread = frame.dynamicsSpreadDb { item["dy"] = spread }
                return item
            }
        ]
        lock.unlock()
        guard var frameObjects = metadata["frames"] as? [[String: Any]],
              var summary = metadata["summary"] as? [String: Any] else { return nil }
        let originalDropped = droppedFramesAtSnapshot
        while true {
            metadata["frames"] = frameObjects
            summary["frames_dropped"] = originalDropped + (keptFrames.count - frameObjects.count)
            metadata["summary"] = summary
            guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) else {
                FileLogger.shared.warn(.network, "Stream: VAD telemetry serialization failed")
                return nil
            }
            if data.count <= 768 * 1024 {
                let totalDropped = originalDropped + (keptFrames.count - frameObjects.count)
                if totalDropped > 0 {
                    FileLogger.shared.warn(.network, "Stream: VAD telemetry frames truncated", payload: ["framesDropped": totalDropped])
                }
                return data
            }
            guard !frameObjects.isEmpty else { return nil }
            frameObjects.removeLast(min(100, frameObjects.count))
        }
    }
}
