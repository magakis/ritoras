import Foundation

/// LM-gated candidates for apostrophe-less forms that ARE real dictionary words.
///
/// Unlike `Contractions` (deterministic fast-path), every key here has a
/// legitimate standalone meaning (`its` = possessive, `cant` = hypocritical
/// talk or jargon, `id` = identification, `well`/`were`/`shell`/`ill`/`wed`/
/// `lets` are ordinary words), so a deterministic rewrite would corrupt
/// correct usage ("the dog ate its food"). Instead the contraction form is
/// injected as a candidate tagged `.ambiguousContraction` at a competitive
/// score and flows through normal KenLM fusion; autocorrect only applies it
/// when the LM-margin gate in `PredictionEngine.topCorrection` passes.
enum AmbiguousContractions {
    /// Canonical apostrophe U+2019. Matches `ApostropheNormalizer.canonical` and
    /// iOS Smart Punctuation output.
    private static let apostrophe = "\u{2019}"

    /// Maps canonicalized-lowercase apostrophe-less input → correctly-cased
    /// contraction. Values carry the correct casing for pronoun contractions
    /// (capital "I"); `applyCapitalizationTemplate` preserves it for lowercase
    /// input and normalizes a standalone lowercase "i" if it ever appears.
    static let table: [String: String] = [
        "its": "it" + apostrophe + "s",
        "cant": "can" + apostrophe + "t",
        "id": "I" + apostrophe + "d",
        "well": "we" + apostrophe + "ll",
        "were": "we" + apostrophe + "re",
        "shell": "she" + apostrophe + "ll",
        "ill": "I" + apostrophe + "ll",
        "wed": "we" + apostrophe + "d",
        "lets": "let" + apostrophe + "s",
        // NOTE: "hell" (→ he'll) deliberately omitted — low value by decision.
    ]

    /// Returns the contraction candidate for the given canonicalized-lowercase
    /// apostrophe-less input, or nil if no mapping exists.
    static func expansion(for word: String) -> String? {
        return table[word]
    }
}
