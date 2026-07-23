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

    /// The active WebSocket task, or nil when disconnected.
    private var task: URLSessionWebSocketTask?

    /// Shared URLSession (no custom delegate needed).
    private let session: URLSession = .shared

    /// Periodic keepalive task that sends app-level PING frames while connected.
    private var keepaliveTask: Task<Void, Never>?

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
    init?(baseURL: String) {
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
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()

        FileLogger.shared.info(.network, "Connecting to WebSocket",
                               payload: ["url": url.absoluteString])

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
                                                       payload: ["url": self.url.absoluteString])
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
                FileLogger.shared.warn(.network, "Connection timed out",
                                       payload: ["url": self.url.absoluteString,
                                                 "timeout": SharedConfig.Defaults.streamWsConnectTimeout])
                throw WhisperError.timeout
            }

            try await group.next()
            group.cancelAll()
        }

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
        FileLogger.shared.info(.network, "Keepalive loop started",
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
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        try await task.send(.string(#"{"type":"END"}"#))
        FileLogger.shared.info(.network, "Sent END")
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

    // MARK: - Receiving

    /// Reads messages from the WebSocket until a `final` transcription
    /// arrives or the `streamFinalTimeout` expires.
    ///
    /// Partial transcriptions are passed to `onPartial` as they arrive.
    /// On a `final` message the full, normalized transcription is returned.
    /// An `error` frame causes the method to throw `WhisperError.httpError`.
    ///
    /// - Parameter onPartial: Closure invoked on every partial result.
    ///   Called from the receive loop's async context; the caller should
    ///   marshal to `MainActor` if UI updates are needed.
    /// - Returns: The final, normalized transcription.
    /// - Throws: `WhisperError.timeout` if `streamFinalTimeout` elapses
    ///   without receiving `final`.
    /// - Throws: `WhisperError.httpError` if the server returns an error frame.
    /// - Throws: `WhisperError.networkError` on transport failure.
    func receiveMessages(
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }

        return try await withThrowingTaskGroup(of: String.self) { group in

            // Receive loop
            group.addTask {
                do {
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
                                    FileLogger.shared.debug(.network, "Received partial",
                                                            payload: ["preview": String(msg.transcription.prefix(60)),
                                                                      "length": msg.transcription.count,
                                                                      "chunkId": msg.chunk_id as Any])
                                    onPartial(msg.transcription)

                                case "final":
                                    let msg = try JSONDecoder().decode(
                                        StreamFinal.self, from: data)
                                    FileLogger.shared.info(.network, "Received final",
                                                           payload: ["preview": String(msg.transcription.prefix(60)),
                                                                     "length": msg.transcription.count,
                                                                     "chunkId": msg.chunk_id as Any])
                                    return msg.transcription

                                case "PONG":
                                    FileLogger.shared.debug(.network, "Received PONG")
                                    continue

                                case "error":
                                    let msg = try JSONDecoder().decode(
                                        StreamError.self, from: data)
                                    FileLogger.shared.error(.network, "Received error",
                                                            payload: ["message": msg.message])
                                    throw WhisperError.httpError(0, msg.message)

                                default:
                                    // Unknown type — defensive: ignore
                                    FileLogger.shared.warn(.network, "Ignored unknown message type",
                                                           payload: ["type": base.type])
                                    continue
                                }

                            } catch let error as WhisperError {
                                throw error
                            } catch {
                                // Malformed frame — log and skip
                                FileLogger.shared.warn(.network, "Malformed frame, skipping",
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

            // Timeout guard
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(SharedConfig.Defaults.streamFinalTimeout * 1_000_000_000)
                )
                FileLogger.shared.warn(.network, "receiveMessages timed out",
                                       payload: ["timeout": SharedConfig.Defaults.streamFinalTimeout])
                throw WhisperError.timeout
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw WhisperError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Disconnection

    /// Forcefully tears down the transport so that any in-flight
    /// `send()`/`receive()` calls fail immediately rather than waiting
    /// for `streamFinalTimeout`.
    private func forceClose() {
        task?.cancel(with: .goingAway, reason: nil)
        FileLogger.shared.warn(.network, "Force-close: transport cancelled")
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
        FileLogger.shared.info(.network, "Disconnected")
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
