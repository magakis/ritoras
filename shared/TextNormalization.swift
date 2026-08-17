import Foundation

/// Normalizes apostrophe variants to a single canonical codepoint.
///
/// iOS Smart Punctuation inserts U+2019 (right single quotation mark); the bundled
/// dictionary stores U+0027 (straight apostrophe); UITextChecker may return either.
/// Without normalization, lookups silently fail across variants. Canonicalizing to
/// U+2019 means the keyboard's emitted text matches iOS native output, so the host
/// field's Smart Punctuation pass is a no-op rather than a double-substitution.
///
/// No language gate: Greek tokens contain no apostrophe variants (Modern Greek
/// has no apostrophe contractions), so `canonicalize` passes them through
/// unchanged — running it unconditionally is both correct and cheaper than a
/// per-language dispatch.
enum ApostropheNormalizer {
    /// Canonical apostrophe: U+2019 RIGHT SINGLE QUOTATION MARK.
    static let canonical: Character = "\u{2019}"

    /// All apostrophe variants that normalize to `canonical`.
    static let variants: Set<Character> = ["\u{0027}", "\u{2018}", "\u{2019}"]

    /// Returns the input with every apostrophe variant replaced by the canonical
    /// U+2019. Idempotent: canonicalizing already-canonical text is a no-op.
    static func canonicalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            out.append(variants.contains(ch) ? canonical : ch)
        }
        return out
    }

    /// True iff `ch` is one of the three apostrophe variants.
    static func isApostropheVariant(_ ch: Character) -> Bool {
        return variants.contains(ch)
    }
}

/// Quote/bracket characters treated as word boundaries when they lead or trail
/// an in-progress token. Apostrophes are NOT members here as a category — they are
/// word-internal when between letters (handled separately by the tokenizer) but
/// ARE members of this set because a single leading/trailing apostrophe-quote is a
/// boundary (e.g. `'em`, `cats'`-with-quote-context). The tokenizer preserves
/// apostrophes that sit between letters via a separate check.
enum WordBoundaryPunctuation {
    /// Quote/bracket characters treated as word boundaries at the leading/trailing
    /// edge of an in-progress token. Drawn from common Latin, CJK, and European
    /// quotation marks.
    static let boundaryQuotes: Set<Character> = [
        "\"",                              // straight double quote
        "\u{201C}", "\u{201D}",            // curly double quotes (left/right)
        "\u{2018}", "\u{2019}",            // curly single quotes (left/right) — edge boundaries only
        "«", "»",                          // guillemets
        "「", "」", "『", "』",            // CJK corner brackets
        "„",                               // low double quote (opening, German/Eastern European)
    ]
}
