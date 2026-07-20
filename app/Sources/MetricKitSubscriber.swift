import Foundation
import MetricKit

// MARK: - MetricReport

struct MetricReport: Identifiable, Hashable {
    let id: Int
    let timestamp: Date
    let kind: String
    let summary: String
    let rawJSON: String
}

// MARK: - MetricKitSubscriber

final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitSubscriber()

    private static let fileName = "ritoras-metric-reports.jsonl"
    private static let maxReports = 50
    private static var _nextID: Int = 0

    private static let queue = DispatchQueue(label: "ritoras.metrickit", qos: .utility)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Registers the subscriber with `MXMetricManager`. Call from app launch
    /// (not from view appear) to avoid delaying first-frame presentation.
    func start() {
        MXMetricManager.shared.add(self)
    }

    /// Reads stored MetricKit reports from disk, returns newest-first.
    /// Tolerates corrupt or malformed lines by skipping them.
    static func loadReports() -> [MetricReport] {
        guard let url = fileURL() else { return [] }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var reports: [MetricReport] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int,
                  let tsStr = obj["ts"] as? String,
                  let ts = isoFormatter.date(from: tsStr),
                  let kind = obj["kind"] as? String,
                  let summary = obj["summary"] as? String,
                  let rawJSON = obj["raw"] as? String
            else { continue }

            reports.append(MetricReport(id: id, timestamp: ts, kind: kind, summary: summary, rawJSON: rawJSON))
        }

        return reports.sorted { $0.timestamp > $1.timestamp }
    }

    /// Deletes the stored MetricKit reports file.
    static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        Self.queue.async {
            FileLogger.shared.info(.app, "MetricKit metrics received", payload: ["count": payloads.count])
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.queue.async { [payloads] in
            for payload in payloads {
                let ts = payload.timeStampBegin

                for crash in payload.crashDiagnostics ?? [] {
                    Self.storeReport(
                        timestamp: ts,
                        kind: "crash",
                        summary: crash.terminationReason.map { "crash: \($0)" } ?? "crash",
                        rawJSON: String(data: crash.jsonRepresentation(), encoding: .utf8) ?? "{}"
                    )
                }

                for hang in payload.hangDiagnostics ?? [] {
                    let duration = hang.hangDuration.converted(to: .seconds).value
                    Self.storeReport(
                        timestamp: ts,
                        kind: "hang",
                        summary: String(format: "hang (%.1fs)", duration),
                        rawJSON: String(data: hang.jsonRepresentation(), encoding: .utf8) ?? "{}"
                    )
                }

                for exc in payload.cpuExceptionDiagnostics ?? [] {
                    Self.storeReport(
                        timestamp: ts,
                        kind: "cpu-exception",
                        summary: "cpu-exception",
                        rawJSON: String(data: exc.jsonRepresentation(), encoding: .utf8) ?? "{}"
                    )
                }

                for exc in payload.diskWriteExceptionDiagnostics ?? [] {
                    Self.storeReport(
                        timestamp: ts,
                        kind: "disk-write-exception",
                        summary: "disk-write-exception",
                        rawJSON: String(data: exc.jsonRepresentation(), encoding: .utf8) ?? "{}"
                    )
                }
            }
        }
    }

    // MARK: - Private

    private static func storeReport(timestamp: Date, kind: String, summary: String, rawJSON: String) {
        let report = MetricReport(
            id: nextID(),
            timestamp: timestamp,
            kind: kind,
            summary: summary,
            rawJSON: rawJSON
        )
        appendReport(report)
        FileLogger.shared.info(.app, "metric report received", payload: ["kind": kind])
    }

    private static func appendReport(_ report: MetricReport) {
        guard let url = fileURL() else { return }

        // Read existing content
        let currentContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = currentContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Serialize the new report as a JSON line
        let dict: [String: Any] = [
            "id": report.id,
            "ts": isoFormatter.string(from: report.timestamp),
            "kind": report.kind,
            "summary": report.summary,
            "raw": report.rawJSON
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let jsonLine = String(data: data, encoding: .utf8)
        else { return }

        lines.append(jsonLine)

        // FIFO eviction: keep only the last maxReports lines
        if lines.count > Self.maxReports {
            lines = Array(lines.suffix(Self.maxReports))
        }

        // Atomic write: write to temp, then replace
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".ritoras-metric-reports.tmp")

        let output = lines.joined(separator: "\n") + "\n"
        do {
            try output.write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL,
                                                       backupItemName: nil,
                                                       options: [])
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Resolves the reports file URL in the app group container.
    private static func fileURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent(Self.fileName)
        }
        return container.appendingPathComponent(Self.fileName)
    }

    private static func nextID() -> Int {
        defer { _nextID += 1 }
        return _nextID
    }
}
