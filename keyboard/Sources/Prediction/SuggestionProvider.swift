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
    let previousWord2: String?
    let isMidWord: Bool
}

// MARK: - Suggestion

struct Suggestion: Hashable {
    let text: String
    let score: Double
    let source: Source
    /// True when this is the user's typed word rendered as the verbatim
    /// candidate AND the word is not a known/learned word. Drives the
    /// quote-wrapped display ("word") in the suggestion bar.
    let isUnknownVerbatim: Bool

    enum Source: String {
        case symspell
        case apple
        case lexicon
        case trigram
        case contraction
    }
}
