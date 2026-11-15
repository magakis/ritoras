import Darwin
import Foundation

/// Ships complete trace lines from the keyboard's Documents directory without
/// removing local bytes until the app acknowledges them.
final class KeyboardKeystrokeTraceShipper {
    private struct CursorStore: Codable {
        var epoch: UInt64 = 0
        var offsets: [String: UInt64] = [:]
    }

    private struct Segment {
        let name: String
        let url: URL
        let identity: String
        let byteCount: UInt64
    }

    private struct UploadAttempt: Sendable {
        let request: KeystrokeTraceUploadRequest
        let nextOffset: UInt64
    }

    private enum UploadAttemptResult {
        case attempt(UploadAttempt)
        case skipped(SkipReason)
    }

    private struct UploadFailure: Sendable {
        let kind: UploadErrorKind
        let httpStatus: Int?
    }

    private enum UploadErrorKind: String, Sendable {
        case connectionRefused = "connection-refused"
        case timeout
        case unauthorized = "401"
        case notFound = "404"
        case other
    }

    enum SkipReason: String {
        case notRunning = "not-running"
        case noDirectory = "no-directory"
        case noSegments = "no-segments"
        case allAtEOF = "all-at-eof"
        case noCompleteLine = "no-complete-line"
        case firstLineOverLimit = "first-line-over-limit"
        case bodySizeMismatch = "body-size-mismatch"
        case epochResetInFlight = "epoch-reset-in-flight"
        case requestInFlight = "request-in-flight"
    }

    private enum PayloadResult {
        case complete(Data, fixedBodyByteCount: Int)
        case noCompleteLines
    }

    private static let cadenceSeconds: TimeInterval = 2
    // Ignore isolated misses; warn once after the cadence confirms persistence.
    private static let persistentFailureThreshold = 3
    private static let cursorStoreKey = "ritoras_keystroke_trace_upload_state"
    private static let segmentNames = [
        KeystrokeTraceSchema.rotatedFileName,
        KeystrokeTraceSchema.liveFileName
    ]

    private let directoryURLProvider: () -> URL?
    private let queue = DispatchQueue(label: "com.ritoras.keystroke-trace-shipper")
    private let onEpochMismatch: () -> Bool
    private var state: CursorStore
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var requestInFlight = false
    private var epochResetInProgress = false
    private var lastSkipReason: SkipReason?
    private var lastChunkEstimate: Int?
    private var lastChunkActual: Int?
    private var uploadAttemptCount: UInt64 = 0
    private var lastAttemptAt: Date?
    private var lastUploadErrorKind: String?
    private var lastUploadHTTPStatus: Int?
    private var consecutiveUploadFailures = 0
    private var didLogPersistentUploadFailure = false
    private var didLogEpochWipe = false

    struct DiagnosticSnapshot {
        let timerRunning: Bool
        let uploadAttemptCount: UInt64
        let requestInFlight: Bool
        let cursorEpoch: UInt64
        let cursorOffsets: [String: UInt64]
        let lastUploadErrorKind: String?
        let lastUploadHTTPStatus: Int?
        let lastAttemptAt: Date?
        let lastSkipReason: SkipReason?
        let lastChunkEstimate: Int?
        let lastChunkActual: Int?
    }

    init(
        directoryURLProvider: @escaping () -> URL?,
        onEpochMismatch: @escaping () -> Bool
    ) {
        self.directoryURLProvider = directoryURLProvider
        self.onEpochMismatch = onEpochMismatch
        state = Self.loadCursorStore()
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        queue.async {
            self.isRunning = true
            guard self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.cadenceSeconds,
                repeating: Self.cadenceSeconds,
                leeway: .seconds(1)
            )
            timer.setEventHandler { [weak self] in
                self?.shipOldestPendingChunk()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func shipPending() {
        queue.async {
            self.shipOldestPendingChunk()
        }
    }

    func diagnosticSnapshot() -> DiagnosticSnapshot {
        queue.sync {
            DiagnosticSnapshot(
                timerRunning: isRunning && timer != nil,
                uploadAttemptCount: uploadAttemptCount,
                requestInFlight: requestInFlight,
                cursorEpoch: state.epoch,
                cursorOffsets: state.offsets,
                lastUploadErrorKind: lastUploadErrorKind,
                lastUploadHTTPStatus: lastUploadHTTPStatus,
                lastAttemptAt: lastAttemptAt,
                lastSkipReason: lastSkipReason,
                lastChunkEstimate: lastChunkEstimate,
                lastChunkActual: lastChunkActual
            )
        }
    }

    private static func loadCursorStore() -> CursorStore {
        guard let data = UserDefaults.standard.data(forKey: cursorStoreKey) else {
            return CursorStore()
        }
        do {
            return try JSONDecoder().decode(CursorStore.self, from: data)
        } catch {
            // A lost cursor must replay data, not skip it.
            UserDefaults.standard.removeObject(forKey: cursorStoreKey)
            return CursorStore()
        }
    }

    private func persistCursorStore() throws {
        let data = try JSONEncoder().encode(state)
        UserDefaults.standard.set(data, forKey: Self.cursorStoreKey)
    }

    private func shipOldestPendingChunk() {
        lastSkipReason = nil
        guard isRunning else {
            lastSkipReason = .notRunning
            return
        }
        guard !requestInFlight else {
            lastSkipReason = .requestInFlight
            return
        }
        guard !epochResetInProgress else {
            lastSkipReason = .epochResetInFlight
            return
        }
        guard let directoryURL = directoryURLProvider() else {
            lastSkipReason = .noDirectory
            return
        }

        do {
            let segments = try existingSegments(in: directoryURL)
            try reconcileCursors(with: segments)
            guard !segments.isEmpty else {
                lastSkipReason = .noSegments
                return
            }
            let attempt: UploadAttempt
            switch try nextUploadAttempt(from: segments) {
            case let .attempt(builtAttempt):
                attempt = builtAttempt
            case let .skipped(reason):
                lastSkipReason = reason
                return
            }

            requestInFlight = true
            uploadAttemptCount &+= 1
            lastAttemptAt = Date()
            Task { [weak self] in
                do {
                    let response = try await LocalhostClient.postKeystrokeTrace(attempt.request)
                    self?.queue.async { [weak self] in
                        self?.completeUpload(attempt, response: response)
                    }
                } catch {
                    let failure = Self.classifyUploadFailure(error)
                    self?.queue.async { [weak self] in
                        self?.completeFailedUpload(failure)
                    }
                }
            }
        } catch {
            recordUploadFailure(UploadFailure(kind: .other, httpStatus: nil))
        }
    }

    private func completeFailedUpload(_ failure: UploadFailure) {
        requestInFlight = false
        recordUploadFailure(failure)
    }

    private func completeUpload(
        _ attempt: UploadAttempt,
        response: KeystrokeTraceUploadResponse
    ) {
        guard response.epoch == state.epoch else {
            lastUploadErrorKind = UploadErrorKind.other.rawValue
            lastUploadHTTPStatus = nil
            if !didLogEpochWipe {
                didLogEpochWipe = true
                FileLogger.shared.warn(
                    .network,
                    "keystroke trace epoch mismatch; clearing local segments",
                    payload: [
                        "localEpoch": state.epoch,
                        "serverEpoch": response.epoch
                    ]
                )
            }
            epochResetInProgress = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let didClearLocalData = self.onEpochMismatch()
                self.queue.async { [weak self] in
                    self?.completeEpochReset(didClearLocalData, newEpoch: response.epoch)
                }
            }
            return
        }

        requestInFlight = false
        let currentOffset = state.offsets[attempt.request.segmentIdentity]
        guard response.acknowledged else {
            recordUploadFailure(UploadFailure(kind: .other, httpStatus: nil))
            return
        }
        guard currentOffset == nil || currentOffset == attempt.request.offset else {
            return
        }

        let previousOffset = currentOffset
        state.offsets[attempt.request.segmentIdentity] = attempt.nextOffset
        do {
            try persistCursorStore()
        } catch {
            state.offsets[attempt.request.segmentIdentity] = previousOffset
            recordUploadFailure(UploadFailure(kind: .other, httpStatus: nil))
            return
        }
        consecutiveUploadFailures = 0
        shipOldestPendingChunk()
    }

    private func completeEpochReset(_ didClearLocalData: Bool, newEpoch: UInt64) {
        defer {
            epochResetInProgress = false
            requestInFlight = false
        }

        // Keep the old epoch until local deletion succeeds; future requests retry.
        guard didClearLocalData else { return }
        let previousState = state
        state = CursorStore(epoch: newEpoch, offsets: [:])
        do {
            try persistCursorStore()
        } catch {
            state = previousState
            return
        }
        shipOldestPendingChunk()
    }

    private func recordUploadFailure(_ failure: UploadFailure) {
        lastUploadErrorKind = failure.kind.rawValue
        lastUploadHTTPStatus = failure.httpStatus
        consecutiveUploadFailures += 1

        guard consecutiveUploadFailures >= Self.persistentFailureThreshold,
              !didLogPersistentUploadFailure else {
            return
        }
        didLogPersistentUploadFailure = true

        var payload: [String: Any] = ["errorKind": failure.kind.rawValue]
        if let httpStatus = failure.httpStatus {
            payload["httpStatus"] = httpStatus
        }
        FileLogger.shared.warn(
            .network,
            "keystroke trace shipping persistently failing",
            payload: payload
        )
    }

    private static func classifyUploadFailure(_ error: Error) -> UploadFailure {
        if let uploadError = error as? KeystrokeTraceUploadError {
            switch uploadError {
            case let .httpStatus(status):
                let kind: UploadErrorKind
                switch status {
                case 401:
                    kind = .unauthorized
                case 404:
                    kind = .notFound
                default:
                    kind = .other
                }
                return UploadFailure(kind: kind, httpStatus: status)
            case .requestBodyTooLarge, .invalidResponse:
                return UploadFailure(kind: .other, httpStatus: nil)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return UploadFailure(kind: .timeout, httpStatus: nil)
            case NSURLErrorCannotConnectToHost:
                return UploadFailure(kind: .connectionRefused, httpStatus: nil)
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(ETIMEDOUT) {
                return UploadFailure(kind: .timeout, httpStatus: nil)
            }
            if nsError.code == Int(ECONNREFUSED) {
                return UploadFailure(kind: .connectionRefused, httpStatus: nil)
            }
        }
        return UploadFailure(kind: .other, httpStatus: nil)
    }

    private func existingSegments(in directoryURL: URL) throws -> [Segment] {
        let fileManager = FileManager.default
        var segments: [Segment] = []
        segments.reserveCapacity(Self.segmentNames.count)

        for name in Self.segmentNames {
            let url = directoryURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }

            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  let identity = segmentIdentity(from: attributes, at: url) else {
                throw KeystrokeTraceShipError.segmentIdentityUnavailable(url)
            }
            segments.append(Segment(
                name: name,
                url: url,
                identity: identity,
                byteCount: size.uint64Value
            ))
        }
        return segments
    }

    private func reconcileCursors(with segments: [Segment]) throws {
        let currentIdentities = Set(segments.map(\.identity))
        var changed = false

        // The core's segment rotation is the only permitted eviction boundary.
        for identity in Array(state.offsets.keys) {
            if !currentIdentities.contains(identity) {
                state.offsets.removeValue(forKey: identity)
                changed = true
            }
        }
        for segment in segments {
            guard let offset = state.offsets[segment.identity] else { continue }
            guard offset <= segment.byteCount else {
                state.offsets[segment.identity] = 0
                changed = true
                continue
            }
            if offset > 0 {
                let previousByte = try readBytes(
                    from: segment,
                    offset: offset - 1,
                    maximumByteCount: 1
                ).first
                if previousByte != 0x0A {
                    // Replay a partial record rather than upload from its middle.
                    state.offsets[segment.identity] = 0
                    changed = true
                }
            }
        }
        if changed {
            try persistCursorStore()
        }
    }

    private func nextUploadAttempt(from segments: [Segment]) throws -> UploadAttemptResult {
        var hasUnreadBytes = false

        for segment in segments {
            let offset = state.offsets[segment.identity] ?? 0
            guard offset < segment.byteCount else { continue }

            hasUnreadBytes = true
            let bytes = try readBytes(from: segment, offset: offset)
            switch try lineAlignedPayload(
                bytes,
                segment: segment,
                offset: offset
            ) {
            case .complete(var payload, let fixedBodyByteCount):
                var shouldDropOneTrailingLine = true
                while true {
                    let request = KeystrokeTraceUploadRequest(
                        segmentName: segment.name,
                        segmentIdentity: segment.identity,
                        offset: offset,
                        epoch: state.epoch,
                        payload: payload
                    )
                    let body = try KeystrokeTraceWireContract.encode(request)
                    let estimatedBodyByteCount = requestBodyByteCount(
                        fixedBodyByteCount: fixedBodyByteCount,
                        payloadByteCount: payload.count
                    )
                    if body.count != estimatedBodyByteCount {
                        lastChunkEstimate = estimatedBodyByteCount
                        lastChunkActual = body.count
                    }
                    guard body.count > KeystrokeTraceWireContract.maximumRequestBodyBytes else {
                        return .attempt(UploadAttempt(
                            request: request,
                            nextOffset: offset + UInt64(payload.count)
                        ))
                    }

                    let smallerPayload: Data?
                    if shouldDropOneTrailingLine {
                        smallerPayload = payloadByDroppingLastLine(payload)
                        shouldDropOneTrailingLine = false
                    } else {
                        smallerPayload = payloadByKeepingFirstHalfOfLines(payload)
                    }
                    guard let smallerPayload else {
                        return .skipped(.firstLineOverLimit)
                    }
                    payload = smallerPayload
                }
            case .noCompleteLines:
                continue
            }
        }
        return .skipped(hasUnreadBytes ? .noCompleteLine : .allAtEOF)
    }

    private func readBytes(
        from segment: Segment,
        offset: UInt64,
        maximumByteCount: Int = KeystrokeTraceSchema.ringCapacityBytes
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: segment.url)
        let remainingByteCount = segment.byteCount - offset
        let readByteCount = Int(min(
            remainingByteCount,
            UInt64(maximumByteCount)
        ))
        let data: Data
        do {
            try handle.seek(toOffset: offset)
            data = try handle.read(upToCount: readByteCount) ?? Data()
        } catch {
            let readError = error
            do {
                try handle.close()
            } catch {
                throw KeystrokeTraceShipError.readAndClose(
                    segment.url,
                    readError,
                    error
                )
            }
            throw readError
        }
        try handle.close()
        guard try segmentIdentity(at: segment.url) == segment.identity else {
            throw KeystrokeTraceShipError.segmentChanged(segment.url)
        }
        return data
    }

    private func segmentIdentity(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let identity = segmentIdentity(from: attributes, at: url) else {
            throw KeystrokeTraceShipError.segmentIdentityUnavailable(url)
        }
        return identity
    }

    private func segmentIdentity(
        from attributes: [FileAttributeKey: Any],
        at url: URL
    ) -> String? {
        guard let fileNumber = attributes[.systemFileNumber] as? NSNumber,
              let creationDate = attributes[.creationDate] as? Date else {
            return nil
        }
        return "\(fileNumber.stringValue):\(String(creationDate.timeIntervalSince1970.bitPattern, radix: 16))"
    }

    private func lineAlignedPayload(
        _ bytes: Data,
        segment: Segment,
        offset: UInt64
    ) throws -> PayloadResult {
        let emptyRequest = KeystrokeTraceUploadRequest(
            segmentName: segment.name,
            segmentIdentity: segment.identity,
            offset: offset,
            epoch: state.epoch,
            payload: Data()
        )
        let emptyBodyByteCount = try KeystrokeTraceWireContract.encode(emptyRequest).count
        // The empty base64 string's quotes are replaced by the payload's base64 bytes.
        let fixedBodyByteCount = emptyBodyByteCount - 2
        var payload = Data()
        var lineStart = 0

        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            let lineByteCount = index - lineStart + 1
            let nextPayloadByteCount = payload.count + lineByteCount
            let candidateBodyByteCount = requestBodyByteCount(
                fixedBodyByteCount: fixedBodyByteCount,
                payloadByteCount: nextPayloadByteCount
            )
            guard candidateBodyByteCount <= KeystrokeTraceWireContract.maximumRequestBodyBytes else {
                // Estimates may drift, so let the actual encoder enforce the hard cap.
                payload.append(contentsOf: bytes[lineStart...index])
                return .complete(payload, fixedBodyByteCount: fixedBodyByteCount)
            }
            payload.append(contentsOf: bytes[lineStart...index])
            lineStart = index + 1
        }

        guard !payload.isEmpty else { return .noCompleteLines }
        return .complete(payload, fixedBodyByteCount: fixedBodyByteCount)
    }

    private func payloadByDroppingLastLine(_ payload: Data) -> Data? {
        let lineCount = completeLineCount(in: payload)
        guard lineCount > 1 else { return nil }
        return payloadPrefix(payload, keepingLineCount: lineCount - 1)
    }

    private func payloadByKeepingFirstHalfOfLines(_ payload: Data) -> Data? {
        let lineCount = completeLineCount(in: payload)
        guard lineCount > 1 else { return nil }
        return payloadPrefix(payload, keepingLineCount: max(1, lineCount / 2))
    }

    private func completeLineCount(in payload: Data) -> Int {
        payload.reduce(into: 0) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        }
    }

    private func payloadPrefix(_ payload: Data, keepingLineCount lineCount: Int) -> Data? {
        guard lineCount > 0 else { return nil }
        var currentLineCount = 0
        for (index, byte) in payload.enumerated() where byte == 0x0A {
            currentLineCount += 1
            if currentLineCount == lineCount {
                return Data(payload[...index])
            }
        }
        return nil
    }

    private func requestBodyByteCount(
        fixedBodyByteCount: Int,
        payloadByteCount: Int
    ) -> Int {
        fixedBodyByteCount + base64ByteCount(for: payloadByteCount)
    }

    private func base64ByteCount(for byteCount: Int) -> Int {
        4 * ((byteCount + 2) / 3)
    }
}

private enum KeystrokeTraceShipError: Error {
    case segmentIdentityUnavailable(URL)
    case segmentChanged(URL)
    case readAndClose(URL, Error, Error)
}
