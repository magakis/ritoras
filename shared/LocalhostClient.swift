import Foundation

// MARK: - Errors

enum LocalhostClient {
    enum LocalhostError: Error {
        case connectionRefused
        case timeout
        case invalidResponse
        case notFound
        case malformedJSON
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

    /// Fetches the current dictation state from `GET /state`.
    /// - Parameter id: Optional dictation UUID. When nil, the request omits
    ///   the query parameter and the server returns whatever state is active.
    /// - Returns: A `DictationStateSnapshot` if the server responds 200,
    ///            or `nil` on 404 (no active state for the given ID).
    /// - Throws: `LocalhostError` on connection errors, timeouts, or
    ///           malformed responses.
    static func getState(id: UUID?) async throws -> DictationStateSnapshot? {
        var components = URLComponents(url: baseURL.appendingPathComponent("state"), resolvingAgainstBaseURL: false)!
        if let id = id {
            components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        }
        guard let url = components.url else {
            throw LocalhostError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await activeSession.data(for: request)
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw LocalhostError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalhostError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(DictationStateSnapshot.self, from: data)
            } catch {
                throw LocalhostError.malformedJSON
            }
        case 404:
            return nil
        default:
            throw LocalhostError.invalidResponse
        }
    }

    /// Fetches the terminal transcription result from `GET /result`.
    /// - Parameter id: The dictation UUID (required).
    /// - Returns: A `DictationResultSnapshot` if the server responds 200.
    /// - Throws: `LocalhostError.notFound` on 404, or other `LocalhostError`
    ///           values on connection / decode failures.
    static func getResult(id: UUID) async throws -> DictationResultSnapshot? {
        var components = URLComponents(url: baseURL.appendingPathComponent("result"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        guard let url = components.url else {
            throw LocalhostError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await activeSession.data(for: request)
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw LocalhostError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalhostError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(DictationResultSnapshot.self, from: data)
            } catch {
                throw LocalhostError.malformedJSON
            }
        case 404:
            throw LocalhostError.notFound
        default:
            throw LocalhostError.invalidResponse
        }
    }

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

    // MARK: - Error Mapping

    private static func mapURLError(_ error: URLError) -> LocalhostError {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return .connectionRefused
        case .timedOut:
            return .timeout
        default:
            return .invalidResponse
        }
    }
}
