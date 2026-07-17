import Foundation
import UIKit

/// Wraps Apple's `UITextChecker` as a `SuggestionProvider`.
///
/// Provides two correction sources:
/// 1. **Guesses** — full-word corrections for misspelled words (score: 0.85).
/// 2. **Completions** — prefix completions for partial words (score: 0.6).
///
/// Both are returned as `Suggestion` values with `source: .apple`. Results are
/// deduplicated internally (guesses win over completions when both match).
final class AppleSpellCheckerProvider: SuggestionProvider {

    private let checker = UITextChecker()
    private let language: String

    init(language: String = SharedConfig.Defaults.appleSpellCheckerLanguage) {
        self.language = language
    }

    func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion] {
        let word = context.lookupWord
        guard !word.isEmpty else { return [] }

        let range = NSRange(location: 0, length: word.utf16.count)
        var results: [Suggestion] = []
        var seen = Set<String>()

        // 1. Check for misspelling → get full-word corrections.
        let misspelledRange = checker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: language
        )

        if misspelledRange.location != NSNotFound {
            if let guesses = checker.guesses(forWordRange: misspelledRange, in: word, language: language) {
                for guess in guesses.prefix(limit) {
                    let key = guess.lowercased()
                    if !seen.contains(key) {
                        seen.insert(key)
                        results.append(
                            Suggestion(text: guess, score: 0.85, source: .apple)
                        )
                    }
                }
            }
        }

        // 2. Prefix completions (for partial words or as additional candidates).
        if let completions = checker.completions(forPartialWordRange: range, in: word, language: language) {
            for completion in completions.prefix(limit) {
                let key = completion.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    results.append(
                        Suggestion(text: completion, score: 0.6, source: .apple)
                    )
                }
            }
        }

        return Array(results.prefix(limit * 2))
    }
}
