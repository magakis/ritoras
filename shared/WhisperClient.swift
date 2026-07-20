import Foundation

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case invalidURL
    case noResponse
    case httpError(Int, String)
    case decodingError(String)
    case timeout
    case networkError(Error)
    case allServersFailed([String])

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL. Check your server address in Settings."
        case .noResponse:
            return "No response received from the server."
        case .httpError(let code, let body):
            return "Server returned HTTP \(code): \(body)"
        case .decodingError(let detail):
            return "Failed to decode server response: \(detail)"
        case .timeout:
            return "Server unreachable. Check your connection and server address."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .allServersFailed(let servers):
            return "All \(servers.count) server(s) failed: \(servers.joined(separator: ", "))"
        }
    }
}

// MARK: - Response Model

struct WhisperResponse: Decodable {
    let success: Bool
    let transcription: String
}

// MARK: - Client

enum WhisperClient {

    /// Low-latency URLSession tuned for foreground app-extension HTTP.
    /// - `waitsForConnectivity = false`: fail fast so multi-server failover kicks in
    ///   instead of waiting indefinitely for connectivity.
    /// - `timeoutIntervalForResource = 60`: cap total request time (default is 7 days,
    ///   which is wildly inappropriate for a foreground dictation request).
    /// - `httpShouldUsePipelining = true`: removes a round-trip per request on HTTP/1.1.
    /// - `requestCachePolicy = .reloadIgnoringLocalCacheData`: dictation POSTs are not
    ///   cacheable; bypass cache lookup.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = SharedConfig.Defaults.timeoutSeconds
        config.timeoutIntervalForResource = SharedConfig.Defaults.timeoutSeconds * 2
        config.httpShouldUsePipelining = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Transcribes the audio file at `audioURL` by iterating configured servers
    /// in order and returning the first successful result.
    ///
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a).
    ///   - config:        Server configuration from `SharedConfig`.
    ///   - correlationId: Optional UUID to correlate this request across processes.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` if all servers fail.
    static func transcribe(
        audioURL: URL,
        config: SharedConfig,
        correlationId: UUID? = nil
    ) async throws -> String {
        var failedServers: [String] = []
        let t0 = Date()

        // Generate boundary ONCE and build multipart body ONCE — read the audio
        // file a single time regardless of server count.
        let boundary = "Boundary-\(UUID().uuidString)"
        let body: Data
        do {
            let bodyBuildT0 = Date()
            body = try buildBody(audioURL: audioURL, boundary: boundary)
            FileLogger.shared.debug(.transcription, "multipart body build", payload: [
                "elapsed_ms": Date().timeIntervalSince(bodyBuildT0) * 1000,
                "bodyBytes": body.count
            ])
        } catch {
            throw WhisperError.networkError(error)
        }

        for (serverIndex, server) in config.servers.enumerated() {
            let attemptElapsed = Date().timeIntervalSince(t0) * 1000
            var attemptPayload: [String: Any] = [
                "server_index": serverIndex,
                "server": server,
                "attempt_elapsed_ms": attemptElapsed
            ]
            if let id = correlationId { attemptPayload["id"] = id.uuidString }
            FileLogger.shared.debug(.transcription, "transcribe attempt", payload: attemptPayload)

            do {
                let text = try await transcribeAgainst(
                    serverURL: server,
                    body: body,
                    boundary: boundary,
                    timeout: config.timeoutSeconds,
                    correlationId: correlationId
                )
                return text
            } catch {
                failedServers.append(server)
                continue
            }
        }

        throw WhisperError.allServersFailed(failedServers)
    }

    /// Transcribes against a single, pre-selected server. Used when a health
    /// probe has already identified the target server, avoiding the per-server
    /// 30s timeout in the iterating transcribe. If this throws, callers should
    /// fall back to the iterating transcribe(audioURL:config:) for safety.
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a).
    ///   - serverURL:     The target server base URL.
    ///   - correlationId: Optional UUID to correlate this request across processes.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` if the single server attempt fails.
    static func transcribe(
        audioURL: URL,
        serverURL: String,
        correlationId: UUID? = nil
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body: Data
        do {
            let bodyBuildT0 = Date()
            body = try buildBody(audioURL: audioURL, boundary: boundary)
            FileLogger.shared.debug(.transcription, "multipart body build", payload: [
                "elapsed_ms": Date().timeIntervalSince(bodyBuildT0) * 1000,
                "bodyBytes": body.count
            ])
        } catch {
            throw WhisperError.networkError(error)
        }

        return try await transcribeAgainst(
            serverURL: serverURL,
            body: body,
            boundary: boundary,
            timeout: SharedConfig.Defaults.timeoutSeconds,
            correlationId: correlationId
        )
    }

    /// Pings a server to check if it is reachable.
    /// - Parameters:
    ///   - serverURL: Base URL of the Whisper server.
    ///   - timeout:   Request timeout in seconds (default 5).
    /// - Returns: `true` if the server responds with HTTP 200 on `/health`,
    ///            or any sub-500 status on the root endpoint as fallback.
    static func checkHealth(serverURL: String, timeout: TimeInterval = 5) async -> Bool {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Try /health first
        if let url = URL(string: "\(base)/health") {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout

            if let (_, response) = try? await Self.session.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200
            {
                return true
            }
        }

        // Fallback: try root, accept < 500
        if let url = URL(string: "\(base)/") {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout

            if let (_, response) = try? await Self.session.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode < 500
            {
                return true
            }
        }

        return false
    }

    /// Probes all servers in parallel and returns the highest-priority healthy one.
    /// - Parameters:
    ///   - servers: Candidate server URLs in priority order.
    ///   - timeout: Per-server probe timeout (default from SharedConfig.Defaults).
    /// - Returns: The first server (by input order) that responded healthy, or nil if none did.
    static func selectFirstHealthyServer(
        servers: [String],
        timeout: TimeInterval = SharedConfig.Defaults.serverProbeTimeoutSeconds
    ) async -> String? {
        let candidates = servers
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let healthy: [String] = await withTaskGroup(of: String?.self) { group in
            for server in candidates {
                group.addTask {
                    let ok = await Self.checkHealth(serverURL: server, timeout: timeout)
                    return ok ? server : nil
                }
            }
            var results: [String] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }
        let selected = candidates.first { healthy.contains($0) }
        FileLogger.shared.info(.network, "server selection", payload: [
            "selected": selected ?? "none",
            "candidates": candidates,
            "healthy": healthy
        ])
        return selected
    }

    // MARK: - Private Helpers

    /// Builds the multipart/form-data body for a transcription request.
    /// Reads the audio file from disk exactly once.
    private static func buildBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        // File part
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")

        // Close boundary
        append("--\(boundary)--\r\n")

        return body
    }

    /// Builds a multipart/form-data URLRequest targeting a single server.
    /// The body must be pre-built via `buildBody(audioURL:boundary:)`. The same
    /// boundary string that was passed to `buildBody` must be passed here so the
    /// `Content-Type` header matches the body's boundary markers.
    private static func buildRequest(
        baseURL: String,
        body: Data,
        boundary: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/transcribe") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        return request
    }

    /// Attempts transcription against a single server. Both the iterating
    /// `transcribe(audioURL:config:)` and the single-server overload delegate
    /// here so the request-build and response-decode logic lives in one place.
    /// - Parameters:
    ///   - serverURL:     Target server base URL (trimmed internally).
    ///   - body:          Pre-built multipart form body.
    ///   - boundary:      Boundary string matching the body.
    ///   - timeout:       Per-request timeout.
    ///   - correlationId: Optional UUID for cross-process correlation.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` on any failure.
    private static func transcribeAgainst(
        serverURL: String,
        body: Data,
        boundary: String,
        timeout: TimeInterval,
        correlationId: UUID?
    ) async throws -> String {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw WhisperError.invalidURL }

        let request = try buildRequest(
            baseURL: base,
            body: body,
            boundary: boundary,
            timeout: timeout
        )

        let bodyBytes = request.httpBody?.count ?? 0
        var postPayload: [String: Any] = [
            "bodyBytes": bodyBytes
        ]
        if let id = correlationId { postPayload["id"] = id.uuidString }
        FileLogger.shared.debug(.transcription, "HTTP POST /transcribe start", payload: postPayload)

        let httpT0 = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WhisperError.timeout
        } catch {
            throw WhisperError.networkError(error)
        }

        let httpElapsed = Date().timeIntervalSince(httpT0) * 1000

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.noResponse
        }

        var respPayload: [String: Any] = [
            "statusCode": httpResponse.statusCode,
            "elapsed_ms": httpElapsed
        ]
        if let id = correlationId { respPayload["id"] = id.uuidString }
        FileLogger.shared.debug(.transcription, "HTTP response", payload: respPayload)

        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? "(empty response)"
            throw WhisperError.httpError(httpResponse.statusCode, bodyString)
        }

        // Attempt JSON decode -> WhisperResponse
        let decodeT0 = Date()
        if let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data) {
            FileLogger.shared.debug(.transcription, "JSON decode", payload: [
                "elapsed_ms": Date().timeIntervalSince(decodeT0) * 1000
            ])
            guard decoded.success else {
                throw WhisperError.httpError(200, "Server returned success=false")
            }
            return decoded.transcription
        }

        // Fallback: attempt plain text extraction.
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return text
        }

        throw WhisperError.decodingError("Response was neither valid JSON nor plain text.")
    }
}
