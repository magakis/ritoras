/// Pure "full collapse" word-unit deletion model for backspace Phase 3.
///
/// Given the text before the cursor (`documentContextBeforeInput`), computes
/// exactly how many characters `deleteBackward()` must be called to remove
/// the preceding word AND its adjacent separator whitespace, landing the
/// cursor flush against the next token.
///
/// **Full collapse semantic** (native iOS): the deleted unit includes the
/// word *and* its leading separator whitespace. One tick of `"hello world|"`
/// produces `"hello|"` — the space between the words is consumed entirely
/// in a single deletion.
///
/// ## Worked examples
/// - `"hello world"` → 6. Deletes `" world"`, yields `"hello"`.
/// - `"hello, world"` → 6. Deletes `" world"`, yields `"hello,"`. A
///   subsequent tick returns 1 (deletes `","`).
/// - `"line1\nline2"` → 6. Deletes `"\nline2"`, yields `"line1"`.
/// - `nil` or `""` → 0.
/// - `"   "` (all whitespace) → 3. Deletes the entire buffer.
/// - `"word"` → 4. Deletes the whole word; no preceding whitespace.
/// - `"hello world "` (trailing space) → 7. Trailing whitespace is consumed,
///   then `" world"` is deleted, yielding `"hello"`.
///
/// - Note: Operates at the `Character` level, so emoji and composed
///   grapheme clusters count as single units — consistent with UIKit's
///   `UITextDocumentProxy.deleteBackward()`.
enum BackspaceModel {

    /// Computes the number of characters to delete for one "whole-word"
    /// backspace tick under the full-collapse strategy.
    ///
    /// - Parameter contextBeforeInput: The value of
    ///   `textDocumentProxy.documentContextBeforeInput` (may be `nil`).
    /// - Returns: The number of `deleteBackward()` invocations needed, or
    ///   `0` when the input is `nil` or empty.
    static func wordUnitLength(for contextBeforeInput: String?) -> Int {
        guard let text = contextBeforeInput, !text.isEmpty else {
            return 0
        }

        let chars = Array(text)
        var i = chars.count - 1

        // 1. Consume trailing whitespace run.
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }

        // 2. Entire context was whitespace — delete it all.
        if i < 0 {
            return chars.count
        }

        // 3. Classify the current character (word vs punctuation).
        let wordClass = chars[i].isLetter || chars[i].isNumber

        // 4. Consume the token run (word or punctuation cluster).
        while i >= 0 && (chars[i].isLetter || chars[i].isNumber) == wordClass && !chars[i].isWhitespace {
            i -= 1
        }

        // 5. Consume the preceding whitespace run (the separator before the token).
        while i >= 0 && chars[i].isWhitespace {
            i -= 1
        }

        // 6. The difference is the number of characters to delete.
        return chars.count - 1 - i
    }
}
