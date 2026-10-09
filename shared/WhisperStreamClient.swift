import Foundation

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

actor WhisperStreamClient {

    // MARK: - Private Properties

    /// The WebSocket URL derived from the HTTP base URL.
    private let url: URL
    private let dictationID: String

    /// The active WebSocket task, or nil when disconnected.
    private var task: URLSessionWebSocketTask?

    /// Shared URLSession (no custom delegate needed).
    private let session: URLSession = .shared

    /// Periodic keepalive task that sends app-level PING frames while connected.
    private var keepaliveTask: Task<Void, Never>?

    /// Last PONG or partial received; used as liveness evidence only while recording.
    private var lastActivityDate: Date = .distantPast
    /// PONG-only liveness evidence, used after END has been sent.
    private var lastPongDate: Date = .distantPast
    private var endSentAt: Date?

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

        lastActivityDate = Date()

        // Start the periodic keepalive loop. It must stay under nginx idle
        // (~60s) and the server's 600s recv timeout.
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SharedConfig.Defaults.streamKeepaliveIntervalSeconds * 1_000_000_000))
                guard let self else { break }
                do { try await self.sendPing() }
                catch { await self.forceClose(); break }
            }
        }
        FileLogger.shared.debug(.network, "Keepalive loop started",
                               payload: ["interval": SharedConfig.Defaults.streamKeepaliveIntervalSeconds])
    }

    // MARK: - Sending

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
            if endSentAt == nil {
                endSentAt = sentAt
            }
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

    /// Records activity that keeps the stream alive while recording.
    private func touchActivity() { lastActivityDate = Date() }

    /// Records a PONG for both recording and post-END liveness checks.
    private func touchPong() {
        lastPongDate = Date()
        touchActivity()
    }

    /// Returns time since the evidence appropriate to the current stream phase.
    private func livenessStatus() -> (endSent: Bool, secondsSinceEvidence: TimeInterval) {
        let now = Date()
        if let endSentAt {
            return (true, now.timeIntervalSince(max(endSentAt, lastPongDate)))
        }
        return (false, now.timeIntervalSince(lastActivityDate))
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
                                    await self.touchActivity()

                                case "final":
                                    let msg = try JSONDecoder().decode(
                                        StreamFinal.self, from: data)
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
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        return ""   // cancelled (final arrived / group torn down)
                    }
                    try? await self.sendPing()  // solicit a PONG
                    let status = await self.livenessStatus()
                    if status.secondsSinceEvidence >= interval * Double(maxMissed) {
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
                }
                return ""
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw WhisperError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func elapsedSinceEndMs() -> Double? {
        guard let endSentAt else { return nil }
        return Date().timeIntervalSince(endSentAt) * 1000
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
            "endSent": endSentAt != nil,
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

    // MARK: - Disconnection

    /// Forcefully tears down the transport so that any in-flight
    /// `send()`/`receive()` calls fail immediately rather than waiting
    /// for `streamFinalTimeout`.
    private func forceClose() {
        task?.cancel(with: .goingAway, reason: nil)
        FileLogger.shared.info(.network, "Force-close: transport cancelled")
    }

    /// Gracefully closes the WebSocket connection.
    ///
    /// It is safe to call this method even if the client is not currently
    /// connected; it becomes a no-op.
    func disconnect() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
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
