import Foundation
import CoreFoundation

enum VADTelemetryDigest {
    static let defaultBudget = 96 * 1024

    struct RecordingSummary {
        struct TimelinePoint {
            let time: Double
            let frameDb: Double
            let floorDb: Double?
            let isSpeech: Bool
        }

        let jobId: String
        let startedAt: String
        let durationSeconds: Double
        let outcome: String
        let parameters: [String: Any]?
        let frameCount: Int
        let speechPercent: Int?
        let decisionTallies: [String: Int]
        let chunkCount: Int
        let emittedSpeechSeconds: Double
        let emittedChunkSeconds: Double
        let floorFirst: Double?
        let floorMinimum: Double?
        let floorMaximum: Double?
        let floorLast: Double?
        let timeline: [TimelinePoint]
        fileprivate let orderingDate: Date?
    }

    private struct LoadedSummary {
        let summary: RecordingSummary
        let sourceOrder: Int
    }

    private static let parameterNames = [
        "endpointOnsetMs": "onset",
        "endpointEndEvidenceMs": "endEvidence",
        "endpointSilenceMs": "endpointSilence",
        "endpointResumeMs": "resume",
        "endpointAmbiguousRescueMs": "rescue",
        "endpointPreRollMs": "preRoll",
        "strongDeltaDb": "strongDelta",
        "continuationDeltaDb": "continuationDelta",
        "silenceDeltaDb": "silenceDelta",
        "dynamicsSpreadDb": "dynamicsSpread",
        "flatSpreadDb": "flatSpread",
        "riseMultiplier": "adaptationSpeed"
    ]
    private static let parameterOrder = [
        "endpointOnsetMs",
        "endpointEndEvidenceMs",
        "endpointSilenceMs",
        "endpointResumeMs",
        "endpointAmbiguousRescueMs",
        "endpointPreRollMs",
        "minSpeechMs",
        "minChunkMs"
    ]

    static func buildText(
        files: [URL],
        globalSettings: [(String, String)],
        budget: Int = defaultBudget
    ) -> String {
        let loadedSummaries = files.enumerated().compactMap { index, url -> LoadedSummary? in
            guard let fallbackJobId = jobIdFromFilename(url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }
            let records = parseLines(text)
            guard let summary = summarize(
                records: records,
                fallbackJobId: fallbackJobId,
                modifiedAt: modificationDate(for: url)
            ) else {
                return nil
            }
            return LoadedSummary(summary: summary, sourceOrder: index)
        }.sorted { lhs, rhs in
            switch (lhs.summary.orderingDate, rhs.summary.orderingDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.sourceOrder < rhs.sourceOrder
            }
        }

        return renderText(
            summaries: loadedSummaries.map(\.summary),
            globalSettings: globalSettings,
            budget: max(0, budget),
            exportedAt: Date()
        )
    }

    static func summarize(
        records: [[String: Any]],
        fallbackJobId: String,
        modifiedAt: Date? = nil
    ) -> RecordingSummary? {
        let meta = records.first { $0["t"] as? String == "meta" }
        let jobId = (meta?["jobId"] as? String).flatMap { validJobId($0) ? $0 : nil }
            ?? fallbackJobId
        let parsedStartDate = (meta?["startedAt"] as? String).flatMap(parseDate)
        let startedAt = parsedStartDate.map(formatUTC) ?? "unknown"
        let frames = records.filter { $0["t"] as? String == "f" }
        let events = records.filter { $0["t"] as? String == "ev" }

        var duration = 0.0
        var foundFrameDuration = false
        var missingFrameDuration = false
        var timeline: [RecordingSummary.TimelinePoint] = []
        var timelineTime = 0.0
        var nextTimelineTime = 0.0
        var floors: [Double] = []
        var speechFrames = 0
        var decisionTallies = ["emit": 0, "resume": 0, "rescue": 0]

        for frame in frames {
            let frameDuration = number(frame["dt"])
            if let frameDuration, frameDuration >= 0 {
                duration += frameDuration
                foundFrameDuration = true
            } else {
                missingFrameDuration = true
            }
            if let floor = number(frame["fl"]) {
                floors.append(floor)
            }
            let isSpeech = frame["sp"] as? Bool ?? false
            if isSpeech { speechFrames += 1 }

            let decision = frame["d"] as? String ?? ""
            if decision.hasPrefix("finalize_") {
                decisionTallies["emit", default: 0] += 1
            }
            if frame["ps"] as? String == "endPending",
               frame["es"] as? String == "speechActive" {
                switch frame["e"] as? String {
                case "strong", "continuing":
                    decisionTallies["resume", default: 0] += 1
                case "ambiguous":
                    decisionTallies["rescue", default: 0] += 1
                default:
                    break
                }
            }

            if timelineTime + 1e-9 >= nextTimelineTime,
               let frameDb = number(frame["db"]) {
                timeline.append(RecordingSummary.TimelinePoint(
                    time: timelineTime,
                    frameDb: frameDb,
                    floorDb: number(frame["fl"]),
                    isSpeech: isSpeech
                ))
                while nextTimelineTime <= timelineTime + 1e-9 {
                    nextTimelineTime += 0.25
                }
            }
            timelineTime += frameDuration.flatMap { $0 >= 0 ? $0 : nil } ?? 0
        }

        if !foundFrameDuration || missingFrameDuration || duration == 0 {
            if let sequence = frames.reversed().compactMap({ number($0["q"]) }).first,
               let frameDuration = frames.reversed().compactMap({ number($0["dt"]) }).first,
               sequence >= 0, frameDuration >= 0 {
                duration = sequence * frameDuration
            }
        }

        let startEvent = events.first { $0["k"] as? String == "session_start" }
        let parameters = startEvent?["c"] as? [String: Any]
        let outcome = events.last(where: { $0["k"] as? String == "outcome" })?["r"] as? String
            ?? "unknown"
        let emittedEvents = events.filter { $0["k"] as? String == "emit" }
        let emittedSpeechSeconds = emittedEvents.reduce(0.0) { total, event in
            total + (number(event["sm"]) ?? 0) / 1000.0
        }
        let emittedChunkSeconds = emittedEvents.reduce(0.0) { total, event in
            total + (number(event["tm"]) ?? 0) / 1000.0
        }
        let jobIdMatches = validJobId(jobId)
        guard jobIdMatches else { return nil }

        return RecordingSummary(
            jobId: jobId,
            startedAt: startedAt,
            durationSeconds: duration,
            outcome: outcome,
            parameters: parameters,
            frameCount: frames.count,
            speechPercent: frames.isEmpty ? nil : Int((Double(speechFrames) / Double(frames.count) * 100).rounded()),
            decisionTallies: decisionTallies,
            chunkCount: emittedEvents.count,
            emittedSpeechSeconds: emittedSpeechSeconds,
            emittedChunkSeconds: emittedChunkSeconds,
            floorFirst: floors.first,
            floorMinimum: floors.min(),
            floorMaximum: floors.max(),
            floorLast: floors.last,
            timeline: timeline,
            orderingDate: parsedStartDate ?? modifiedAt
        )
    }

    private static func renderText(
        summaries: [RecordingSummary],
        globalSettings: [(String, String)],
        budget: Int,
        exportedAt: Date
    ) -> String {
        var stride = 1
        var removedTimelines = Set<Int>()
        var text = render(
            summaries: summaries,
            globalSettings: globalSettings,
            budget: budget,
            exportedAt: exportedAt,
            timelineStride: stride,
            removedTimelines: removedTimelines
        )

        while text.utf8.count > budget,
              summaries.contains(where: { $0.timeline.count > 1 && $0.timeline.count / (stride * 2) > 0 }) {
            stride *= 2
            text = render(
                summaries: summaries,
                globalSettings: globalSettings,
                budget: budget,
                exportedAt: exportedAt,
                timelineStride: stride,
                removedTimelines: removedTimelines
            )
        }

        if text.utf8.count > budget {
            for index in summaries.indices.reversed() where !summaries[index].timeline.isEmpty {
                removedTimelines.insert(index)
                text = render(
                    summaries: summaries,
                    globalSettings: globalSettings,
                    budget: budget,
                    exportedAt: exportedAt,
                    timelineStride: stride,
                    removedTimelines: removedTimelines
                )
                if text.utf8.count <= budget { break }
            }
        }
        return text
    }

    private static func render(
        summaries: [RecordingSummary],
        globalSettings: [(String, String)],
        budget: Int,
        exportedAt: Date,
        timelineStride: Int,
        removedTimelines: Set<Int>
    ) -> String {
        let telemetryValue = globalSettings.first(where: { $0.0 == "telemetryEnabled" })?.1 ?? "ON"
        let budgetKilobytes = (budget + 1023) / 1024
        var lines = [
            "Ritoras VAD digest v1 — exported \(formatUTC(exportedAt))",
            "recordings: \(summaries.count) retained (telemetry toggle currently \(telemetryValue)) | budget: \(budgetKilobytes) KB",
            "",
            "== Current global VAD settings ==",
            globalSettings.map { "\($0.0)=\($0.1)" }.joined(separator: " "),
            ""
        ]

        for (index, summary) in summaries.enumerated() {
            let ordinal = index + 1
            let newestLabel = index == 0 ? " (newest)" : ""
            lines.append("== Recording \(ordinal)/\(summaries.count)\(newestLabel) ==")
            lines.append("job=\(summary.jobId) started=\(summary.startedAt) dur=\(fixed(summary.durationSeconds, digits: 1))s outcome=\(summary.outcome)")
            lines.append("chunks=\(summary.chunkCount) emitted speech=\(fixed(summary.emittedSpeechSeconds, digits: 1))s/\(fixed(summary.emittedChunkSeconds, digits: 1))s")
            lines.append(formatParameters(summary.parameters))
            lines.append("floorDb first/min/max/last=\(optionalFixed(summary.floorFirst))/\(optionalFixed(summary.floorMinimum))/\(optionalFixed(summary.floorMaximum))/\(optionalFixed(summary.floorLast))")
            let speechPercent = summary.speechPercent.map(String.init) ?? "n/a"
            let decisions = ["emit", "resume", "rescue"].map { key in
                "\(key)=\(summary.decisionTallies[key, default: 0])"
            }.joined(separator: ",")
            lines.append("frames n=\(summary.frameCount) speech%=\(speechPercent) decisions{\(decisions)}")
            lines.append(formatTimeline(
                summary.timeline,
                stride: timelineStride,
                truncated: removedTimelines.contains(index)
            ))
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func formatParameters(_ parameters: [String: Any]?) -> String {
        guard let parameters else { return "params=unknown" }
        let hasStaleFloorBreakdown = number(parameters["staleFloorSeconds"]) != nil
            && number(parameters["staleFloorSecondsRaw"]) != nil
            && number(parameters["riseSpeedMultiplier"]) != nil
        let values = parameters.keys.sorted(by: parameterKeyComesFirst).compactMap { key -> String? in
            if hasStaleFloorBreakdown,
               key == "staleFloorSecondsRaw" || key == "riseSpeedMultiplier" {
                return nil
            }
            guard let value = parameters[key] else { return nil }
            let name: String
            let renderedValue: String
            if key == "staleFloorSeconds", hasStaleFloorBreakdown,
               let effective = number(parameters["staleFloorSeconds"]),
               let raw = number(parameters["staleFloorSecondsRaw"]),
               let multiplier = number(parameters["riseSpeedMultiplier"]) {
                name = "staleFloor"
                renderedValue = "eff=\(fixed(effective, digits: 2))s (raw=\(fixed(raw, digits: 1))s ÷ ×\(fixed(multiplier, digits: 1)))"
            } else {
                name = parameterNames[key] ?? key
                renderedValue = parameterValue(value, key: key)
            }
            return "\(name)=\(renderedValue)"
        }
        return "params(\(values.joined(separator: " ")))"
    }

    private static func parameterKeyComesFirst(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "mode" { return false }
        if rhs == "mode" { return true }
        let lhsOrder = parameterOrder.firstIndex(of: lhs) ?? Int.max
        let rhsOrder = parameterOrder.firstIndex(of: rhs) ?? Int.max
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return lhs < rhs
    }

    private static func parameterValue(_ value: Any, key: String) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let numericValue = number.doubleValue
            if key.hasSuffix("Ms") {
                return "\(compact(numericValue))ms"
            }
            if key.hasSuffix("Db") || key.hasSuffix("SpreadDb") {
                return "\(fixed(numericValue, digits: 1))dB"
            }
            if key.hasSuffix("Seconds") || key.hasSuffix("Sec") {
                return "\(fixed(numericValue, digits: 1))s"
            }
            if key.hasSuffix("Hz") {
                return "\(compact(numericValue))Hz"
            }
            return compact(numericValue)
        }
        return String(describing: value)
    }

    private static func formatTimeline(
        _ points: [RecordingSummary.TimelinePoint],
        stride: Int,
        truncated: Bool
    ) -> String {
        let selected = points.enumerated().compactMap { index, point in
            index % stride == 0 ? point : nil
        }
        let didTruncate = truncated || selected.count < points.count
        var values = selected.map { point in
            let floor = point.floorDb.map { fixed($0, digits: 1) } ?? "n/a"
            let speech = point.isSpeech ? "S" : "-"
            return "\(timelineTime(point.time)):\(fixed(point.frameDb, digits: 1)):\(floor):\(speech)"
        }
        if didTruncate { values.append("…truncated") }
        return "timeline(250ms decimated): \(values.isEmpty ? "n/a" : values.joined(separator: " "))"
    }

    private static func parseLines(_ text: String) -> [[String: Any]] {
        var records: [[String: Any]] = []
        text.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let record = value as? [String: Any] else {
                return
            }
            records.append(record)
        }
        return records
    }

    private static func jobIdFromFilename(_ filename: String) -> String? {
        guard filename.hasSuffix("-vad.jsonl") else { return nil }
        let jobId = String(filename.dropLast("-vad.jsonl".count))
        return validJobId(jobId) ? jobId : nil
    }

    private static func validJobId(_ jobId: String) -> Bool {
        jobId.range(
            of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
            options: .regularExpression
        ) != nil
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func formatUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private static func fixed(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }

    private static func optionalFixed(_ value: Double?) -> String {
        value.map { fixed($0, digits: 1) } ?? "n/a"
    }

    private static func compact(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return fixed(value, digits: 1)
    }

    private static func timelineTime(_ value: Double) -> String {
        let formatted = fixed(value, digits: 2)
        var compacted = formatted
        while compacted.last == "0" { compacted.removeLast() }
        if compacted.last == "." { compacted += "0" }
        return compacted
    }
}
