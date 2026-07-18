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
        let word = context.lookupWord.lowercased()
        guard !word.isEmpty else { return [] }

        // Always include the input itself as the leftmost chip.
        var results: [Suggestion] = [
            Suggestion(text: context.currentWord, score: 1.0, source: .symspell)
        ]

        let isRealWord = trie.contains(word: word)

        if isRealWord {
            // Prefix completions from trie.
            let completions = trie.suggest(prefix: word, limit: limit)
            for completion in completions {
                let capped = Self.applyCapitalizationTemplate(from: context.currentWord, to: completion)
                if capped.lowercased() != word {
                    results.append(
                        Suggestion(text: capped, score: 0.5, source: .symspell)
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
                        score = Double(1.0 - Double(distance) * 0.3)
                    }
                    results.append(
                        Suggestion(text: capped, score: score, source: .symspell)
                    )
                }
            }
        }

        return results
    }
}
