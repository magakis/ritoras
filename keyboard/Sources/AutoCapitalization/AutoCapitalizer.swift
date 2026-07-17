import Foundation

/// Pure heuristic that determines whether the next letter typed should be
/// automatically capitalised, based solely on the text before the cursor.
///
/// ## Behaviour (modelled after Apple `.sentences` autocapitalisation)
///
/// Returns `true` (capitalise next letter) when:
/// - The cursor is at the start of the field (empty, whitespace-only, or
///   newline-only input).
/// - The last non-whitespace character is `.`, `!`, or `?` **and** it has
///   been verified as a true sentence end (not an abbreviation, initial, or
///   decimal point).
/// - Trailing closing quotes/brackets (`"`, `'`, `)`, `]`, `}`, `」`, `』`,
///   `„`, `"`) are **transparent** — a terminal punctuation mark behind
///   them is still recognised.
/// - An opening quote/bracket (`"`, `'`, `(`, `[`, `{`, `«`, `„`, `"`) at a
///   sentence-start position (only whitespace before it) — also transparent.
///
/// Returns `false` when:
/// - Mid-sentence punctuation is at the end: `,`, `:`, `;`, `-`, `—`, `…`.
/// - A period has no following whitespace (`Hello.etc`).
/// - A period is between two digits (`3.14`, `192.168.0.1`, `v1.2.3`).
/// - The last whitespace-delimited token is a known abbreviation (see
///   `AbbreviationSet`).
/// - The period belongs to a single-letter initial (`A.`, `J.`, `S.`).
/// - The tail token is in a script without case (CJK, Arabic, Thai, …).
/// - A regular letter is mid-sentence.
///
/// - Note: Operates on a bounded lookback (`lookbackLimit` = 200 chars) to
///   guarantee O(1) per-call cost. No NLP or ML.
enum AutoCapitalizer {

    private static let lookbackLimit = 200

    /// Characters treated as closing quotes/brackets that are transparent
    /// when they trail a terminal punctuation mark.
    private static let closingPunctuation: Set<Character> = [
        "\"", "'", ")", "]", "}", "」", "』", "„", "\u{201D}", // right double quotation mark
    ]

    /// Characters treated as opening quotes/brackets that are transparent
    /// at a sentence-start position.
    private static let openingPunctuation: Set<Character> = [
        "\"", "'", "(", "[", "{", "«", "„", "\u{201C}", // left double quotation mark
    ]

    /// Mid-sentence punctuation that must never trigger capitalisation.
    private static let midSentencePunctuationSet: Set<Character> = [
        ",", ":", ";", "-", "\u{2013}", // en dash
        "\u{2014}", // em dash
        "\u{2026}", // horizontal ellipsis
    ]

    // MARK: - Public API

    /// Returns `true` when the next character typed at the cursor position
    /// should be automatically capitalised.
    ///
    /// - Parameter contextBeforeCursor: The full text before the cursor
    ///   (from `textDocumentProxy.documentContextBeforeInput`).
    /// - Returns: `true` to capitalise, `false` to leave as-is.
    static func shouldCapitalizeNext(contextBeforeCursor: String) -> Bool {
        let suffix = String(contextBeforeCursor.suffix(lookbackLimit))

        // 1. Start of field.
        if suffix.isEmpty || suffix.allSatisfy(\.isWhitespace) {
            return true
        }

        // 2. Peel off trailing whitespace and closing quotes/brackets.
        var effective = suffix.trimmingTrailingWhitespace()
        effective = stripTrailingClosingPunctuation(effective)
        effective = effective.trimmingTrailingWhitespace()

        // 3. Strip leading opening quotes/brackets (symmetric trailing-closing
        //    counterpart). Opening punctuation is transparent at a sentence-start
        //    position, so stripping it lets the empty/start check fire correctly.
        effective = stripLeadingOpeningPunctuation(effective)
        effective = effective.trimmingLeadingWhitespace()

        // 4. After stripping, nothing left → sentence start.
        if effective.isEmpty {
            return true
        }

        // 5. Examine the last non-whitespace character.
        guard let lastChar = effective.last else {
            return true
        }

        // 6. Terminal punctuation that may end a sentence.
        if lastChar == "." || lastChar == "!" || lastChar == "?" {
            return isTrueSentenceEnd(lastChar, in: effective)
        }

        // 7. Mid-sentence punctuation — never capitalise.
        if midSentencePunctuationSet.contains(lastChar) {
            return false
        }

        // 8. Default: mid-word or mid-sentence → don't capitalise.
        return false
    }

    // MARK: - Private Helpers

    /// Determines whether the terminal punctuation at the end of `text`
    /// represents a true sentence end, or is part of an abbreviation,
    /// initial, or numeric expression.
    private static func isTrueSentenceEnd(_ char: Character, in text: String) -> Bool {
        // Exclamation and question marks are always sentence-ending.
        if char == "!" || char == "?" {
            return true
        }

        guard char == "." else { return false }

        // Extract the last whitespace-delimited token (the word that ends
        // with this period).
        let lastToken = extractLastToken(text)

        // a) Known abbreviation → not a sentence end.
        if AbbreviationSet.contains(lastToken) {
            return false
        }

        let withoutPeriod = String(lastToken.dropLast())

        // b) Single-letter initial (e.g. "A.", "J.").
        if withoutPeriod.count == 1, withoutPeriod.first?.isLetter == true {
            return false
        }

        // c) Multi-initial pattern (e.g. "J.K.", "U.S.A.").
        if withoutPeriod.count > 1 {
            let segments = withoutPeriod.components(separatedBy: ".")
            if segments.count > 1, segments.allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) {
                return false
            }
        }

        // d) Decimal guard: character immediately before the period is a digit.
        if let charBefore = text.dropLast().last, charBefore.isNumber {
            return false
        }

        // Verified true sentence end.
        return true
    }

    /// Returns the last whitespace-delimited token (word) in `text`.
    private static func extractLastToken(_ text: String) -> String {
        if let lastSpace = text.lastIndex(where: { $0.isWhitespace }) {
            return String(text[text.index(after: lastSpace)...])
        }
        return text
    }

    /// Strips trailing closing quotes/brackets from `text` iteratively.
    private static func stripTrailingClosingPunctuation(_ text: String) -> String {
        var result = text
        while let last = result.last, closingPunctuation.contains(last) {
            result = String(result.dropLast())
        }
        return result
    }

    /// Strips leading opening quotes/brackets from `text` iteratively — mirrors
    /// `stripTrailingClosingPunctuation`. Opening punctuation is transparent
    /// at a sentence-start position, so stripping it lets the empty/start
    /// check fire correctly.
    private static func stripLeadingOpeningPunctuation(_ text: String) -> String {
        var result = text
        while let first = result.first, openingPunctuation.contains(first) {
            result = String(result.dropFirst())
        }
        return result
    }
}

// MARK: - String Helpers

private extension String {
    func trimmingTrailingWhitespace() -> String {
        String(reversed().drop(while: { $0.isWhitespace }).reversed())
    }

    func trimmingLeadingWhitespace() -> String {
        String(drop(while: { $0.isWhitespace }))
    }
}
