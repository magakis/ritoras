import Foundation

enum UnifiedStreamConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case ending
    case cancelling
    case closed
    case failed
}

enum UnifiedStreamClientEvent: Sendable {
    case connectionState(UnifiedStreamConnectionState)
    case interim(UnifiedStreamInterim)
    case finalSegment(UnifiedStreamFinalSegment)
    case final(UnifiedStreamFinal)
    case pong
    case error(String)
    case cancelled
    case deadSocket
    case unknownMessage(String)
}

enum UnifiedStreamClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidState
    case invalidTimeout
    case timeout
    case notConnected
    case connectionClosed
    case cancelled
    case pingAlreadyPending
    case sendQueueFull
    case deadSocket
    case serverFailure(String)
    case networkFailure(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "The unified streaming operation is not valid in the current connection state."
        case .invalidTimeout:
            return "Timeouts must be finite and non-negative; connect requires a positive value."
        case .timeout:
            return "The unified streaming server did not respond in time."
        case .notConnected:
            return "The unified streaming WebSocket is not connected."
        case .connectionClosed:
            return "The unified streaming WebSocket closed before completion."
        case .cancelled:
            return "The unified streaming session was cancelled."
        case .pingAlreadyPending:
            return "A unified streaming PING is already awaiting its PONG."
        case .sendQueueFull:
            return "The bounded unified streaming send queue is full."
        case .deadSocket:
            return "The unified streaming server did not answer PING."
        case .serverFailure(let message):
            return "Unified streaming server error: \(message)"
        case .networkFailure(let message):
            return "Unified streaming network error: \(message)"
        case .protocolFailure(let message):
            return "Invalid unified streaming response: \(message)"
        }
    }
}

private enum UnifiedStreamFinalWaitOutcome: Sendable {
    case final(UnifiedStreamFinal)
    case failure(UnifiedStreamClientError)
}

/// A dedicated client for the experimental `/stream-unified` raw PCM protocol.
actor UnifiedStreamClient {
    private static let maximumTimeoutSeconds = Double(UInt64.max / 1_000_000_000)
    private static let keepaliveIntervalNanoseconds: UInt64 = 30_000_000_000
    private static let pongTimeoutNanoseconds: UInt64 = 10_000_000_000
    // Serializes audio and control frames while bounding retained payloads.
    private static let maximumPendingSends = 4
    private static let pingMessage = #"{"type":"PING"}"#
    private static let endMessage = #"{"type":"END"}"#
    private static let cancelMessage = #"{"type":"CANCEL"}"#

    private let url: URL
    private let apiKey: String?
    private let session = URLSession.shared
    private let eventStream: AsyncStream<UnifiedStreamClientEvent>
    private let eventContinuation: AsyncStream<UnifiedStreamClientEvent>.Continuation

    private var webSocket: URLSessionWebSocketTask?
    private var connectionState: UnifiedStreamConnectionState = .disconnected
    private var connectionGeneration: UInt64 = 0
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var pongTimeoutTask: Task<Void, Never>?
    private var awaitingPongID: UInt64?
    private var pingGeneration: UInt64 = 0
    private var lastPongDate: Date?
    private var sendTail: Task<Void, Error>?
    private var sendGeneration: UInt64 = 0
    private var pendingSendCount = 0
    private var chunkIDs = UnifiedStreamChunkIDSequence()
    private var transcript = UnifiedStreamTranscriptAccumulator()
    private var finalResult: UnifiedStreamFinal?
    private var endRequested = false
    private var lastFailure: UnifiedStreamClientError?
    private var finalWaiters: [UUID: AsyncStream<UnifiedStreamFinalWaitOutcome>.Continuation] = [:]

    // MARK: - Initialization

    /// Creates a client from an HTTP(S) base URL, preserving its path before
    /// appending `/stream-unified`. Empty API keys omit the Authorization header.
    init?(baseURL: String, apiKey: String? = nil) {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = (basePath.isEmpty ? "" : "/\(basePath)") + "/stream-unified"
        components.fragment = nil
        guard let url = components.url else { return nil }

        let (eventStream, eventContinuation) = AsyncStream<UnifiedStreamClientEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        self.url = url
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.eventStream = eventStream
        self.eventContinuation = eventContinuation
    }

    /// A bounded stream of server events and connection-state changes.
    func events() -> AsyncStream<UnifiedStreamClientEvent> {
        eventStream
    }

    // MARK: - Connection

    /// Opens the WebSocket and confirms reachability with the allowed PING/PONG control.
    func connect(timeout: TimeInterval = 20) async throws {
        if connectionState == .connected {
            return
        }
        guard connectionState == .disconnected else {
            throw UnifiedStreamClientError.connectionClosed
        }
        let timeoutNanoseconds = try Self.nanoseconds(for: timeout)

        connectionGeneration &+= 1
        let generation = connectionGeneration
        chunkIDs = UnifiedStreamChunkIDSequence()
        updateConnectionState(.connecting)

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()

        do {
            try await verifyConnection(task, generation: generation, timeoutNanoseconds: timeoutNanoseconds)
            guard isCurrent(task, generation: generation) else {
                throw UnifiedStreamClientError.connectionClosed
            }
            updateConnectionState(.connected)
            startReceiveLoop(task, generation: generation)
            startKeepalive(generation: generation)
        } catch {
            if isCurrent(task, generation: generation) {
                let failure = Self.clientError(from: error)
                failConnection(
                    failure,
                    generation: generation,
                    deadSocket: failure == .timeout)
            }
            throw error
        }
    }

    /// Sends one non-empty 16 kHz mono Float32 buffer as a unique, ordered binary frame.
    func sendAudio(samples: [Float]) async throws {
        guard connectionState == .connected, let task = webSocket else {
            throw UnifiedStreamClientError.notConnected
        }
        guard !samples.isEmpty else {
            throw UnifiedStreamProtocolError.invalidAudioFrame
        }

        let chunkID = try chunkIDs.next()
        let frame = try UnifiedStreamFrameCodec.encode(chunkID: chunkID, samples: samples)
        try await enqueueSend(.data(frame), on: task, generation: connectionGeneration)
    }

    // MARK: - Controls

    /// Sends a JSON PING and marks the socket dead if its PONG does not arrive in time.
    func sendPing() async throws {
        guard (connectionState == .connected || connectionState == .ending),
              let task = webSocket else {
            throw UnifiedStreamClientError.notConnected
        }
        guard awaitingPongID == nil else {
            throw UnifiedStreamClientError.pingAlreadyPending
        }

        pingGeneration &+= 1
        let pingID = pingGeneration
        let generation = connectionGeneration
        awaitingPongID = pingID
        pongTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.pongTimeoutNanoseconds)
                await self?.pingTimedOut(pingID, generation: generation)
            } catch {
                return
            }
        }

        do {
            try await enqueueSend(.string(Self.pingMessage), on: task, generation: generation)
        } catch {
            if awaitingPongID == pingID {
                awaitingPongID = nil
                pongTimeoutTask?.cancel()
                pongTimeoutTask = nil
            }
            throw error
        }
    }

    /// Sends CANCEL. The server replies with `cancelled` and closes with code 1000.
    func sendCancel() async throws {
        guard connectionState == .connected || connectionState == .ending,
              let task = webSocket else {
            throw UnifiedStreamClientError.notConnected
        }
        let previousState = connectionState
        updateConnectionState(.cancelling)
        stopKeepalive()
        clearPendingPong()
        do {
            try await enqueueSend(.string(Self.cancelMessage), on: task, generation: connectionGeneration)
        } catch UnifiedStreamClientError.sendQueueFull {
            updateConnectionState(previousState)
            startKeepalive(generation: connectionGeneration)
            throw UnifiedStreamClientError.sendQueueFull
        }
    }

    /// Sends END; only this control asks the server to produce its aggregate final.
    func sendEnd() async throws {
        guard let task = webSocket else {
            throw UnifiedStreamClientError.notConnected
        }
        guard connectionState == .connected || (connectionState == .ending && !endRequested) else {
            throw UnifiedStreamClientError.invalidState
        }
        endRequested = true
        updateConnectionState(.ending)
        do {
            try await enqueueSend(.string(Self.endMessage), on: task, generation: connectionGeneration)
        } catch UnifiedStreamClientError.sendQueueFull {
            endRequested = false
            throw UnifiedStreamClientError.sendQueueFull
        }
    }

    // MARK: - Transcript and Disconnection

    /// Awaits the server aggregate with a caller-selected timeout.
    func awaitFinal(timeout: TimeInterval) async throws -> UnifiedStreamFinal {
        if let finalResult {
            return finalResult
        }
        guard connectionState != .disconnected else {
            throw UnifiedStreamClientError.notConnected
        }
        if let lastFailure {
            throw lastFailure
        }
        guard connectionState != .closed else {
            throw UnifiedStreamClientError.connectionClosed
        }
        guard timeout.isFinite, timeout >= 0,
              timeout <= Self.maximumTimeoutSeconds else {
            throw UnifiedStreamClientError.invalidTimeout
        }

        let waiterID = UUID()
        let (outcomes, continuation) = AsyncStream<UnifiedStreamFinalWaitOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        finalWaiters[waiterID] = continuation
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)

        do {
            let outcome = try await withThrowingTaskGroup(
                of: UnifiedStreamFinalWaitOutcome.self) { group in
                    group.addTask {
                        for await outcome in outcomes {
                            return outcome
                        }
                        throw UnifiedStreamClientError.connectionClosed
                    }
                    group.addTask {
                        if timeoutNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        }
                        throw UnifiedStreamClientError.timeout
                    }
                    guard let firstOutcome = try await group.next() else {
                        throw UnifiedStreamClientError.connectionClosed
                    }
                    group.cancelAll()
                    return firstOutcome
                }
            finalWaiters.removeValue(forKey: waiterID)?.finish()
            switch outcome {
            case .final(let final):
                return final
            case .failure(let error):
                throw error
            }
        } catch {
            finalWaiters.removeValue(forKey: waiterID)?.finish()
            throw error
        }
    }

    /// Returns live display text and the final or degraded aggregate, when available.
    func transcriptSnapshot() -> UnifiedStreamTranscriptSnapshot {
        transcript.snapshot()
    }

    /// The time of the latest JSON PONG received on this connection.
    func lastPongReceivedAt() -> Date? {
        lastPongDate
    }

    /// Closes this single-use client without asking the server to finalize audio.
    func disconnect() {
        guard connectionState != .closed, connectionState != .failed else { return }
        finishConnection(state: .closed, closeCode: .goingAway)
        resolveFinalWaiters(.failure(.connectionClosed))
    }

    // MARK: - Receive Loop

    private func verifyConnection(
        _ task: URLSessionWebSocketTask,
        generation: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw UnifiedStreamClientError.connectionClosed }
                try await withTaskCancellationHandler {
                    try await task.send(.string(Self.pingMessage))
                    while true {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            let parsed: UnifiedStreamServerMessage
                            do {
                                parsed = try UnifiedStreamMessageParser.parse(text)
                            } catch {
                                throw UnifiedStreamClientError.protocolFailure(String(describing: error))
                            }
                            if case .pong = parsed {
                                await self.receivePong(generation: generation)
                                return
                            }
                            await self.handleServerMessage(parsed, generation: generation)
                        case .data:
                            throw UnifiedStreamClientError.protocolFailure(
                                "The server sent an unexpected binary frame.")
                        @unknown default:
                            continue
                        }
                    }
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw UnifiedStreamClientError.timeout
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask, generation: UInt64) {
        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: task, generation: generation)
        }
    }

    private func receiveMessages(from task: URLSessionWebSocketTask, generation: UInt64) async {
        do {
            while !Task.isCancelled, isCurrent(task, generation: generation) {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    let parsed: UnifiedStreamServerMessage
                    do {
                        parsed = try UnifiedStreamMessageParser.parse(text)
                    } catch {
                        throw UnifiedStreamClientError.protocolFailure(String(describing: error))
                    }
                    handleServerMessage(parsed, generation: generation)
                case .data:
                    throw UnifiedStreamClientError.protocolFailure(
                        "The server sent an unexpected binary frame.")
                @unknown default:
                    continue
                }
            }
        } catch {
            guard isCurrent(task, generation: generation), connectionState != .closed else { return }
            failConnection(Self.clientError(from: error), generation: generation)
        }
    }

    private func handleServerMessage(_ message: UnifiedStreamServerMessage, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        switch message {
        case .interim(let interim):
            transcript.consume(message)
            eventContinuation.yield(.interim(interim))

        case .finalSegment(let segment):
            transcript.consume(message)
            eventContinuation.yield(.finalSegment(segment))

        case .final(let final):
            transcript.consume(message)
            finalResult = final
            eventContinuation.yield(.final(final))
            resolveFinalWaiters(.final(final))
            finishConnection(state: .closed, closeCode: .normalClosure)

        case .pong:
            receivePong(generation: generation)

        case .error(let message):
            failConnection(.serverFailure(message), generation: generation)

        case .cancelled:
            eventContinuation.yield(.cancelled)
            lastFailure = .cancelled
            finishConnection(state: .closed, closeCode: .normalClosure)
            resolveFinalWaiters(.failure(.cancelled))

        case .unknown(let type):
            eventContinuation.yield(.unknownMessage(type))
        }
    }

    private func receivePong(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        lastPongDate = Date()
        clearPendingPong()
        eventContinuation.yield(.pong)
    }

    // MARK: - Liveness

    private func startKeepalive(generation: UInt64) {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.keepaliveIntervalNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                do {
                    try await self.sendPing()
                } catch UnifiedStreamClientError.pingAlreadyPending {
                    continue
                } catch UnifiedStreamClientError.sendQueueFull {
                    continue
                } catch {
                    await self.stopKeepaliveIfCurrent(generation: generation)
                    return
                }
            }
        }
    }

    private func pingTimedOut(_ pingID: UInt64, generation: UInt64) {
        guard generation == connectionGeneration, awaitingPongID == pingID else { return }
        awaitingPongID = nil
        pongTimeoutTask = nil
        failConnection(.deadSocket, generation: generation, deadSocket: true)
    }

    // MARK: - Ordered Sending

    private func enqueueSend(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask,
        generation: UInt64
    ) async throws {
        guard isCurrent(task, generation: generation) else {
            throw UnifiedStreamClientError.connectionClosed
        }
        guard pendingSendCount < Self.maximumPendingSends else {
            throw UnifiedStreamClientError.sendQueueFull
        }

        pendingSendCount += 1
        sendGeneration &+= 1
        let operationID = sendGeneration
        let previousSend = sendTail
        let operation = Task { [weak self] in
            if let previousSend {
                try await previousSend.value
            }
            guard let self else { throw UnifiedStreamClientError.connectionClosed }
            try await self.sendImmediately(message, on: task, generation: generation)
        }
        sendTail = operation

        do {
            try await operation.value
            completeSend(operationID)
        } catch {
            completeSend(operationID)
            throw error
        }
    }

    private func sendImmediately(
        _ message: URLSessionWebSocketTask.Message,
        on task: URLSessionWebSocketTask,
        generation: UInt64
    ) async throws {
        guard isCurrent(task, generation: generation), connectionState != .closed,
              connectionState != .failed else {
            throw UnifiedStreamClientError.connectionClosed
        }
        do {
            try await task.send(message)
        } catch {
            let failure = UnifiedStreamClientError.networkFailure(error.localizedDescription)
            failConnection(failure, generation: generation)
            throw failure
        }
    }

    private func completeSend(_ operationID: UInt64) {
        pendingSendCount -= 1
        if operationID == sendGeneration {
            sendTail = nil
        }
    }

    private func clearPendingPong() {
        awaitingPongID = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil
    }

    private func stopKeepaliveIfCurrent(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        stopKeepalive()
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Teardown

    private func failConnection(
        _ error: UnifiedStreamClientError,
        generation: UInt64,
        deadSocket: Bool = false
    ) {
        guard generation == connectionGeneration, connectionState != .closed,
              connectionState != .failed else { return }
        lastFailure = error
        eventContinuation.yield(.error(error.localizedDescription))
        if deadSocket {
            eventContinuation.yield(.deadSocket)
        }
        finishConnection(state: .failed, closeCode: .goingAway)
        resolveFinalWaiters(.failure(error))
        eventContinuation.finish()
    }

    private func finishConnection(
        state: UnifiedStreamConnectionState,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        updateConnectionState(state)
        stopKeepalive()
        clearPendingPong()
        receiveTask?.cancel()
        receiveTask = nil
        closeTransport(closeCode: closeCode)
        eventContinuation.finish()
    }

    private func closeTransport(closeCode: URLSessionWebSocketTask.CloseCode) {
        connectionGeneration &+= 1
        let task = webSocket
        webSocket = nil
        task?.cancel(with: closeCode, reason: nil)
    }

    private func updateConnectionState(_ newState: UnifiedStreamConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        eventContinuation.yield(.connectionState(newState))
    }

    private func resolveFinalWaiters(_ outcome: UnifiedStreamFinalWaitOutcome) {
        let waiters = Array(finalWaiters.values)
        finalWaiters.removeAll()
        for waiter in waiters {
            waiter.yield(outcome)
            waiter.finish()
        }
    }

    private func isCurrent(_ task: URLSessionWebSocketTask, generation: UInt64) -> Bool {
        connectionGeneration == generation && webSocket === task
    }

    private static func clientError(from error: Error) -> UnifiedStreamClientError {
        if let error = error as? UnifiedStreamClientError {
            return error
        }
        if let error = error as? UnifiedStreamProtocolError {
            return .protocolFailure(String(describing: error))
        }
        return .networkFailure(error.localizedDescription)
    }

    private static func nanoseconds(for seconds: TimeInterval) throws -> UInt64 {
        guard seconds.isFinite, seconds > 0,
              seconds <= maximumTimeoutSeconds else {
            throw UnifiedStreamClientError.invalidTimeout
        }
        return UInt64(seconds * 1_000_000_000)
    }
}
