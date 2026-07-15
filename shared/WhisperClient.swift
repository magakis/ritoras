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

    /// Transcribes the audio file at `audioURL` by iterating configured servers
    /// in order and returning the first successful result.
    ///
    /// - Parameters:
    ///   - audioURL: Local file URL of the recorded audio (.m4a).
    ///   - config:   Server configuration from `SharedConfig`.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` if all servers fail.
    static func transcribe(
        audioURL: URL,
        config: SharedConfig
    ) async throws -> String {
        var failedServers: [String] = []

        for server in config.servers {
            let base = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else {
                failedServers.append(server)
                continue
            }

            let boundary = "Boundary-\(UUID().uuidString)"

            do {
                let request = try buildRequest(
                    baseURL: base,
                    audioURL: audioURL,
                    boundary: boundary,
                    timeout: config.timeoutSeconds
                )

                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await URLSession.shared.data(for: request)
                } catch let error as URLError where error.code == .timedOut {
                    throw WhisperError.timeout
                } catch {
                    throw WhisperError.networkError(error)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WhisperError.noResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let bodyString = String(data: data, encoding: .utf8) ?? "(empty response)"
                    throw WhisperError.httpError(httpResponse.statusCode, bodyString)
                }

                // Attempt JSON decode -> WhisperResponse
                if let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data) {
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
            } catch {
                failedServers.append(server)
                continue
            }
        }

        throw WhisperError.allServersFailed(failedServers)
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

            if let (_, response) = try? await URLSession.shared.data(for: request),
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

            if let (_, response) = try? await URLSession.shared.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode < 500
            {
                return true
            }
        }

        return false
    }

    /// Writes the multipart/form-data body to a temp file and returns its URL.
    /// Background URLSession uploads REQUIRE a file body (`uploadTask(with:fromFile:)`);
    /// Data-bodied uploads are not background-safe.
    static func writeMultipartBodyToFile(baseURL: String, audioURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-body-\(UUID().uuidString).bin")

        var body = Data()
        func append(_ string: String) { body.append(string.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")
        append("--\(boundary)--\r\n")

        try body.write(to: bodyURL)
        return bodyURL
    }

    // MARK: - Private Helpers

    /// Builds a multipart/form-data URLRequest targeting a single server.
    private static func buildRequest(
        baseURL: String,
        audioURL: URL,
        boundary: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/transcribe") else {
            throw WhisperError.invalidURL
        }

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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        return request
    }
}
