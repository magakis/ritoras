import Foundation

struct KeystrokeTraceWindowExport {
    let contents: String
    let recordCount: Int
    let capturedAt: Date
    let oldestRetainedTimestamp: Date?
    let coverageDuration: TimeInterval
    let hasFullWindowCoverage: Bool
}

enum KeyboardKeystrokeTraceExporter {
    static let windowDuration: TimeInterval = 5 * 60

    private static let readChunkSize = 64 * 1024

    private enum ExportError: Error {
        case documentsDirectoryUnavailable
        case segmentExceedsCapacity(String)
        case segmentReadFailed(String, Error)
    }

    private struct TimestampParser {
        private let fractionalFormatter = ISO8601DateFormatter()
        private let standardFormatter = ISO8601DateFormatter()

        init() {
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            standardFormatter.formatOptions = [.withInternetDateTime]
        }

        func date(from timestamp: String) -> Date? {
            fractionalFormatter.date(from: timestamp) ?? standardFormatter.date(from: timestamp)
        }
    }

    private struct SelectionBuilder {
        private static let validEventTypes: Set<String> = [
            "key",
            "suggestion",
            "decision",
            "state",
            "meta",
        ]

        private(set) var contents = ""
        private(set) var recordCount = 0
        private(set) var oldestRetainedTimestamp: Date?

        mutating func include(
            line: Data,
            windowStart: Date,
            capturedAt: Date,
            timestampParser: TimestampParser
        ) {
            guard let lineText = String(data: line, encoding: .utf8),
                  let record = try? JSONSerialization.jsonObject(
                    with: line,
                    options: [.fragmentsAllowed]
                  ) as? [String: Any],
                  let schemaVersion = record["schemaVersion"] as? Int,
                  schemaVersion == KeystrokeTraceRecord.currentSchemaVersion,
                  let timestampString = record["timestamp"] as? String,
                  let event = record["event"] as? [String: Any],
                  let eventType = event["type"] as? String,
                  Self.validEventTypes.contains(eventType),
                  event["payload"] as? [String: Any] != nil,
                  let timestamp = timestampParser.date(from: timestampString),
                  timestamp <= capturedAt else {
                return
            }

            if let oldestRetainedTimestamp {
                if timestamp < oldestRetainedTimestamp {
                    self.oldestRetainedTimestamp = timestamp
                }
            } else {
                oldestRetainedTimestamp = timestamp
            }
            guard timestamp >= windowStart else { return }

            // Keep coverage metadata out of the clipboard so the stream stays viewer-compatible NDJSON.
            contents.append(lineText)
            contents.append("\n")
            recordCount += 1
        }

        func finish(capturedAt: Date, windowStart: Date) -> KeystrokeTraceWindowExport {
            let coverageDuration = oldestRetainedTimestamp.map {
                min(
                    KeyboardKeystrokeTraceExporter.windowDuration,
                    max(0, capturedAt.timeIntervalSince($0))
                )
            } ?? 0
            let hasFullWindowCoverage = oldestRetainedTimestamp.map {
                $0 <= windowStart
            } ?? false
            return KeystrokeTraceWindowExport(
                contents: contents,
                recordCount: recordCount,
                capturedAt: capturedAt,
                oldestRetainedTimestamp: oldestRetainedTimestamp,
                coverageDuration: coverageDuration,
                hasFullWindowCoverage: hasFullWindowCoverage
            )
        }
    }

    static func prepareLastFiveMinutes(
        completion: @escaping (Result<KeystrokeTraceWindowExport, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result: Result<KeystrokeTraceWindowExport, Error>
            do {
                result = .success(try autoreleasepool {
                    try makeLastFiveMinutesExport()
                })
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func makeLastFiveMinutesExport() throws -> KeystrokeTraceWindowExport {
        guard let directoryURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ExportError.documentsDirectoryUnavailable
        }

        let currentMilliseconds = floor(Date().timeIntervalSince1970 * 1_000)
        let capturedAt = Date(timeIntervalSince1970: currentMilliseconds / 1_000)
        let windowStart = capturedAt.addingTimeInterval(-windowDuration)
        let timestampParser = TimestampParser()
        var selection = SelectionBuilder()

        for fileName in [
            KeystrokeTraceSchema.rotatedFileName,
            KeystrokeTraceSchema.liveFileName,
        ] {
            let segmentURL = directoryURL.appendingPathComponent(fileName)
            try scanSegment(
                at: segmentURL,
                windowStart: windowStart,
                capturedAt: capturedAt,
                timestampParser: timestampParser,
                selection: &selection
            )
        }

        return selection.finish(capturedAt: capturedAt, windowStart: windowStart)
    }

    private static func scanSegment(
        at url: URL,
        windowStart: Date,
        capturedAt: Date,
        timestampParser: TimestampParser,
        selection: inout SelectionBuilder
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ExportError.segmentReadFailed(url.lastPathComponent, error)
        }

        var bytesRead = 0
        var line = Data()
        do {
            // Stream one bounded segment at a time and release parsed Foundation objects per line.
            while let chunk = try fileHandle.read(upToCount: readChunkSize), !chunk.isEmpty {
                guard chunk.count <= KeystrokeTraceSchema.segmentCapacityBytes - bytesRead else {
                    throw ExportError.segmentExceedsCapacity(url.lastPathComponent)
                }
                bytesRead += chunk.count

                var lineStart = 0
                for index in chunk.indices where chunk[index] == 0x0A {
                    line.append(contentsOf: chunk[lineStart..<index])
                    autoreleasepool {
                        selection.include(
                            line: line,
                            windowStart: windowStart,
                            capturedAt: capturedAt,
                            timestampParser: timestampParser
                        )
                    }
                    line.removeAll(keepingCapacity: true)
                    lineStart = index + 1
                }
                if lineStart < chunk.count {
                    line.append(contentsOf: chunk[lineStart..<chunk.count])
                }
            }
            try fileHandle.close()
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.segmentReadFailed(url.lastPathComponent, error)
        }
    }
}
