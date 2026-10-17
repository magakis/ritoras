import Dispatch
import Foundation

// Strict, zero-leeway DispatchSourceTimers avoid the background timer
// coalescing that can defer Task.sleep wakeups. One-shot sources are rearmed
// after each tick completes, preserving delay-after-send cadence, and their
// owners cancel them on teardown.
private func makeStrictStreamTimer(
    after interval: TimeInterval,
    handler: @escaping @Sendable () -> Void
) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(
        flags: .strict,
        queue: DispatchQueue.global(qos: .userInitiated)
    )
    scheduleStrictStreamTimer(timer, after: interval)
    timer.setEventHandler(handler: handler)
    return timer
}

private func scheduleStrictStreamTimer(
    _ timer: DispatchSourceTimer,
    after interval: TimeInterval
) {
    let intervalNanoseconds = Int(interval * 1_000_000_000)
    timer.schedule(
        deadline: .now() + .nanoseconds(intervalNanoseconds),
        leeway: .nanoseconds(0)
    )
}

// MARK: - Streaming Whisper Client
//
// This actor manages a persistent WebSocket connection to the server's /stream
// endpoint using the custom WhisperLive-style binary+JSON protocol.
//
// Unlike the stateless WhisperClient enum, WhisperStreamClient is stateful
// (it holds an open URLSessionWebSocketTask for the duration of a dictation
// session). This is a justified deviation because a streaming WebSocket
// connection inherently maintains per-connection state.
//
// Protocol:
//   Client → Server (binary): [4-byte BE chunk_id][float32 LE PCM @ 16 kHz]
//   Client → Server (text):   {"type":"END"}, {"type":"PING"}, {"type":"CONTEXT",...}
//   Server → Client (text):   {"type":"partial","transcription":"...","chunk_id":N}
//                             {"type":"final","transcription":"...","chunk_id":N}
//                             {"type":"PONG"}
//                             {"type":"error","message":"..."}

enum StreamTelemetrySendError: Error {
    case timeout
}

private final class TelemetrySendContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

actor WhisperStreamClient {

    private static let telemetrySendTimeoutNanoseconds: UInt64 = 3_000_000_000


    // MARK: - Private Properties

    /// The WebSocket URL derived from the HTTP base URL.
    private let url: URL
    private let dictationID: String

    /// The active WebSocket task, or nil when disconnected.
    private var task: URLSessionWebSocketTask?
    private var receiveFailed = false

    /// Shared URLSession (no custom delegate needed).
    private let session: URLSession = .shared

    /// One-shot timer rearmed after each successful keepalive send.
    private var keepaliveTimer: DispatchSourceTimer?
    private var keepaliveTimerID: UUID?

    /// Pure timestamp accounting for tiered liveness and bounded upload pauses.
    private var livenessEvaluator = StreamLivenessEvaluator()

    // MARK: - Initialization

    /// Creates a streaming client for the given base URL.
    ///
    /// The URL scheme is rewritten from `http`/`https` to `ws`/`wss` and
    /// `/stream` is appended to form the WebSocket endpoint.  If the
    /// `baseURL` contains a path component it is preserved before `/stream`.
    ///
    /// - Parameter baseURL: Base URL of the Whisper server, e.g.
    ///   `"http://192.168.1.100:5000"`.
    /// - Returns: `nil` if the base URL cannot be parsed into a valid WebSocket URL.
    init?(baseURL: String, dictationID: UUID) {
        self.dictationID = dictationID.uuidString
        var urlString = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Rewrite scheme: http → ws, https → wss
        if urlString.hasPrefix("https://") {
            urlString = "wss://" + urlString.dropFirst(8)
        } else if urlString.hasPrefix("http://") {
            urlString = "ws://" + urlString.dropFirst(7)
        }

        urlString += "/stream"

        guard let parsed = URL(string: urlString) else { return nil }
        self.url = parsed
    }

    // MARK: - Connection

    /// Opens the WebSocket connection and verifies reachability
    /// via a PING/PONG handshake.
    ///
    /// - Throws: `WhisperError.timeout` if the connection does not
    ///   complete within `streamWsConnectTimeout`.
    /// - Throws: `WhisperError.networkError` if the transport reports
    ///   a connection failure.
    func connect() async throws {
        stopKeepaliveTimer()
        var request = URLRequest(url: url)
        WhisperClient.applyAuth(to: &request)
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()

        FileLogger.shared.debug(.network, "Stream: connecting",
                               payload: ["jobId": dictationID, "server": url.absoluteString])

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Probe: send PING, wait for PONG
                group.addTask {
                    do {
                        try await newTask.send(.string(#"{"type":"PING"}"#))

                        while true {
                            switch try await newTask.receive() {
                            case .string(let text):
                                if text.contains("PONG") {
                                    FileLogger.shared.info(.network, "Connected (PONG received)",
                                                           payload: ["jobId": self.dictationID,
                                                                     "server": self.url.absoluteString])
                                    return
                                }
                                // Unexpected message before PONG — ignore
                                continue
                            case .data:
                                continue
                            @unknown default:
                                continue
                            }
                        }
                    } catch let error as WhisperError {
                        throw error
                    } catch {
                        throw WhisperError.networkError(error)
                    }
                }

                // Timeout guard
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(SharedConfig.Defaults.streamWsConnectTimeout * 1_000_000_000)
                    )
                    FileLogger.shared.debug(.network, "Connection timed out",
                                           payload: ["id": self.dictationID,
                                                     "timeout": SharedConfig.Defaults.streamWsConnectTimeout])
                    throw WhisperError.timeout
                }

                try await group.next()
                group.cancelAll()
            }
        } catch {
            newTask.cancel(with: .goingAway, reason: nil)
            if task === newTask {
                task = nil
            }
            throw error
        }

        livenessEvaluator.recordConnected(at: Date())

        startKeepaliveTimer()
        FileLogger.shared.debug(.network, "Keepalive loop started",
                               payload: ["interval": SharedConfig.Defaults.streamKeepaliveIntervalSeconds])
    }

    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timerID = UUID()
        let interval = SharedConfig.Defaults.streamKeepaliveIntervalSeconds
        let timer = makeStrictStreamTimer(after: interval) { [weak self] in
            Task { [weak self] in
                await self?.keepaliveTimerFired(timerID: timerID)
            }
        }
        keepaliveTimerID = timerID
        keepaliveTimer = timer
        timer.resume()
    }

    private func keepaliveTimerFired(timerID: UUID) async {
        guard keepaliveTimerID == timerID else { return }
        do {
            try await sendPing()
        } catch {
            guard keepaliveTimerID == timerID else { return }
            forceClose()
            return
        }

        guard keepaliveTimerID == timerID, let keepaliveTimer else { return }
        scheduleStrictStreamTimer(
            keepaliveTimer,
            after: SharedConfig.Defaults.streamKeepaliveIntervalSeconds
        )
    }

    private func stopKeepaliveTimer() {
        keepaliveTimerID = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - Sending

    /// Sends one JSON telemetry text frame. The caller orders it before END.
    func sendTelemetry(_ data: Data) async throws {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = TelemetrySendContinuation(continuation)
            Task {
                do {
                    try await task.send(.string(text))
                    resumeOnce.resume(with: .success(()))
                } catch {
                    resumeOnce.resume(with: .failure(error))
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(Self.telemetrySendTimeoutNanoseconds))) {
                    resumeOnce.resume(with: .failure(StreamTelemetrySendError.timeout))
                }
        }
    }

    func isHealthyForTelemetry() -> Bool {
        !receiveFailed && task?.state == .running
    }

    /// Sends a binary frame containing a PCM audio chunk.
    ///
    /// Wire format (pinned by `server.py:880-882`):
    /// ```
    /// [4 bytes big-endian uint32 chunk_id][float32 LE PCM samples @ 16 kHz]
    /// ```
    ///
    /// - Parameters:
    ///   - id:      Monotonically increasing chunk identifier.
    ///   - samples: Float PCM samples (16 kHz mono).
    /// - Throws: `WhisperError.networkError` if the transport fails.
    func sendChunk(id: UInt32, samples: [Float]) async throws {
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }

        var data = Data(capacity: 4 + samples.count * MemoryLayout<Float>.size)

        // 4-byte big-endian chunk_id
        var bigEndianId = id.bigEndian
        withUnsafeBytes(of: &bigEndianId) { data.append(contentsOf: $0) }

        // float32 PCM samples (little-endian on ARM64, matching numpy default)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        let windowEvents = livenessEvaluator.recordFrameEnqueued(
            bytes: data.count,
            at: Date(),
            minimumBytes: SharedConfig.Defaults.streamUploadWindowMinimumBytes,
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents, bytes: data.count)

        try await task.send(.data(data))

        FileLogger.shared.debug(.network, "Sent chunk",
                                payload: ["chunkId": id, "bytes": data.count])
    }

    /// Signals the end of the audio stream by sending
    /// `{"type":"END"}`.  The server will drain the worker and
    /// respond with a `final` transcription.
    func sendEnd() async throws {
        let timestamp = Date()
        guard let task = task else {
            FileLogger.shared.debug(.network, "Stream: END send result", payload: [
                "jobId": dictationID,
                "server": url.absoluteString,
                "sent": false,
                "result": "failed",
                "timestamp_ms": timestamp.timeIntervalSince1970 * 1000,
                "error": "WebSocket is not connected"
            ])
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        do {
            try await task.send(.string(#"{"type":"END"}"#))
            let sentAt = Date()
            let windowEvents = livenessEvaluator.recordEndSent(
                at: sentAt,
                maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
            logUploadWindowEvents(windowEvents)
            FileLogger.shared.info(.network, "Stream: END send result", payload: [
                "jobId": dictationID,
                "server": url.absoluteString,
                "sent": true,
                "result": "sent",
                "timestamp_ms": sentAt.timeIntervalSince1970 * 1000
            ])
        } catch {
            FileLogger.shared.debug(.network, "Stream: END send result", payload: [
                "jobId": dictationID,
                "server": url.absoluteString,
                "sent": false,
                "result": "failed",
                "timestamp_ms": timestamp.timeIntervalSince1970 * 1000,
                "error": String(error.localizedDescription.prefix(160))
            ])
            throw error
        }
    }

    /// Sends a keepalive ping (`{"type":"PING"}`).  The server's
    /// idle timeout is 600 s; the caller should send a PING well
    /// before that threshold during long pauses.
    func sendPing() async throws {
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        try await task.send(.string(#"{"type":"PING"}"#))
        FileLogger.shared.debug(.network, "Sent PING")
    }

    /// Records a partial that keeps the stream alive only before END.
    private func touchActivity() {
        let windowEvents = livenessEvaluator.recordPartialReceived(
            at: Date(),
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents)
    }

    /// Records a PONG for both recording and post-END liveness checks.
    private func touchPong() {
        let windowEvents = livenessEvaluator.recordPongReceived(
            at: Date(),
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents)
    }

    /// Records a final frame as post-END evidence for closing an upload window.
    private func touchFinal() {
        let windowEvents = livenessEvaluator.recordFinalReceived(
            at: Date(),
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents)
    }

    /// Returns staleness after accounting for upload time using wall-clock dates.
    private func livenessStatus() -> StreamLivenessEvaluator.Evaluation {
        let status = livenessEvaluator.evaluate(
            at: Date(),
            interval: SharedConfig.Defaults.streamHealthCheckInterval,
            maxMissedPongs: SharedConfig.Defaults.streamMaxMissedPongs,
            maxUploadWindowAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(status.windowEvents)
        return status
    }

    private func logUploadWindowEvents(
        _ events: StreamLivenessEvaluator.WindowEvents,
        bytes: Int? = nil
    ) {
        if events.lapsed {
            FileLogger.shared.debug(.network, "Upload window lapsed", payload: [
                "maxAgeSec": SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds
            ])
        }
        if events.closed {
            FileLogger.shared.debug(.network, "Upload window closed", payload: [
                "reason": "inbound_evidence"
            ])
        }
        if events.opened {
            var payload: [String: Any] = [
                "maxAgeSec": SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds
            ]
            if let bytes {
                payload["bytes"] = bytes
            }
            FileLogger.shared.debug(.network, "Upload window opened", payload: payload)
        }
    }

    // MARK: - Receiving

    /// Reads messages from the WebSocket until a `final` transcription
    /// arrives or the `streamFinalTimeout` expires.
    ///
    /// Partial transcriptions are passed to `onPartial` as they arrive.
    /// Per-chunk transcriptions are passed to `onChunkResult` when the server
    /// includes a chunk ID.
    /// On a `final` message the full, normalized transcription is returned.
    /// An `error` frame causes the method to throw `WhisperError.httpError`.
    ///
    /// - Parameter onPartial: Closure invoked on every partial result.
    ///   Called from the receive loop's async context; the caller should
    ///   marshal to `MainActor` if UI updates are needed.
    /// - Parameter onChunkResult: Optional closure invoked with the server's
    ///   chunk ID and transcription for each partial or final result that includes an ID.
    /// - Returns: The final, normalized transcription.
    /// - Throws: `WhisperError.timeout` if `streamFinalTimeout` elapses
    ///   without receiving `final`.
    /// - Throws: `WhisperError.httpError` if the server returns an error frame.
    /// - Throws: `WhisperError.networkError` on transport failure.
    func receiveMessages(
        onPartial: @escaping @Sendable (String) -> Void,
        onChunkResult: (@Sendable (UInt32, String) async -> Void)? = nil
    ) async throws -> String {
        receiveFailed = false
        do {
            let transcription = try await receiveMessagesLoop(
                onPartial: onPartial,
                onChunkResult: onChunkResult)
            let completedNormally = !Task.isCancelled
            logReceiveTaskExit(
                reason: completedNormally ? "normal_completion" : "cancellation",
                finalFrameReceived: completedNormally,
                serverErrorFrameReceived: false)
            return transcription
        } catch {
            receiveFailed = true
            let reason = isReceiveCancellation(error) ? "cancellation" : "error"
            logReceiveTaskExit(
                reason: reason,
                finalFrameReceived: false,
                serverErrorFrameReceived: isServerErrorFrame(error),
                error: error.localizedDescription)
            throw error
        }
    }

    private func receiveMessagesLoop(
        onPartial: @escaping @Sendable (String) -> Void,
        onChunkResult: (@Sendable (UInt32, String) async -> Void)?
    ) async throws -> String {
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }

        return try await withThrowingTaskGroup(of: String.self) { group in

            // Receive loop
            group.addTask {
                do {
                    var accumulated = ""

                    while true {
                        let message = try await task.receive()

                        switch message {
                        case .string(let text):
                            guard let data = text.data(using: .utf8) else {
                                continue
                            }

                            do {
                                let base = try JSONDecoder().decode(
                                    StreamMessage.self, from: data)

                                switch base.type {
                                case "partial":
                                    let msg = try JSONDecoder().decode(
                                        StreamPartial.self, from: data)
                                    await self.touchActivity()
                                    if let chunkId = msg.chunk_id {
                                        await onChunkResult?(chunkId, msg.transcription)
                                    } else {
                                        FileLogger.shared.debug(.network, "Received partial without chunk ID")
                                    }
                                    accumulated = accumulated.isEmpty
                                        ? msg.transcription
                                        : accumulated + " " + msg.transcription
                                    FileLogger.shared.debug(.network, "Received partial",
                                                            payload: ["preview": String(accumulated.prefix(60)),
                                                                      "length": accumulated.count,
                                                                      "chunkId": msg.chunk_id as Any])
                                    onPartial(accumulated)

                                case "final":
                                    let msg = try JSONDecoder().decode(
                                        StreamFinal.self, from: data)
                                    await self.touchFinal()
                                    let elapsedSinceEndMs = await self.elapsedSinceEndMs()
                                    if let chunkId = msg.chunk_id {
                                        await onChunkResult?(chunkId, msg.transcription)
                                    }
                                    var payload: [String: Any] = [
                                        "jobId": self.dictationID,
                                        "server": self.url.absoluteString,
                                        "preview": String(msg.transcription.prefix(60)),
                                        "length": msg.transcription.count,
                                        "chunkId": msg.chunk_id as Any
                                    ]
                                    if let elapsedSinceEndMs {
                                        payload["elapsed_since_end_ms"] = elapsedSinceEndMs
                                    } else {
                                        payload["elapsed_since_end_ms"] = NSNull()
                                    }
                                    FileLogger.shared.info(.network, "Received final",
                                                           payload: payload)
                                    return msg.transcription

                                case "PONG":
                                    FileLogger.shared.debug(.network, "Received PONG")
                                    await self.touchPong()
                                    continue

                                case "error":
                                    let msg = try JSONDecoder().decode(
                                        StreamError.self, from: data)
                                    let elapsedSinceEndMs = await self.elapsedSinceEndMs()
                                    var payload: [String: Any] = [
                                        "jobId": self.dictationID,
                                        "server": self.url.absoluteString,
                                        "reason": String(msg.message.prefix(120))
                                    ]
                                    if let elapsedSinceEndMs {
                                        payload["elapsed_since_end_ms"] = elapsedSinceEndMs
                                    } else {
                                        payload["elapsed_since_end_ms"] = NSNull()
                                    }
                                    FileLogger.shared.error(.network, "Stream: server error",
                                                            payload: payload)
                                    throw WhisperError.httpError(0, msg.message)

                                default:
                                    // Unknown type — defensive: ignore
                                    FileLogger.shared.debug(.network, "Ignored unknown message type",
                                                           payload: ["type": base.type])
                                    continue
                                }

                            } catch let error as WhisperError {
                                throw error
                            } catch {
                                // Malformed frame — log and skip
                                FileLogger.shared.debug(.network, "Malformed frame, skipping",
                                                       payload: ["error": error.localizedDescription])
                                continue
                            }

                        case .data:
                            // Server never sends binary frames to the client
                            // in this protocol.
                            continue

                        @unknown default:
                            continue
                        }
                    }
                } catch let error as WhisperError {
                    throw error
                } catch {
                    throw WhisperError.networkError(error)
                }
            }

            // While recording, partials or PONGs count as activity. After END, only PONGs
            // count because no more partials are expected.
            group.addTask { [self] in
                let interval = SharedConfig.Defaults.streamHealthCheckInterval
                let maxMissed = SharedConfig.Defaults.streamMaxMissedPongs
                let (ticks, tickContinuation) = AsyncStream<Void>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                let timer = makeStrictStreamTimer(after: interval) { [weak self] in
                    Task { [weak self] in
                        await self?.yieldLivenessTick(to: tickContinuation)
                    }
                }
                timer.resume()
                defer {
                    timer.cancel()
                    tickContinuation.finish()
                }

                return try await withTaskCancellationHandler {
                    for await _ in ticks {
                        guard !Task.isCancelled else { return "" }
                        try? await self.sendPing()  // solicit a PONG
                        let status = await self.livenessStatus()
                        if status.shouldTimeout {
                            let missingEvidence = status.endSent ? "PONG" : "activity"
                            FileLogger.shared.warn(.network,
                                                   "Stream liveness: no \(missingEvidence), declaring timeout",
                                                   payload: ["id": self.dictationID,
                                                             "staleSec": status.secondsSinceEvidence,
                                                             "interval": interval,
                                                             "maxMissedPongs": maxMissed,
                                                             "endSent": status.endSent])
                            throw WhisperError.timeout
                        }
                        scheduleStrictStreamTimer(timer, after: interval)
                    }
                    return ""
                } onCancel: {
                    timer.cancel()
                    tickContinuation.finish()
                }
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw WhisperError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func yieldLivenessTick(to continuation: AsyncStream<Void>.Continuation) {
        continuation.yield(())
    }

    private func elapsedSinceEndMs() -> Double? {
        livenessEvaluator.elapsedSinceEndMs(at: Date())
    }

    private func logReceiveTaskExit(
        reason: String,
        finalFrameReceived: Bool,
        serverErrorFrameReceived: Bool,
        error: String? = nil
    ) {
        var payload: [String: Any] = [
            "jobId": dictationID,
            "server": url.absoluteString,
            "reason": reason,
            "endSent": livenessEvaluator.hasSentEnd,
            "finalFrameReceived": finalFrameReceived,
            "serverErrorFrameReceived": serverErrorFrameReceived
        ]
        if let elapsedSinceEndMs = elapsedSinceEndMs() {
            payload["elapsed_since_end_ms"] = elapsedSinceEndMs
        } else {
            payload["elapsed_since_end_ms"] = NSNull()
        }
        if let error {
            payload["error"] = String(error.prefix(160))
        }
        FileLogger.shared.log(reason == "error" ? .debug : .info,
                              .network,
                              "Stream: receive task exited",
                              payload: payload)
    }

    private func isServerErrorFrame(_ error: Error) -> Bool {
        guard let whisperError = error as? WhisperError,
              case .httpError = whisperError else {
            return false
        }
        return true
    }

    private func isReceiveCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        if let whisperError = error as? WhisperError {
            switch whisperError {
            case .cancelled:
                return true
            case .networkError(let underlying):
                return underlying is CancellationError
                    || (underlying as? URLError)?.code == .cancelled
            default:
                return false
            }
        }
        return false
    }

    private struct StreamLivenessEvaluator {
        struct WindowEvents {
            var opened = false
            var closed = false
            var lapsed = false
        }

        struct Evaluation {
            let endSent: Bool
            let receivedFinal: Bool
            let secondsSinceEvidence: TimeInterval
            let shouldTimeout: Bool
            let windowOpen: Bool
            let windowEvents: WindowEvents
        }

        private var lastActivityDate: Date = .distantPast
        private var lastPongDate: Date = .distantPast
        private var lastFinalDate: Date?
        private var endSentAt: Date?
        private var receivedFinal = false
        private var uploadWindowOpenedAt: Date?
        /// A lapse cannot be renewed by sends alone; tier-appropriate evidence clears this.
        private var uploadWindowReopenBlocked = false
        /// Cumulative pause credit and the portion already preceding current evidence.
        private var completedUploadPauseSeconds: TimeInterval = 0
        private var uploadPauseCreditAtEvidence: TimeInterval = 0

        var hasSentEnd: Bool { endSentAt != nil }

        func elapsedSinceEndMs(at now: Date) -> Double? {
            guard let endSentAt else { return nil }
            return now.timeIntervalSince(endSentAt) * 1000
        }

        mutating func recordConnected(at date: Date) {
            lastActivityDate = date
            uploadPauseCreditAtEvidence = completedUploadPauseSeconds
        }

        mutating func recordFrameEnqueued(
            bytes: Int,
            at date: Date,
            minimumBytes: Int,
            maxAge: TimeInterval
        ) -> WindowEvents {
            var events = WindowEvents()
            events.lapsed = expireUploadWindowIfNeeded(at: date, maxAge: maxAge)
            guard bytes >= minimumBytes,
                  uploadWindowOpenedAt == nil,
                  !uploadWindowReopenBlocked,
                  !receivedFinal else { return events }
            uploadWindowOpenedAt = date
            events.opened = true
            return events
        }

        mutating func recordEndSent(at date: Date, maxAge: TimeInterval) -> WindowEvents {
            var events = WindowEvents()
            events.lapsed = expireUploadWindowIfNeeded(at: date, maxAge: maxAge)
            guard endSentAt == nil else { return events }
            endSentAt = date
            uploadPauseCreditAtEvidence = completedUploadPauseSeconds
            return events
        }

        mutating func recordPartialReceived(at date: Date, maxAge: TimeInterval) -> WindowEvents {
            var events = WindowEvents()
            events.lapsed = expireUploadWindowIfNeeded(at: date, maxAge: maxAge)
            let closesWindow = endSentAt == nil && closeUploadWindow(at: date, maxAge: maxAge)
            lastActivityDate = date
            guard endSentAt == nil else { return events }
            uploadPauseCreditAtEvidence = completedUploadPauseSeconds
            uploadWindowReopenBlocked = false
            events.closed = closesWindow
            return events
        }

        mutating func recordPongReceived(at date: Date, maxAge: TimeInterval) -> WindowEvents {
            var events = WindowEvents()
            events.lapsed = expireUploadWindowIfNeeded(at: date, maxAge: maxAge)
            events.closed = closeUploadWindow(at: date, maxAge: maxAge)
            lastPongDate = date
            lastActivityDate = date
            uploadPauseCreditAtEvidence = completedUploadPauseSeconds
            uploadWindowReopenBlocked = false
            return events
        }

        mutating func recordFinalReceived(at date: Date, maxAge: TimeInterval) -> WindowEvents {
            var events = WindowEvents()
            events.lapsed = expireUploadWindowIfNeeded(at: date, maxAge: maxAge)
            receivedFinal = true
            if endSentAt != nil {
                events.closed = closeUploadWindow(at: date, maxAge: maxAge)
                uploadWindowReopenBlocked = false
            }
            lastFinalDate = date
            // Keep cumulative pause credit; rebase its contribution at final evidence.
            uploadPauseCreditAtEvidence = completedUploadPauseSeconds
            return events
        }

        mutating func evaluate(
            at now: Date,
            interval: TimeInterval,
            maxMissedPongs: Int,
            maxUploadWindowAge: TimeInterval
        ) -> Evaluation {
            var events = WindowEvents()
            events.lapsed = expireUploadWindowIfNeeded(at: now, maxAge: maxUploadWindowAge)
            let evidenceDate = currentEvidenceDate
            let secondsSinceEvidence = max(
                0,
                now.timeIntervalSince(evidenceDate)
                    - (completedUploadPauseSeconds - uploadPauseCreditAtEvidence)
                    - currentUploadPauseSeconds(
                        at: now,
                        evidenceDate: evidenceDate,
                        maxAge: maxUploadWindowAge)
            )
            return Evaluation(
                endSent: endSentAt != nil,
                receivedFinal: receivedFinal,
                secondsSinceEvidence: secondsSinceEvidence,
                shouldTimeout: !receivedFinal
                    && secondsSinceEvidence >= interval * Double(maxMissedPongs),
                windowOpen: uploadWindowOpenedAt != nil,
                windowEvents: events)
        }

        private var currentEvidenceDate: Date {
            if let endSentAt {
                return max(endSentAt, max(lastPongDate, lastFinalDate ?? .distantPast))
            }
            return lastActivityDate
        }

        private mutating func closeUploadWindow(at date: Date, maxAge: TimeInterval) -> Bool {
            guard let openedAt = uploadWindowOpenedAt else { return false }
            let pausedUntil = min(date, openedAt.addingTimeInterval(maxAge))
            let pausedFrom = max(openedAt, currentEvidenceDate)
            if pausedUntil > pausedFrom {
                completedUploadPauseSeconds += pausedUntil.timeIntervalSince(pausedFrom)
            }
            uploadWindowOpenedAt = nil
            return true
        }

        private mutating func expireUploadWindowIfNeeded(
            at now: Date,
            maxAge: TimeInterval
        ) -> Bool {
            guard let openedAt = uploadWindowOpenedAt else { return false }
            let deadline = openedAt.addingTimeInterval(maxAge)
            guard now >= deadline else { return false }

            let pausedFrom = max(openedAt, currentEvidenceDate)
            if deadline > pausedFrom {
                completedUploadPauseSeconds += deadline.timeIntervalSince(pausedFrom)
            }
            uploadWindowOpenedAt = nil
            uploadWindowReopenBlocked = true
            return true
        }

        private func currentUploadPauseSeconds(
            at now: Date,
            evidenceDate: Date,
            maxAge: TimeInterval
        ) -> TimeInterval {
            guard let openedAt = uploadWindowOpenedAt else { return 0 }
            let pausedFrom = max(openedAt, evidenceDate)
            let pausedUntil = min(now, openedAt.addingTimeInterval(maxAge))
            return max(0, pausedUntil.timeIntervalSince(pausedFrom))
        }
    }

    // MARK: - Disconnection

    /// Forcefully tears down the transport so that any in-flight
    /// `send()`/`receive()` calls fail immediately rather than waiting
    /// for `streamFinalTimeout`.
    private func forceClose() {
        stopKeepaliveTimer()
        task?.cancel(with: .goingAway, reason: nil)
        FileLogger.shared.info(.network, "Force-close: transport cancelled")
    }

    /// Gracefully closes the WebSocket connection.
    ///
    /// It is safe to call this method even if the client is not currently
    /// connected; it becomes a no-op.
    func disconnect() async {
        stopKeepaliveTimer()
        // Cancel any in-flight receive/send operations and close.
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        FileLogger.shared.info(.network, "Stream: disconnected", payload: ["id": dictationID])
    }


    // MARK: - Decodable Helpers

    private struct StreamMessage: Decodable {
        let type: String
    }

    private struct StreamPartial: Decodable {
        let type: String
        let transcription: String
        let chunk_id: UInt32?
    }

    private struct StreamFinal: Decodable {
        let type: String
        let transcription: String
        let chunk_id: UInt32?
    }

    private struct StreamError: Decodable {
        let type: String
        let message: String
    }
}
