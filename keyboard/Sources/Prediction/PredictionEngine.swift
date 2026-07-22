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
    ///   - previousWord2: The word two before the current word (nil if fewer than 2 prior words).
    ///   - limit: Maximum number of suggestions to return.
    /// - Returns: Sorted array of suggestion strings.
    func suggestions(
        forCurrentWord currentWord: String,
        lookupWord: String,
        previousWord: String? = nil,
        previousWord2: String? = nil,
        limit: Int = 3
    ) -> [String] {
        let context = SuggestionContext(
            currentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2,
            isMidWord: !currentWord.isEmpty
        )

        // ──────────────────────────────────────────────
        // EMPTY-PREFIX CASE: cursor is after whitespace
        // ──────────────────────────────────────────────
        if currentWord.isEmpty {
            var pool: [Suggestion] = []
            for provider in providers {
                let results = provider.suggest(for: context, limit: limit)
                pool.append(contentsOf: results)
            }

            // Cold-start fallback: show defaults when no provider contributed
            // (e.g. TrigramProvider not yet loaded) or there is no context.
            if pool.isEmpty {
                if previousWord == nil || !providers.contains(where: { ($0 as? TrigramProvider)?.isReady == true }) {
                    return Self.defaultTopSuggestions
                }
                return []
            }

            return pool
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0.text }
        }

        // ──────────────────────────────────────────────
        // MID-WORD CASE: user is typing a word
        // ──────────────────────────────────────────────
        var allSuggestions = mergedPool(
            forCurrentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            limit: limit
        )

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

        // — Trigram re-rank —
        // Boost candidates from non-trigram providers by trigramBoostFactor if
        // they are common followers of the previous bigram context.
        if let prev = previousWord?.lowercased(), !prev.isEmpty {
            if let trigram = providers.compactMap({ $0 as? TrigramProvider }).first,
               let followers = trigram.followerWordSet(previousWord2: previousWord2, previousWord: previousWord) {
                allSuggestions = allSuggestions.map { suggestion in
                    guard suggestion.source != .trigram else { return suggestion }
                    guard followers.contains(suggestion.text.lowercased()) else { return suggestion }
                    return Suggestion(
                        text: suggestion.text,
                        score: min(suggestion.score * SharedConfig.Defaults.trigramBoostFactor, 1.0),
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

    // MARK: - Autocorrect Support

    /// Returns the highest-scoring suggestion for `lookupWord` (excluding the
    /// typed word itself), or nil if no provider offers a correction. Used by
    /// AutocorrectController to make confidence-gated replacement decisions on
    /// separator press.
    ///
    /// Unlike `suggestions(...)`, this returns the full `Suggestion` (with score)
    /// rather than just the text, so callers can apply a confidence threshold.
    /// Excludes `.trigram` source — trigrams predict the NEXT word, not corrections.
    func topCorrection(
        forCurrentWord currentWord: String,
        lookupWord: String,
        previousWord: String? = nil,
        previousWord2: String? = nil
    ) -> Suggestion? {
        guard !currentWord.isEmpty, !lookupWord.isEmpty else { return nil }
        let pool = mergedPool(
            forCurrentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2
        )
        let lowerTyped = currentWord.lowercased()
        return pool
            .filter { $0.source != .trigram && $0.text.lowercased() != lowerTyped }
            .max { $0.score < $1.score }
    }

    // MARK: - Shared Pool Builder

    /// Builds the unified suggestion pool from all registered providers.
    /// Shared by both `suggestions(...)` and `topCorrection(...)`.
    private func mergedPool(
        forCurrentWord currentWord: String,
        lookupWord: String,
        previousWord: String?,
        previousWord2: String? = nil,
        limit: Int = SharedConfig.Defaults.providerResultLimit
    ) -> [Suggestion] {
        let context = SuggestionContext(
            currentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2,
            isMidWord: !currentWord.isEmpty
        )
        var allSuggestions: [Suggestion] = []
        for provider in providers {
            let results = provider.suggest(for: context, limit: limit)
            allSuggestions.append(contentsOf: results)
        }
        return allSuggestions
    }
}
