import Foundation

/// The prediction engine that merges suggestions from multiple SuggestionProviders.
///
/// Collects suggestions from all registered providers, deduplicates by text
/// (keeping the highest score), sorts by score descending, and returns the
/// top-N results.
final class PredictionEngine {

    // MARK: - Default Top-3 Fallback

    /// Hardcoded suggestions shown on a fresh text field (no current word,
    /// no previous word) when no provider returns results.
    private static let defaultTopSuggestions = ["the", "I", "and"]

    // MARK: - Providers

    private var providers: [SuggestionProvider] = []

    // MARK: - Registration

    func addProvider(_ provider: SuggestionProvider) {
        providers.append(provider)
    }

    // MARK: - Public API

    /// Returns suggestions for the current word context, merged and deduped.
    /// - Parameters:
    ///   - currentWord: The word currently being typed (empty when after whitespace) — used for display.
    ///   - lookupWord: The word with trailing punctuation stripped — used for dictionary lookups.
    ///   - previousWord: The word before the current word (nil if no prior word).
    ///   - limit: Maximum number of suggestions to return.
    /// - Returns: Sorted array of suggestion strings.
    func suggestions(
        forCurrentWord currentWord: String,
        lookupWord: String,
        previousWord: String? = nil,
        limit: Int = 3
    ) -> [String] {
        let context = SuggestionContext(
            currentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            isMidWord: false
        )

        // ──────────────────────────────────────────────
        // EMPTY-PREFIX CASE: cursor is after whitespace
        // ──────────────────────────────────────────────
        if currentWord.isEmpty {
            // In this case only BigramPredictor (and any future lexicon
            // provider) can contribute — SymSpell and Apple return [] for
            // empty words.
            var bigramSuggestions: [Suggestion] = []
            for provider in providers {
                let results = provider.suggest(for: context, limit: limit)
                bigramSuggestions.append(contentsOf: results)
            }

            // No results and no previous word → hardcoded top-3 fallback.
            if bigramSuggestions.isEmpty, previousWord == nil {
                return Self.defaultTopSuggestions
            }

            return bigramSuggestions
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0.text }
        }

        // ──────────────────────────────────────────────
        // MID-WORD CASE: user is typing a word
        // ──────────────────────────────────────────────
        var allSuggestions: [Suggestion] = []
        for provider in providers {
            let results = provider.suggest(for: context, limit: limit)
            allSuggestions.append(contentsOf: results)
        }

        // — Boost Apple suggestions when SymSpell is uncertain —
        // When the highest-scoring SymSpell correction (excluding the input
        // word itself) is below 0.7, SymSpell has low confidence — defer to
        // Apple's native spellchecker by boosting its scores.
        let symspellMaxNonInput = allSuggestions
            .filter { $0.source == .symspell && $0.text.lowercased() != currentWord.lowercased() }
            .map { $0.score }
            .max() ?? 0

        if symspellMaxNonInput < 0.7 {
            allSuggestions = allSuggestions.map { suggestion in
                guard suggestion.source == .apple else { return suggestion }
                return Suggestion(
                    text: suggestion.text,
                    score: min(suggestion.score * 1.2, 1.0),
                    source: suggestion.source
                )
            }
        }

        // — Bigram re-rank —
        // Boost candidates from non-bigram providers by bigramBoostFactor if
        // they are common followers of the previous word.
        if let prev = previousWord?.lowercased(), !prev.isEmpty {
            if let bigram = providers.compactMap({ $0 as? BigramPredictor }).first,
               let followers = bigram.followerWordSet(for: prev) {
                allSuggestions = allSuggestions.map { suggestion in
                    guard suggestion.source != .bigram else { return suggestion }
                    guard followers.contains(suggestion.text.lowercased()) else { return suggestion }
                    return Suggestion(
                        text: suggestion.text,
                        score: min(suggestion.score * SharedConfig.Defaults.bigramBoostFactor, 1.0),
                        source: suggestion.source
                    )
                }
            }
        }

        // — Dedupe by text, keeping the highest score —
        var bestByText: [String: Suggestion] = [:]
        for suggestion in allSuggestions {
            if let existing = bestByText[suggestion.text] {
                if suggestion.score > existing.score {
                    bestByText[suggestion.text] = suggestion
                }
            } else {
                bestByText[suggestion.text] = suggestion
            }
        }

        // — Sort by score descending, take limit —
        let sorted = bestByText.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.text }

        return sorted
    }
}
