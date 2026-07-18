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

    // MARK: - Initialization

    /// Creates a streaming client for the given base URL.
    ///
    /// The URL scheme is rewritten from `http`/`https` to `ws`/`wss` and
    /// `/stream` is appended to form the WebSocket endpoint.  If the
    /// `baseURL` contains a path component it is preserved before `/stream`.
    ///
    /// - Parameter baseURL: Base URL of the Whisper server, e.g.
    ///   `"http://192.168.1.100:5000"`.
    init(baseURL: String) {
        var urlString = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Rewrite scheme: http → ws, https → wss
        if urlString.hasPrefix("https://") {
            urlString = "wss://" + urlString.dropFirst(8)
        } else if urlString.hasPrefix("http://") {
            urlString = "ws://" + urlString.dropFirst(7)
        }

        urlString += "/stream"

        if let parsed = URL(string: urlString) {
            self.url = parsed
        } else {
            // Fallback: connect() will use this URL and throw .networkError
            // when the WebSocket handshake inevitably fails.  The alternative
            // would be to throw from init, but that would require a throwing
            // init, which is not idiomatic for simple value construction.
            self.url = URL(string: "ws://localhost:5000/stream")!
        }
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

#if DEBUG
        print("[WhisperStreamClient] Connecting to \(url)")
#endif

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Probe: send PING, wait for PONG
            group.addTask {
                do {
                    try await newTask.send(.string(#"{"type":"PING"}"#))

                    while true {
                        switch try await newTask.receive() {
                        case .string(let text):
                            if text.contains("PONG") {
#if DEBUG
                                print("[WhisperStreamClient] Connected (PONG received)")
#endif
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
#if DEBUG
                print("[WhisperStreamClient] Connection timed out")
#endif
                throw WhisperError.timeout
            }

            try await group.next()
            group.cancelAll()
        }
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

#if DEBUG
        print("[WhisperStreamClient] Sent chunk \(id) (\(data.count) bytes)")
#endif
    }

    /// Signals the end of the audio stream by sending
    /// `{"type":"END"}`.  The server will drain the worker and
    /// respond with a `final` transcription.
    func sendEnd() async throws {
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        try await task.send(.string(#"{"type":"END"}"#))
#if DEBUG
        print("[WhisperStreamClient] Sent END")
#endif
    }

    /// Sends a keepalive ping (`{"type":"PING"}`).  The server's
    /// idle timeout is 600 s; the caller should send a PING well
    /// before that threshold during long pauses.
    func sendPing() async throws {
        guard let task = task else {
            throw WhisperError.networkError(URLError(.notConnectedToInternet))
        }
        try await task.send(.string(#"{"type":"PING"}"#))
#if DEBUG
        print("[WhisperStreamClient] Sent PING")
#endif
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
#if DEBUG
                                    let preview = msg.transcription.prefix(60)
                                    print("[WhisperStreamClient] Received partial: \"\(preview)...\"")
#endif
                                    onPartial(msg.transcription)

                                case "final":
                                    let msg = try JSONDecoder().decode(
                                        StreamFinal.self, from: data)
#if DEBUG
                                    let preview = msg.transcription.prefix(60)
                                    print("[WhisperStreamClient] Received final: \"\(preview)...\"")
#endif
                                    return msg.transcription

                                case "PONG":
#if DEBUG
                                    print("[WhisperStreamClient] Received PONG")
#endif
                                    continue

                                case "error":
                                    let msg = try JSONDecoder().decode(
                                        StreamError.self, from: data)
#if DEBUG
                                    print("[WhisperStreamClient] Received error: \(msg.message)")
#endif
                                    throw WhisperError.httpError(0, msg.message)

                                default:
                                    // Unknown type — defensive: ignore
#if DEBUG
                                    print("[WhisperStreamClient] Ignored unknown message type: \(base.type)")
#endif
                                    continue
                                }

                            } catch let error as WhisperError {
                                throw error
                            } catch {
                                // Malformed frame — log and skip
#if DEBUG
                                print("[WhisperStreamClient] Malformed frame, skipping: \(error)")
#endif
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
#if DEBUG
                print("[WhisperStreamClient] receiveMessages timed out")
#endif
                throw WhisperError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Disconnection

    /// Gracefully closes the WebSocket connection.
    ///
    /// It is safe to call this method even if the client is not currently
    /// connected; it becomes a no-op.
    func disconnect() {
        // Cancel any in-flight receive/send operations and close.
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
#if DEBUG
        print("[WhisperStreamClient] Disconnected")
#endif
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
