import Foundation

/// Adapts SymSpell to the SuggestionProvider protocol.
///
/// Handles the fusion rule:
/// - If `lookupWord` is a real word (trie hit) → prefix completions from trie.
/// - If `lookupWord` is a typo (no trie hit) → SymSpell corrections.
///
/// Capitalization is inferred from `currentWord` and applied to suggestions
/// so that the input chip and suggestion chips appear consistent.
final class SymSpellProvider: SuggestionProvider {

    private let symSpell: SymSpell
    private let trie: Trie

    init(symSpell: SymSpell, trie: Trie) {
        self.symSpell = symSpell
        self.trie = trie
    }

    /// Applies the capitalization pattern from `input` to `suggestion`.
    ///
    /// Heuristic (covers ~95% of real cases):
    /// - If suggestion already contains an uppercase letter beyond position 0,
    ///   it is likely a proper noun (e.g. "USA", "iPhone") → return as-is.
    /// - If `input.first?.isUppercase == true` and the rest is lowercase →
    ///   "sentence case" → uppercase the first letter of suggestion.
    /// - If `input.allSatisfy(\.isUppercase)` and `input.count > 1` →
    ///   "all caps" → uppercase the entire suggestion.
    /// - Otherwise → "lowercase / mixed" → return suggestion as-is.
    static func applyCapitalizationTemplate(from input: String, to suggestion: String) -> String {
        // Preserve suggestions that are already capitalized (proper nouns / acronyms).
        let suggestionAfterFirst = suggestion.dropFirst()
        if suggestionAfterFirst.contains(where: { $0.isUppercase }) {
            return suggestion
        }

        guard let firstChar = input.first else { return suggestion }

        let rest = input.dropFirst()

        if firstChar.isUppercase, rest.allSatisfy({ $0.isLowercase || $0.isWhitespace }) {
            // Sentence case: capitalize first letter of suggestion.
            guard let sugFirst = suggestion.first else { return suggestion }
            return String(sugFirst.uppercased()) + suggestion.dropFirst()
        }

        if input.count > 1, input.allSatisfy(\.isUppercase) {
            // All caps: uppercase the entire suggestion.
            return suggestion.uppercased()
        }

        // Lowercase / mixed: leave suggestion as-is.
        return suggestion
    }

    func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion] {
        let word = ApostropheNormalizer.canonicalize(context.lookupWord.lowercased())
        guard !word.isEmpty else { return [] }

        // Compute isRealWord once — drives both the verbatim-candidate display
        // signal and the prefix-completion vs typo-correction branch.
        // A word is "real" if it is in the built-in trie OR has been learned
        // by the user. Learned words must take the prefix-completion path so
        // SymSpell does not treat them as typos and outrank them with corrections.
        let isRealWord = trie.contains(word: word)
            || LearnedWordsStore.shared.contains(word)

        let contractionExpansion = Contractions.expansion(for: word)

        // When a contraction exists, it should be the PRIMARY candidate (leftmost
        // chip, highest score). The verbatim is demoted so it appears as a
        // secondary option the user can tap to keep the apostrophe-less form if
        // they really want it. The 0.5 score gap ensures the contraction survives
        // KenLM fusion (which blends at α=0.5, preserving a 0.25 gap after
        // blending — contraction always wins).
        let verbatimScore: Double = contractionExpansion != nil ? 0.5 : 1.0

        // Always include the input itself as a chip. Mark it as an unknown-verbatim
        // when the typed word is not a known/learned word — the UI renders these
        // with quotes so the user can distinguish the verbatim candidate from a
        // normal suggestion.
        var results: [Suggestion] = [
            Suggestion(
                text: context.currentWord,
                score: verbatimScore,
                source: .symspell,
                isUnknownVerbatim: !isRealWord
            )
        ]

        // Contraction fast-path: checked BEFORE trie/SymSpell so that
        // apostrophe-less forms like "dont" produce "don't" deterministically.
        // Real-word status is irrelevant here — "dont" IS a real word in our
        // lexicon but the user very likely meant "don't". Inserted at position 0
        // so it appears leftmost in the suggestion bar.
        if let contraction = contractionExpansion {
            let capped = Self.applyCapitalizationTemplate(from: context.currentWord, to: contraction)
            results.insert(
                Suggestion(
                    text: capped,
                    score: 1.0,
                    source: .contraction,
                    isUnknownVerbatim: false
                ),
                at: 0
            )
        }

        if isRealWord {
            // Prefix completions from trie.
            let completions = trie.suggest(prefix: word, limit: max(limit, 20))
            // Sort by frequency from SymSpell's canonical dictionary.
            let sorted = completions.sorted { (symSpell.dictionary[$0.lowercased()] ?? 0) > (symSpell.dictionary[$1.lowercased()] ?? 0) }
            for completion in sorted.prefix(limit) {
                let capped = Self.applyCapitalizationTemplate(from: context.currentWord, to: completion)
                if capped.lowercased() != word {
                    results.append(
                        Suggestion(text: capped, score: 0.5, source: .symspell, isUnknownVerbatim: false)
                    )
                }
            }
        } else {
            // Typo correction via SymSpell.
            let corrections = symSpell.lookup(
                input: word,
                verbosity: .top
            )

            for (term, _, distance) in corrections.prefix(limit) {
                let capped = Self.applyCapitalizationTemplate(from: context.currentWord, to: term)
                if capped.lowercased() != word {
                    let score: Double
                    if distance == 0 {
                        score = 1.0
                    } else {
                        score = QwertyGeometry.score(
                            typed: word,
                            candidate: term,
                            symSpellDistance: distance,
                            beta: SharedConfig.Defaults.qwertyDistanceBeta,
                            doublingDiscount: SharedConfig.Defaults.qwertyDoublingDiscount,
                            transpositionDiscount: SharedConfig.Defaults.qwertyTranspositionDiscount
                        )
                    }
                    results.append(
                        Suggestion(text: capped, score: score, source: .symspell, isUnknownVerbatim: false)
                    )
                }
            }
        }

        return results
    }

    deinit {
        FileLogger.shared.info(.prediction, "SymSpellProvider deinit")
    }
}
