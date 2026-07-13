import Foundation

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case invalidURL
    case noResponse
    case httpError(Int, String)
    case decodingError(String)
    case timeout
    case networkError(Error)

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

    /// Transcribes the audio file at `audioURL` by sending it to the configured
    /// custom Whisper server.
    ///
    /// - Parameters:
    ///   - audioURL: Local file URL of the recorded audio (.m4a).
    ///   - config:   Server configuration from `SharedConfig`.
    /// - Returns: The transcribed text string.
    /// - Throws: `WhisperError` on any failure (network, HTTP, decoding, timeout).
    ///
    /// Cleanup of `audioURL` is the caller's responsibility (Phase 8).
    static func transcribe(
        audioURL: URL,
        config: SharedConfig
    ) async throws -> String {
        // 1. Build the full URL: config.baseUrl/transcribe
        let base = config.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/transcribe") else {
            throw WhisperError.invalidURL
        }

        // 2. Build multipart/form-data body with boundary
        let boundary = "Boundary-\(UUID().uuidString)"
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

        // 3. Create URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = body
        request.timeoutInterval = config.timeoutSeconds

        // 4-5. Send request via async/await URLSession
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw WhisperError.timeout
        } catch {
            throw WhisperError.networkError(error)
        }

        // 6. Check HTTP status code
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.noResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? "(empty response)"
            throw WhisperError.httpError(httpResponse.statusCode, bodyString)
        }

        // 7-8. Decode JSON response -> WhisperResponse
        // Parse the server's custom JSON response. Fall back to plain text
        // if JSON decoding fails.
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
    }
}
