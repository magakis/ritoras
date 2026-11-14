import Foundation

struct KeystrokeTraceFileSnapshot {
    struct Segment: Identifiable {
        let fileName: String
        let byteCount: Int64?
        let exists: Bool

        var id: String { fileName }

        var sizeLabel: String {
            guard exists else { return "Not present" }
            guard let byteCount else { return "Size unavailable" }
            return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }
    }

    let isLoading: Bool
    let isAvailable: Bool
    let segments: [Segment]
    let totalSizeBytes: Int64
    let oldestEventDate: Date?
    let shareContent: String
    let errors: [String]

    static let loading = KeystrokeTraceFileSnapshot(
        isLoading: true,
        isAvailable: false,
        segments: [],
        totalSizeBytes: 0,
        oldestEventDate: nil,
        shareContent: "",
        errors: []
    )

    var totalSizeLabel: String {
        if isLoading { return "Loading…" }
        guard isAvailable else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    var oldestEventAgeLabel: String {
        if isLoading { return "Loading…" }
        guard isAvailable else { return "Unavailable" }
        guard let oldestEventDate else { return "No events retained" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: oldestEventDate, relativeTo: Date())
    }

    var hasFiles: Bool {
        segments.contains(where: \.exists)
    }

    var hasData: Bool {
        totalSizeBytes > 0
    }
}

enum KeystrokeTraceFileStore {
    private static let fileNames = [
        KeystrokeTraceSchema.rotatedFileName,
        KeystrokeTraceSchema.liveFileName
    ]

    static func load() -> KeystrokeTraceFileSnapshot {
        guard let container = appGroupContainerURL() else {
            return KeystrokeTraceFileSnapshot(
                isLoading: false,
                isAvailable: false,
                segments: [],
                totalSizeBytes: 0,
                oldestEventDate: nil,
                shareContent: "Keystroke trace files are unavailable.",
                errors: ["The app-group container is unavailable."]
            )
        }

        let fileManager = FileManager.default
        var segments: [KeystrokeTraceFileSnapshot.Segment] = []
        var totalSizeBytes: Int64 = 0
        var oldestEventDate: Date?
        var traceSections: [String] = ["Ritoras keystroke trace"]
        var errors: [String] = []

        for fileName in fileNames {
            let fileURL = container.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                segments.append(
                    KeystrokeTraceFileSnapshot.Segment(
                        fileName: fileName,
                        byteCount: nil,
                        exists: false
                    )
                )
                continue
            }

            var byteCount: Int64?
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                byteCount = (attributes[.size] as? NSNumber)?.int64Value
                totalSizeBytes += byteCount ?? 0
            } catch {
                errors.append("Could not inspect \(fileName): \(error.localizedDescription)")
            }

            do {
                let lines = try KeystrokeTraceSegmentReader.readCompleteLines(from: fileURL)
                let content = lines
                    .map { String(decoding: $0, as: UTF8.self) }
                    .joined(separator: "\n")
                if !content.isEmpty {
                    traceSections.append("--- \(fileName) ---\n\(content)")
                }
                if oldestEventDate == nil {
                    oldestEventDate = firstValidTimestamp(in: lines)
                }
            } catch {
                errors.append("Could not read \(fileName): \(error.localizedDescription)")
            }

            segments.append(
                KeystrokeTraceFileSnapshot.Segment(
                    fileName: fileName,
                    byteCount: byteCount,
                    exists: true
                )
            )
        }

        if traceSections.count == 1 {
            traceSections.append("No complete trace records were found.")
        }

        return KeystrokeTraceFileSnapshot(
            isLoading: false,
            isAvailable: true,
            segments: segments,
            totalSizeBytes: totalSizeBytes,
            oldestEventDate: oldestEventDate,
            shareContent: traceSections.joined(separator: "\n\n"),
            errors: errors
        )
    }

    static func deleteAll() throws {
        guard let container = appGroupContainerURL() else {
            throw KeystrokeTraceFileStoreError.appGroupUnavailable
        }

        let fileManager = FileManager.default
        var failures: [String] = []

        for fileName in fileNames {
            let fileURL = container.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }

            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                failures.append("\(fileName): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            throw KeystrokeTraceFileStoreError.deletionFailed(failures)
        }
    }

    private static func appGroupContainerURL() -> URL? {
        guard AppGroupResolver.shared.containerAvailable else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        )
    }

    private static func firstValidTimestamp(in lines: [Data]) -> Date? {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let record = try? decoder.decode(KeystrokeTraceRecord.self, from: line),
                  let timestamp = formatter.date(from: record.timestamp) else {
                continue
            }
            return timestamp
        }
        return nil
    }
}

private enum KeystrokeTraceFileStoreError: LocalizedError {
    case appGroupUnavailable
    case deletionFailed([String])

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "The app-group container is unavailable."
        case let .deletionFailed(failures):
            return "Could not delete all trace files: \(failures.joined(separator: "; "))"
        }
    }
}
