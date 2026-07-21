import Foundation

/// Pure logic for detecting whether the cursor sits in the immediate-after-autocorrect
/// position where backspace should revert the correction.
///
/// Extracted from `KeyboardViewController.isCursorRightAfterTrailingSpaceFollowing(_:)`
/// for unit-testability — `KeyboardViewController` is not compiled into the test target.
///
/// The matcher accepts the context ending in `word` (case-insensitive), with `word`
/// treated as a complete word (the char immediately before it must be whitespace or
/// absent). This tolerates UITextProxy quirks where `documentContextBeforeInput`
/// occasionally omits the trailing space that the autocorrect inserted.
///
/// The revert path in `KeyboardViewController` always deletes `1 + word.count` chars,
/// which is safe because `lastAutoCorrection` is only non-nil in the narrow window
/// between autocorrect and the next `textDidChange` — meaning the real document state
/// always has the trailing space at match time even when the proxy reports otherwise.
enum BackspaceRevertMatcher {

    /// Returns true if `context` ends with `word` (case-insensitive) and `word` is a
    /// complete word (preceded by whitespace or start of context).
    static func isCursorRightAfter(word: String, inContext context: String) -> Bool {
        // Guard against degenerate empty-word match (would otherwise match any context).
        guard !word.isEmpty else { return false }
        guard context.count >= word.count else { return false }

        // Context must end with the word (case-insensitive).
        let suffix = String(context.suffix(word.count))
        guard suffix.lowercased() == word.lowercased() else { return false }

        // Ensure we matched a complete word, not a substring (e.g., "NotMichael"
        // must not match "Michael"). The char immediately before the word must be
        // whitespace, or absent if the word is at the very start of context.
        if context.count > word.count {
            let charBeforeWord = context.dropLast(word.count).last
            guard charBeforeWord?.isWhitespace == true else { return false }
        }

        return true
    }
}
