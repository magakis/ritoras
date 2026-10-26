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

enum StreamChunkResultKind: Equatable, Sendable {
    case partial
    case final
}

enum WhisperStreamTransportError: Error {
    case dead
    case notReady
    case superseded
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
    private let aacEnabled: Bool
    private let aacSourceSampleRate: Int
    /// Survives reconnects for this client/session after an ambiguous timeout or CONFIG error.
    private var sessionLegacyPinned = false

    /// The active WebSocket task, or nil when disconnected.
    private var task: URLSessionWebSocketTask?
    private var receiveFailed = false
    private var connectionReady = false
    private var connectionGeneration: UInt64 = 0
    private var connectionAttempt: Task<Void, Error>?
    private var connectionAttemptID: UUID?
    private var negotiatedAudioMode: StreamFormatNegotiation.AudioMode?
    private var negotiationDeadline: Date?
    /// Server-minted token from the final message, when the server supports uploads.
    private(set) var finalRecordingToken: String?
    /// Stop-time telemetry starts finalization; reconnecting after it could orphan END.
    private var finalizationStarted = false

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
    init?(baseURL: String, dictationID: UUID, aacEnabled: Bool, aacSourceSampleRate: Int) {
        self.dictationID = dictationID.uuidString
        self.aacEnabled = aacEnabled
        self.aacSourceSampleRate = aacSourceSampleRate
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

    /// Opens the WebSocket connection and verifies reachability via a PING/PONG handshake.
    /// Concurrent callers share the in-flight handshake.
    ///
    /// - Throws: `WhisperError.timeout` if the connection does not complete within
    ///   `streamWsConnectTimeout`.
    /// - Throws: `WhisperError.networkError` if the transport reports a connection failure.
    /// - Throws: `WhisperStreamTransportError.superseded` if another lifecycle action wins.
    func connect() async throws {
        if let connectionAttempt {
            guard let currentTask = task else {
                throw WhisperStreamTransportError.superseded
            }
            let generation = connectionGeneration
            try await connectionAttempt.value
            guard isReadyConnection(currentTask, generation: generation) else {
                throw WhisperStreamTransportError.superseded
            }
            return
        }

        let generation = prepareNewConnection()
        var request = URLRequest(url: url)
        WhisperClient.applyAuth(to: &request)
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()

        FileLogger.shared.debug(.network, "Stream: connecting",
                               payload: ["jobId": dictationID, "server": url.absoluteString])

        let attemptID = UUID()
        let attempt = Task { [weak self] in
            guard let self else { throw WhisperStreamTransportError.superseded }
            try await self.completeConnectionHandshake(using: newTask, generation: generation)
        }
        connectionAttemptID = attemptID
        connectionAttempt = attempt

        do {
            try await attempt.value
            guard isReadyConnection(newTask, generation: generation) else {
                throw WhisperStreamTransportError.superseded
            }
            if connectionAttemptID == attemptID {
                connectionAttempt = nil
                connectionAttemptID = nil
            }
        } catch {
            if connectionAttemptID == attemptID {
                connectionAttempt = nil
                connectionAttemptID = nil
                if isCurrentConnection(newTask, generation: generation) {
                    closeConnection(markReceiveFailed: true)
                }
            }
            throw error
        }
    }

    /// Starts one fresh server session, bounded by the normal connect handshake timeout.
    /// Reconnect is invalid once stop-time telemetry or END has begun.
    func reconnect() async -> Bool {
        guard !finalizationStarted else { return false }
        do {
            try await connect()
            return isConnected()
        } catch {
            return false
        }
    }

    private func prepareNewConnection() -> UInt64 {
        connectionGeneration &+= 1
        stopKeepaliveTimer()
        connectionAttempt?.cancel()
        connectionAttempt = nil
        connectionAttemptID = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionReady = false
        receiveFailed = false
        negotiatedAudioMode = nil
        negotiationDeadline = nil
        finalizationStarted = false
        livenessEvaluator = StreamLivenessEvaluator()
        return connectionGeneration
    }

    private func completeConnectionHandshake(
        using newTask: URLSessionWebSocketTask,
        generation: UInt64
    ) async throws {
        let handshakeDeadline = Date().addingTimeInterval(
            SharedConfig.Defaults.streamWsConnectTimeout)
        let shouldNegotiateAAC = StreamFormatNegotiation.shouldSendConfig(
            aacEnabled: aacEnabled,
            sessionLegacyPinned: sessionLegacyPinned)
        let configMessage: String?
        if shouldNegotiateAAC {
            guard let message = StreamFormatNegotiation.configMessage(
                sampleRate: aacSourceSampleRate) else {
                throw StreamFormatNegotiationError.unsupportedSourceSampleRate(aacSourceSampleRate)
            }
            configMessage = message
        } else {
            configMessage = nil
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    do {
                        try await newTask.send(.string(#"{"type":"PING"}"#))

                        while true {
                            switch try await newTask.receive() {
                            case .string(let text):
                                if text.contains("PONG") {
                                    guard await self.isCurrentConnection(
                                        newTask, generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }
                                    if let configMessage {
                                        try await newTask.send(.string(configMessage))
                                    }
                                    return
                                }
                                continue
                            case .data:
                                continue
                            @unknown default:
                                continue
                            }
                        }
                    } catch let error as WhisperStreamTransportError {
                        throw error
                    } catch let error as WhisperError {
                        throw error
                    } catch {
                        throw WhisperError.networkError(error)
                    }
                } onCancel: {
                    newTask.cancel(with: .goingAway, reason: nil)
                }
            }

            group.addTask {
                let remaining = max(0, handshakeDeadline.timeIntervalSinceNow)
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard await self.isCurrentConnection(
                    newTask, generation: generation) else {
                    throw WhisperStreamTransportError.superseded
                }
                FileLogger.shared.debug(.network, "Connection timed out",
                                       payload: ["id": self.dictationID,
                                                 "timeout": SharedConfig.Defaults.streamWsConnectTimeout])
                throw WhisperError.timeout
            }

            try await group.next()
            group.cancelAll()
        }

        guard isCurrentConnection(newTask, generation: generation) else {
            throw WhisperStreamTransportError.superseded
        }

        negotiatedAudioMode = StreamFormatNegotiation.initialMode(aacEnabled: shouldNegotiateAAC)
        negotiationDeadline = negotiatedAudioMode == nil ? handshakeDeadline : nil
        if configMessage != nil {
            FileLogger.shared.debug(.network, "Stream: CONFIG sent", payload: [
                "jobId": dictationID,
                "sampleRate": aacSourceSampleRate
            ])
        }

        FileLogger.shared.info(.network, "Connected (PONG received)",
                               payload: ["jobId": dictationID, "server": url.absoluteString])
        livenessEvaluator.recordConnected(at: Date())
        connectionReady = true

        startKeepaliveTimer(for: newTask, generation: generation)
        FileLogger.shared.debug(.network, "Keepalive loop started",
                               payload: ["interval": SharedConfig.Defaults.streamKeepaliveIntervalSeconds])
    }

    private func isCurrentConnection(
        _ expectedTask: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        connectionGeneration == generation && task === expectedTask
    }

    private func isReadyConnection(
        _ expectedTask: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        isCurrentConnection(expectedTask, generation: generation)
            && connectionReady
            && !receiveFailed
            && expectedTask.state == .running
    }

    private func recordFinalRecordingToken(_ token: String?) {
        finalRecordingToken = token
    }

    private func activeConnection() throws -> (task: URLSessionWebSocketTask, generation: UInt64) {
        guard let task, task.state == .running, !receiveFailed else {
            throw WhisperStreamTransportError.dead
        }
        guard connectionReady else {
            throw WhisperStreamTransportError.notReady
        }
        return (task, connectionGeneration)
    }

    func isTransportDead() -> Bool {
        guard let task else { return true }
        return receiveFailed || task.state != .running
    }

    func isConnected() -> Bool {
        guard let task else { return false }
        return isReadyConnection(task, generation: connectionGeneration)
    }

    private func startKeepaliveTimer(
        for task: URLSessionWebSocketTask,
        generation: UInt64
    ) {
        stopKeepaliveTimer()
        let timerID = UUID()
        let interval = SharedConfig.Defaults.streamKeepaliveIntervalSeconds
        let timer = makeStrictStreamTimer(after: interval) { [weak self] in
            Task { [weak self] in
                await self?.keepaliveTimerFired(
                    timerID: timerID,
                    task: task,
                    generation: generation)
            }
        }
        keepaliveTimerID = timerID
        keepaliveTimer = timer
        timer.resume()
    }

    private func keepaliveTimerFired(
        timerID: UUID,
        task: URLSessionWebSocketTask,
        generation: UInt64
    ) async {
        guard keepaliveTimerID == timerID,
              isReadyConnection(task, generation: generation) else { return }
        do {
            try await sendPing(on: task, generation: generation)
        } catch {
            guard keepaliveTimerID == timerID,
                  isReadyConnection(task, generation: generation) else { return }
            forceClose()
            return
        }

        guard keepaliveTimerID == timerID,
              isReadyConnection(task, generation: generation),
              let keepaliveTimer else { return }
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

    /// Waits for the per-connection audio mode before the first binary frame.
    /// The ACK deadline shares the original PING/PONG connection-setup budget;
    /// expiry closes the ambiguous socket and pins future session connections to PCM.
    func waitForNegotiatedAudioMode() async throws -> StreamFormatNegotiation.AudioMode {
        let connection = try activeConnection()
        while true {
            guard isReadyConnection(connection.task, generation: connection.generation) else {
                throw WhisperStreamTransportError.dead
            }
            if let negotiatedAudioMode {
                return negotiatedAudioMode
            }
            guard let negotiationDeadline else {
                throw WhisperStreamTransportError.notReady
            }

            let remaining = negotiationDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                closeAndPinLegacyAfterNegotiationTimeout()
                throw WhisperStreamTransportError.dead
            }

            try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.05) * 1_000_000_000))
        }
    }

    /// Sends one JSON telemetry text frame. The caller orders it before END.
    func sendTelemetry(_ data: Data) async throws {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        let connection = try activeConnection()
        finalizationStarted = true
        try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = TelemetrySendContinuation(continuation)
            Task {
                do {
                    try await connection.task.send(.string(text))
                    let stillConnected = await self.isReadyConnection(
                        connection.task,
                        generation: connection.generation)
                    guard stillConnected else {
                        resumeOnce.resume(with: .failure(WhisperStreamTransportError.dead))
                        return
                    }
                    resumeOnce.resume(with: .success(()))
                } catch {
                    let mappedError = await self.mappedSendFailure(
                        error,
                        task: connection.task,
                        generation: connection.generation)
                    resumeOnce.resume(with: .failure(mappedError))
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(Self.telemetrySendTimeoutNanoseconds))) {
                    resumeOnce.resume(with: .failure(StreamTelemetrySendError.timeout))
                }
        }
    }

    func isHealthyForTelemetry() -> Bool {
        isConnected()
    }

    /// Sends a binary frame containing a legacy Float32 PCM audio chunk.
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
        guard negotiatedAudioMode == .float32PCM else {
            throw WhisperStreamTransportError.notReady
        }
        try await sendChunkFrame(
            id: id,
            payloadByteCount: samples.count * MemoryLayout<Float>.size
        ) { data in
            // Float32 PCM samples are little-endian on ARM64, matching numpy default.
            samples.withUnsafeBytes { data.append(contentsOf: $0) }
        }
    }

    /// Sends one complete AAC/MPEG-4 container after the existing chunk ID prefix.
    func sendAACChunk(id: UInt32, payload: Data) async throws {
        guard negotiatedAudioMode == .aacM4A else {
            throw WhisperStreamTransportError.notReady
        }
        try await sendChunkFrame(id: id, payloadByteCount: payload.count) { data in
            data.append(payload)
        }
    }

    private func sendChunkFrame(
        id: UInt32,
        payloadByteCount: Int,
        appendPayload: (inout Data) -> Void
    ) async throws {
        let connection = try activeConnection()
        var data = Data(capacity: 4 + payloadByteCount)

        // The chunk identifier remains a 4-byte big-endian prefix in both modes.
        var bigEndianId = id.bigEndian
        withUnsafeBytes(of: &bigEndianId) { data.append(contentsOf: $0) }
        appendPayload(&data)

        let windowEvents = livenessEvaluator.recordFrameEnqueued(
            bytes: data.count,
            at: Date(),
            minimumBytes: SharedConfig.Defaults.streamUploadWindowMinimumBytes,
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents, bytes: data.count)

        do {
            try await connection.task.send(.data(data))
        } catch {
            throw mappedSendFailure(
                error,
                task: connection.task,
                generation: connection.generation)
        }
        guard isReadyConnection(connection.task, generation: connection.generation) else {
            throw WhisperStreamTransportError.dead
        }

        FileLogger.shared.debug(.network, "Sent chunk",
                                payload: ["chunkId": id, "bytes": data.count])
    }

    /// Signals the end of the audio stream by sending
    /// `{"type":"END"}`.  The server will drain the worker and
    /// respond with a `final` transcription.
    func sendEnd() async throws {
        let timestamp = Date()
        let connection: (task: URLSessionWebSocketTask, generation: UInt64)
        do {
            connection = try activeConnection()
        } catch {
            FileLogger.shared.debug(.network, "Stream: END send result", payload: [
                "jobId": dictationID,
                "server": url.absoluteString,
                "sent": false,
                "result": "failed",
                "timestamp_ms": timestamp.timeIntervalSince1970 * 1000,
                "error": "WebSocket is not connected"
            ])
            throw error
        }
        finalizationStarted = true
        do {
            try await connection.task.send(.string(#"{"type":"END"}"#))
            guard isReadyConnection(connection.task, generation: connection.generation) else {
                throw WhisperStreamTransportError.dead
            }
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
            throw mappedSendFailure(
                error,
                task: connection.task,
                generation: connection.generation)
        }
    }

    /// Sends a keepalive ping (`{"type":"PING"}`).  The server's
    /// idle timeout is 600 s; the caller should send a PING well
    /// before that threshold during long pauses.
    func sendPing() async throws {
        let connection = try activeConnection()
        try await sendPing(on: connection.task, generation: connection.generation)
    }

    private func sendPing(
        on task: URLSessionWebSocketTask,
        generation: UInt64
    ) async throws {
        guard isReadyConnection(task, generation: generation) else {
            throw WhisperStreamTransportError.dead
        }
        do {
            try await task.send(.string(#"{"type":"PING"}"#))
        } catch {
            throw mappedSendFailure(error, task: task, generation: generation)
        }
        guard isReadyConnection(task, generation: generation) else {
            throw WhisperStreamTransportError.dead
        }
        FileLogger.shared.debug(.network, "Sent PING")
    }

    private func mappedSendFailure(
        _ error: Error,
        task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Error {
        guard isReadyConnection(task, generation: generation) else {
            if isCurrentConnection(task, generation: generation) {
                forceClose()
            }
            return WhisperStreamTransportError.dead
        }
        return error
    }

    /// Records a partial that keeps the stream alive only before END.
    private func touchActivity(
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        guard isReadyConnection(task, generation: generation) else { return false }
        let windowEvents = livenessEvaluator.recordPartialReceived(
            at: Date(),
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents)
        return true
    }

    /// Records a PONG for both recording and post-END liveness checks.
    private func touchPong(
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        guard isReadyConnection(task, generation: generation) else { return false }
        let windowEvents = livenessEvaluator.recordPongReceived(
            at: Date(),
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents)
        return true
    }

    /// Records a final frame as post-END evidence for closing an upload window.
    private func touchFinal(
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        guard isReadyConnection(task, generation: generation) else { return false }
        let windowEvents = livenessEvaluator.recordFinalReceived(
            at: Date(),
            maxAge: SharedConfig.Defaults.streamUploadWindowMaxAgeSeconds)
        logUploadWindowEvents(windowEvents)
        return true
    }

    private func publishPartial(
        _ partial: String,
        using callback: @Sendable (String) -> Void,
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        guard isReadyConnection(task, generation: generation) else { return false }
        callback(partial)
        return true
    }

    private func publishChunkResult(
        id: UInt32,
        kind: StreamChunkResultKind,
        text: String,
        using callback: (@Sendable (UInt32, StreamChunkResultKind, String) async -> Void)?,
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) async -> Bool {
        guard isReadyConnection(task, generation: generation) else { return false }
        await callback?(id, kind, text)
        return isReadyConnection(task, generation: generation)
    }

    private func consumeNegotiationResponse(
        _ text: String,
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        guard isReadyConnection(task, generation: generation),
              negotiatedAudioMode == nil else {
            return false
        }
        let deadlineExpired = negotiationDeadline.map { $0.timeIntervalSinceNow <= 0 } ?? false
        switch StreamFormatNegotiation.decision(
            forServerMessage: text,
            aacEnabled: aacEnabled,
            deadlineExpired: deadlineExpired) {
        case .wait:
            return true
        case .select(.aacM4A):
            negotiatedAudioMode = .aacM4A
            negotiationDeadline = nil
            FileLogger.shared.info(.network, "Stream: AAC format accepted", payload: [
                "jobId": dictationID,
                "sampleRate": aacSourceSampleRate
            ])
            return true
        case .select(.float32PCM):
            negotiatedAudioMode = .float32PCM
            negotiationDeadline = nil
            FileLogger.shared.info(.network, "Stream: AAC disabled; using Float32", payload: [
                "jobId": dictationID
            ])
            return true
        case .fallbackInPlaceAndPinLegacy:
            sessionLegacyPinned = true
            negotiatedAudioMode = .float32PCM
            negotiationDeadline = nil
            FileLogger.shared.warn(.network, "Stream: CONFIG rejected; using Float32", payload: [
                "jobId": dictationID
            ])
            return true
        case .closeConnectionAndPinLegacy:
            closeAndPinLegacyAfterNegotiationTimeout()
            return true
        }
    }

    private func closeAndPinLegacyAfterNegotiationTimeout() {
        guard negotiatedAudioMode == nil else { return }
        guard case .closeConnectionAndPinLegacy = StreamFormatNegotiation.timeoutDecision() else {
            return
        }
        sessionLegacyPinned = true
        negotiationDeadline = nil
        FileLogger.shared.warn(
            .network,
            "Stream: CONFIG ACK timed out; closing and pinning session to Float32",
            payload: ["jobId": dictationID])
        forceClose()
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

    private func livenessStatus(
        for task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> StreamLivenessEvaluator.Evaluation? {
        guard isReadyConnection(task, generation: generation) else { return nil }
        return livenessStatus()
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
    ///   chunk ID, result kind, and transcription for each partial or final result that includes an ID.
    /// - Returns: The final, normalized transcription.
    /// - Throws: `WhisperError.timeout` if `streamFinalTimeout` elapses
    ///   without receiving `final`.
    /// - Throws: `WhisperError.httpError` if the server returns an error frame.
    /// - Throws: `WhisperStreamTransportError` if the connection is dead, not ready, or superseded.
    /// - Throws: `WhisperError.networkError` on transport failure.
    func receiveMessages(
        onPartial: @escaping @Sendable (String) -> Void,
        onChunkResult: (@Sendable (UInt32, StreamChunkResultKind, String) async -> Void)? = nil
    ) async throws -> String {
        let connection = try activeConnection()
        do {
            let transcription = try await receiveMessagesLoop(
                task: connection.task,
                generation: connection.generation,
                onPartial: onPartial,
                onChunkResult: onChunkResult)
            guard isReadyConnection(connection.task, generation: connection.generation) else {
                throw WhisperStreamTransportError.superseded
            }
            let completedNormally = !Task.isCancelled
            logReceiveTaskExit(
                reason: completedNormally ? "normal_completion" : "cancellation",
                finalFrameReceived: completedNormally,
                serverErrorFrameReceived: false)
            return transcription
        } catch {
            if isCurrentConnection(connection.task, generation: connection.generation) {
                closeConnection(markReceiveFailed: true)
                let reason = isReceiveCancellation(error) ? "cancellation" : "error"
                logReceiveTaskExit(
                    reason: reason,
                    finalFrameReceived: false,
                    serverErrorFrameReceived: isServerErrorFrame(error),
                    error: error.localizedDescription)
            }
            throw error
        }
    }

    private func receiveMessagesLoop(
        task: URLSessionWebSocketTask,
        generation: UInt64,
        onPartial: @escaping @Sendable (String) -> Void,
        onChunkResult: (@Sendable (UInt32, StreamChunkResultKind, String) async -> Void)?
    ) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in

            // Receive loop
            group.addTask {
                do {
                    var accumulated = ""

                    while true {
                        let message = try await task.receive()
                        guard await self.isReadyConnection(task, generation: generation) else {
                            throw WhisperStreamTransportError.superseded
                        }

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
                                    guard await self.touchActivity(
                                        from: task, generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }
                                    if let chunkId = msg.chunk_id {
                                        guard await self.publishChunkResult(
                                            id: chunkId,
                                            kind: .partial,
                                            text: msg.transcription,
                                            using: onChunkResult,
                                            from: task,
                                            generation: generation) else {
                                            throw WhisperStreamTransportError.superseded
                                        }
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
                                    guard await self.publishPartial(
                                        accumulated,
                                        using: onPartial,
                                        from: task,
                                        generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }

                                case "final":
                                    let msg = try JSONDecoder().decode(
                                        StreamFinal.self, from: data)
                                    guard await self.touchFinal(
                                        from: task, generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }
                                    let elapsedSinceEndMs = await self.elapsedSinceEndMs()
                                    guard await self.isReadyConnection(
                                        task, generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }
                                    await self.recordFinalRecordingToken(msg.recording_token)
                                    if let chunkId = msg.chunk_id {
                                        guard await self.publishChunkResult(
                                            id: chunkId,
                                            kind: .final,
                                            text: msg.transcription,
                                            using: onChunkResult,
                                            from: task,
                                            generation: generation) else {
                                            throw WhisperStreamTransportError.superseded
                                        }
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
                                    guard await self.touchPong(
                                        from: task, generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }
                                    FileLogger.shared.debug(.network, "Received PONG")
                                    continue

                                case "CONFIG_ACK":
                                    _ = await self.consumeNegotiationResponse(
                                        text,
                                        from: task,
                                        generation: generation)
                                    continue

                                case "error":
                                    if await self.consumeNegotiationResponse(
                                        text,
                                        from: task,
                                        generation: generation) {
                                        continue
                                    }
                                    let msg = try JSONDecoder().decode(
                                        StreamError.self, from: data)
                                    let elapsedSinceEndMs = await self.elapsedSinceEndMs()
                                    guard await self.isReadyConnection(
                                        task, generation: generation) else {
                                        throw WhisperStreamTransportError.superseded
                                    }
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

                            } catch let error as WhisperStreamTransportError {
                                throw error
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
                } catch let error as WhisperStreamTransportError {
                    throw error
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
                        await self?.yieldLivenessTick(
                            to: tickContinuation,
                            from: task,
                            generation: generation)
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
                        guard await self.isReadyConnection(
                            task, generation: generation) else {
                            throw WhisperStreamTransportError.superseded
                        }
                        do {
                            try await self.sendPing(on: task, generation: generation)
                        } catch {
                            guard await self.isReadyConnection(
                                task, generation: generation) else {
                                throw WhisperStreamTransportError.superseded
                            }
                        }
                        guard let status = await self.livenessStatus(
                            for: task,
                            generation: generation) else {
                            throw WhisperStreamTransportError.superseded
                        }
                        if status.shouldTimeout {
                            let missingEvidence = status.endSent ? "PONG" : "activity"
                            guard await self.logLivenessTimeoutIfCurrent(
                                status,
                                missingEvidence: missingEvidence,
                                interval: interval,
                                maxMissed: maxMissed,
                                task: task,
                                generation: generation) else {
                                throw WhisperStreamTransportError.superseded
                            }
                            throw WhisperError.timeout
                        }
                        guard await self.isReadyConnection(
                            task, generation: generation) else {
                            throw WhisperStreamTransportError.superseded
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

    private func yieldLivenessTick(
        to continuation: AsyncStream<Void>.Continuation,
        from task: URLSessionWebSocketTask,
        generation: UInt64
    ) {
        guard isReadyConnection(task, generation: generation) else { return }
        continuation.yield(())
    }

    private func logLivenessTimeoutIfCurrent(
        _ status: StreamLivenessEvaluator.Evaluation,
        missingEvidence: String,
        interval: TimeInterval,
        maxMissed: Int,
        task: URLSessionWebSocketTask,
        generation: UInt64
    ) -> Bool {
        guard isReadyConnection(task, generation: generation) else { return false }
        FileLogger.shared.warn(.network,
                               "Stream liveness: no \(missingEvidence), declaring timeout",
                               payload: ["id": dictationID,
                                         "staleSec": status.secondsSinceEvidence,
                                         "interval": interval,
                                         "maxMissedPongs": maxMissed,
                                         "endSent": status.endSent])
        return true
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
        closeConnection(markReceiveFailed: true)
        FileLogger.shared.info(.network, "Force-close: transport cancelled")
    }

    private func closeConnection(markReceiveFailed: Bool) {
        connectionGeneration &+= 1
        stopKeepaliveTimer()
        connectionAttempt?.cancel()
        connectionAttempt = nil
        connectionAttemptID = nil
        let oldTask = task
        task = nil
        connectionReady = false
        if markReceiveFailed {
            receiveFailed = true
        }
        oldTask?.cancel(with: .goingAway, reason: nil)
    }

    /// Gracefully closes the WebSocket connection.
    ///
    /// It is safe to call this method even if the client is not currently
    /// connected; it becomes a no-op.
    func disconnect() async {
        closeConnection(markReceiveFailed: false)
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
        let recording_token: String?
    }

    private struct StreamError: Decodable {
        let type: String
        let message: String
    }
}
