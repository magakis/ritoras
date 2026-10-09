import Foundation

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case invalidURL
    case noResponse
    case unauthorized
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
        case .unauthorized:
            return "Server rejected the API key (HTTP 401). Check the API key in Settings."
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
    /// Whether this error represents a transient connection or request timeout that can be retried.
    var isRetryableConnectionFailure: Bool {
        switch self {
        case .timeout, .allServersFailed:
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

private struct ServerStatusResponse: Decodable {
    let modelLoaded: Bool?

    enum CodingKeys: String, CodingKey {
        case modelLoaded = "model_loaded"
    }
}

/// Keeps request failures distinct from deadline-driven probe cancellation.
private enum ServerProbeCompletion: Sendable {
    case response
    case transportFailure
    case invalidURL
    case cancelled
    case roundDeadlineCutoff
}

private struct ServerProbeOutcome: Sendable {
    let server: String
    let configuredIndex: Int
    let statusCode: Int?
    let modelLoaded: Bool?
    let roundTripTimeMilliseconds: Double
    let completion: ServerProbeCompletion

    var isAuthenticated: Bool {
        guard let statusCode else { return false }
        return (200..<300).contains(statusCode)
    }

    var receivedResponse: Bool {
        statusCode != nil
    }

    var isResponse: Bool {
        if case .response = completion { return true }
        return false
    }
}

struct ServerSelectionResult: Sendable {
    let server: String?
    let modelLoaded: Bool?
    let usedPinnedServerPreflight: Bool
}

private struct PersistedServerRankingEntry: Codable, Sendable {
    let server: String
    let modelLoaded: Bool?
}

private struct PersistedServerRanking: Codable, Sendable {
    let timestamp: Date
    let entries: [PersistedServerRankingEntry]
}

private struct ServerCircuitBreakerRecord: Codable, Sendable {
    var consecutiveFailures: Int
    var openUntil: Date?
}

private enum ServerProbeStateDefaults {
    static let rankingKey = "ritoras.serverProbe.ranking.v1"
    static let circuitBreakersKey = "ritoras.serverProbe.breakers.v1"
}

private enum ServerProbeStart: Sendable {
    case ready
    case halfOpen
    case skipped(reason: String, openUntil: Date?)
}

private enum ServerProbeBreakerTransition: Sendable {
    case opened(failures: Int, until: Date)
    case reopened(failures: Int, until: Date)
    case closed
}

private actor ServerProbeState {
    static let shared = ServerProbeState()

    private var breakerRecords: [String: ServerCircuitBreakerRecord] = [:]
    private var halfOpenServers: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: ServerProbeStateDefaults.circuitBreakersKey) {
            do {
                breakerRecords = try JSONDecoder().decode([String: ServerCircuitBreakerRecord].self, from: data)
            } catch {
                FileLogger.shared.warn(.network, "server breaker state decode failed", payload: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func persistedBestServer(configuredServers: Set<String>) -> String? {
        guard let data = UserDefaults.standard.data(forKey: ServerProbeStateDefaults.rankingKey) else { return nil }
        do {
            let ranking = try JSONDecoder().decode(PersistedServerRanking.self, from: data)
            return ranking.entries.first(where: { configuredServers.contains($0.server) })?.server
        } catch {
            FileLogger.shared.warn(.network, "server ranking decode failed", payload: [
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    func persistedRankingEntries() -> [PersistedServerRankingEntry] {
        guard let data = UserDefaults.standard.data(forKey: ServerProbeStateDefaults.rankingKey) else { return [] }
        do {
            return try JSONDecoder().decode(PersistedServerRanking.self, from: data).entries
        } catch {
            FileLogger.shared.warn(.network, "server ranking decode failed", payload: [
                "error": error.localizedDescription
            ])
            return []
        }
    }

    func beginProbe(server: String) -> ServerProbeStart {
        let breaker = breakerRecords[server]
        if let openUntil = breaker?.openUntil, openUntil > Date() {
            return .skipped(reason: "cooldown", openUntil: openUntil)
        }

        if breaker?.openUntil != nil {
            guard !halfOpenServers.contains(server) else {
                return .skipped(reason: "half-open-in-flight", openUntil: breaker?.openUntil)
            }
            halfOpenServers.insert(server)
            return .halfOpen
        }
        return .ready
    }

    func finishProbe(
        server: String,
        completion: ServerProbeCompletion
    ) -> ServerProbeBreakerTransition? {
        let wasHalfOpen = halfOpenServers.remove(server) != nil

        var breaker = breakerRecords[server] ?? ServerCircuitBreakerRecord(
            consecutiveFailures: 0,
            openUntil: nil
        )
        switch completion {
        case .roundDeadlineCutoff, .cancelled, .invalidURL:
            return nil
        case .transportFailure:
            if !wasHalfOpen, let openUntil = breaker.openUntil, openUntil > Date() {
                return nil
            }
            breaker.consecutiveFailures += 1
            if wasHalfOpen || breaker.consecutiveFailures >= SharedConfig.Defaults.serverProbeBreakerFailureThreshold {
                let until = Date().addingTimeInterval(SharedConfig.Defaults.serverProbeBreakerCooldownSeconds)
                breaker.consecutiveFailures = max(
                    breaker.consecutiveFailures,
                    SharedConfig.Defaults.serverProbeBreakerFailureThreshold
                )
                breaker.openUntil = until
                breakerRecords[server] = breaker
                persistBreakers()
                return wasHalfOpen
                    ? .reopened(failures: breaker.consecutiveFailures, until: until)
                    : .opened(failures: breaker.consecutiveFailures, until: until)
            }
            breakerRecords[server] = breaker
            persistBreakers()
            return nil
        case .response:
            let recovered = breaker.consecutiveFailures > 0 || breaker.openUntil != nil
            breaker.consecutiveFailures = 0
            breaker.openUntil = nil
            breakerRecords[server] = breaker
            persistBreakers()
            return recovered ? .closed : nil
        }
    }

    func canConnect(server: String) -> Bool {
        breakerRecords[server]?.openUntil == nil
    }

    func persistRanking(entries: [PersistedServerRankingEntry], timestamp: Date) {
        guard !Task.isCancelled else {
            FileLogger.shared.debug(.network, "server ranking persistence skipped after cancellation")
            return
        }
        let ranking = PersistedServerRanking(timestamp: timestamp, entries: entries)
        do {
            let data = try JSONEncoder().encode(ranking)
            guard !Task.isCancelled else {
                FileLogger.shared.debug(.network, "server ranking persistence skipped after cancellation")
                return
            }
            UserDefaults.standard.set(data, forKey: ServerProbeStateDefaults.rankingKey)
        } catch {
            FileLogger.shared.warn(.network, "server ranking persistence failed", payload: [
                "error": error.localizedDescription
            ])
        }
    }

    private func persistBreakers() {
        do {
            let data = try JSONEncoder().encode(breakerRecords)
            UserDefaults.standard.set(data, forKey: ServerProbeStateDefaults.circuitBreakersKey)
        } catch {
            FileLogger.shared.warn(.network, "server breaker state persistence failed", payload: [
                "error": error.localizedDescription
            ])
        }
    }
}

private struct ServerProbeCandidate: Sendable {
    let server: String
    let configuredIndex: Int
}

private struct ServerProbeRound: Sendable {
    let selection: ServerSelectionResult
    let outcomes: [String: ServerProbeOutcome]
    let orderedServers: [String]
    let responderCount: Int
    let authenticatedResponderCount: Int
    let deadlineExpired: Bool
    let elapsedMilliseconds: Double
}

private enum ServerProbeRoundEvent: Sendable {
    case probe(ServerProbeOutcome)
    case deadline
    case timerCancelled
}

// MARK: - Client

enum WhisperClient {

    /// Attaches `Authorization: Bearer <key>` when a non-empty API key is
    /// configured. Empty key → no header (permissive servers tolerate absence).
    static func applyAuth(to request: inout URLRequest) {
        let key = SharedConfig.load().apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    /// Resets the active URLSession, forcing new requests to use a fresh
    /// connection. Safe to call from any thread — forwards to the lock-guarded
    /// SessionHolder. This is the public entry point for NetworkChangeMonitor.
    static func resetSession() {
        SessionHolder.shared.reset()
    }

    /// Transcribes against a single, pre-selected server. Used when a health
    /// probe has already identified the target server, avoiding iteration over
    /// configured servers. If this throws, callers should
    /// fall back to the iterating transcribe(audioURL:config:) for safety.
    /// - Parameters:
    ///   - audioURL:      Local file URL of the recorded audio (.m4a or .wav).
    ///   - serverURL:     The target server base URL.
    ///   - correlationId: Optional UUID to correlate this request across processes.
    ///   - language:      Optional ISO-639-1 language code sent as a form field.
    ///   - recordingDurationSeconds: Recorded audio duration used to scale the request timeout.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` if the single server attempt fails.
    static func transcribe(
        audioURL: URL,
        serverURL: String,
        correlationId: UUID? = nil,
        language: String? = nil,
        recordingDurationSeconds: TimeInterval = 0,
        timeout: TimeInterval = SharedConfig.Defaults.timeoutSeconds
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
            timeout: timeout,
            recordingDurationSeconds: recordingDurationSeconds,
            correlationId: correlationId
        )
    }

    /// Single canonical entrypoint for transcribing a recorded audio file.
    ///
    /// Resolves a server (using `preferredServer` when it is present in
    /// `config.servers`, otherwise a scored parallel probe), submits via async
    /// /transcriptions with polling, and falls back to sync POST /transcribe
    /// against the same resolved server when the server does not implement the
    /// async endpoint.
    ///
    /// When `preferredServer` is nil, all servers are probed concurrently.
    /// Only authenticated 2xx responders are eligible; among them, loaded
    /// models, lower RTT, then configured order determine preference.
    /// `onServerSelected` runs on the main actor after the actual submit server is resolved.
    static func routeTranscription(
        audioURL: URL,
        jobId: UUID,
        config: SharedConfig,
        correlationId: UUID? = nil,
        preferredServer: String? = nil,
        onServerSelected: (@MainActor (String) -> Void)? = nil,
        language: String? = nil,
        recordingDurationSeconds: TimeInterval = 0
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
        SharedConfig.setSelectedServer(serverURL)
        do {
            return try await transcribeAsync(
                audioURL: audioURL, jobId: jobId, config: config,
                correlationId: correlationId, preferredServer: serverURL,
                onServerSelected: onServerSelected, language: language,
                recordingDurationSeconds: recordingDurationSeconds)
        } catch WhisperError.asyncUnsupported {
            FileLogger.shared.info(.network, "async unsupported; sync fallback",
                                   payload: ["server": serverURL])
            return try await transcribe(
                audioURL: audioURL,
                serverURL: serverURL,
                correlationId: correlationId,
                language: language,
                recordingDurationSeconds: recordingDurationSeconds,
                timeout: config.timeoutSeconds)
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
            applyAuth(to: &request)
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
            applyAuth(to: &request)
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

    /// Fires a best-effort POST /warmup so the server pre-loads its model while
    /// the user is still dictating. Only HTTP 200 (already warm) and 202
    /// (warming) count as success; failures are logged and tolerated.
    static func warmup(serverURL: String, timeout: TimeInterval = 5) async {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: "\(base)/warmup") else {
            FileLogger.shared.warn(.network, "warmup invalid URL", payload: ["server": serverURL])
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.timeoutInterval = timeout
        let session = SessionHolder.shared.get()
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                FileLogger.shared.warn(.network, "warmup invalid response", payload: ["server": base])
                return
            }

            switch httpResponse.statusCode {
            case 200:
                FileLogger.shared.debug(.network, "warmup ready", payload: [
                    "server": base,
                    "status": httpResponse.statusCode
                ])
            case 202:
                FileLogger.shared.debug(.network, "warmup started", payload: [
                    "server": base,
                    "status": httpResponse.statusCode
                ])
            default:
                FileLogger.shared.warn(.network, "warmup rejected", payload: [
                    "server": base,
                    "status": httpResponse.statusCode
                ])
            }
        } catch {
            FileLogger.shared.warn(.network, "warmup failed", payload: [
                "server": base,
                "error": error.localizedDescription
            ])
        }
    }

    /// Probes configured servers concurrently and ranks authenticated 2xx
    /// responses received before the round deadline. Prefers a loaded model,
    /// lower RTT, then configured order.
    /// - Parameters:
    ///   - servers: Candidate server URLs in configured order.
    ///   - timeout: Per-server probe timeout (default from SharedConfig.Defaults).
    /// - Returns: The highest-ranked authenticated server, or nil if none respond in time.
    static func selectFirstHealthyServer(
        servers: [String],
        timeout: TimeInterval = SharedConfig.Defaults.serverProbeTimeoutSeconds
    ) async -> String? {
        let round = await probeServerRound(
            servers: servers,
            timeout: timeout,
            deadline: SharedConfig.Defaults.serverProbeRoundDeadlineSeconds,
            purpose: "selection"
        )
        logServerSelection(round, purpose: "selection")
        if let server = round.selection.server, round.selection.modelLoaded == false {
            Task {
                await Self.warmup(serverURL: server)
            }
        }
        return round.selection.server
    }

    /// Verifies the persisted best server before starting the full stream
    /// selection round. A warm preflight result is authoritative for this start.
    static func selectStreamServer(servers: [String]) async -> ServerSelectionResult {
        let normalizedServers = servers.map(Self.normalizedServerURL).filter { !$0.isEmpty }
        let configuredServers = Set(normalizedServers)
        let preflightStartedAt = ProcessInfo.processInfo.systemUptime
        guard let pinnedServer = await ServerProbeState.shared.persistedBestServer(
            configuredServers: configuredServers
        ) else {
            FileLogger.shared.debug(.network, "server selection preflight", payload: [
                "result": "miss",
                "reason": "no-valid-persisted-ranking",
                "elapsed_ms": max(0, (ProcessInfo.processInfo.systemUptime - preflightStartedAt) * 1000)
            ])
            let round = await probeServerRound(
                servers: servers,
                timeout: SharedConfig.Defaults.serverProbeTimeoutSeconds,
                deadline: SharedConfig.Defaults.serverProbeRoundDeadlineSeconds,
                purpose: "stream-selection"
            )
            logServerSelection(round, purpose: "stream-selection")
            warmColdSelection(round.selection, excluding: nil)
            return round.selection
        }

        let preflight = await probeServerRound(
            servers: servers,
            probeOnlyServers: [pinnedServer],
            timeout: SharedConfig.Defaults.serverProbeTimeoutSeconds,
            deadline: SharedConfig.Defaults.serverProbePreflightDeadlineSeconds,
            purpose: "preflight"
        )
        guard !Task.isCancelled else {
            return ServerSelectionResult(server: nil, modelLoaded: nil, usedPinnedServerPreflight: false)
        }

        let preflightOutcome = preflight.outcomes[pinnedServer]
        let preflightHit = preflightOutcome?.statusCode == 200
            && preflightOutcome?.isAuthenticated == true
            && preflightOutcome?.modelLoaded == true
        let preflightReason: String
        if preflightHit {
            preflightReason = "warm"
        } else if preflightOutcome?.modelLoaded == false {
            preflightReason = "cold"
        } else if preflightOutcome == nil {
            preflightReason = "unreachable-or-slow"
        } else {
            preflightReason = "not-authenticated-warm-200"
        }
        FileLogger.shared.debug(.network, "server selection preflight", payload: [
            "server": pinnedServer,
            "result": preflightHit ? "hit" : "miss",
            "reason": preflightReason,
            "elapsed_ms": preflight.elapsedMilliseconds
        ])

        if preflightHit {
            let selection = ServerSelectionResult(
                server: pinnedServer,
                modelLoaded: true,
                usedPinnedServerPreflight: true
            )
            FileLogger.shared.info(.network, "server selection pinned-server connect-direct", payload: [
                "server": pinnedServer,
                "elapsed_ms": preflight.elapsedMilliseconds
            ])
            FileLogger.shared.info(.network, "server selection", payload: [
                "selected": pinnedServer,
                "candidates": preflight.orderedServers,
                "reason": "pinned-server-preflight",
                "elapsed_ms": preflight.elapsedMilliseconds
            ])
            return selection
        }

        if preflightOutcome?.modelLoaded == false {
            Task.detached(priority: .utility) {
                await Self.warmup(serverURL: pinnedServer)
            }
        }

        let round = await probeServerRound(
            servers: servers,
            timeout: SharedConfig.Defaults.serverProbeTimeoutSeconds,
            deadline: SharedConfig.Defaults.serverProbeRoundDeadlineSeconds,
            purpose: "stream-selection"
        )
        logServerSelection(round, purpose: "stream-selection")
        warmColdSelection(round.selection, excluding: preflightOutcome?.modelLoaded == false ? pinnedServer : nil)
        return round.selection
    }

    /// Runs the same bounded round used by selection and persists its ranking.
    /// The app refresher handles warming a cold winner.
    static func refreshServerRanking(servers: [String]) async -> ServerSelectionResult {
        let round = await probeServerRound(
            servers: servers,
            timeout: SharedConfig.Defaults.serverProbeTimeoutSeconds,
            deadline: SharedConfig.Defaults.serverProbeRoundDeadlineSeconds,
            purpose: "refresh"
        )
        logServerSelection(round, purpose: "refresh")
        return round.selection
    }

    /// Whether the connection loop should avoid a server until its half-open
    /// status probe succeeds.
    static func serverCircuitAllowsConnection(_ server: String) async -> Bool {
        await ServerProbeState.shared.canConnect(server: normalizedServerURL(server))
    }

    private static func probeServerRound(
        servers: [String],
        probeOnlyServers: Set<String>? = nil,
        timeout: TimeInterval,
        deadline: TimeInterval,
        purpose: String
    ) async -> ServerProbeRound {
        let roundStart = ProcessInfo.processInfo.systemUptime
        let previousRanking = await ServerProbeState.shared.persistedRankingEntries()
        var previousPositions: [String: Int] = [:]
        var previousModelLoaded: [String: Bool] = [:]
        for (index, entry) in previousRanking.enumerated() {
            if previousPositions[entry.server] == nil {
                previousPositions[entry.server] = index
            }
            if let modelLoaded = entry.modelLoaded {
                previousModelLoaded[entry.server] = modelLoaded
            }
        }
        let candidates = servers.enumerated().compactMap { entry -> (index: Int, server: String)? in
            let server = normalizedServerURL(entry.element)
            guard !server.isEmpty else { return nil }
            return (index: entry.offset, server: server)
        }
        let probeCandidates = candidates.filter { candidate in
            probeOnlyServers.map { $0.contains(candidate.server) } ?? true
        }

        var activeCandidates: [ServerProbeCandidate] = []
        for candidate in probeCandidates {
            guard !Task.isCancelled else { break }
            switch await ServerProbeState.shared.beginProbe(server: candidate.server) {
            case .ready:
                activeCandidates.append(ServerProbeCandidate(
                    server: candidate.server,
                    configuredIndex: candidate.index
                ))
            case .halfOpen:
                activeCandidates.append(ServerProbeCandidate(
                    server: candidate.server,
                    configuredIndex: candidate.index
                ))
                FileLogger.shared.debug(.network, "server breaker half-open", payload: [
                    "server": candidate.server
                ])
            case .skipped(let reason, let openUntil):
                var payload: [String: Any] = ["server": candidate.server, "reason": reason]
                if let openUntil {
                    payload["cooldown_remaining_sec"] = max(0, openUntil.timeIntervalSinceNow)
                }
                FileLogger.shared.debug(.network, "server breaker skip", payload: payload)
            }
        }

        if Task.isCancelled {
            for candidate in activeCandidates {
                _ = await ServerProbeState.shared.finishProbe(
                    server: candidate.server,
                    completion: .cancelled
                )
            }
            return emptyProbeRound(servers: candidates.map(\.server), startedAt: roundStart)
        }

        var outcomes: [String: ServerProbeOutcome] = [:]
        var completedServers: Set<String> = []
        var deadlineExpired = false
        if !activeCandidates.isEmpty {
            let deadlineNanoseconds = UInt64(max(0.001, deadline) * 1_000_000_000)
            await withTaskGroup(of: ServerProbeRoundEvent.self) { group in
                for candidate in activeCandidates {
                    group.addTask {
                        .probe(await probeServerStatus(
                            serverURL: candidate.server,
                            configuredIndex: candidate.configuredIndex,
                            timeout: timeout
                        ))
                    }
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: deadlineNanoseconds)
                        return .deadline
                    } catch {
                        return .timerCancelled
                    }
                }

                var completedProbeCount = 0
                while let event = await group.next() {
                    switch event {
                    case .probe(let outcome):
                        completedProbeCount += 1
                        completedServers.insert(outcome.server)
                        let exceededDeadline = outcome.roundTripTimeMilliseconds > deadline * 1000
                        if exceededDeadline {
                            deadlineExpired = true
                        }
                        let breakerCompletion: ServerProbeCompletion
                        if Task.isCancelled {
                            breakerCompletion = .cancelled
                        } else if deadlineExpired, case .cancelled = outcome.completion {
                            breakerCompletion = .roundDeadlineCutoff
                        } else {
                            breakerCompletion = outcome.completion
                        }
                        let transition = await ServerProbeState.shared.finishProbe(
                            server: outcome.server,
                            completion: breakerCompletion
                        )
                        logBreakerTransition(transition, server: outcome.server)
                        if case .roundDeadlineCutoff = breakerCompletion {
                            FileLogger.shared.debug(.network, "server status probe excluded at round deadline", payload: [
                                "server": outcome.server,
                                "elapsed_ms": outcome.roundTripTimeMilliseconds
                            ])
                        }
                        if !Task.isCancelled && !exceededDeadline && outcome.isResponse {
                            outcomes[outcome.server] = outcome
                        }
                        if completedProbeCount == activeCandidates.count {
                            group.cancelAll()
                        }
                    case .deadline:
                        guard completedProbeCount < activeCandidates.count else { continue }
                        deadlineExpired = true
                        group.cancelAll()
                    case .timerCancelled:
                        break
                    }
                }
            }
        }

        if Task.isCancelled {
            for candidate in activeCandidates where !completedServers.contains(candidate.server) {
                _ = await ServerProbeState.shared.finishProbe(
                    server: candidate.server,
                    completion: .cancelled
                )
            }
            return emptyProbeRound(servers: candidates.map(\.server), startedAt: roundStart)
        }

        if deadlineExpired {
            FileLogger.shared.debug(.network, "server selection round deadline expired", payload: [
                "round": purpose,
                "deadline_ms": deadline * 1000,
                "responders": outcomes.values.filter(\.receivedResponse).count,
                "authenticatedResponders": outcomes.values.filter(\.isAuthenticated).count,
                "candidateCount": activeCandidates.count
            ])
        }

        let respondingOutcomes = outcomes.values.sorted(by: ranksBefore)
        let nonRespondingCandidates = candidates.filter { outcomes[$0.server] == nil }.sorted { lhs, rhs in
            let lhsPosition = previousPositions[lhs.server] ?? Int.max
            let rhsPosition = previousPositions[rhs.server] ?? Int.max
            return lhsPosition == rhsPosition
                ? lhs.index < rhs.index
                : lhsPosition < rhsPosition
        }
        let winner = outcomes.values.filter(\.isAuthenticated).min(by: ranksBefore)
        let rankingEntries = respondingOutcomes.map {
            PersistedServerRankingEntry(server: $0.server, modelLoaded: $0.modelLoaded)
        } + nonRespondingCandidates.map { candidate in
            PersistedServerRankingEntry(
                server: candidate.server,
                modelLoaded: previousModelLoaded[candidate.server]
            )
        }
        guard !Task.isCancelled else {
            return emptyProbeRound(servers: candidates.map(\.server), startedAt: roundStart)
        }
        await ServerProbeState.shared.persistRanking(entries: rankingEntries, timestamp: Date())
        guard !Task.isCancelled else {
            return emptyProbeRound(servers: candidates.map(\.server), startedAt: roundStart)
        }

        return ServerProbeRound(
            selection: ServerSelectionResult(
                server: winner?.server,
                modelLoaded: winner?.modelLoaded,
                usedPinnedServerPreflight: false
            ),
            outcomes: outcomes,
            orderedServers: rankingEntries.map(\.server),
            responderCount: outcomes.values.filter(\.receivedResponse).count,
            authenticatedResponderCount: outcomes.values.filter(\.isAuthenticated).count,
            deadlineExpired: deadlineExpired,
            elapsedMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - roundStart) * 1000)
        )
    }

    private static func emptyProbeRound(servers: [String], startedAt: TimeInterval) -> ServerProbeRound {
        ServerProbeRound(
            selection: ServerSelectionResult(server: nil, modelLoaded: nil, usedPinnedServerPreflight: false),
            outcomes: [:],
            orderedServers: servers,
            responderCount: 0,
            authenticatedResponderCount: 0,
            deadlineExpired: false,
            elapsedMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        )
    }

    private static func logServerSelection(_ round: ServerProbeRound, purpose: String) {
        let level: LogLevel = purpose == "refresh" ? .debug : .info
        FileLogger.shared.log(level, .network, "server selection", payload: [
            "selected": round.selection.server ?? "none",
            "candidates": round.orderedServers,
            "round": purpose,
            "responders": round.responderCount,
            "authenticatedResponders": round.authenticatedResponderCount,
            "deadlineExpired": round.deadlineExpired,
            "elapsed_ms": round.elapsedMilliseconds
        ])
    }

    private static func logBreakerTransition(
        _ transition: ServerProbeBreakerTransition?,
        server: String
    ) {
        guard let transition else { return }
        switch transition {
        case .opened(let failures, let until):
            FileLogger.shared.warn(.network, "server breaker open", payload: [
                "server": server,
                "consecutiveFailures": failures,
                "cooldown_until": until.timeIntervalSince1970
            ])
        case .reopened(let failures, let until):
            FileLogger.shared.warn(.network, "server breaker re-opened", payload: [
                "server": server,
                "consecutiveFailures": failures,
                "cooldown_until": until.timeIntervalSince1970
            ])
        case .closed:
            FileLogger.shared.info(.network, "server breaker closed", payload: ["server": server])
        }
    }

    private static func warmColdSelection(_ selection: ServerSelectionResult, excluding: String?) {
        guard let server = selection.server,
              selection.modelLoaded == false,
              server != excluding else { return }
        Task.detached(priority: .utility) {
            await Self.warmup(serverURL: server)
        }
    }

    private static func probeServerStatus(
        serverURL: String,
        configuredIndex: Int,
        timeout: TimeInterval
    ) async -> ServerProbeOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard let url = URL(string: "\(serverURL)/status") else {
            let outcome = ServerProbeOutcome(
                server: serverURL,
                configuredIndex: configuredIndex,
                statusCode: nil,
                modelLoaded: nil,
                roundTripTimeMilliseconds: 0,
                completion: .invalidURL
            )
            FileLogger.shared.debug(.network, "server status probe failed", payload: [
                "server": serverURL,
                "error": "invalid URL",
                "elapsed_ms": 0
            ])
            return outcome
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await SessionHolder.shared.get().data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let statusPayload: ServerStatusResponse?
            if let statusCode, (200..<300).contains(statusCode) {
                statusPayload = try? JSONDecoder().decode(ServerStatusResponse.self, from: data)
            } else {
                statusPayload = nil
            }
            let elapsedMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            let completion: ServerProbeCompletion
            if Task.isCancelled {
                completion = .cancelled
            } else if statusCode == nil {
                completion = .transportFailure
            } else {
                completion = .response
            }
            let outcome = ServerProbeOutcome(
                server: serverURL,
                configuredIndex: configuredIndex,
                statusCode: statusCode,
                modelLoaded: statusPayload?.modelLoaded,
                roundTripTimeMilliseconds: elapsedMilliseconds,
                completion: completion
            )
            var payload: [String: Any] = [
                "server": serverURL,
                "statusCode": statusCode ?? -1,
                "elapsed_ms": elapsedMilliseconds
            ]
            if let modelLoaded = outcome.modelLoaded {
                payload["model_loaded"] = modelLoaded
            }
            if statusCode == nil {
                payload["response"] = "non-HTTP"
            }
            FileLogger.shared.debug(.network, "server status probe", payload: payload)
            return outcome
        } catch {
            let elapsedMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
            if cancelled {
                FileLogger.shared.debug(.network, "server status probe cancelled", payload: [
                    "server": serverURL,
                    "elapsed_ms": elapsedMilliseconds
                ])
            } else {
                FileLogger.shared.debug(.network, "server status probe failed", payload: [
                    "server": serverURL,
                    "elapsed_ms": elapsedMilliseconds,
                    "error": error.localizedDescription
                ])
            }
            return ServerProbeOutcome(
                server: serverURL,
                configuredIndex: configuredIndex,
                statusCode: nil,
                modelLoaded: nil,
                roundTripTimeMilliseconds: elapsedMilliseconds,
                completion: cancelled ? .cancelled : .transportFailure
            )
        }
    }

    private static func normalizedServerURL(_ server: String) -> String {
        server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func ranksBefore(_ lhs: ServerProbeOutcome, _ rhs: ServerProbeOutcome) -> Bool {
        if lhs.isAuthenticated != rhs.isAuthenticated {
            return lhs.isAuthenticated
        }
        guard lhs.isAuthenticated else {
            return lhs.configuredIndex < rhs.configuredIndex
        }

        let lhsIsWarm = lhs.modelLoaded == true
        let rhsIsWarm = rhs.modelLoaded == true
        if lhsIsWarm != rhsIsWarm {
            return lhsIsWarm
        }
        if lhs.roundTripTimeMilliseconds != rhs.roundTripTimeMilliseconds {
            return lhs.roundTripTimeMilliseconds < rhs.roundTripTimeMilliseconds
        }
        return lhs.configuredIndex < rhs.configuredIndex
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
        applyAuth(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(jobId.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        if let id = correlationId {
            request.setValue(id.uuidString, forHTTPHeaderField: "X-Correlation-ID")
        }
        request.timeoutInterval = timeout

        let session = SessionHolder.shared.get(minimumResourceTimeout: request.timeoutInterval)
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
        case 401:
            throw WhisperError.unauthorized
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
        applyAuth(to: &request)
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
        case 401:
            throw WhisperError.unauthorized
        default:
            let bodyString = String(data: data, encoding: .utf8) ?? "(empty response)"
            throw WhisperError.httpError(httpResponse.statusCode, bodyString)
        }
    }

    /// Transcribes audio using the async POST /transcriptions → GET /jobs/{id}
    /// polling pattern. Suitable for long recordings where holding a synchronous
    /// HTTP connection risks `URLError(.networkConnectionLost)` on app suspend.
    ///
    /// Uses `selectFirstHealthyServer` to pick a ranked server, submits via
    /// `submitTranscription`, then polls until the job reaches a terminal state
    /// or the deadline expires. Respects `Task.isCancelled` and the total deadline.
    ///
    /// When `preferredServer` is provided and is in `config.servers`, server
    /// selection is skipped entirely and the preferred server is used directly.
    /// This avoids redundant probing when a background probe already selected it.
    ///
    /// - Parameters:
    ///   - audioURL:        Local file URL of the recorded audio (.m4a or .wav).
    ///   - jobId:           UUID for this dictation (used as Idempotency-Key).
    ///   - config:          Server configuration from `SharedConfig`.
    ///   - correlationId:   Optional UUID to correlate this request across processes.
    ///   - preferredServer: Optional pre-selected server URL to use without probing.
    ///   - onServerSelected: Optional main-actor callback when the actual server is resolved.
    ///   - language:        Optional ISO-639-1 language code sent as a form field.
    ///   - recordingDurationSeconds: Recorded audio duration used to scale timeouts.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError.asyncUnsupported` if the server lacks /transcriptions;
    ///           `.jobFailed` on transcription failure; `.timeout` on deadline.
    static func transcribeAsync(
        audioURL: URL,
        jobId: UUID,
        config: SharedConfig,
        correlationId: UUID? = nil,
        preferredServer: String? = nil,
        onServerSelected: (@MainActor (String) -> Void)? = nil,
        language: String? = nil,
        recordingDurationSeconds: TimeInterval = 0
    ) async throws -> String {
        FileLogger.shared.debug(.network, "transcribeAsync start", payload: [
            "jobId": jobId.uuidString,
            "serverCount": config.servers.count
        ])

        // 1. Pick a server — use preferredServer if available and valid, otherwise
        //    probe candidates in parallel and rank responses within the round deadline.
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
        SharedConfig.setSelectedServer(serverURL)
        if let onServerSelected {
            await onServerSelected(serverURL)
        }
        FileLogger.shared.info(.network, "server selection", payload: [
            "selected": serverURL,
            "jobId": jobId.uuidString
        ])
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
        // inference instead of returning 202 up front — the duration-scaled submit
        // timeout then fires before inference finishes. On a submit timeout,
        // retry twice with backoff using the same idempotency key, then fall back
        // to sync /transcribe, whose timeout is at least the duration-scaled poll
        // deadline. The poll-loop deadline timeout (below) is NOT caught here, so
        // a genuinely-async job that runs out of polling time is still surfaced
        // as a real failure rather than falling back redundantly.
        let submitTimeout = SharedConfig.AsyncTranscription.submitTimeout(
            baseTimeoutSeconds: config.timeoutSeconds,
            recordingDurationSeconds: recordingDurationSeconds
        )
        let submitResponse: AsyncSubmitResponse
        do {
            submitResponse = try await submitTranscription(
                audioURL: audioURL,
                serverURL: serverURL,
                bodyFileURL: bodyFileURL,
                boundary: boundary,
                jobId: jobId,
                timeout: submitTimeout,
                correlationId: correlationId
            )
        } catch WhisperError.timeout {
            do {
                submitResponse = try await retryTimedOutSubmission(
                    audioURL: audioURL,
                    serverURL: serverURL,
                    bodyFileURL: bodyFileURL,
                    boundary: boundary,
                    jobId: jobId,
                    timeout: submitTimeout,
                    correlationId: correlationId
                )
            } catch WhisperError.timeout {
                FileLogger.shared.warn(.network, "async submit retries exhausted; falling back to sync /transcribe", payload: [
                    "serverURL": serverURL,
                    "jobId": jobId.uuidString,
                    "submitTimeoutSeconds": submitTimeout,
                    "resubmissions": SharedConfig.AsyncTranscription.submitTimeoutRetryCount
                ])
                return try await transcribeAgainst(
                    serverURL: serverURL,
                    bodyFileURL: bodyFileURL,
                    boundary: boundary,
                    timeout: config.timeoutSeconds,
                    recordingDurationSeconds: recordingDurationSeconds,
                    correlationId: correlationId
                )
            }
        }
        FileLogger.shared.debug(.network, "transcribeAsync submitted", payload: [
            "jobId": submitResponse.jobId,
            "statusEndpoint": submitResponse.statusEndpoint
        ])

        // 4. Poll loop.
        let pollDeadline = SharedConfig.AsyncTranscription.pollDeadline(
            recordingDurationSeconds: recordingDurationSeconds
        )
        let deadline = Date().addingTimeInterval(pollDeadline)
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
            } catch WhisperError.unauthorized {
                throw WhisperError.unauthorized
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

    private static func retryTimedOutSubmission(
        audioURL: URL,
        serverURL: String,
        bodyFileURL: URL,
        boundary: String,
        jobId: UUID,
        timeout: TimeInterval,
        correlationId: UUID?
    ) async throws -> AsyncSubmitResponse {
        var retryNumber = 1
        while retryNumber <= SharedConfig.AsyncTranscription.submitTimeoutRetryCount {
            guard !Task.isCancelled else { throw WhisperError.cancelled }

            let backoff = SharedConfig.AsyncTranscription.submitTimeoutRetryDelay(retryNumber: retryNumber)
            FileLogger.shared.debug(.network, "async submit timed out; retrying", payload: [
                "jobId": jobId.uuidString,
                "resubmission": retryNumber,
                "backoffSeconds": backoff
            ])
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                throw WhisperError.cancelled
            }

            do {
                return try await submitTranscription(
                    audioURL: audioURL,
                    serverURL: serverURL,
                    bodyFileURL: bodyFileURL,
                    boundary: boundary,
                    jobId: jobId,
                    timeout: timeout,
                    correlationId: correlationId
                )
            } catch WhisperError.timeout {
                retryNumber += 1
            }
        }

        throw WhisperError.timeout
    }

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
        timeout: TimeInterval,
        recordingDurationSeconds: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/transcribe") else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = SharedConfig.AsyncTranscription.syncRequestTimeout(
            baseTimeoutSeconds: timeout,
            recordingDurationSeconds: recordingDurationSeconds
        )

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
        recordingDurationSeconds: TimeInterval,
        correlationId: UUID?
    ) async throws -> String {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw WhisperError.invalidURL }

        let request = try buildRequest(
            baseURL: base,
            boundary: boundary,
            timeout: timeout,
            recordingDurationSeconds: recordingDurationSeconds
        )

        let bodyBytes = (try? FileManager.default.attributesOfItem(atPath: bodyFileURL.path)[.size] as? Int64).map(Int.init) ?? 0
        var postPayload: [String: Any] = [
            "bodyBytes": bodyBytes
        ]
        if let id = correlationId { postPayload["id"] = id.uuidString }
        FileLogger.shared.debug(.transcription, "HTTP POST /transcribe start", payload: postPayload)

        let session = SessionHolder.shared.get(minimumResourceTimeout: request.timeoutInterval)
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

        if httpResponse.statusCode == 401 {
            throw WhisperError.unauthorized
        }
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
