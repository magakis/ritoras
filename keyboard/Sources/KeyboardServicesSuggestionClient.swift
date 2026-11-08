import Foundation

/// Outcome of one keyboard-service request; response bodies and server errors are not retained.
enum KeyboardServicesSuggestionRequestOutcome: Sendable {
    case candidates([String])
    case disabled
    case unauthorized
    case tolerated
    case failure
    case cancelled
}

struct KeyboardServicesSuggestionRequestInput: Sendable {
    let typedWord: String
    let previousWord: String
    let context: String
    let wordInProgress: String?
}

/// Authenticated, short-timeout requests for display-only server suggestions.
enum KeyboardServicesSuggestionClient {
    private static let requestTimeoutSeconds: TimeInterval = 1.25
    private static let maximumResponseBytes = 16 * 1024
    private static let maximumCandidateCount = KeyboardServicesSuggestionPolicy.maximumDisplayedCandidates
    private static let maximumWordLength = 128
    private static let maximumPredictionContextLength = 512
    private static let maximumPredictionCandidateCount = 16

    private struct WordRequest: Encodable {
        let typedWord: String
        let previousWord: String

        enum CodingKeys: String, CodingKey {
            case typedWord = "typed_word"
            case previousWord = "previous_word"
        }
    }

    private struct PredictionRequest: Encodable {
        let context: String
        let candidates: [String]
        let wordInProgress: String?
        let language: String

        enum CodingKeys: String, CodingKey {
            case context
            case candidates
            case wordInProgress = "word_in_progress"
            case language
        }
    }

    private struct WordResponse: Decodable {
        let rankedCandidates: [String]

        enum CodingKeys: String, CodingKey {
            case rankedCandidates = "ranked_candidates"
        }
    }

    private struct RankedCandidate: Decodable {
        let candidate: String
    }

    private struct PredictionResponse: Decodable {
        let rankedCandidates: [RankedCandidate]

        enum CodingKeys: String, CodingKey {
            case rankedCandidates = "ranked_candidates"
        }
    }

    private struct ErrorEnvelope: Decodable {
        let detail: ErrorDetail?
    }

    private struct ErrorDetail: Decodable {
        let status: String?
    }

    /// Requests at most one bounded candidate list from the selected endpoint.
    static func request(
        endpoint: KeyboardServicesSuggestionEndpoint,
        server: String,
        input: KeyboardServicesSuggestionRequestInput,
        localCandidates: [String],
        language: KeyboardLanguage
    ) async -> KeyboardServicesSuggestionRequestOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let request = makeRequest(
            endpoint: endpoint,
            server: server,
            input: input,
            localCandidates: localCandidates,
            language: language
        ) else {
            return .tolerated
        }
        guard !Task.isCancelled else { return .cancelled }

        do {
            let (bytes, response) = try await SessionHolder.shared
                .get(minimumResourceTimeout: requestTimeoutSeconds)
                .bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure
            }

            var responseData = Data()
            var responseTooLarge = false
            for try await byte in bytes {
                if responseData.count < maximumResponseBytes {
                    responseData.append(byte)
                } else {
                    responseTooLarge = true
                }
            }
            guard !responseTooLarge else { return .failure }

            switch httpResponse.statusCode {
            case 200..<300:
                guard let candidates = decodeCandidates(
                    responseData,
                    endpoint: endpoint,
                    requestedCandidates: localCandidates
                ) else {
                    return .failure
                }
                return .candidates(candidates)
            case 401:
                return .unauthorized
            case 422:
                return .tolerated
            case 503 where isDisabled(responseData):
                return .disabled
            default:
                return .failure
            }
        } catch {
            return Task.isCancelled ? .cancelled : .failure
        }
    }

    private static func makeRequest(
        endpoint: KeyboardServicesSuggestionEndpoint,
        server: String,
        input: KeyboardServicesSuggestionRequestInput,
        localCandidates: [String],
        language: KeyboardLanguage
    ) -> URLRequest? {
        let baseURL = server.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path: String
        let body: Data

        switch endpoint {
        case .spelling, .vocabulary:
            let typedWord = input.typedWord
            let previousWord = input.previousWord
            guard !typedWord.isEmpty,
                  typedWord.unicodeScalars.count <= maximumWordLength,
                  previousWord.unicodeScalars.count <= maximumWordLength else {
                return nil
            }
            path = endpoint == .spelling
                ? "/slots/spelling/suggest"
                : "/slots/vocabulary/lookup"
            guard let encodedBody = try? JSONEncoder().encode(
                WordRequest(typedWord: typedWord, previousWord: previousWord)
            ) else {
                return nil
            }
            body = encodedBody

        case .prediction:
            guard language == .english else { return nil }
            if let wordInProgress = input.wordInProgress {
                guard !wordInProgress.isEmpty,
                      wordInProgress.unicodeScalars.count <= maximumWordLength else {
                    return nil
                }
            }
            let candidates = boundedPredictionCandidates(localCandidates)
            guard !candidates.isEmpty else { return nil }
            path = "/slots/prediction/rank"
            let encodedRequest = PredictionRequest(
                context: suffix(input.context, maximumScalars: maximumPredictionContextLength),
                candidates: candidates,
                wordInProgress: input.wordInProgress,
                language: language.bcp47Tag
            )
            guard let encodedBody = try? JSONEncoder().encode(encodedRequest) else { return nil }
            body = encodedBody
        }

        guard let url = URL(string: baseURL + path),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        WhisperClient.applyAuth(to: &request)
        return request
    }

    private static func decodeCandidates(
        _ data: Data,
        endpoint: KeyboardServicesSuggestionEndpoint,
        requestedCandidates: [String]
    ) -> [String]? {
        let candidates: [String]
        switch endpoint {
        case .spelling, .vocabulary:
            guard let response = try? JSONDecoder().decode(WordResponse.self, from: data) else {
                return nil
            }
            candidates = response.rankedCandidates
        case .prediction:
            guard let response = try? JSONDecoder().decode(PredictionResponse.self, from: data) else {
                return nil
            }
            let requested = Set(requestedCandidates.map { $0.lowercased() })
            candidates = response.rankedCandidates.compactMap { ranked in
                requested.contains(ranked.candidate.lowercased()) ? ranked.candidate : nil
            }
        }

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            guard !candidate.isEmpty,
                  candidate.unicodeScalars.count <= maximumWordLength,
                  seen.insert(candidate.lowercased()).inserted else {
                return nil
            }
            return candidate
        }.prefix(maximumCandidateCount).map { $0 }
    }

    private static func boundedPredictionCandidates(_ candidates: [String]) -> [String] {
        candidates.filter { candidate in
            !candidate.isEmpty && candidate.unicodeScalars.count <= maximumWordLength
        }.prefix(maximumPredictionCandidateCount).map { $0 }
    }

    private static func suffix(_ value: String, maximumScalars: Int) -> String {
        var suffix = String.UnicodeScalarView()
        for scalar in value.unicodeScalars.suffix(maximumScalars) {
            suffix.append(scalar)
        }
        return String(suffix)
    }

    private static func isDisabled(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else {
            return false
        }
        return envelope.detail?.status == "disabled"
    }
}
