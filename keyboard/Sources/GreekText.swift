import Foundation

/// Pure Greek final-sigma conversion logic. UIKit-free by design so the JS
/// mirror in scripts/prediction-sim/lib/greek-text.mjs stays 1:1.
enum GreekText {

    /// Converts a single trailing `σ` (U+03C3) to the word-final form `ς`
    /// (U+03C2). A no-op for words shorter than two characters, words ending
    /// in any other character, and words already ending in `ς` (idempotent).
    /// Uppercase `Σ` is left untouched — the conversion applies to lowercase
    /// typing only.
    static func finalSigma(atWordEnd word: String) -> String {
        guard word.count >= 2, word.last == "σ" else { return word }
        return String(word.dropLast()) + "ς"
    }

    /// Predicate for the backspace revert: true when the character immediately
    /// before the cursor is a word-final `ς` preceded by a letter — the exact
    /// shape the keyboard's auto-conversion produces. The controller
    /// additionally gates on its own tracking of an auto-inserted ς; this
    /// function only validates the text shape.
    static func shouldRevertSigma(before text: String) -> Bool {
        guard text.count >= 2, text.last == "ς" else { return false }
        let charBefore = text[text.index(before: text.endIndex)]
        return charBefore.isLetter
    }
}
