import Foundation

/// Pure decision logic for autocorrect-on-space. No UIKit import.
/// Fully unit-testable without a host app.
enum AutocorrectController {

    // MARK: - Decision

    enum Decision: Equatable {
        /// Autocorrect should replace `typedWord` with `correction`.
        case correct(typedWord: String, correction: String)
        /// Leave the typed word as-is.
        case leaveAsIs
    }

    // MARK: - Configuration

    struct Config: Equatable {
        let minWordLength: Int
        let maxWordLength: Int
        let minConfidenceScore: Double

        static let `default` = Config(
            minWordLength: SharedConfig.Defaults.autocorrectMinWordLength,
            maxWordLength: SharedConfig.Defaults.autocorrectMaxWordLength,
            minConfidenceScore: SharedConfig.Defaults.autocorrectMinConfidenceScore
        )
    }

    // MARK: - Evaluation

    /// Evaluates whether the typed word should be auto-corrected.
    ///
    /// - Parameters:
    ///   - typedWord: The word the user actually typed.
    ///   - origin: The origin of the current word (`.typing`, `.suggestionTap`, or `.autocorrectApplied`).
    ///   - topCorrection: The highest-scoring suggestion from the prediction engine, or `nil`.
    ///   - isLearned: Whether the user has explicitly learned this word.
    ///   - config: Tunable thresholds (defaults from `SharedConfig.Defaults`).
    /// - Returns: `.correct(typedWord:correction:)` when conditions are met, otherwise `.leaveAsIs`.
    static func evaluate(
        typedWord: String,
        origin: WordOrigin,
        topCorrection: Suggestion?,
        isLearned: Bool,
        config: Config = .default
    ) -> Decision {
        // LOCKED origins — never re-correct.
        guard origin == .typing else { return .leaveAsIs }

        // Length guards (UITextChecker ~25-char cap; ignore trivial 1-2 char tokens).
        guard typedWord.count >= config.minWordLength,
              typedWord.count <= config.maxWordLength else { return .leaveAsIs }

        // User has explicitly accepted this word before.
        if isLearned { return .leaveAsIs }

        // No candidate available.
        guard let candidate = topCorrection else { return .leaveAsIs }

        // Don't "correct" to the same word (case-insensitive).
        guard candidate.text.lowercased() != typedWord.lowercased() else { return .leaveAsIs }

        // Confidence threshold.
        guard candidate.score >= config.minConfidenceScore else { return .leaveAsIs }

        // Apply case preservation.
        let cased = preserveCase(of: typedWord, appliedTo: candidate.text)
        return .correct(typedWord: typedWord, correction: cased)
    }

    // MARK: - Case Preservation

    /// Lowercases `correction` then re-applies the case shape of `typed`.
    ///
    /// - "hello" + "world" → "world"  (typed is lowercase)
    /// - "Hello" + "world" → "World"  (typed is Capitalized)
    /// - "HELLO" + "world" → "WORLD"  (typed is ALL CAPS)
    /// - "HELLO" + "hello" → "HELLO"  (correction matches typed after uppercasing)
    ///
    /// - Note: Uses `String.capitalized`/`uppercased`/`lowercased` which are locale-aware.
    ///   The keyboard currently ships as English-only (`PrimaryLanguage: "en-US"`); if
    ///   multilingual support is added, audit this method for locale-specific behavior
    ///   (e.g., German ß → SS under uppercase, Turkish İ dotted/dotless).
    private static func preserveCase(of typed: String, appliedTo correction: String) -> String {
        guard !typed.isEmpty else { return correction }
        if typed == typed.uppercased() {
            return correction.uppercased()
        }
        if typed == typed.capitalized {
            return correction.capitalized
        }
        return correction.lowercased()
    }
}
