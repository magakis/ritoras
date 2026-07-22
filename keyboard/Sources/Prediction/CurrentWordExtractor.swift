import Foundation

/// Pure function for extracting the current word and previous word from
/// the text document context before the cursor.
enum CurrentWordExtractor {

        /// The result of extracting word context from the document.
    struct ExtractedContext {
        /// The last whitespace-delimited token, with trailing punctuation preserved (for display).
        let currentWord: String
        /// The last whitespace-delimited token, with trailing punctuation stripped (for dictionary lookups).
        /// Apostrophes are preserved to avoid breaking contractions (don't, O'Brien) and possessives.
        let lookupWord: String
        /// The second-to-last token, with trailing punctuation stripped (nil if none).
        let previousWord: String?
        /// The third-to-last token, with trailing punctuation stripped (nil if fewer than 3 tokens).
        let previousWord2: String?
    }

    /// Extracts the current word, lookup word, and previous word from the
    /// document context before the cursor.
    ///
    /// - Parameter context: The full string before the cursor (from `textDocumentProxy.documentContextBeforeInput`).
    /// - Returns: An `ExtractedContext` with:
    ///   `currentWord`: the last whitespace-delimited token (may be empty), punctuation preserved.
    ///   `lookupWord`: same as currentWord but with trailing non-apostrophe punctuation stripped.
    ///   `previousWord`: the second-to-last token, with trailing punctuation stripped (nil if none).
    static func extract(from context: String?) -> ExtractedContext {
        guard let context, !context.isEmpty else {
            return ExtractedContext(currentWord: "", lookupWord: "", previousWord: nil, previousWord2: nil)
        }

        // Check if cursor is at a word boundary (last char is whitespace).
        let isAtWordBoundary = context.last?.isWhitespace ?? true

        // Split into non-empty tokens (do NOT trim the input first).
        let tokens = context
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        if isAtWordBoundary {
            // Cursor is after whitespace → ready for next-word prediction.
            let currentWord = ""
            let lookupWord = ""
            let previousWord = stripTrailingPunctuation(from: tokens.last)
            let previousWord2: String?
            if tokens.count >= 2 {
                previousWord2 = stripTrailingPunctuation(from: tokens[tokens.count - 2])
            } else {
                previousWord2 = nil
            }
            return ExtractedContext(currentWord: currentWord, lookupWord: lookupWord, previousWord: previousWord, previousWord2: previousWord2)
        } else {
            // Cursor is mid-word → completions of the current word.
            let currentWord = tokens.last ?? ""
            let lookupWord = stripTrailingNonApostrophePunctuation(from: currentWord)

            let previousWord: String?
            if tokens.count >= 2 {
                previousWord = stripTrailingPunctuation(from: tokens[tokens.count - 2])
            } else {
                previousWord = nil
            }

            let previousWord2: String?
            if tokens.count >= 3 {
                previousWord2 = stripTrailingPunctuation(from: tokens[tokens.count - 3])
            } else {
                previousWord2 = nil
            }

            return ExtractedContext(currentWord: currentWord, lookupWord: lookupWord, previousWord: previousWord, previousWord2: previousWord2)
        }
    }

    // MARK: - Helpers

    /// Strip ALL trailing punctuation (apostrophes included) from a finished word.
    /// Returns `nil` if the input is nil, empty, or becomes empty after stripping.
    private static func stripTrailingPunctuation(from word: String?) -> String? {
        guard let word = word, !word.isEmpty else { return nil }
        var result = word
        while let last = result.last, last.isPunctuation {
            result = String(result.dropLast())
        }
        return result.isEmpty ? nil : result
    }

    /// Strip trailing punctuation from a word, but preserve apostrophes
    /// (contractions like don't, names like O'Brien, possessives).
    private static func stripTrailingNonApostrophePunctuation(from word: String) -> String {
        var result = word
        while let last = result.last, last != "'", last.isPunctuation {
            result = String(result.dropLast())
        }
        return result
    }
}
