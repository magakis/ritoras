import Foundation
import Network

// MARK: - LocalhostServer

/// Lightweight HTTP/1.1 server on a localhost port that exposes health
/// and log-shipping endpoints.
final class LocalhostServer {
    private struct CancelRequest: Decodable {
        let id: UUID
    }

    private let port: UInt16
    private let authorizationToken: String
    private let listenerLock = NSLock()
    private var _listener: NWListener?
    private var listener: NWListener? {
        get { listenerLock.lock(); defer { listenerLock.unlock() }; return _listener }
        set { listenerLock.lock(); defer { listenerLock.unlock() }; _listener = newValue }
    }
    private let queue = DispatchQueue(label: "com.ritoras.localhostserver", qos: .utility)
    private let onStop: (() async -> Void)?
    private let onCancel: ((UUID) async -> Void)?
    private let onState: (() -> DictationPayload?)?

    // Listener health/restart state. All of these are guarded by `listenerLock`
    // and must only be touched while holding it.
    private var _isHealthy = false
    private var intentionalStop = false
    private var restartCount = 0
    private var lastRestartAt: Date = .distantPast
    private static let restartDebounce: TimeInterval = 2.0
    private static let maxRestarts = 5

    /// In-flight connections accepted since the listener started. Guarded by
    /// `listenerLock`. Tracked so `stop()`/`restart()` can cancel them
    /// deterministically; otherwise cancelling the listener orphans them and
    /// the keyboard's URLSession continuation may resume twice (SIGTRAP).
    private var activeConnections: [NWConnection] = []
    private var hasLoggedAuthenticationRejection = false

    /// The port the listener is actually bound to. Equals `port` when a fixed
    /// port was given; differs when port 0 was passed (OS-assigned).
    /// Returns `nil` before the listener reaches `.ready`.
    var actualPort: UInt16? {
        listener?.port?.rawValue
    }

    /// Whether the listener last reported `.ready`. `false` while stopped,
    /// failed, or cancelled. Thread-safe.
    var isHealthy: Bool {
        listenerLock.lock(); defer { listenerLock.unlock() }
        return _isHealthy
    }

    /// Whether a listener object currently exists (started or failed but not
    /// yet reaped). Thread-safe.
    var hasListener: Bool {
        listenerLock.lock(); defer { listenerLock.unlock() }
        return _listener != nil
    }

    private static let maxRequestSize = 65536
    private static let maxActiveConnections = 16
    private static let idleConnectionTimeout: TimeInterval = 30

    init(port: UInt16, onStop: (() async -> Void)? = nil, onCancel: ((UUID) async -> Void)? = nil, onState: (() -> DictationPayload?)? = nil) {
        self.port = port
        self.authorizationToken = SharedConfig.prepareLocalhostAuthorizationToken()
        self.onStop = onStop
        self.onCancel = onCancel
        self.onState = onState
    }

    // MARK: - Lifecycle

    func start() throws {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard _listener == nil else {
            FileLogger.shared.info(.network, "LocalhostServer: already running",
                                   payload: ["port": port])
            return
        }
        try startListenerLocked()
        FileLogger.shared.info(.network, "LocalhostServer: start requested",
                               payload: ["port": port])
    }

    /// Creates and starts a fresh NWListener bound to `port`. Caller MUST hold
    /// `listenerLock`.
    private func startListenerLocked() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback

        let newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        _listener = newListener

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            self?.handleListenerState(state, newListener: newListener)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        newListener.start(queue: queue)
    }

    /// Handles `NWListener` state transitions. Runs on `self.queue`; all state
    /// mutations are serialized by `listenerLock`.
    private func handleListenerState(_ state: NWListener.State, newListener: NWListener?) {
        switch state {
        case .ready:
            listenerLock.lock()
            _isHealthy = true
            restartCount = 0
            listenerLock.unlock()
            let actual = newListener?.port?.rawValue ?? 0   // local capture — no self.listener read
            FileLogger.shared.info(.network, "LocalhostServer: ready",
                                   payload: ["port": actual])
        case .failed(let error):
            listenerLock.lock()
            _isHealthy = false
            if _listener === newListener { _listener = nil }
            listenerLock.unlock()
            FileLogger.shared.warn(.network, "LocalhostServer: listener failed",
                                   payload: ["error": error.localizedDescription])
            scheduleRestart(reason: "failed")
        case .cancelled:
            listenerLock.lock()
            if intentionalStop {
                intentionalStop = false
                listenerLock.unlock()
                FileLogger.shared.debug(.network, "LocalhostServer: listener cancelled (intentional)")
                return
            }
            _isHealthy = false
            if _listener === newListener { _listener = nil }
            listenerLock.unlock()
            FileLogger.shared.warn(.network, "LocalhostServer: listener cancelled unexpectedly")
            scheduleRestart(reason: "cancelled")
        default:
            break
        }
    }

    func stop() {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard let listener = _listener else { return }
        intentionalStop = true
        for conn in activeConnections { conn.cancel() }
        activeConnections.removeAll()
        listener.cancel()
        _listener = nil
        _isHealthy = false
        FileLogger.shared.info(.network, "LocalhostServer: stopped")
    }

    /// Manually replaces the current listener with a fresh one. Safe to call
    /// while running or after failure; resets the auto-restart retry budget.
    func restart() {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        if _listener != nil {
            intentionalStop = true
            for conn in activeConnections { conn.cancel() }
            activeConnections.removeAll()
            _listener?.cancel()
            _listener = nil
            _isHealthy = false
        }
        do {
            try startListenerLocked()
            FileLogger.shared.warn(.network, "LocalhostServer: listener manually restarted")
            restartCount = 0
        } catch {
            FileLogger.shared.error(.network, "LocalhostServer: manual restart failed",
                                    payload: ["error": error.localizedDescription])
        }
    }

    /// Schedules an automatic listener restart after `restartDebounce`, capped
    /// at `maxRestarts` consecutive failures. The retry budget resets on
    /// `.ready` and on manual `restart()`.
    private func scheduleRestart(reason: String) {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard restartCount < Self.maxRestarts else {
            FileLogger.shared.error(.network, "LocalhostServer: gave up restarting listener after \(Self.maxRestarts) attempts")
            return
        }
        let wait = max(0, Self.restartDebounce - Date().timeIntervalSince(lastRestartAt))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self else { return }
            self.listenerLock.lock()
            defer { self.listenerLock.unlock() }
            guard self._listener == nil else { return }
            do {
                try self.startListenerLocked()
                self.restartCount += 1
                self.lastRestartAt = Date()
                FileLogger.shared.warn(.network, "LocalhostServer: restarting listener (attempt \(self.restartCount), reason: \(reason))")
            } catch {
                FileLogger.shared.error(.network, "LocalhostServer: restart failed",
                                        payload: ["error": error.localizedDescription, "reason": reason])
            }
        }
    }

    deinit {
        stop()
    }

    // MARK: - Connection Handling

    private func registerConnection(_ connection: NWConnection) -> Bool {
        listenerLock.lock(); defer { listenerLock.unlock() }
        guard activeConnections.count < Self.maxActiveConnections else { return false }
        activeConnections.append(connection)
        return true
    }

    private func unregisterConnection(_ connection: NWConnection) {
        listenerLock.lock(); defer { listenerLock.unlock() }
        activeConnections.removeAll { $0 === connection }
    }

    private func handleConnection(_ connection: NWConnection) {
        let connectionTag = String(UUID().uuidString.prefix(8))
        let connQueue = DispatchQueue(
            label: "com.ritoras.localhostserver.conn.\(connectionTag)",
            qos: .utility
        )
        guard registerConnection(connection) else {
            connection.cancel()
            FileLogger.shared.debug(.network, "LocalhostServer: connection cap reached")
            return
        }

        connection.start(queue: connQueue)
        FileLogger.shared.debug(.network, "LocalhostServer: connection accepted", payload: ["connection": connectionTag])

        var requestData = Data()
        var isClosed = false
        var authorizationChecked = false
        var idleTimeoutWorkItem: DispatchWorkItem?

        func resetIdleTimeout() {
            idleTimeoutWorkItem?.cancel()
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self, !isClosed else { return }
                isClosed = true
                self.unregisterConnection(connection)
                FileLogger.shared.debug(.network, "LocalhostServer: idle connection timed out",
                                        payload: ["connection": connectionTag])
                connection.cancel()
            }
            idleTimeoutWorkItem = timeoutWorkItem
            connQueue.asyncAfter(
                deadline: .now() + Self.idleConnectionTimeout,
                execute: timeoutWorkItem
            )
        }

        func send(_ response: Data) {
            guard !isClosed else { return }
            isClosed = true
            idleTimeoutWorkItem?.cancel()
            idleTimeoutWorkItem = nil
            self.sendResponse(response, on: connection, connectionTag: connectionTag)
        }

        func readNext() {
            let remaining = Self.maxRequestSize - requestData.count
            guard remaining > 0 else {
                if let response = handleRequest(data: requestData, connectionTag: connectionTag) {
                    send(response)
                }
                return
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }

                if let error = error {
                    guard !isClosed else { return }
                    isClosed = true
                    idleTimeoutWorkItem?.cancel()
                    idleTimeoutWorkItem = nil
                    FileLogger.shared.debug(.network, "LocalhostServer: receive error",
                                           payload: ["error": error.localizedDescription])
                    self.unregisterConnection(connection)
                    FileLogger.shared.debug(.network, "LocalhostServer: connection closed", payload: ["connection": connectionTag])
                    connection.cancel()
                    return
                }

                if let data = data {
                    requestData.append(data)
                    if !data.isEmpty { resetIdleTimeout() }
                }

                if !authorizationChecked, Self.findHeaderEnd(requestData) != nil {
                    authorizationChecked = true
                    if let response = self.handleRequest(
                        data: requestData,
                        connectionTag: connectionTag,
                        authenticateOnly: true
                    ) {
                        send(response)
                        return
                    }
                }

                // Body-completeness check: if headers are done and we have enough
                // body bytes, process the request. Otherwise keep reading.
                if Self.isRequestComplete(requestData) || isComplete || requestData.count >= Self.maxRequestSize {
                    if let response = self.handleRequest(data: requestData, connectionTag: connectionTag) {
                        send(response)
                    }
                } else {
                    readNext()
                }
            }
        }

        resetIdleTimeout()
        readNext()
    }

    private func sendResponse(_ data: Data, on connection: NWConnection, connectionTag: String) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.unregisterConnection(connection)
            FileLogger.shared.debug(.network, "LocalhostServer: connection closed", payload: ["connection": connectionTag])
        })
    }

    // MARK: - Header Detection

    /// Returns the byte offset of the first byte after `\r\n\r\n`, or `nil` if the
    /// header terminator has not yet been fully received.
    private static func findHeaderEnd(_ data: Data) -> Int? {
        data.withUnsafeBytes { buffer -> Int? in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = data.count
            guard count >= 4 else { return nil }
            for i in 0...(count - 4) {
                if base[i] == 0x0D, base[i + 1] == 0x0A,
                   base[i + 2] == 0x0D, base[i + 3] == 0x0A {
                    return i + 4 // position after \r\n\r\n
                }
            }
            return nil
        }
    }

    /// Returns `true` when the HTTP request is fully received: headers complete
    /// AND (no Content-Length OR body fully received).
    private static func isRequestComplete(_ data: Data) -> Bool {
        guard let headerEnd = findHeaderEnd(data) else { return false }
        let bodyLength = parseContentLength(from: data, headerEnd: headerEnd)
        let bodyReceived = data.count - headerEnd
        return bodyReceived >= bodyLength
    }

    /// Parses the `Content-Length` header value from the header section.
    /// Returns 0 if the header is absent or unparseable.
    private static func parseContentLength(from data: Data, headerEnd: Int) -> Int {
        guard headerEnd >= 4 else { return 0 }
        let headerData = data[..<(headerEnd - 4)]
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return 0 }
        let lines = headerStr.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst(15).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    // MARK: - Request Handling

    private func handleRequest(
        data: Data,
        connectionTag: String,
        authenticateOnly: Bool = false
    ) -> Data? {
        // Locate header terminator via findHeaderEnd (works on raw Data)
        guard let headerEndOffset = Self.findHeaderEnd(data) else {
            return Self.makeJSONResponse(status: 400, body: ["error": "Bad Request", "detail": "Missing header terminator"])
        }

        // Decode the header section (without the \r\n\r\n terminator)
        let headerData = data[..<(headerEndOffset - 4)]
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            return Self.makeJSONResponse(status: 400, body: ["error": "Bad Request", "detail": "Non-UTF-8 request"])
        }

        let lines = headerStr.components(separatedBy: "\r\n")

        guard Self.headerValue(named: "Authorization", in: lines) == "Bearer \(authorizationToken)" else {
            logAuthenticationRejection(connectionTag: connectionTag)
            return Self.makeJSONResponse(status: 401, body: ["error": "unauthorized"])
        }
        guard !authenticateOnly else { return nil }

        // Parse request line: METHOD path HTTP/1.1
        guard let requestLine = lines.first else {
            return Self.makeJSONResponse(status: 400, body: ["error": "Bad Request", "detail": "Empty request line"])
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return Self.makeJSONResponse(status: 400, body: ["error": "Bad Request", "detail": "Invalid request line"])
        }

        let method = parts[0].uppercased()
        let rawPath = parts[1]
        FileLogger.shared.debug(.network, "LocalhostServer: served route", payload: ["connection": connectionTag, "route": rawPath])

        if method == "POST" {
            if rawPath == "/logs" {
                return handlePostLogs(bodyData: data[headerEndOffset...])
            } else if rawPath == "/stop" {
                return handlePostStop()
            } else if rawPath == "/cancel" {
                return handlePostCancel(bodyData: data[headerEndOffset...])
            } else {
                return Self.makeJSONResponse(status: 404, body: ["error": "not found", "path": rawPath])
            }
        }

        guard method == "GET" else {
            return Self.makeJSONResponse(status: 405, body: ["error": "Method Not Allowed", "method": method])
        }

        return handleRoute(rawPath)
    }

    private func logAuthenticationRejection(connectionTag: String) {
        listenerLock.lock()
        let isFirstRejection = !hasLoggedAuthenticationRejection
        hasLoggedAuthenticationRejection = true
        listenerLock.unlock()

        if isFirstRejection {
            FileLogger.shared.warn(.network, "LocalhostServer: unauthorized request",
                                   payload: ["connection": connectionTag])
        } else {
            FileLogger.shared.debug(.network, "LocalhostServer: unauthorized request",
                                    payload: ["connection": connectionTag])
        }
    }

    private static func headerValue(named name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() else {
                continue
            }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Routing

    private func handleRoute(_ rawPath: String) -> Data {
        FileLogger.shared.debug(.network, "LocalhostServer: handled request",
                               payload: ["path": rawPath])

        switch rawPath {
        case "/health":
            return Self.makeJSONResponse(status: 200, body: [
                "status": "ok",
                "port": actualPort ?? port
            ])

        case "/state":
            guard let payload = onState?() else {
                return Self.makeJSONResponse(status: 204, body: ["status": "idle"])
            }
            return Self.makeJSONResponse(status: 200, body: payload)

        default:
            return Self.makeJSONResponse(status: 404, body: [
                "error": "not found",
                "path": rawPath
            ])
        }
    }

    // MARK: - POST /logs

    /// Handles `POST /logs`: decodes a JSON array of `LogShipmentEntry` values
    /// and writes each to the container app's `FileLogger` with the original
    /// level, component, and message.
    /// Queues persistence off the connection queue and returns 200 with
    /// `{"received": <count>}`; returns 400 on decode failure.
    private func handlePostLogs(bodyData: Data) -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let wrapper = try decoder.decode([String: [LogShipmentEntry]].self, from: bodyData)
            let entries = wrapper["entries"] ?? []
            var batch: [(LogLevel, LogComponent, String, [String: Any]?)] = []
            for entry in entries {
                let level = LogLevel(rawValue: entry.level) ?? .info
                let component = LogComponent(rawValue: entry.component) ?? .keyboard
                let payload = entry.payload as [String: Any]?
                batch.append((level, component, entry.message, payload))
            }
            if !batch.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    FileLogger.shared.logBatch(batch)
                }
            }
            return Self.makeJSONResponse(status: 200, body: ["received": entries.count])
        } catch {
            return Self.makeJSONResponse(status: 400, body: [
                "error": "Bad Request",
                "detail": "Invalid JSON body"
            ])
        }
    }

    // MARK: - POST /stop and POST /cancel

    /// Handles `POST /stop`: asks the container app to stop the active
    /// dictation session. Fire-and-forget — returns 202 immediately; the
    /// keyboard learns the outcome via the app-group snapshot pipeline.
    private func handlePostStop() -> Data {
        FileLogger.shared.info(.network, "POST /stop received", payload: ["id": onState?().map { String($0.id.uuidString.prefix(8)) } ?? "nil", "hasHandler": onStop != nil])
        guard let handler = onStop else {
            return Self.makeJSONResponse(status: 503, body: ["error": "no handler"])
        }
        Task { await handler() }
        return Self.makeJSONResponse(status: 202, body: ["status": "stopRequested"])
    }

    /// Handles `POST /cancel`: resolves the command to one session before
    /// scheduling teardown. Empty or malformed bodies retain compatibility with
    /// older keyboards by targeting the current active session.
    private func handlePostCancel(bodyData: Data) -> Data {
        guard let handler = onCancel else {
            return Self.makeJSONResponse(status: 503, body: ["error": "no handler"])
        }

        let requestedID = (try? JSONDecoder().decode(CancelRequest.self, from: bodyData))?.id
        let recordID = SharedConfig.pendingDictationCancel()?.id
        let currentPayload = onState?()
        let activeSessionID = currentPayload.flatMap { payload -> UUID? in
            switch payload.status {
            case .recording, .transcribing:
                return payload.id
            case .completed, .error, .cancelled:
                return nil
            }
        }

        let requestedIDMatchesActive = requestedID != nil && requestedID == activeSessionID
        if requestedIDMatchesActive {
            if let recordID, recordID != requestedID {
                SharedConfig.clearPendingDictationCancel(matching: recordID)
            }
        } else if let requestedID, let recordID, requestedID != recordID {
            return cancelMismatchResponse(requestedID: requestedID,
                                         recordID: recordID,
                                         activeID: activeSessionID)
        }

        let targetID = requestedIDMatchesActive ? requestedID : recordID ?? requestedID ?? activeSessionID
        if let targetID, let activeSessionID, targetID != activeSessionID {
            return cancelMismatchResponse(requestedID: requestedID,
                                         recordID: recordID,
                                         activeID: activeSessionID)
        }
        guard let targetID else {
            return Self.makeJSONResponse(status: 409, body: ["error": "no active session"])
        }

        FileLogger.shared.info(.network, "POST /cancel received", payload: [
            "id": String(targetID.uuidString.prefix(8)),
            "durable": recordID != nil
        ])
        Task { await handler(targetID) }
        return Self.makeJSONResponse(status: 202, body: ["status": "cancelRequested"])
    }

    private func cancelMismatchResponse(
        requestedID: UUID?,
        recordID: UUID?,
        activeID: UUID?
    ) -> Data {
        FileLogger.shared.warn(.network, "POST /cancel session mismatch", payload: [
            "request": requestedID.map { String($0.uuidString.prefix(8)) } ?? "nil",
            "record": recordID.map { String($0.uuidString.prefix(8)) } ?? "nil",
            "active": activeID.map { String($0.uuidString.prefix(8)) } ?? "nil"
        ])
        return Self.makeJSONResponse(status: 409, body: ["error": "cancel session mismatch"])
    }

    // MARK: - Response Helpers

    private static func makeJSONResponse<T: Encodable>(status: Int, body: T) -> Data {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(body)
        } catch {
            bodyData = Data("{\"error\":\"internal serialization error\"}".utf8)
        }
        return formatHTTP(status: status, contentType: "application/json", body: bodyData)
    }

    private static func makeJSONResponse(status: Int, body: [String: Any]) -> Data {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return Data("{\"error\":\"internal serialization error\"}".utf8)
        }
        return formatHTTP(status: status, contentType: "application/json", body: bodyData)
    }

    private static func formatHTTP(status: Int, contentType: String, body: Data) -> Data {
        let statusLine: String
        switch status {
        case 200: statusLine = "HTTP/1.1 200 OK"
        case 202: statusLine = "HTTP/1.1 202 Accepted"
        case 204: statusLine = "HTTP/1.1 204 No Content"
        case 400: statusLine = "HTTP/1.1 400 Bad Request"
        case 404: statusLine = "HTTP/1.1 404 Not Found"
        case 405: statusLine = "HTTP/1.1 405 Method Not Allowed"
        case 401: statusLine = "HTTP/1.1 401 Unauthorized"
        case 503: statusLine = "HTTP/1.1 503 Service Unavailable"
        default:  statusLine = "HTTP/1.1 \(status)"
        }

        var response = "\(statusLine)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        if status != 204 {
            response += "Content-Length: \(body.count)\r\n"
        }
        response += "Connection: close\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        if status != 204 {
            data.append(body)
        }
        return data
    }

}
