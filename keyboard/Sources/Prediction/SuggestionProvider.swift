import Foundation

// MARK: - Suggestion Provider Protocol

protocol SuggestionProvider {
    func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion]
}

// MARK: - Suggestion Context

struct SuggestionContext {
    let currentWord: String
    let lookupWord: String
    let previousWord: String?
    let previousWord2: String? = nil
    let isMidWord: Bool
}

// MARK: - Suggestion

struct Suggestion: Hashable {
    let text: String
    let score: Double
    let source: Source

    enum Source: String {
        case symspell
        case apple
        case lexicon
        case trigram
    }
}
