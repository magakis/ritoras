import Foundation

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case invalidURL
    case noResponse
    case httpError(Int, String)
    case decodingError(String)
    case timeout
    case cancelled
    case networkError(Error)
    case allServersFailed([String])
    case asyncUnsupported
    case jobFailed(String)

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
        case .cancelled:
            return "Transcription was cancelled."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .allServersFailed(let servers):
            return "All \(servers.count) server(s) failed: \(servers.joined(separator: ", "))"
        case .asyncUnsupported:
            return "Server does not support async transcription."
        case .jobFailed(let reason):
            return "Transcription job failed: \(reason)"
        }
    }
}

// MARK: - Response Model

struct WhisperResponse: Decodable {
    let success: Bool
    let transcription: String
}

// MARK: - Async Transcription Models

/// Response from POST /transcriptions (§11).
struct AsyncSubmitResponse: Decodable {
    let jobId: String
    let statusEndpoint: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case statusEndpoint = "status_endpoint"
    }
}

/// Response from GET /jobs/{id} (§12).
struct JobStatusResponse: Decodable {
    let status: String
    let text: String?
    let revision: Int?
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

    /// Test seam — overrides the shared session when non-nil.
    /// Set in test setUp, cleared in tearDown.
    static var _testSession: URLSession?

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
        let session = Self._testSession ?? Self.session

        // Try /health first
        if let url = URL(string: "\(base)/health") {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout

            if let (_, response) = try? await session.data(for: request),
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

            if let (_, response) = try? await session.data(for: request),
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

    // MARK: - Async Transcription (Phase 3)

    /// Submits a transcription job to the async endpoint.
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a).
    ///   - serverURL:     The target server base URL.
    ///   - body:          Pre-built multipart form body.
    ///   - boundary:      Boundary string matching the body.
    ///   - jobId:         UUID used as Idempotency-Key.
    ///   - timeout:       Per-request timeout for the submit.
    ///   - correlationId: Optional UUID for cross-process correlation.
    /// - Returns: The parsed `AsyncSubmitResponse` with job_id and status_endpoint.
    /// - Throws: `WhisperError.asyncUnsupported` on 404; `.networkError`, `.httpError`, etc.
    private static func submitTranscription(
        audioURL: URL,
        serverURL: String,
        body: Data,
        boundary: String,
        jobId: UUID,
        timeout: TimeInterval,
        correlationId: UUID?
    ) async throws -> AsyncSubmitResponse {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw WhisperError.invalidURL }
        guard let url = URL(string: "\(base)/transcriptions") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(jobId.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        if let id = correlationId {
            request.setValue(id.uuidString, forHTTPHeaderField: "X-Correlation-ID")
        }
        request.httpBody = body
        request.timeoutInterval = timeout

        let session = Self._testSession ?? Self.session
        let bodyBytes = request.httpBody?.count ?? 0

        FileLogger.shared.debug(.network, "async submit start", payload: [
            "serverURL": base,
            "bodyBytes": bodyBytes,
            "jobId": jobId.uuidString,
            "idempotencyKey": jobId.uuidString.lowercased()
        ])

        let httpT0 = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WhisperError.timeout
        } catch {
            throw WhisperError.networkError(error)
        }

        let httpElapsed = Date().timeIntervalSince(httpT0) * 1000

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.noResponse
        }

        FileLogger.shared.debug(.network, "async submit response", payload: [
            "statusCode": httpResponse.statusCode,
            "elapsed_ms": httpElapsed
        ])

        switch httpResponse.statusCode {
        case 202:
            do {
                let decoded = try JSONDecoder().decode(AsyncSubmitResponse.self, from: data)
                FileLogger.shared.debug(.network, "async submit accepted", payload: [
                    "jobId": decoded.jobId,
                    "statusEndpoint": decoded.statusEndpoint
                ])
                return decoded
            } catch {
                throw WhisperError.decodingError("Failed to decode submit response: \(error.localizedDescription)")
            }
        case 404:
            throw WhisperError.asyncUnsupported
        default:
            let bodyString = String(data: data, encoding: .utf8) ?? "(empty response)"
            throw WhisperError.httpError(httpResponse.statusCode, bodyString)
        }
    }

    /// Polls the job status endpoint for the current transcription result.
    /// - Parameters:
    ///   - statusEndpoint: Relative endpoint path from the submit response (e.g. "/jobs/{id}").
    ///   - serverURL:      The target server base URL.
    /// - Returns: The `JobStatusResponse` with status, optional text, and revision.
    /// - Throws: `WhisperError.jobFailed` on terminal failure or 404; `.timeout`, `.networkError`, etc.
    private static func pollJob(
        statusEndpoint: String,
        serverURL: String, 
        correlationId: UUID?
    ) async throws -> JobStatusResponse {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw WhisperError.invalidURL }
        guard let url = URL(string: "\(base)\(statusEndpoint)") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = SharedConfig.AsyncTranscription.pollRequestTimeout
        if let id = correlationId {
            request.setValue(id.uuidString, forHTTPHeaderField: "X-Correlation-ID")
        }

        let session = Self._testSession ?? Self.session
        FileLogger.shared.debug(.network, "poll job start", payload: [
            "url": url.absoluteString
        ])

        let httpT0 = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WhisperError.timeout
        } catch {
            throw WhisperError.networkError(error)
        }

        let httpElapsed = Date().timeIntervalSince(httpT0) * 1000

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.noResponse
        }

        FileLogger.shared.debug(.network, "poll job response", payload: [
            "statusCode": httpResponse.statusCode,
            "elapsed_ms": httpElapsed
        ])

        switch httpResponse.statusCode {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(JobStatusResponse.self, from: data)
                FileLogger.shared.debug(.network, "poll job decoded", payload: [
                    "status": decoded.status,
                    "hasText": decoded.text != nil,
                    "revision": decoded.revision ?? -1
                ])
                return decoded
            } catch {
                throw WhisperError.decodingError("Failed to decode job status: \(error.localizedDescription)")
            }
        case 404:
            throw WhisperError.jobFailed("job evicted")
        default:
            let bodyString = String(data: data, encoding: .utf8) ?? "(empty response)"
            throw WhisperError.httpError(httpResponse.statusCode, bodyString)
        }
    }

    /// Transcribes audio using the async POST /transcriptions → GET /jobs/{id}
    /// polling pattern. Suitable for long recordings where holding a synchronous
    /// HTTP connection risks `URLError(.networkConnectionLost)` on app suspend.
    ///
    /// Uses `selectFirstHealthyServer` to pick a live server, submits via
    /// `submitTranscription`, then polls until the job reaches a terminal state
    /// or the deadline expires. Respects `Task.isCancelled` and the total deadline.
    ///
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a).
    ///   - jobId:         UUID for this dictation (used as Idempotency-Key).
    ///   - config:        Server configuration from `SharedConfig`.
    ///   - correlationId: Optional UUID to correlate this request across processes.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError.asyncUnsupported` if the server lacks /transcriptions;
    ///           `.jobFailed` on transcription failure; `.timeout` on deadline.
    static func transcribeAsync(
        audioURL: URL,
        jobId: UUID,
        config: SharedConfig,
        correlationId: UUID? = nil
    ) async throws -> String {
        FileLogger.shared.debug(.network, "transcribeAsync start", payload: [
            "jobId": jobId.uuidString,
            "serverCount": config.servers.count
        ])

        // 1. Pick a healthy server.
        guard let serverURL = await selectFirstHealthyServer(servers: config.servers) else {
            throw WhisperError.allServersFailed(config.servers)
        }
        FileLogger.shared.debug(.network, "transcribeAsync server selected", payload: [
            "serverURL": serverURL
        ])

        // 2. Build multipart body once.
        let boundary = "Boundary-\(UUID().uuidString)"
        let body: Data
        do {
            let bodyBuildT0 = Date()
            body = try buildBody(audioURL: audioURL, boundary: boundary)
            FileLogger.shared.debug(.transcription, "async multipart body build", payload: [
                "elapsed_ms": Date().timeIntervalSince(bodyBuildT0) * 1000,
                "bodyBytes": body.count
            ])
        } catch {
            throw WhisperError.networkError(error)
        }

        // 3. Submit transcription.
        let submitResponse = try await submitTranscription(
            audioURL: audioURL,
            serverURL: serverURL,
            body: body,
            boundary: boundary,
            jobId: jobId,
            timeout: config.timeoutSeconds,
            correlationId: correlationId
        )
        FileLogger.shared.debug(.network, "transcribeAsync submitted", payload: [
            "jobId": submitResponse.jobId,
            "statusEndpoint": submitResponse.statusEndpoint
        ])

        // 4. Poll loop.
        let deadline = Date().addingTimeInterval(SharedConfig.AsyncTranscription.totalDeadline)
        var pollCount = 0

        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                FileLogger.shared.debug(.network, "transcribeAsync deadline exceeded", payload: [
                    "pollCount": pollCount
                ])
                throw WhisperError.timeout
            }

            // Sleep with cancellation handling — Task.sleep throws on cancel.
            do {
                try await Task.sleep(nanoseconds: UInt64(SharedConfig.AsyncTranscription.pollInterval * 1_000_000_000))
            } catch {
                break // task was cancelled
            }
            guard !Task.isCancelled else { break }

            pollCount += 1

            let pollResult: JobStatusResponse
            do {
                pollResult = try await pollJob(
                    statusEndpoint: submitResponse.statusEndpoint,
                    serverURL: serverURL,
                    correlationId: correlationId
                )
            } catch WhisperError.jobFailed(let message) {
                throw WhisperError.jobFailed(message)
            } catch WhisperError.timeout {
                // Per-poll timeout — transient, retry
                FileLogger.shared.debug(.network, "transcribeAsync poll timeout, retrying", payload: [
                    "pollCount": pollCount
                ])
                continue
            } catch {
                // Transient network error — retry
                FileLogger.shared.debug(.network, "transcribeAsync poll transient error, retrying", payload: [
                    "pollCount": pollCount,
                    "error": error.localizedDescription
                ])
                continue
            }

            switch pollResult.status {
            case "ready":
                guard let text = pollResult.text, !text.isEmpty else {
                    throw WhisperError.decodingError("Job ready but text is empty")
                }
                FileLogger.shared.debug(.network, "transcribeAsync ready", payload: [
                    "pollCount": pollCount,
                    "textLength": text.count,
                    "revision": pollResult.revision ?? -1
                ])
                return text

            case "failed":
                let reason = pollResult.text ?? "unknown error"
                FileLogger.shared.debug(.network, "transcribeAsync failed", payload: [
                    "reason": reason
                ])
                throw WhisperError.jobFailed(reason)

            case "pending", "transcribing":
                FileLogger.shared.debug(.network, "transcribeAsync poll", payload: [
                    "status": pollResult.status,
                    "pollCount": pollCount,
                    "remainingSec": remaining
                ])
                continue

            default:
                FileLogger.shared.warn(.network, "transcribeAsync unknown status", payload: [
                    "status": pollResult.status
                ])
                continue
            }
        }

        // If we reach here, the task was cancelled.
        FileLogger.shared.debug(.network, "transcribeAsync cancelled")
        throw WhisperError.cancelled
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
        // Floor timeout at totalDeadline so legacy servers (no /transcriptions)
        // get a long enough leash for one sync attempt.
        request.timeoutInterval = max(timeout, SharedConfig.AsyncTranscription.totalDeadline)

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

        let session = Self._testSession ?? Self.session
        let httpT0 = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
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
