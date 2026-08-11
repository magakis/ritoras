import Foundation
import Network

// MARK: - LocalhostServer

/// Lightweight HTTP/1.1 server on a localhost port that exposes health
/// and log-shipping endpoints.
final class LocalhostServer {
    private let port: UInt16
    private let listenerLock = NSLock()
    private var _listener: NWListener?
    private var listener: NWListener? {
        get { listenerLock.lock(); defer { listenerLock.unlock() }; return _listener }
        set { listenerLock.lock(); defer { listenerLock.unlock() }; _listener = newValue }
    }
    private let queue = DispatchQueue(label: "com.ritoras.localhostserver", qos: .utility)
    private let onStop: (() async -> Void)?
    private let onCancel: (() async -> Void)?
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

    init(port: UInt16, onStop: (() async -> Void)? = nil, onCancel: (() async -> Void)? = nil, onState: (() -> DictationPayload?)? = nil) {
        self.port = port
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

    private func registerConnection(_ connection: NWConnection) {
        listenerLock.lock(); defer { listenerLock.unlock() }
        activeConnections.append(connection)
    }

    private func unregisterConnection(_ connection: NWConnection) {
        listenerLock.lock(); defer { listenerLock.unlock() }
        activeConnections.removeAll { $0 === connection }
    }

    private func handleConnection(_ connection: NWConnection) {
        let connQueue = DispatchQueue(
            label: "com.ritoras.localhostserver.conn.\(UUID().uuidString.prefix(8))",
            qos: .utility
        )
        connection.start(queue: connQueue)

        registerConnection(connection)

        var requestData = Data()

        func readNext() {
            let remaining = Self.maxRequestSize - requestData.count
            guard remaining > 0 else {
                let response = handleRequest(data: requestData)
                sendResponse(response, on: connection)
                return
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }

                if let error = error {
                    FileLogger.shared.debug(.network, "LocalhostServer: receive error",
                                           payload: ["error": error.localizedDescription])
                    self.unregisterConnection(connection)
                    connection.cancel()
                    return
                }

                if let data = data {
                    requestData.append(data)
                }

                // Body-completeness check: if headers are done and we have enough
                // body bytes, process the request. Otherwise keep reading.
                if Self.isRequestComplete(requestData) || isComplete || requestData.count >= Self.maxRequestSize {
                    let response = self.handleRequest(data: requestData)
                    self.sendResponse(response, on: connection)
                } else {
                    readNext()
                }
            }
        }

        readNext()
    }

    private func sendResponse(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.unregisterConnection(connection)
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

    private func handleRequest(data: Data) -> Data {
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

        if method == "POST" {
            if rawPath == "/logs" {
                return handlePostLogs(bodyData: data[headerEndOffset...])
            } else if rawPath == "/stop" {
                return handlePostStop()
            } else if rawPath == "/cancel" {
                return handlePostCancel()
            } else {
                return Self.makeJSONResponse(status: 404, body: ["error": "not found", "path": rawPath])
            }
        }

        guard method == "GET" else {
            return Self.makeJSONResponse(status: 405, body: ["error": "Method Not Allowed", "method": method])
        }

        return handleRoute(rawPath)
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
    /// Returns 200 with `{"received": <count>}` on success, 400 on decode failure.
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
                FileLogger.shared.logBatch(batch)
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
        FileLogger.shared.info(.network, "POST /stop received", payload: ["hasHandler": onStop != nil])
        guard let handler = onStop else {
            return Self.makeJSONResponse(status: 503, body: ["error": "no handler"])
        }
        Task { await handler() }
        return Self.makeJSONResponse(status: 202, body: ["status": "stopRequested"])
    }

    /// Handles `POST /cancel`: asks the container app to cancel the active
    /// dictation session. Fire-and-forget — returns 202 immediately; the
    /// keyboard learns the outcome via the app-group snapshot pipeline.
    private func handlePostCancel() -> Data {
        FileLogger.shared.info(.network, "POST /cancel received", payload: ["hasHandler": onCancel != nil])
        guard let handler = onCancel else {
            return Self.makeJSONResponse(status: 503, body: ["error": "no handler"])
        }
        Task { await handler() }
        return Self.makeJSONResponse(status: 202, body: ["status": "cancelRequested"])
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

    // MARK: - URL Parsing

    private struct URLQueryItem {
        let name: String
        let value: String?
    }

    /// Splits a request path into the base path and parsed query parameters.
    private static func parsePath(_ path: String) -> (path: String, query: [URLQueryItem]?) {
        guard let questionIdx = path.firstIndex(of: "?") else {
            return (path, nil)
        }
        let basePath = String(path[..<questionIdx])
        let queryStr = String(path[path.index(after: questionIdx)...])

        let items = queryStr.split(separator: "&").compactMap { pair -> URLQueryItem? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            let name = String(parts[0])
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : nil
            return URLQueryItem(name: name, value: value)
        }
        return (basePath, items.isEmpty ? nil : items)
    }
}
