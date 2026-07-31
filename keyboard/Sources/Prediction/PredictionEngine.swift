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
    private let poolCache = MergedPoolLRU()

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

            if pool.isEmpty {
                return Self.defaultTopSuggestions
            }

            return pool
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0.text }
        }

        // ──────────────────────────────────────────────
        // MID-WORD CASE: user is typing a word
        // ──────────────────────────────────────────────
        let allSuggestions = fusedPool(
            forCurrentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2
        )

        // — Pin verbatim/current word to #1 (iOS QuickType convention),
        // then sort corrections by score descending —
        let lowerCurrent = currentWord.lowercased()
        let verbatim = allSuggestions.first { $0.text.lowercased() == lowerCurrent }
        let corrections = allSuggestions.filter { $0.text.lowercased() != lowerCurrent }
            .sorted { $0.score > $1.score }

        let pinned: [Suggestion]
        if let v = verbatim {
            pinned = [v] + Array(corrections.prefix(max(limit - 1, 0)))
        } else {
            pinned = Array(corrections.prefix(limit))
        }

        return pinned
            .prefix(limit)
            .map { suggestion -> String in
                if suggestion.isUnknownVerbatim {
                    return "\"\(suggestion.text)\""
                }
                return suggestion.text
            }
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
        let pool = fusedPool(
            forCurrentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2
        )
        let lowerTyped = currentWord.lowercased()
        let candidates = pool.filter {
            $0.source != .trigram && $0.text.lowercased() != lowerTyped
        }
        guard let winner = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }

        // Absolute KenLM floor: reject if the winner is contextually implausible even
        // after min-max normalization inflated its relative score. Only applies when
        // fusion is active (trigram ready); otherwise there's no KenLM score to check.
        if fusionIsActive(previousWord: previousWord),
           let trigramProvider = providers.compactMap({ $0 as? TrigramProvider }).first(where: { $0.isReady }) {
            let logProb = trigramProvider.rawLogProb(
                for: winner.text,
                previousWord: previousWord,
                previousWord2: previousWord2
            ) ?? -10.0
            if logProb < SharedConfig.Defaults.kenlmAutocorrectAbsoluteLogProbFloor {
                return nil
            }
        }

        // Ambiguous-contraction margin gate: never auto-flip a real dictionary
        // word ("its", "cant", "id") to its contraction form without LM context,
        // and only when KenLM clearly favors the contraction over the typed
        // literal. Without context the typed form is the safer default — the
        // token is a valid word with its own meaning.
        if winner.source == .ambiguousContraction {
            guard fusionIsActive(previousWord: previousWord),
                  let trigramProvider = providers.compactMap({ $0 as? TrigramProvider }).first(where: { $0.isReady }) else {
                return nil
            }
            let contractionLogProb = trigramProvider.rawLogProb(
                for: winner.text,
                previousWord: previousWord,
                previousWord2: previousWord2
            ) ?? -10.0
            let typedLiteralLogProb = trigramProvider.rawLogProb(
                for: currentWord,
                previousWord: previousWord,
                previousWord2: previousWord2
            ) ?? -10.0
            if contractionLogProb - typedLiteralLogProb < SharedConfig.Defaults.ambiguousContractionLogProbMargin {
                return nil
            }
        }
        return winner
    }

    // MARK: - Fusion Pool

    /// Apple-boost + KenLM re-score + dedup. Pure function over the input pool.
    /// NOT cached (the cache lives in `mergedPool`). Called by both `suggestions()`
    /// and `topCorrection()` so autocorrect decisions use the same context-aware
    /// scoring as the suggestion bar.
    private func fusedPool(
        forCurrentWord currentWord: String,
        lookupWord: String,
        previousWord: String?,
        previousWord2: String?
    ) -> [Suggestion] {
        var allSuggestions = mergedPool(
            forCurrentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2
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
                    source: suggestion.source,
                    isUnknownVerbatim: false
                )
            }
        }

        // — KenLM contextual scoring —
        // Score every mid-word candidate with direct KenLM log-probability and
        // blend with the SymSpell/Apple score. Replaces the old binary follower-set
        // boost with true contextual probability for each candidate.
        if let trigramProvider = providers.compactMap({ $0 as? TrigramProvider }).first(where: { $0.isReady }) {
            // Phase 1: compute raw log probs for all candidates
            var scored: [(suggestion: Suggestion, logProb: Double)] = []
            for s in allSuggestions {
                let lp = trigramProvider.rawLogProb(
                    for: s.text,
                    previousWord: previousWord,
                    previousWord2: previousWord2
                ) ?? -10.0
                scored.append((s, lp))
            }

            // Phase 2: normalize log probs to [0, 1] relative to the pool
            let logProbs = scored.map { $0.logProb }
            if let maxLog = logProbs.max(), let minLog = logProbs.min() {
                let range = max(maxLog - minLog, 0.001)
                let blendWeight = SharedConfig.Defaults.kenlmBlendWeight

                // Phase 3: blend SymSpell score with normalized KenLM score
                allSuggestions = scored.map { item in
                    let normalizedKenLM = (item.logProb - minLog) / range
                    let blendedScore = (1.0 - blendWeight) * item.suggestion.score + blendWeight * normalizedKenLM
                    return Suggestion(
                        text: item.suggestion.text,
                        score: blendedScore,
                        source: item.suggestion.source,
                        isUnknownVerbatim: item.suggestion.isUnknownVerbatim
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

        return Array(bestByText.values)
    }

    // MARK: - Fusion State

    /// True when KenLM fusion would actually run: a previous word exists to give
    /// context AND the trigram provider is loaded. Used by `KeyboardViewController`
    /// to pick the two-tier autocorrect threshold (0.65 fused / 0.70 unfused).
    func fusionIsActive(previousWord: String?) -> Bool {
        guard let prev = previousWord, !prev.isEmpty else { return false }
        return providers.compactMap { $0 as? TrigramProvider }.first(where: { $0.isReady }) != nil
    }

    // MARK: - Shared Pool Builder

    /// Builds the unified suggestion pool from all registered providers.
    /// Shared by both `suggestions(...)` and `topCorrection(...)`.
    ///
    /// Always builds with `SharedConfig.Defaults.providerResultLimit` so the
    /// cached pool is the same regardless of which caller triggers the miss.
    /// Callers (suggestions, topCorrection) trim/filter downstream.
    private func mergedPool(
        forCurrentWord currentWord: String,
        lookupWord: String,
        previousWord: String?,
        previousWord2: String? = nil
    ) -> [Suggestion] {
        let cacheKey = ContextHash.fnv1a(
            "\(currentWord)\u{1F}\(lookupWord)\u{1F}\(previousWord ?? "")\u{1F}\(previousWord2 ?? "")"
        )

        if let cached = poolCache.get(cacheKey) {
            return cached
        }

        let context = SuggestionContext(
            currentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord,
            previousWord2: previousWord2,
            isMidWord: !currentWord.isEmpty
        )
        var allSuggestions: [Suggestion] = []
        for provider in providers {
            let results = provider.suggest(for: context, limit: SharedConfig.Defaults.providerResultLimit)
            allSuggestions.append(contentsOf: results)
        }
        poolCache.set(cacheKey, allSuggestions)
        return allSuggestions
    }

    deinit {
        FileLogger.shared.info(.prediction, "PredictionEngine deinit",
            payload: ["providerCount": providers.count])
    }
}
