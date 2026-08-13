import Foundation

/// Pure function for extracting recently committed words from the document
/// context, walking backwards from the cursor. No UIKit import.
///
/// Used by retroactive autocorrect: when the user presses a separator, the
/// keyboard can revisit the last few words and correct ones that were typed
/// without an inline suggestion.
enum RecentWordsExtractor {

    /// A single committed word found before the cursor.
    struct RecentWord {
        /// The token as it appears in the document (trailing punctuation
        /// preserved, for display).
        let word: String
        /// The token with trailing punctuation stripped and apostrophes
        /// canonicalized (for dictionary lookups).
        let lookupWord: String
        /// Character distance from the cursor to the END of the word's body
        /// (after trailing punctuation). `RetroactiveApplyPlan` navigates back
        /// to the word with `backMove == -offsetFromCursorEnd`.
        let offsetFromCursorEnd: Int
    }

    /// Walks backwards from the cursor (the end of `context`), collecting up to
    /// `maxCount` completed words.
    ///
    /// If the cursor is mid-word, the in-progress token is skipped — only
    /// committed words can be retroactively corrected. The most recent word is
    /// returned first; each entry's `offsetFromCursorEnd` grows as the walk
    /// moves further back.
    ///
    /// Tokenization mirrors `CurrentWordExtractor`: whitespace-delimited
    /// tokens, trailing punctuation stripped from finished words, apostrophes
    /// canonicalized via `ApostropheNormalizer.canonicalize`.
    ///
    /// - Parameters:
    ///   - context: The full string before the cursor (from `textDocumentProxy.documentContextBeforeInput`).
    ///   - maxCount: Maximum number of committed words to return (older words are dropped).
    /// - Returns: Up to `maxCount` `RecentWord`s, most recent first.
    static func extract(from context: String?, maxCount: Int) -> [RecentWord] {
        guard let context, !context.isEmpty, maxCount > 0 else { return [] }

        // True when the cursor sits at a word boundary (the last char is whitespace).
        let endsWithWhitespace = context.last?.isWhitespace ?? true

        var results: [RecentWord] = []
        results.reserveCapacity(maxCount)

        var index = context.endIndex

        // Skip trailing whitespace so `index` lands just after the last token.
        while index > context.startIndex {
            let previous = context.index(before: index)
            if context[previous].isWhitespace {
                index = previous
            } else {
                break
            }
        }

        // If the cursor is mid-word, the token ending at `index` is the word
        // being typed — skip it and the whitespace before it, so `index` points
        // just after the last committed word. Only committed words qualify.
        if !endsWithWhitespace {
            while index > context.startIndex {
                let previous = context.index(before: index)
                if context[previous].isWhitespace {
                    index = previous
                    break
                }
                index = previous
            }
        }

        // Collect committed words walking backwards, up to maxCount.
        while results.count < maxCount, index > context.startIndex {
            // Find the start of the token ending at `index`.
            var tokenStart = index
            while tokenStart > context.startIndex {
                let previous = context.index(before: tokenStart)
                if context[previous].isWhitespace {
                    break
                }
                tokenStart = previous
            }

            let word = String(context[tokenStart..<index])
            let stripped = stripTrailingPunctuation(from: word) ?? word
            let lookupWord = ApostropheNormalizer.canonicalize(stripped)

            // The word's body (after trailing punctuation) ends `strippedCount`
            // characters before the token's display end. The apply plan deletes
            // exactly the body, so the offset must point at the body end.
            let strippedCount = word.count - stripped.count
            let bodyEnd = context.index(index, offsetBy: -strippedCount)

            results.append(RecentWord(
                word: word,
                lookupWord: lookupWord,
                offsetFromCursorEnd: context[bodyEnd..<context.endIndex].utf16.count
            ))

            // Advance to the previous token: hop over the current token's start
            // position, then over any whitespace separating it from the next token.
            index = tokenStart
            while index > context.startIndex {
                let previous = context.index(before: index)
                if context[previous].isWhitespace {
                    index = previous
                } else {
                    break
                }
            }
        }

        return results
    }

    // MARK: - Helpers

    /// Strip ALL trailing punctuation (apostrophes included) from a finished
    /// word. Returns `nil` if the input is empty or becomes empty after
    /// stripping. Mirrors `CurrentWordExtractor.stripTrailingPunctuation(from:)`
    /// (private there, so duplicated here).
    private static func stripTrailingPunctuation(from word: String) -> String? {
        guard !word.isEmpty else { return nil }
        var result = word
        while let last = result.last, last.isPunctuation {
            result = String(result.dropLast())
        }
        return result.isEmpty ? nil : result
    }
}
