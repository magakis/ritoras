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
    case serverUnreachable
    case asyncUnsupported
    case jobFailed(String)
    case stuck

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
            return "The server didn't respond in time. It may be busy or slow — try again."
        case .serverUnreachable:
            return "Couldn't reach any transcription server. Check your connection and the server address in Settings."
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
        case .stuck:
            return "Transcription stuck — server stopped responding to polls."
        }
    }
}

extension WhisperError {
    /// Whether this error represents a transient connection failure that can be retried quickly.
    var isRetryableConnectionFailure: Bool {
        switch self {
        case .serverUnreachable, .allServersFailed:
            return true
        case .networkError(let error):
            guard let urlError = error as? URLError else { return false }
            switch urlError.code {
            case .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .timedOut:
                return true
            default:
                return false
            }
        default:
            return false
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

    /// Resets the active URLSession, forcing new requests to use a fresh
    /// connection. Safe to call from any thread — forwards to the lock-guarded
    /// SessionHolder. This is the public entry point for NetworkChangeMonitor.
    static func resetSession() {
        SessionHolder.shared.reset()
    }

    /// Transcribes the audio file at `audioURL` by iterating configured servers
    /// in order and returning the first successful result.
    ///
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a or .wav).
    ///   - config:        Server configuration from `SharedConfig`.
    ///   - correlationId: Optional UUID to correlate this request across processes.
    ///   - language:      Optional ISO-639-1 language code sent as a form field.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` if all servers fail.
    static func transcribe(
        audioURL: URL,
        config: SharedConfig,
        correlationId: UUID? = nil,
        language: String? = nil
    ) async throws -> String {
        var failedServers: [String] = []
        let t0 = Date()

        // Generate boundary ONCE and build multipart body ONCE — read the audio
        // file a single time regardless of server count.
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFileURL: URL
        do {
            let bodyBuildT0 = Date()
            bodyFileURL = try await buildBodyFileOffMain(audioURL: audioURL, boundary: boundary, language: language)
            let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyFileURL.path)[.size] as? Int64).map(Int.init) ?? 0
            FileLogger.shared.debug(.transcription, "multipart body build", payload: [
                "elapsed_ms": Date().timeIntervalSince(bodyBuildT0) * 1000,
                "bodyBytes": bodyBytes,
                "language": language ?? "none"
            ])
        } catch {
            throw WhisperError.networkError(error)
        }
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

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
                    bodyFileURL: bodyFileURL,
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
    ///   - audioURL:      Local file URL of the recorded audio (.m4a or .wav).
    ///   - serverURL:     The target server base URL.
    ///   - correlationId: Optional UUID to correlate this request across processes.
    ///   - language:      Optional ISO-639-1 language code sent as a form field.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` if the single server attempt fails.
    static func transcribe(
        audioURL: URL,
        serverURL: String,
        correlationId: UUID? = nil,
        language: String? = nil
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFileURL: URL
        do {
            let bodyBuildT0 = Date()
            bodyFileURL = try await buildBodyFileOffMain(audioURL: audioURL, boundary: boundary, language: language)
            let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyFileURL.path)[.size] as? Int64).map(Int.init) ?? 0
            FileLogger.shared.debug(.transcription, "multipart body build", payload: [
                "elapsed_ms": Date().timeIntervalSince(bodyBuildT0) * 1000,
                "bodyBytes": bodyBytes,
                "language": language ?? "none"
            ])
        } catch {
            throw WhisperError.networkError(error)
        }
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        return try await transcribeAgainst(
            serverURL: serverURL,
            bodyFileURL: bodyFileURL,
            boundary: boundary,
            timeout: SharedConfig.Defaults.timeoutSeconds,
            correlationId: correlationId
        )
    }

    /// Single canonical entrypoint for transcribing a recorded audio file.
    ///
    /// Resolves a healthy server (using `preferredServer` when it is present in
    /// `config.servers`, otherwise a parallel probe of `config.servers`), submits
    /// via async /transcriptions with polling, and falls back to sync POST
    /// /transcribe against the same resolved server when the server does not
    /// implement the async endpoint.
    ///
    /// Order-independent: when `preferredServer` is nil, all servers are probed
    /// concurrently and the first healthy responder is used, so an unreachable
    /// server at index 0 cannot block a reachable server later in the list.
    static func routeTranscription(
        audioURL: URL,
        jobId: UUID,
        config: SharedConfig,
        correlationId: UUID? = nil,
        preferredServer: String? = nil,
        language: String? = nil
    ) async throws -> String {
        let serverURL: String
        if let preferredServer, config.servers.contains(preferredServer) {
            serverURL = preferredServer
        } else {
            guard let healthy = await selectFirstHealthyServer(servers: config.servers) else {
                throw WhisperError.serverUnreachable
            }
            serverURL = healthy
        }
        do {
            return try await transcribeAsync(
                audioURL: audioURL, jobId: jobId, config: config,
                correlationId: correlationId, preferredServer: serverURL, language: language)
        } catch WhisperError.asyncUnsupported {
            FileLogger.shared.info(.network, "async unsupported; sync fallback",
                                   payload: ["server": serverURL])
            return try await transcribe(
                audioURL: audioURL, serverURL: serverURL, correlationId: correlationId, language: language)
        }
    }

    /// Pings a server to check if it is reachable.
    /// - Parameters:
    ///   - serverURL: Base URL of the Whisper server.
    ///   - timeout:   Request timeout in seconds (default 5).
    /// - Returns: `true` if the server responds with HTTP 200 on `/health`,
    ///            or any sub-500 status on the root endpoint as fallback.
    static func checkHealth(serverURL: String, timeout: TimeInterval = 5) async -> Bool {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let session = SessionHolder.shared.get()

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

    /// Fires a fire-and-forget POST /warmup so the server pre-loads its model
    /// while the user is still dictating. Never throws; failures are logged
    /// at debug level and tolerated — warm-up is strictly best-effort.
    static func warmup(serverURL: String, timeout: TimeInterval = 5) async {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: "\(base)/warmup") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let session = SessionHolder.shared.get()
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            FileLogger.shared.debug(.network, "warmup", payload: ["status": status])
        } catch {
            FileLogger.shared.debug(.network, "warmup failed (tolerated)", payload: [
                "error": error.localizedDescription
            ])
        }
    }

    /// Probes all servers in parallel and returns the first healthy one.
    /// Returns as soon as any server responds, cancelling remaining probes.
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

        let selected: String? = await withTaskGroup(of: (String, Bool).self) { group in
            for server in candidates {
                group.addTask {
                    let ok = await Self.checkHealth(serverURL: server, timeout: timeout)
                    return (server, ok)
                }
            }

            for await result in group {
                if result.1 {
                    group.cancelAll()
                    return result.0
                }
            }

            return nil
        }

        FileLogger.shared.info(.network, "server selection", payload: [
            "selected": selected ?? "none",
            "candidates": candidates
        ])
        return selected
    }

    // MARK: - Async Transcription (Phase 3)

    /// Submits a transcription job to the async endpoint.
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a or .wav).
    ///   - serverURL:     The target server base URL.
    ///   - bodyFileURL:   Temp file containing the multipart body.
    ///   - boundary:      Boundary string matching the body.
    ///   - jobId:         UUID used as Idempotency-Key.
    ///   - timeout:       Per-request timeout for the submit.
    ///   - correlationId: Optional UUID for cross-process correlation.
    /// - Returns: The parsed `AsyncSubmitResponse` with job_id and status_endpoint.
    /// - Throws: `WhisperError.asyncUnsupported` on 404; `.networkError`, `.httpError`, etc.
    private static func submitTranscription(
        audioURL: URL,
        serverURL: String,
        bodyFileURL: URL,
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
        request.timeoutInterval = timeout

        let session = SessionHolder.shared.get()
        let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyFileURL.path)[.size] as? Int64).map(Int.init) ?? 0

        FileLogger.shared.debug(.network, "async submit start", payload: [
            "serverURL": base,
            "bodyBytes": bodyBytes,
            "jobId": jobId.uuidString,
            "idempotencyKey": jobId.uuidString.lowercased()
        ])

        let httpT0 = Date()
        let (data, response): (Data, URLResponse)
        do {
            let bodyData = try Data(contentsOf: bodyFileURL)
            (data, response) = try await session.upload(for: request, from: bodyData)
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

        let session = SessionHolder.shared.get()
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
    /// When `preferredServer` is provided and is in `config.servers`, health probe
    /// is skipped entirely and the preferred server is used directly. This avoids
    /// redundant probing when a background probe already selected a healthy server.
    ///
    /// - Parameters:
    ///   - audioURL:        Local file URL of the recorded audio (.m4a or .wav).
    ///   - jobId:           UUID for this dictation (used as Idempotency-Key).
    ///   - config:          Server configuration from `SharedConfig`.
    ///   - correlationId:   Optional UUID to correlate this request across processes.
    ///   - preferredServer: Optional pre-selected server URL to use without probing.
    ///   - language:        Optional ISO-639-1 language code sent as a form field.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError.asyncUnsupported` if the server lacks /transcriptions;
    ///           `.jobFailed` on transcription failure; `.timeout` on deadline.
    static func transcribeAsync(
        audioURL: URL,
        jobId: UUID,
        config: SharedConfig,
        correlationId: UUID? = nil,
        preferredServer: String? = nil,
        language: String? = nil
    ) async throws -> String {
        FileLogger.shared.debug(.network, "transcribeAsync start", payload: [
            "jobId": jobId.uuidString,
            "serverCount": config.servers.count
        ])

        // 1. Pick a healthy server — use preferredServer if available and valid,
        //    otherwise probe candidates in parallel until the first responds.
        let serverURL: String
        if let preferredServer, config.servers.contains(preferredServer) {
            serverURL = preferredServer
            FileLogger.shared.debug(.network, "transcribeAsync using preferred server", payload: [
                "server": preferredServer
            ])
        } else {
            guard let healthyServer = await selectFirstHealthyServer(servers: config.servers) else {
                throw WhisperError.allServersFailed(config.servers)
            }
            serverURL = healthyServer
        }
        FileLogger.shared.debug(.network, "transcribeAsync server selected", payload: [
            "serverURL": serverURL
        ])

        // 2. Build multipart body once (temp file, streamed).
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFileURL: URL
        do {
            let bodyBuildT0 = Date()
            bodyFileURL = try await buildBodyFileOffMain(audioURL: audioURL, boundary: boundary, language: language)
            let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyFileURL.path)[.size] as? Int64).map(Int.init) ?? 0
            FileLogger.shared.debug(.transcription, "async multipart body build", payload: [
                "elapsed_ms": Date().timeIntervalSince(bodyBuildT0) * 1000,
                "bodyBytes": bodyBytes,
                "language": language ?? "none"
            ])
        } catch {
            throw WhisperError.networkError(error)
        }
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        // 3. Submit transcription. A compliant async server returns 202 immediately.
        // Some servers (e.g. optiplex) accept /transcriptions but block on full
        // inference instead of returning 202 up front — the per-request submit
        // timeout (config.timeoutSeconds, 20s) then fires before inference
        // finishes. On a SUBMIT timeout, fall back to the sync /transcribe path,
        // which floors its own timeout at AsyncTranscription.totalDeadline (600s)
        // and is proven to handle blocking servers (manual sync retry succeeds in
        // ~48s for an 85s clip). The poll-loop deadline timeout (below) is NOT
        // caught here, so a genuinely-async job that runs out of polling time is
        // still surfaced as a real failure rather than retried redundantly.
        let submitResponse: AsyncSubmitResponse
        do {
            submitResponse = try await submitTranscription(
                audioURL: audioURL,
                serverURL: serverURL,
                bodyFileURL: bodyFileURL,
                boundary: boundary,
                jobId: jobId,
                timeout: config.timeoutSeconds,
                correlationId: correlationId
            )
        } catch WhisperError.timeout {
            FileLogger.shared.warn(.network, "async submit timed out; server blocks on /transcriptions instead of returning 202. Falling back to sync /transcribe.", payload: [
                "serverURL": serverURL,
                "jobId": jobId.uuidString,
                "submitTimeoutSeconds": config.timeoutSeconds
            ])
            return try await transcribeAgainst(
                serverURL: serverURL,
                bodyFileURL: bodyFileURL,
                boundary: boundary,
                timeout: config.timeoutSeconds,
                correlationId: correlationId
            )
        }
        FileLogger.shared.debug(.network, "transcribeAsync submitted", payload: [
            "jobId": submitResponse.jobId,
            "statusEndpoint": submitResponse.statusEndpoint
        ])

        // 4. Poll loop.
        let deadline = Date().addingTimeInterval(SharedConfig.AsyncTranscription.totalDeadline)
        var pollCount = 0
        var consecutivePollFailures = 0
        var lastSuccessfulPollAt = Date()
        var stuckWarned = false

        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                FileLogger.shared.debug(.network, "transcribeAsync deadline exceeded", payload: [
                    "pollCount": pollCount
                ])
                throw WhisperError.timeout
            }

            // B.6 — Adaptive interval based on pollCount
            let base = pollCount < SharedConfig.AsyncTranscription.initialPollCount
                ? SharedConfig.AsyncTranscription.initialPollInterval
                : SharedConfig.AsyncTranscription.pollInterval

            // B.7 — ±10% jitter
            let jitter = base * Double.random(in: -0.1...0.1)
            let sleep = max(0.05, base + jitter)

            // B.9 — Stuck-state detection
            let elapsed = Date().timeIntervalSince(lastSuccessfulPollAt)
            if elapsed >= 60 {
                throw WhisperError.stuck
            }
            if elapsed >= 30 && !stuckWarned {
                FileLogger.shared.warn(.network, "transcribeAsync no successful poll in 30s", payload: [
                    "pollCount": pollCount
                ])
                stuckWarned = true
            }

            // Sleep with cancellation handling — Task.sleep throws on cancel.
            do {
                try await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
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
                // B.8 — Reset consecutive failures on any successful poll
                consecutivePollFailures = 0
                lastSuccessfulPollAt = Date()
                stuckWarned = false
            } catch WhisperError.jobFailed(let message) {
                throw WhisperError.jobFailed(message)
            } catch WhisperError.timeout {
                // B.8 — Exponential backoff on poll timeout
                consecutivePollFailures += 1
                // B.10 — Circuit breaker at N=8
                if consecutivePollFailures >= 8 {
                    FileLogger.shared.warn(.network, "transcribeAsync circuit breaker opened", payload: [
                        "pollCount": pollCount,
                        "consecutivePollFailures": consecutivePollFailures
                    ])
                    throw WhisperError.allServersFailed([serverURL])
                }
                let backoff = min(8.0, pow(2.0, Double(min(consecutivePollFailures - 1, 3))))
                FileLogger.shared.debug(.network, "transcribeAsync poll timeout, retrying", payload: [
                    "pollCount": pollCount,
                    "consecutivePollFailures": consecutivePollFailures
                ])
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(sleep, backoff) * 1_000_000_000))
                } catch {
                    break
                }
                continue
            } catch {
                // B.8 — Exponential backoff on poll error
                consecutivePollFailures += 1
                // B.10 — Circuit breaker at N=8
                if consecutivePollFailures >= 8 {
                    FileLogger.shared.warn(.network, "transcribeAsync circuit breaker opened", payload: [
                        "pollCount": pollCount,
                        "consecutivePollFailures": consecutivePollFailures
                    ])
                    throw WhisperError.allServersFailed([serverURL])
                }
                let backoff = min(8.0, pow(2.0, Double(min(consecutivePollFailures - 1, 3))))
                FileLogger.shared.debug(.network, "transcribeAsync poll transient error, retrying", payload: [
                    "pollCount": pollCount,
                    "consecutivePollFailures": consecutivePollFailures,
                    "error": error.localizedDescription
                ])
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(sleep, backoff) * 1_000_000_000))
                } catch {
                    break
                }
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

    /// Builds the multipart form body as a temp file off the caller thread on a .userInitiated queue.
    private static func buildBodyFileOffMain(audioURL: URL, boundary: String, language: String?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".multipart")
                do {
                    let ext = audioURL.pathExtension.lowercased()
                    let (filename, mimeType) = ext == "wav" ? ("audio.wav", "audio/wav") : ("audio.m4a", "audio/mp4")
                    try writeBodyToFile(audioURL: audioURL, boundary: boundary, mimeType: mimeType, filename: filename, language: language, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Writes the multipart/form-data body to a temp file, streaming the audio
    /// in 64 KB chunks to avoid loading the entire recording into memory.
    private static func writeBodyToFile(audioURL: URL, boundary: String, mimeType: String, filename: String, language: String?, to tempURL: URL) throws {
        guard let outputStream = OutputStream(url: tempURL, append: false) else {
            throw NSError(domain: "WhisperClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to create output stream"])
        }
        outputStream.open()
        defer { outputStream.close() }

        func writeString(_ string: String) throws {
            let data = string.data(using: .utf8)!
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                var written = 0
                while written < data.count {
                    let result = outputStream.write(bytes.advanced(by: written), maxLength: data.count - written)
                    if result < 0 {
                        throw outputStream.streamError ?? NSError(domain: "WhisperClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to write to output stream"])
                    }
                    written += result
                }
            }
        }

        // Header
        try writeString("--\(boundary)\r\n")
        try writeString("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        try writeString("Content-Type: \(mimeType)\r\n\r\n")

        // Audio bytes in 64 KB chunks
        guard let inputStream = InputStream(url: audioURL) else {
            throw NSError(domain: "WhisperClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to open audio file"])
        }
        inputStream.open()
        defer { inputStream.close() }

        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let readCount = inputStream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw inputStream.streamError ?? NSError(domain: "WhisperClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to read audio file"])
            }
            if readCount == 0 { break }

            var written = 0
            while written < readCount {
                let result = outputStream.write(buffer.advanced(by: written), maxLength: readCount - written)
                if result < 0 {
                    throw outputStream.streamError ?? NSError(domain: "WhisperClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to write audio data to output stream"])
                }
                written += result
            }
        }

        // Optional language form field (ISO-639-1) — appended only when provided.
        if let language {
            try writeString("\r\n--\(boundary)\r\n")
            try writeString("Content-Disposition: form-data; name=\"language\"\r\n")
            try writeString("\r\n")
            try writeString(language)
        }

        // Closing boundary
        try writeString("\r\n--\(boundary)--\r\n")
    }

    /// Builds a multipart/form-data URLRequest targeting a single server.
    /// The body file is uploaded separately via `upload(for:fromFile:)`.
    private static func buildRequest(
        baseURL: String,
        boundary: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/transcribe") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
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
    ///   - bodyFileURL:   Temp file containing the multipart body.
    ///   - boundary:      Boundary string matching the body.
    ///   - timeout:       Per-request timeout.
    ///   - correlationId: Optional UUID for cross-process correlation.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` on any failure.
    private static func transcribeAgainst(
        serverURL: String,
        bodyFileURL: URL,
        boundary: String,
        timeout: TimeInterval,
        correlationId: UUID?
    ) async throws -> String {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw WhisperError.invalidURL }

        let request = try buildRequest(
            baseURL: base,
            boundary: boundary,
            timeout: timeout
        )

        let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyFileURL.path)[.size] as? Int64).map(Int.init) ?? 0
        var postPayload: [String: Any] = [
            "bodyBytes": bodyBytes
        ]
        if let id = correlationId { postPayload["id"] = id.uuidString }
        FileLogger.shared.debug(.transcription, "HTTP POST /transcribe start", payload: postPayload)

        let session = SessionHolder.shared.get()
        let httpT0 = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyFileURL)
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
