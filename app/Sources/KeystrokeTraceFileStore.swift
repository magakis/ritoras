import CryptoKit
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
    let lastDeliveryDate: Date?
    let shareContent: String
    let errors: [String]

    static let loading = KeystrokeTraceFileSnapshot(
        isLoading: true,
        isAvailable: false,
        segments: [],
        totalSizeBytes: 0,
        oldestEventDate: nil,
        lastDeliveryDate: nil,
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
        guard let oldestEventDate else {
            return hasData ? "No valid event timestamp" : "No traces yet"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: oldestEventDate, relativeTo: Date())
    }

    var lastDeliveryLabel: String {
        if isLoading { return "Loading…" }
        guard isAvailable else { return "Unavailable" }
        guard let lastDeliveryDate else { return "No deliveries yet" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastDeliveryDate, relativeTo: Date())
    }

    var hasData: Bool {
        totalSizeBytes > 0
    }
}

struct KeystrokeTraceReceiveResult {
    let statusCode: Int
    let response: KeystrokeTraceUploadResponse
}

private struct KeystrokeTraceSchemaVersionProbe: Decodable {
    enum Value: Decodable {
        case number(Double)
        case other

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .other
            }
        }
    }

    let schemaVersion: Value
}

private struct KeystrokeTraceReceiveEnvelope: Decodable {
    let epoch: UInt64?
    let payload: String?

    private enum CodingKeys: String, CodingKey {
        case epoch
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try? container.decode(UInt64.self, forKey: .epoch)
        payload = try? container.decode(String.self, forKey: .payload)
    }
}

enum KeystrokeTraceFileStore {
    private static let fileNames = [
        KeystrokeTraceSchema.rotatedFileName,
        KeystrokeTraceSchema.liveFileName
    ]
    private static let receiverStateFileName = "ritoras-trace-receiver-state.json"
    // This covers all chunks in the keyboard's 4 MiB store while bounding metadata.
    private static let maximumRememberedChunkHashes = 1_024
    private static let queue = DispatchQueue(label: "com.ritoras.keystroke-trace-store")

    private struct ReceiverState: Codable {
        var epoch: UInt64 = 0
        var contentHashes: [String] = []
        var lastDeliveryDate: Date?
        var pendingDeletion = false
    }

    private static var activeDirectoryURL: URL?
    private static var recorder: KeystrokeTraceRecorder?
    private static var cachedStateDirectoryURL: URL?
    private static var cachedState: ReceiverState?
    // Reconcile an append whose hash metadata was interrupted without storing trace text twice.
    private static var hasScannedStoreForUnknownChunk = false

    static func load() -> KeystrokeTraceFileSnapshot {
        queue.sync {
            loadSnapshot()
        }
    }

    static func receive(bodyData: Data) -> KeystrokeTraceReceiveResult {
        queue.sync {
            receiveUnlocked(bodyData: bodyData)
        }
    }

    static func deleteAll() throws {
        try queue.sync {
            let recorder = try makeRecorder()
            let directoryURL = recorder.liveFileURL.deletingLastPathComponent()
            let state = try loadReceiverState(in: directoryURL)
            let (newEpoch, overflow) = state.epoch.addingReportingOverflow(1)
            guard !overflow else {
                throw KeystrokeTraceFileStoreError.epochExhausted
            }

            var deletingState = ReceiverState(
                epoch: newEpoch,
                contentHashes: [],
                lastDeliveryDate: nil,
                pendingDeletion: true
            )
            try persist(deletingState, in: directoryURL)
            try recorder.clear()

            deletingState.pendingDeletion = false
            try persist(deletingState, in: directoryURL)
            hasScannedStoreForUnknownChunk = true
        }
    }

    private static func loadSnapshot() -> KeystrokeTraceFileSnapshot {
        let directoryURL: URL
        do {
            directoryURL = try storeDirectoryURL()
        } catch {
            return KeystrokeTraceFileSnapshot(
                isLoading: false,
                isAvailable: false,
                segments: [],
                totalSizeBytes: 0,
                oldestEventDate: nil,
                lastDeliveryDate: nil,
                shareContent: "Keystroke trace files are unavailable.",
                errors: [error.localizedDescription]
            )
        }

        let fileManager = FileManager.default
        var segments: [KeystrokeTraceFileSnapshot.Segment] = []
        var totalSizeBytes: Int64 = 0
        var oldestEventDate: Date?
        var traceSections: [String] = ["Ritoras keystroke trace"]
        var errors: [String] = []
        let receiverState: ReceiverState?
        do {
            receiverState = try loadReceiverState(in: directoryURL)
        } catch {
            receiverState = nil
            errors.append("Could not read trace receiver state: \(error.localizedDescription)")
        }

        for fileName in fileNames {
            let fileURL = directoryURL.appendingPathComponent(fileName)
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
            lastDeliveryDate: receiverState?.lastDeliveryDate,
            shareContent: traceSections.joined(separator: "\n\n"),
            errors: errors
        )
    }

    private static func receiveUnlocked(bodyData: Data) -> KeystrokeTraceReceiveResult {
        let recorder: KeystrokeTraceRecorder
        do {
            recorder = try makeRecorder()
        } catch {
            return receiveResult(
                statusCode: 503,
                acknowledged: false,
                epoch: readableEpoch() ?? 0
            )
        }

        let directoryURL = recorder.liveFileURL.deletingLastPathComponent()
        var state: ReceiverState
        do {
            state = try loadReceiverState(in: directoryURL)
        } catch {
            return receiveResult(
                statusCode: 503,
                acknowledged: false,
                epoch: cachedState?.epoch ?? 0
            )
        }
        do {
            state = try recoverPendingOperations(state, in: directoryURL, recorder: recorder)
        } catch {
            return receiveResult(statusCode: 503, acknowledged: false, epoch: state.epoch)
        }

        guard bodyData.count <= KeystrokeTraceWireContract.maximumRequestBodyBytes else {
            return receiveResult(statusCode: 413, acknowledged: false, epoch: state.epoch)
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(
            KeystrokeTraceReceiveEnvelope.self,
            from: bodyData
        ), let requestEpoch = envelope.epoch else {
            return receiveResult(statusCode: 400, acknowledged: false, epoch: state.epoch)
        }

        // An explicit schema mismatch takes precedence over the stale-epoch response.
        if let encodedPayload = envelope.payload,
           let schemaProbePayload = Data(base64Encoded: encodedPayload),
           hasUnsupportedSchemaVersion(schemaProbePayload) {
            return receiveResult(statusCode: 400, acknowledged: false, epoch: state.epoch)
        }

        guard requestEpoch == state.epoch else {
            return receiveResult(statusCode: 200, acknowledged: false, epoch: state.epoch)
        }

        guard let request = try? decoder.decode(
            KeystrokeTraceUploadRequest.self,
            from: bodyData
        ), isValidRequestShape(request), isValidTracePayload(request.payload) else {
            return receiveResult(statusCode: 400, acknowledged: false, epoch: state.epoch)
        }

        let chunkHash = contentHash(request.payload)
        if state.contentHashes.contains(chunkHash) {
            do {
                if try storedData(contains: request.payload, in: directoryURL) {
                    state.lastDeliveryDate = Date()
                    try persist(state, in: directoryURL)
                    return receiveResult(statusCode: 200, acknowledged: true, epoch: state.epoch)
                }
                state.contentHashes.removeAll { $0 == chunkHash }
                try persist(state, in: directoryURL)
                hasScannedStoreForUnknownChunk = true
            } catch {
                return receiveResult(statusCode: 503, acknowledged: false, epoch: state.epoch)
            }
        }

        if !hasScannedStoreForUnknownChunk {
            do {
                hasScannedStoreForUnknownChunk = true
                if try storedData(contains: request.payload, in: directoryURL) {
                    state.contentHashes = rememberedHashes(state.contentHashes, adding: chunkHash)
                    state.lastDeliveryDate = Date()
                    try persist(state, in: directoryURL)
                    return receiveResult(statusCode: 200, acknowledged: true, epoch: state.epoch)
                }
            } catch {
                hasScannedStoreForUnknownChunk = false
                return receiveResult(statusCode: 503, acknowledged: false, epoch: state.epoch)
            }
        }

        let now = Date()
        do {
            try recorder.appendLineAlignedData(request.payload)
        } catch {
            hasScannedStoreForUnknownChunk = false
            return receiveResult(statusCode: 503, acknowledged: false, epoch: state.epoch)
        }

        state.contentHashes = rememberedHashes(
            state.contentHashes,
            adding: chunkHash
        )
        state.lastDeliveryDate = now
        do {
            try persist(state, in: directoryURL)
        } catch {
            hasScannedStoreForUnknownChunk = false
            return receiveResult(statusCode: 503, acknowledged: false, epoch: state.epoch)
        }
        return receiveResult(statusCode: 200, acknowledged: true, epoch: state.epoch)
    }

    private static func receiveResult(
        statusCode: Int,
        acknowledged: Bool,
        epoch: UInt64
    ) -> KeystrokeTraceReceiveResult {
        KeystrokeTraceReceiveResult(
            statusCode: statusCode,
            response: KeystrokeTraceUploadResponse(
                acknowledged: acknowledged,
                epoch: epoch
            )
        )
    }

    private static func isValidRequestShape(_ request: KeystrokeTraceUploadRequest) -> Bool {
        (request.segmentName == KeystrokeTraceSchema.rotatedFileName
            || request.segmentName == KeystrokeTraceSchema.liveFileName)
            && !request.segmentIdentity.isEmpty
            && request.segmentIdentity.utf8.count <= 256
            && !request.payload.isEmpty
            && request.payload.count <= KeystrokeTraceWireContract.maximumRequestBodyBytes
    }

    private static func isValidTracePayload(_ payload: Data) -> Bool {
        guard !payload.isEmpty, payload.last == 0x0A else { return false }

        let decoder = JSONDecoder()
        var lineStart = payload.startIndex
        for index in payload.indices where payload[index] == 0x0A {
            guard index > lineStart else { return false }
            let line = Data(payload[lineStart..<index])
            guard let record = try? decoder.decode(KeystrokeTraceRecord.self, from: line),
                  record.schemaVersion == KeystrokeTraceRecord.currentSchemaVersion else {
                return false
            }
            lineStart = payload.index(after: index)
        }
        return lineStart == payload.endIndex
    }

    private static func hasUnsupportedSchemaVersion(_ payload: Data) -> Bool {
        let decoder = JSONDecoder()
        for line in payload.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let envelope = try? decoder.decode(
                KeystrokeTraceSchemaVersionProbe.self,
                from: Data(line)
            ) else {
                continue
            }
            if case let .number(version) = envelope.schemaVersion,
               version == Double(KeystrokeTraceRecord.currentSchemaVersion) {
                continue
            }
            return true
        }
        return false
    }

    private static func contentHash(_ payload: Data) -> String {
        SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func rememberedHashes(_ hashes: [String], adding hash: String) -> [String] {
        var updated = hashes.filter { $0 != hash }
        updated.append(hash)
        if updated.count > maximumRememberedChunkHashes {
            updated.removeFirst(updated.count - maximumRememberedChunkHashes)
        }
        return updated
    }

    private static func recoverPendingOperations(
        _ state: ReceiverState,
        in directoryURL: URL,
        recorder: KeystrokeTraceRecorder
    ) throws -> ReceiverState {
        var recovered = state
        if recovered.pendingDeletion {
            try recorder.clear()
            recovered.pendingDeletion = false
            try persist(recovered, in: directoryURL)
            hasScannedStoreForUnknownChunk = true
        }
        return recovered
    }

    private static func storedData(contains payload: Data, in directoryURL: URL) throws -> Bool {
        let fileManager = FileManager.default
        var storedData = Data()
        for fileName in fileNames {
            let fileURL = directoryURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            storedData.append(try Data(contentsOf: fileURL))
        }

        guard payload.count <= storedData.count else { return false }
        var searchRange = storedData.startIndex..<storedData.endIndex
        while let match = storedData.range(of: payload, options: [], in: searchRange) {
            if match.lowerBound == storedData.startIndex
                || storedData[storedData.index(before: match.lowerBound)] == 0x0A {
                return true
            }
            searchRange = storedData.index(after: match.lowerBound)..<storedData.endIndex
        }
        return false
    }

    private static func makeRecorder() throws -> KeystrokeTraceRecorder {
        if let recorder {
            return recorder
        }

        var failures: [String] = []
        for directoryURL in directoryCandidates() {
            do {
                let recorder = try KeystrokeTraceRecorder(directoryURL: directoryURL)
                activeDirectoryURL = directoryURL
                self.recorder = recorder
                return recorder
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        throw KeystrokeTraceFileStoreError.storageUnavailable(failures)
    }

    private static func storeDirectoryURL() throws -> URL {
        if let activeDirectoryURL {
            return activeDirectoryURL
        }

        var failures: [String] = []
        for directoryURL in directoryCandidates() {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                activeDirectoryURL = directoryURL
                return directoryURL
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        throw KeystrokeTraceFileStoreError.storageUnavailable(failures)
    }

    private static func directoryCandidates() -> [URL] {
        var candidates: [URL] = []
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) {
            candidates.append(appGroupURL)
        }
        if let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
           !candidates.contains(documentsURL) {
            candidates.append(documentsURL)
        }
        return candidates
    }

    private static func stateFileURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(receiverStateFileName)
    }

    private static func loadReceiverState(in directoryURL: URL) throws -> ReceiverState {
        if cachedStateDirectoryURL == directoryURL, let cachedState {
            return cachedState
        }

        let url = stateFileURL(in: directoryURL)
        let fileManager = FileManager.default
        let state: ReceiverState
        if fileManager.fileExists(atPath: url.path) {
            do {
                state = try JSONDecoder().decode(
                    ReceiverState.self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw KeystrokeTraceFileStoreError.invalidReceiverState(url, error)
            }
            guard isValidReceiverState(state) else {
                throw KeystrokeTraceFileStoreError.invalidReceiverState(url, nil)
            }
        } else {
            state = ReceiverState()
        }
        cachedStateDirectoryURL = directoryURL
        cachedState = state
        return state
    }

    private static func isValidReceiverState(_ state: ReceiverState) -> Bool {
        state.contentHashes.count <= maximumRememberedChunkHashes
            && state.contentHashes.allSatisfy { $0.count == 64 }
    }

    private static func persist(_ state: ReceiverState, in directoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = stateFileURL(in: directoryURL)
        do {
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            throw KeystrokeTraceFileStoreError.statePersistenceFailed(url, error)
        }
        cachedStateDirectoryURL = directoryURL
        cachedState = state
    }

    private static func readableEpoch() -> UInt64? {
        guard let directoryURL = try? storeDirectoryURL(),
              let state = try? loadReceiverState(in: directoryURL) else {
            return nil
        }
        return state.epoch
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
    case storageUnavailable([String])
    case invalidReceiverState(URL, Error?)
    case statePersistenceFailed(URL, Error)
    case epochExhausted

    var errorDescription: String? {
        switch self {
        case let .storageUnavailable(failures):
            return "Could not open the keystroke trace store" +
                (failures.isEmpty ? "." : ": \(failures.joined(separator: "; "))")
        case let .invalidReceiverState(url, error):
            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
            return "Could not read trace receiver state at \(url.path)\(detail)"
        case let .statePersistenceFailed(url, error):
            return "Could not save trace receiver state at \(url.path): \(error.localizedDescription)"
        case .epochExhausted:
            return "The keystroke trace delete epoch cannot be incremented."
        }
    }
}
