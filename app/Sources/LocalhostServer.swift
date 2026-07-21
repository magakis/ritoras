import Foundation
import Network

// MARK: - LocalhostServer

/// Lightweight HTTP/1.1 server on a localhost port that exposes dictation
/// state and result endpoints.
///
/// ## Thread safety
/// `NWConnection.receive` callbacks fire on a `DispatchQueue`. The
/// `stateProvider` and `resultProvider` closures are invoked from those
/// background queues. To avoid `@MainActor` crashes, `DictationViewModel`
/// captures its state into a lock-guarded snapshot before calling
/// `startLocalhostServer()`. The providers read that snapshot — they never
/// touch the live `@Published` properties.
final class LocalhostServer {
    private let port: UInt16
    private let stateProvider: () -> DictationStateSnapshot
    private let resultProvider: @Sendable (UUID) -> DictationResultSnapshot?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.ritoras.localhostserver", qos: .utility)

    /// The port the listener is actually bound to. Equals `port` when a fixed
    /// port was given; differs when port 0 was passed (OS-assigned).
    /// Returns `nil` before the listener reaches `.ready`.
    var actualPort: UInt16? {
        listener?.port?.rawValue
    }

    private static let maxRequestSize = 65536

    init(port: UInt16,
         stateProvider: @escaping () -> DictationStateSnapshot,
         resultProvider: @escaping @Sendable (UUID) -> DictationResultSnapshot?) {
        self.port = port
        self.stateProvider = stateProvider
        self.resultProvider = resultProvider
    }

    // MARK: - Lifecycle

    func start() throws {
        guard listener == nil else {
            FileLogger.shared.info(.network, "LocalhostServer: already running",
                                   payload: ["port": port])
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback

        listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let actual = self?.listener?.port?.rawValue ?? 0
                FileLogger.shared.info(.network, "LocalhostServer: ready",
                                       payload: ["port": actual])
            case .failed(let error):
                FileLogger.shared.error(.network, "LocalhostServer: listener failed",
                                        payload: ["error": error.localizedDescription])
            case .cancelled:
                FileLogger.shared.info(.network, "LocalhostServer: cancelled")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
        FileLogger.shared.info(.network, "LocalhostServer: start requested",
                               payload: ["port": port])
    }

    func stop() {
        guard let listener = listener else { return }
        listener.cancel()
        self.listener = nil
        FileLogger.shared.info(.network, "LocalhostServer: stopped")
    }

    deinit {
        stop()
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let connQueue = DispatchQueue(
            label: "com.ritoras.localhostserver.conn.\(UUID().uuidString.prefix(8))",
            qos: .utility
        )
        connection.start(queue: connQueue)

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
                    FileLogger.shared.warn(.network, "LocalhostServer: receive error",
                                           payload: ["error": error.localizedDescription])
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
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Header Detection

    /// Returns the byte offset of the first byte after `\r\n\r\n`, or `nil` if the
    /// header terminator has not yet been fully received.
    private static func findHeaderEnd(_ data: Data) -> Int? {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return nil }
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
            guard rawPath == "/logs" else {
                return Self.makeJSONResponse(status: 404, body: ["error": "not found", "path": rawPath])
            }
            return handlePostLogs(bodyData: data[headerEndOffset...])
        }

        guard method == "GET" else {
            return Self.makeJSONResponse(status: 405, body: ["error": "Method Not Allowed", "method": method])
        }

        return handleRoute(rawPath)
    }

    // MARK: - Routing

    private func handleRoute(_ rawPath: String) -> Data {
        let (pathComponent, queryItems) = Self.parsePath(rawPath)

        switch pathComponent {
        case "/health":
            return Self.makeJSONResponse(status: 200, body: [
                "status": "ok",
                "port": actualPort ?? port
            ])

        case "/state":
            let snapshot = stateProvider()

            if let idStr = queryItems?.first(where: { $0.name == "id" })?.value,
               let requestedID = UUID(uuidString: idStr) {
                guard let activeIDStr = snapshot.activeID,
                      let activeID = UUID(uuidString: activeIDStr),
                      activeID == requestedID else {
                    return Self.makeJSONResponse(status: 404, body: [
                        "error": "not found",
                        "detail": "No active dictation with the specified ID"
                    ])
                }
            }

            if snapshot.phase == "idle" {
                return Self.makeJSONResponse(status: 404, body: [
                    "error": "not found",
                    "detail": "No active dictation"
                ])
            }

            return Self.makeJSONResponse(status: 200, body: snapshot)

        case "/result":
            guard let idStr = queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: idStr) else {
                return Self.makeJSONResponse(status: 400, body: [
                    "error": "bad request",
                    "detail": "Missing or invalid 'id' query parameter"
                ])
            }

            guard let result = resultProvider(id) else {
                return Self.makeJSONResponse(status: 404, body: [
                    "error": "not found",
                    "detail": "No result for the specified ID"
                ])
            }

            return Self.makeJSONResponse(status: 200, body: result)

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
            for entry in entries {
                let level = LogLevel(rawValue: entry.level) ?? .info
                let component = LogComponent(rawValue: entry.component) ?? .keyboard
                let payload = entry.payload as [String: Any]?
                FileLogger.shared.log(level, component, entry.message, payload: payload)
            }
            return Self.makeJSONResponse(status: 200, body: ["received": entries.count])
        } catch {
            return Self.makeJSONResponse(status: 400, body: [
                "error": "Bad Request",
                "detail": "Invalid JSON body"
            ])
        }
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
        case 400: statusLine = "HTTP/1.1 400 Bad Request"
        case 404: statusLine = "HTTP/1.1 404 Not Found"
        case 405: statusLine = "HTTP/1.1 405 Method Not Allowed"
        default:  statusLine = "HTTP/1.1 \(status)"
        }

        var response = "\(statusLine)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
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
