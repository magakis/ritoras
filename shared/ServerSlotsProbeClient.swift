import Foundation

/// Failure category for an unsuccessful or undecodable `/slots` probe.
enum ServerSlotsProbeFailure: Equatable, Sendable {
    case invalidURL
    case noHTTPResponse
    case httpStatus(Int)
    case undecodableResponse
    case timeout
    case cancelled
    case transport
}

/// Result of one authenticated GET `/slots` request.
struct ServerSlotsProbeOutcome: Equatable, Sendable {
    let serverURL: String
    let statusCode: Int?
    let catalog: ServerSlotCatalog?
    let roundTripTimeMilliseconds: Double
    let failure: ServerSlotsProbeFailure?

    /// Capability classification; any HTTP or decoding failure degrades to dictation-only.
    var capability: ServerCapabilityClassification {
        classifyKeyboardServicesCapability(statusCode: statusCode, catalog: catalog)
    }

    /// Keyboard-consumed slot availability, or all-false when the catalog was not accepted.
    var keyboardServicesAvailability: KeyboardServicesSlotAvailability {
        guard statusCode == 200, let catalog else {
            return .unavailable
        }
        return catalog.keyboardServicesAvailability
    }
}

/// Authenticated, bounded probe client for the server-v2 `/slots` catalog.
enum ServerSlotsProbeClient {
    /// Fetches and decodes one server's slot catalog without changing server ranking state.
    static func probe(
        serverURL: String,
        timeout: TimeInterval = SharedConfig.Defaults.serverProbeTimeoutSeconds
    ) async -> ServerSlotsProbeOutcome {
        let baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/slots") else {
            return failedProbe(
                serverURL: baseURL,
                statusCode: nil,
                roundTripTimeMilliseconds: 0,
                failure: .invalidURL
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        WhisperClient.applyAuth(to: &request)
        request.timeoutInterval = timeout

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let (data, response) = try await SessionHolder.shared.get().data(for: request)
            let elapsedMilliseconds = max(
                0,
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                return failedProbe(
                    serverURL: baseURL,
                    statusCode: nil,
                    roundTripTimeMilliseconds: elapsedMilliseconds,
                    failure: .noHTTPResponse
                )
            }
            guard httpResponse.statusCode == 200 else {
                return failedProbe(
                    serverURL: baseURL,
                    statusCode: httpResponse.statusCode,
                    roundTripTimeMilliseconds: elapsedMilliseconds,
                    failure: .httpStatus(httpResponse.statusCode)
                )
            }

            do {
                let catalog = try JSONDecoder().decode(ServerSlotCatalog.self, from: data)
                return ServerSlotsProbeOutcome(
                    serverURL: baseURL,
                    statusCode: httpResponse.statusCode,
                    catalog: catalog,
                    roundTripTimeMilliseconds: elapsedMilliseconds,
                    failure: nil
                )
            } catch {
                return failedProbe(
                    serverURL: baseURL,
                    statusCode: httpResponse.statusCode,
                    roundTripTimeMilliseconds: elapsedMilliseconds,
                    failure: .undecodableResponse
                )
            }
        } catch {
            let elapsedMilliseconds = max(
                0,
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            )
            let urlError = error as? URLError
            let failure: ServerSlotsProbeFailure
            if Task.isCancelled || urlError?.code == .cancelled {
                failure = .cancelled
            } else if urlError?.code == .timedOut {
                failure = .timeout
            } else {
                failure = .transport
            }
            return failedProbe(
                serverURL: baseURL,
                statusCode: nil,
                roundTripTimeMilliseconds: elapsedMilliseconds,
                failure: failure
            )
        }
    }

    private static func failedProbe(
        serverURL: String,
        statusCode: Int?,
        roundTripTimeMilliseconds: Double,
        failure: ServerSlotsProbeFailure
    ) -> ServerSlotsProbeOutcome {
        if failure != .cancelled {
            var payload: [String: Any] = [
                "server": serverURL,
                "failure": String(describing: failure),
                "elapsed_ms": roundTripTimeMilliseconds
            ]
            if let statusCode {
                payload["statusCode"] = statusCode
            }
            FileLogger.shared.debug(.network, "server slots probe failed", payload: payload)
        }
        return ServerSlotsProbeOutcome(
            serverURL: serverURL,
            statusCode: statusCode,
            catalog: nil,
            roundTripTimeMilliseconds: roundTripTimeMilliseconds,
            failure: failure
        )
    }
}
