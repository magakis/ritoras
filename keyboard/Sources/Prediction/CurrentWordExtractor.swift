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
    }

    /// Extracts the last whitespace-separated token as `currentWord`/`lookupWord` and the
    /// second-to-last as `previousWord`.
    ///
    /// - Parameter context: The full string before the cursor (from `textDocumentProxy.documentContextBeforeInput`).
    /// - Returns: An `ExtractedContext` with:
    ///   `currentWord`: the last whitespace-delimited token (may be empty), punctuation preserved.
    ///   `lookupWord`: same as currentWord but with trailing non-apostrophe punctuation stripped.
    ///   `previousWord`: the second-to-last token, with trailing punctuation stripped (nil if none).
    static func extract(from context: String?) -> ExtractedContext {
        guard let context = context, !context.isEmpty else {
            return ExtractedContext(currentWord: "", lookupWord: "", previousWord: nil)
        }

        let tokens = context
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        let currentWord = tokens.last ?? ""
        let previousWord: String?
        if tokens.count >= 2 {
            var prev = tokens[tokens.count - 2]
            // Strip trailing punctuation from previousWord.
            while let last = prev.last, last.isPunctuation {
                prev = String(prev.dropLast())
            }
            previousWord = prev.isEmpty ? nil : prev
        } else {
            previousWord = nil
        }

        // Strip trailing punctuation from currentWord for lookupWord.
        // Apostrophes are never stripped — they're too ambiguous (contractions,
        // possessives, names like O'Brien).
        var lookupWord = currentWord
        while let last = lookupWord.last, last != "'", last.isPunctuation {
            lookupWord = String(lookupWord.dropLast())
        }

        return ExtractedContext(
            currentWord: currentWord,
            lookupWord: lookupWord,
            previousWord: previousWord
        )
    }
}
