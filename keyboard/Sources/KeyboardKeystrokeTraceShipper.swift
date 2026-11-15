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

    private enum PayloadResult {
        case complete(Data, bodyByteCount: Int)
        case noCompleteLines
        case firstLineExceedsRequestLimit
    }

    private static let cadenceSeconds: TimeInterval = 2
    private static let cursorStoreKey = "ritoras_keystroke_trace_upload_state"
    private static let segmentNames = [
        KeystrokeTraceSchema.rotatedFileName,
        KeystrokeTraceSchema.liveFileName
    ]

    private let directoryURL: URL?
    private let queue = DispatchQueue(label: "com.ritoras.keystroke-trace-shipper")
    private let onEpochMismatch: () -> Bool
    private var state: CursorStore
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var requestInFlight = false
    private var epochResetInProgress = false

    init(
        directoryURL: URL?,
        onEpochMismatch: @escaping () -> Bool
    ) {
        self.directoryURL = directoryURL
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
        guard isRunning,
              !requestInFlight,
              !epochResetInProgress,
              let directoryURL else { return }

        do {
            let segments = try existingSegments(in: directoryURL)
            try reconcileCursors(with: segments)
            guard let attempt = try nextUploadAttempt(from: segments) else { return }

            requestInFlight = true
            Task { [weak self] in
                do {
                    let response = try await LocalhostClient.postKeystrokeTrace(attempt.request)
                    self?.queue.async { [weak self] in
                        self?.completeUpload(attempt, response: response)
                    }
                } catch {
                    self?.queue.async { [weak self] in
                        self?.completeFailedUpload()
                    }
                }
            }
        } catch {
            // Keep every cursor unchanged; the next trigger or cadence retries.
        }
    }

    private func completeFailedUpload() {
        requestInFlight = false
    }

    private func completeUpload(
        _ attempt: UploadAttempt,
        response: KeystrokeTraceUploadResponse
    ) {
        guard response.epoch == state.epoch else {
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
        guard response.acknowledged,
              currentOffset == nil || currentOffset == attempt.request.offset else {
            return
        }

        let previousOffset = currentOffset
        state.offsets[attempt.request.segmentIdentity] = attempt.nextOffset
        do {
            try persistCursorStore()
        } catch {
            state.offsets[attempt.request.segmentIdentity] = previousOffset
            return
        }
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

    private func nextUploadAttempt(from segments: [Segment]) throws -> UploadAttempt? {
        for segment in segments {
            let offset = state.offsets[segment.identity] ?? 0
            guard offset < segment.byteCount else { continue }

            let bytes = try readBytes(from: segment, offset: offset)
            switch try lineAlignedPayload(
                bytes,
                segment: segment,
                offset: offset
            ) {
            case .complete(let payload, let estimatedBodyByteCount):
                let request = KeystrokeTraceUploadRequest(
                    segmentName: segment.name,
                    segmentIdentity: segment.identity,
                    offset: offset,
                    epoch: state.epoch,
                    payload: payload
                )
                let body = try KeystrokeTraceWireContract.encode(request)
                guard body.count == estimatedBodyByteCount,
                      estimatedBodyByteCount
                        <= KeystrokeTraceWireContract.maximumRequestBodyBytes else {
                    return nil
                }
                return UploadAttempt(
                    request: request,
                    nextOffset: offset + UInt64(payload.count)
                )
            case .firstLineExceedsRequestLimit:
                // Do not send newer records around an unshippable oldest line.
                return nil
            case .noCompleteLines:
                continue
            }
        }
        return nil
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
        // Data encodes as a base64 JSON string; replace the empty string's two quotes.
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
                guard !payload.isEmpty else { return .firstLineExceedsRequestLimit }
                return .complete(
                    payload,
                    bodyByteCount: requestBodyByteCount(
                        fixedBodyByteCount: fixedBodyByteCount,
                        payloadByteCount: payload.count
                    )
                )
            }
            payload.append(contentsOf: bytes[lineStart...index])
            lineStart = index + 1
        }

        guard !payload.isEmpty else { return .noCompleteLines }
        return .complete(
            payload,
            bodyByteCount: requestBodyByteCount(
                fixedBodyByteCount: fixedBodyByteCount,
                payloadByteCount: payload.count
            )
        )
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
