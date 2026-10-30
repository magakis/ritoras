import Foundation

final class StreamingChunkSplitterTelemetry: @unchecked Sendable, VADTelemetrySink, VADTelemetryFlushable {
    private let writer: ChunkSplitterTelemetryFileWriter?
    private let lock = NSLock()
    private var historicalFrames: [VADTelemetryFrame] = []
    private var tailFrames: [VADTelemetryFrame] = []
    private var droppedHistoricalFrames = 0
    private var droppedTailFrames = 0
    private var events: [VADTelemetryEvent] = []
    private var chunkTimings: [UInt32: (startMs: Double, endMs: Double)] = [:]
    private var droppedEvents = 0
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

    private static let tailFrameLimit = 500
    private static let historicalFrameLimit = 1_500
    private static let maxEvents = 256
    private static let payloadBudgetBytes = 768 * 1024

    init(writer: ChunkSplitterTelemetryFileWriter?) { self.writer = writer }

    func flushIfNeeded() { writer?.flushIfNeeded() }

    func flush() { writer?.flush() }

    func frame(_ record: VADTelemetryFrame) {
        writer?.frame(record)
        lock.lock()
        defer { lock.unlock() }
        tailFrames.append(record)
        if tailFrames.count > Self.tailFrameLimit {
            historicalFrames.append(tailFrames.removeFirst())
            if historicalFrames.count > Self.historicalFrameLimit {
                let before = historicalFrames.count
                historicalFrames = historicalFrames.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
                droppedHistoricalFrames += before - historicalFrames.count
            }
        }
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
        if events.count == Self.maxEvents {
            events.removeFirst()
            droppedEvents += 1
        }
        events.append(record)
        if record.kind == .emit, let chunkId = record.chunkId,
           let startMs = record.startMs, let endMs = record.endMs {
            chunkTimings[chunkId] = (startMs, endMs)
        }
        if record.kind == .sessionStart { configuration = record.config ?? [:] }
        if record.kind == .emit { emissions += 1 }
        lock.unlock()
    }

    func chunkFinalSegments(texts: [UInt32: String]) -> [ChunkFinalSegment] {
        lock.lock()
        let timings = chunkTimings
        lock.unlock()
        return texts.keys.sorted().compactMap { chunkId in
            guard let text = texts[chunkId], let timing = timings[chunkId] else { return nil }
            return ChunkFinalSegment(chunkId: chunkId, chunkLocalText: text,
                                     startMs: timing.startMs, endMs: timing.endMs)
        }
    }

    func payload(jobId: UUID, startedAt: Date, duration: TimeInterval, now: Date = Date()) -> Data? {
        writer?.flush()
        lock.lock()
        let historicalSnapshot = historicalFrames
        let tailSnapshot = tailFrames
        let eventSnapshot = events
        let droppedHistoricalAtSnapshot = droppedHistoricalFrames
        let droppedTailAtSnapshot = droppedTailFrames
        let droppedEventsAtSnapshot = droppedEvents
        var metadata: [String: Any] = [
            "schema_version": 2,
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
                        "endpoint_decisions": decisions,
                        "retention": ["policy": "stratified_tail", "historical_limit": Self.historicalFrameLimit,
                                      "tail_limit": Self.tailFrameLimit,
                                      "historical_dropped": droppedHistoricalAtSnapshot,
                                      "tail_dropped": droppedTailAtSnapshot,
                                      "events_dropped": droppedEventsAtSnapshot]],
            "events": eventSnapshot.map { event in
                var item: [String: Any] = ["k": event.kind.rawValue]
                if let reason = event.reason { item["r"] = reason }
                if let id = event.chunkId { item["id"] = Int(id) }
                if let samples = event.samples { item["n"] = samples }
                if let speechMs = event.speechMs { item["sm"] = speechMs }
                if let totalMs = event.totalMs { item["tm"] = totalMs }
                if let config = event.config { item["c"] = config }
                if let startMs = event.startMs { item["s0"] = startMs }
                if let endMs = event.endMs { item["s1"] = endMs }
                if let timestampMs = event.timestampMs {
                    item["timestampMs"] = timestampMs
                }
                if let wallTimestampMs = event.wallTimestampMs {
                    item["wallTimestampMs"] = wallTimestampMs
                }
                if let sourceStartSample = event.sourceStartSample {
                    item["sourceStartSample"] = sourceStartSample
                }
                if let sourceEndSample = event.sourceEndSample {
                    item["sourceEndSample"] = sourceEndSample
                }
                if let endpointState = event.endpointState { item["es"] = endpointState }
                if let latencyMs = event.latencyMs { item["lat"] = latencyMs }
                if let chars = event.chars { item["ch"] = chars }
                if let metadata = event.metadata { item.merge(metadata) { _, new in new } }
                return item
            },
            "frames": (historicalSnapshot + tailSnapshot).map { frame in
                var item: [String: Any] = ["q": frame.seq,
                    "sourceStartSample": frame.sourceStartSample,
                    "sourceEndSample": frame.sourceEndSample,
                    "dt": frame.frameDuration, "db": frame.frameDb,
                    "e": frame.evidence, "sp": frame.isSpeech, "fc": frame.floorConverged,
                    "th": frame.strongThresholdDb, "ct": frame.continuationThresholdDb,
                     "st": frame.silenceThresholdDb, "ps": frame.endpointPreviousState,
                     "es": frame.endpointState, "d": frame.endpointDecision,
                     "ss": frame.decisionSilenceSamples, "us": frame.utteranceDurationSamples,
                     "lr": frame.isLoudRegime, "sh": frame.speechShaped]
                if let floorDb = frame.floorDb { item["fl"] = floorDb }
                if let spread = frame.dynamicsSpreadDb { item["dy"] = spread }
                if let spread = frame.shortSpreadDb { item["sdy"] = spread }
                if let ratio = frame.highBandRatioDb { item["hbr"] = ratio }
                if let referenceDb = frame.utteranceLevelReferenceDb { item["ur"] = referenceDb }
                item["uq"] = frame.utteranceLevelQualification
                item["ar"] = frame.ambiguousRunSamples
                item["ac"] = frame.ambiguousFrameCreditSamples
                item["wc"] = frame.weightedSilenceCreditSamples
                item["ts"] = frame.physicalTrailingSilenceSamples
                return item
            }
        ]
        lock.unlock()
        guard var summary = metadata["summary"] as? [String: Any] else { return nil }
        let originalHistoricalDropped = droppedHistoricalAtSnapshot
        let originalTailDropped = droppedTailAtSnapshot
        var historyCount = historicalSnapshot.count
        let tailCount = tailSnapshot.count
        while true {
            let allFrames = historicalSnapshot.prefix(historyCount) + tailSnapshot.suffix(tailCount)
            metadata["frames"] = Array(allFrames).map { frame in
                var item: [String: Any] = ["q": frame.seq,
                    "sourceStartSample": frame.sourceStartSample,
                    "sourceEndSample": frame.sourceEndSample,
                    "dt": frame.frameDuration, "db": frame.frameDb,
                    "e": frame.evidence, "sp": frame.isSpeech, "fc": frame.floorConverged,
                    "th": frame.strongThresholdDb, "ct": frame.continuationThresholdDb,
                     "st": frame.silenceThresholdDb, "ps": frame.endpointPreviousState,
                     "es": frame.endpointState, "d": frame.endpointDecision,
                     "ss": frame.decisionSilenceSamples, "us": frame.utteranceDurationSamples,
                     "lr": frame.isLoudRegime, "sh": frame.speechShaped]
                if let floorDb = frame.floorDb { item["fl"] = floorDb }
                if let spread = frame.dynamicsSpreadDb { item["dy"] = spread }
                if let spread = frame.shortSpreadDb { item["sdy"] = spread }
                if let ratio = frame.highBandRatioDb { item["hbr"] = ratio }
                if let referenceDb = frame.utteranceLevelReferenceDb { item["ur"] = referenceDb }
                item["uq"] = frame.utteranceLevelQualification
                item["ar"] = frame.ambiguousRunSamples
                item["ac"] = frame.ambiguousFrameCreditSamples
                item["wc"] = frame.weightedSilenceCreditSamples
                item["ts"] = frame.physicalTrailingSilenceSamples
                return item
            }
            let trimHistory = historicalSnapshot.count - historyCount
            let trimTail = tailSnapshot.count - tailCount
            summary["retention"] = ["policy": "stratified_tail", "historical_limit": Self.historicalFrameLimit,
                "tail_limit": Self.tailFrameLimit, "historical_dropped": originalHistoricalDropped + trimHistory,
                "tail_dropped": originalTailDropped + trimTail, "events_dropped": droppedEventsAtSnapshot]
            metadata["summary"] = summary
            guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) else {
                FileLogger.shared.warn(.network, "Stream: chunk splitter telemetry serialization failed")
                return nil
            }
            if data.count <= Self.payloadBudgetBytes {
                let totalDropped = originalHistoricalDropped + originalTailDropped + trimHistory + trimTail
                if totalDropped > 0 {
                    FileLogger.shared.warn(.network, "Stream: chunk splitter telemetry frames truncated", payload: ["framesDropped": totalDropped])
                }
                return data
            }
            if historyCount > 0 { historyCount = max(0, historyCount - 100) }
            else { return nil }
        }
    }
}
