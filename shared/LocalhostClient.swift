import Foundation

/// Outcome of a localhost `GET /state` probe, distinguishing the cases the
/// keyboard needs to detect a lost dictation session:
/// - `.payload(decoded)` — HTTP 200 with a decodable snapshot
/// - `.noSession` — HTTP 204, the container app affirms no active session
/// - `.malformed` — HTTP 200 whose body failed to decode: the app is alive and
///   affirming it has a payload, so this must NOT count as unreachable/miss
///   evidence
/// - `.unreachable` — any other status or transport error
enum LocalhostStateProbe {
    case payload(DictationPayload)
    case noSession
    case malformed
    case unreachable
}

struct LocalhostLogExportEstimate: Decodable, Sendable {
    let sinceNs: Int64
    let untilNs: Int64
    let count: Int
    let estimatedBytes: Int64
}

struct LocalhostLogExportResponse: Decodable, Sendable {
    let sinceNs: Int64
    let untilNs: Int64
    let count: Int
    let entries: [LocalhostLogExportEntry]
}

struct LocalhostLogExportEntry: Decodable, Sendable {
    let id: Int64
    let raw: String
    let timestamp: String?
    let level: String?
    let component: String?
    let message: String?
    let payload: [String: LocalhostLogExportValue]?
}

indirect enum LocalhostLogExportValue: Decodable, Sendable {
    case object([String: LocalhostLogExportValue])
    case array([LocalhostLogExportValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: LocalhostLogExportValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(
                    LocalhostLogExportValue.self,
                    forKey: key
                )
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [LocalhostLogExportValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(LocalhostLogExportValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if try container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .number(String(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(String(value))
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var readableText: String {
        switch self {
        case .object(let values):
            let fields = values.keys.sorted().compactMap { key in
                values[key].map { "\(key): \($0.readableText)" }
            }
            return "{\(fields.joined(separator: ", "))}"
        case .array(let values):
            return "[\(values.map(\.readableText).joined(separator: ", "))]"
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum LocalhostLogExportError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Couldn't construct the localhost log export URL."
        case .invalidResponse:
            return "The localhost log server returned an invalid response."
        case .httpStatus(let status):
            return "The localhost log server returned HTTP \(status)."
        case .decoding(let reason):
            return "Couldn't decode the localhost log export response: \(reason)"
        }
    }
}

enum LocalhostClient {
    private struct CancelRequest: Encodable {
        let id: UUID
    }

    // MARK: - Session

    /// Low-latency URLSession tuned for localhost IPC from a keyboard extension.
    /// - `waitsForConnectivity = false`: fail fast — the server is localhost,
    ///   so waiting for connectivity gains nothing.
    /// - `timeoutIntervalForRequest = 1.0`: the localhost server responds in
    ///   microseconds; 1s is generous for overloaded devices.
    /// - `timeoutIntervalForResource = 2.0`: overall budget for retry chains.
    /// - `httpShouldUsePipelining = false`: localhost is a single-connection
    ///   server that sends `Connection: close`; pipelining adds complexity for
    ///   no benefit.
    /// - `requestCachePolicy = .reloadIgnoringLocalCacheData`: state snapshots
    ///   are ephemeral; never serve stale.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 2.0
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Export responses can contain several megabytes, so they use a longer
    /// resource timeout than the low-latency keyboard IPC session.
    private static let logExportSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 300.0
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Override for unit tests (URLProtocol mock injection).
    /// When non-nil, all requests use this session instead of the default.
    static var _testSession: URLSession?

    private static var activeSession: URLSession {
        _testSession ?? session
    }

    private static func authorizedRequest(from request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(
            "Bearer \(SharedConfig.localhostAuthorizationToken())",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private static func authorizedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await authorizedData(for: request, using: activeSession)
    }

    private static func authorizedData(for request: URLRequest,
                                       using session: URLSession) async throws -> (Data, URLResponse) {
        let firstResponse = try await session.data(for: authorizedRequest(from: request))
        guard (firstResponse.1 as? HTTPURLResponse)?.statusCode == 401 else {
            return firstResponse
        }

        // The app may have relaunched with a fresh per-launch token since the
        // keyboard last resolved the app-group value.
        return try await session.data(for: authorizedRequest(from: request))
    }

    // MARK: - Port

    private static var baseURL: URL {
        URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)")!
    }

    // MARK: - Public API

    /// Checks whether the localhost server is reachable and responding.
    /// Returns `true` on HTTP 200 from `/health`, `false` on any error.
    static func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await authorizedData(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    /// Probes the container app's current dictation snapshot via the localhost
    /// `GET /state` fallback transport — used when the app-group container is
    /// nil (SideStore) and the file/UserDefaults snapshot paths are unavailable.
    /// Distinguishes the outcomes the keyboard needs to detect a lost session:
    /// HTTP 200 → `.payload(decoded)`, or `.malformed` if the body fails to
    /// decode (the app is alive but affirming a payload); HTTP 204 →
    /// `.noSession` (idle, no active session); any other status or thrown
    /// transport error → `.unreachable`. Date decoding uses the default
    /// strategy, symmetric with the server's plain `JSONEncoder` and the
    /// existing snapshot file path in `SharedConfig`.
    static func probeState() async -> LocalhostStateProbe {
        let url = URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)/state")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await authorizedData(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .unreachable }
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                do {
                    return .payload(try decoder.decode(DictationPayload.self, from: data))
                } catch {
                    // App is alive but its payload failed to decode — quiet by
                    // design: not a transport error, and never miss evidence.
                    return .malformed
                }
            case 204:
                return .noSession
            default:
                return .unreachable
            }
        } catch {
            FileLogger.shared.debug(.network, "GET /state transport error", payload: ["error": error.localizedDescription])
            return .unreachable
        }
    }

    /// Counts log entries in an inclusive timestamp range without fetching
    /// their contents.
    static func countLogExport(sinceNs: Int64,
                               untilNs: Int64) async throws -> LocalhostLogExportEstimate {
        let data = try await fetchLogExportData(
            sinceNs: sinceNs,
            untilNs: untilNs,
            countOnly: true
        )
        do {
            return try JSONDecoder().decode(LocalhostLogExportEstimate.self, from: data)
        } catch {
            throw LocalhostLogExportError.decoding(error.localizedDescription)
        }
    }

    /// Fetches every log entry in an inclusive timestamp range in one request.
    static func exportLogs(sinceNs: Int64,
                           untilNs: Int64) async throws -> LocalhostLogExportResponse {
        let data = try await fetchLogExportData(
            sinceNs: sinceNs,
            untilNs: untilNs,
            countOnly: false
        )
        do {
            return try JSONDecoder().decode(LocalhostLogExportResponse.self, from: data)
        } catch {
            throw LocalhostLogExportError.decoding(error.localizedDescription)
        }
    }

    private static func fetchLogExportData(sinceNs: Int64,
                                           untilNs: Int64,
                                           countOnly: Bool) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(SharedConfig.Defaults.localhostServerPort)
        components.path = "/logs/export"
        var queryItems = [
            URLQueryItem(name: "sinceNs", value: String(sinceNs)),
            URLQueryItem(name: "untilNs", value: String(untilNs))
        ]
        if countOnly {
            queryItems.append(URLQueryItem(name: "countOnly", value: "1"))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw LocalhostLogExportError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let session = _testSession ?? logExportSession
        let (data, response) = try await authorizedData(for: request, using: session)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalhostLogExportError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LocalhostLogExportError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    /// Ships an array of log entries to the localhost server's `POST /logs`
    /// endpoint. Fire-and-forget: errors are swallowed (connection refused,
    /// timeout, malformed response — all silently dropped). Log shipping is
    /// best-effort and never blocks the caller.
    static func postLogs(_ entries: [LogShipmentEntry]) async {
        guard !entries.isEmpty else { return }
        let url = URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)/logs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(["entries": entries])
            request.httpBody = body
            _ = try await authorizedData(for: request)
        } catch {
            // Swallow — log shipping is best-effort
        }
    }

    /// Requests the container app to stop the active dictation session via
    /// `POST /stop`. Returns `true` on any 2xx response, `false` on a
    /// non-2xx response or any transport error (server dead, timeout).
    /// Unlike `postLogs`, errors are NOT swallowed — the keyboard caller
    /// needs to know the server is unreachable so it can fall back to a
    /// local reset.
    static func postStop() async -> Bool {
        await postCommand("/stop")
    }

    /// Requests cancellation of the specified dictation session via
    /// `POST /cancel`. Returns `true` on any 2xx response, `false` on a
    /// non-2xx response or any transport error.
    static func postCancel(sessionID: UUID) async -> Bool {
        do {
            let body = try JSONEncoder().encode(CancelRequest(id: sessionID))
            return await postCommand("/cancel", body: body)
        } catch {
            FileLogger.shared.error(.network, "POST /cancel body encoding failed")
            return false
        }
    }

    /// Sends a POST command to the localhost server and reports whether the
    /// server accepted it. Uses the same low-latency ephemeral session as
    /// `postLogs`.
    private static func postCommand(_ path: String, body: Data? = nil) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)")!
            .appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (_, response) = try await authorizedData(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            let success = httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
            if !success {
                FileLogger.shared.warn(.network, "POST\(path) non-2xx", payload: ["status": httpResponse.statusCode])
            }
            return success
        } catch {
            FileLogger.shared.warn(.network, "POST\(path) transport error", payload: ["error": error.localizedDescription])
            return false
        }
    }

}
