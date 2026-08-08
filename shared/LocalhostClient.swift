import Foundation

enum LocalhostClient {
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

    /// Override for unit tests (URLProtocol mock injection).
    /// When non-nil, all requests use this session instead of the default.
    static var _testSession: URLSession?

    private static var activeSession: URLSession {
        _testSession ?? session
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
            let (_, response) = try await activeSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    /// Fetches the container app's current dictation snapshot via the localhost
    /// `GET /state` fallback transport — used when the app-group container is
    /// nil (SideStore) and the file/UserDefaults snapshot paths are unavailable.
    /// Returns the snapshot payload on HTTP 200, `nil` on 204 (idle, no active
    /// session) or any transport error. Date decoding uses the default strategy,
    /// symmetric with the server's plain `JSONEncoder` and the existing snapshot
    /// file path in `SharedConfig`.
    static func getState() async -> DictationPayload? {
        let url = URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)/state")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await activeSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }  // 204 = idle, not an error
            let decoder = JSONDecoder()
            return try decoder.decode(DictationPayload.self, from: data)
        } catch {
            FileLogger.shared.debug(.network, "GET /state transport error", payload: ["error": error.localizedDescription])
            return nil
        }
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
            _ = try await activeSession.data(for: request)
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

    /// Requests the container app to cancel the active dictation session via
    /// `POST /cancel`. Returns `true` on any 2xx response, `false` on a
    /// non-2xx response or any transport error (server dead, timeout).
    /// Unlike `postLogs`, errors are NOT swallowed — the keyboard caller
    /// needs to know the server is unreachable so it can fall back to a
    /// local reset.
    static func postCancel() async -> Bool {
        await postCommand("/cancel")
    }

    /// Sends an empty-body POST command to the localhost server and reports
    /// whether the server accepted it. Uses the same low-latency ephemeral
    /// session as `postLogs`.
    private static func postCommand(_ path: String) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(SharedConfig.Defaults.localhostServerPort)")!
            .appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await activeSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            let success = httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
            if !success {
                // DIAGNOSTIC LOGGING — TEMPORARY (Bug 2)
                FileLogger.shared.warn(.network, "POST\(path) non-2xx", payload: ["status": httpResponse.statusCode])
            }
            return success
        } catch {
            // DIAGNOSTIC LOGGING — TEMPORARY (Bug 2)
            FileLogger.shared.warn(.network, "POST\(path) transport error", payload: ["error": error.localizedDescription])
            return false
        }
    }

}
