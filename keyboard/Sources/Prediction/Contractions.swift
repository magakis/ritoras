import Foundation

/// Deterministic fast-path from apostrophe-less forms to canonical U+2019 contractions.
///
/// Consulted by `SymSpellProvider` BEFORE SymSpell lookup. Necessary because
/// SymSpell's `.top` verbosity returns the input word itself at distance 0 when it is
/// a real dictionary word — and many apostrophe-less forms (`dont`, `wont`, `couldnt`,
/// etc.) ARE real dictionary words (included because they are common misspellings in
/// the corpus), so SymSpell offers no correction for them.
///
/// Conservative inclusion policy: only keys that, when the user types them, are almost
/// certainly intended as contractions rather than standalone words. Ambiguous keys like
/// `well` (→ `we'll`), `were` (→ `we're`), `its` (→ `it's`, conflicts with possessive
/// `its`), `cant` (→ `can't`; "cant" is a real word meaning hypocritical talk or jargon),
/// `cause` (→ `'cause`; "cause" is a very common noun/verb), and `bout` (→ `'bout`;
/// "bout" is a real word meaning a short period or contest) are deliberately EXCLUDED
/// to avoid false-positive autocorrects on correctly-typed words.
enum Contractions {
    /// Canonical apostrophe U+2019. Matches `ApostropheNormalizer.canonical` and
    /// iOS Smart Punctuation output.
    private static let apostrophe = "\u{2019}"

    /// Maps canonicalized-lowercase apostrophe-less input → lowercase contraction.
    /// Case is re-applied by the caller via `SymSpellProvider.applyCapitalizationTemplate`.
    static let table: [String: String] = [
        // Negative contractions: apostrophe-less forms that are misspellings
        // in the dictionary, not standalone words with independent meaning.
        "dont": "don" + apostrophe + "t",
        "wont": "won" + apostrophe + "t",
        "couldnt": "couldn" + apostrophe + "t",
        "wouldnt": "wouldn" + apostrophe + "t",
        "shouldnt": "shouldn" + apostrophe + "t",
        "isnt": "isn" + apostrophe + "t",
        "wasnt": "wasn" + apostrophe + "t",
        "arent": "aren" + apostrophe + "t",
        "didnt": "didn" + apostrophe + "t",
        "doesnt": "doesn" + apostrophe + "t",
        "havent": "haven" + apostrophe + "t",
        "hadnt": "hadn" + apostrophe + "t",
        "hasnt": "hasn" + apostrophe + "t",
        "werent": "weren" + apostrophe + "t",
        "neednt": "needn" + apostrophe + "t",
        "oughtnt": "oughtn" + apostrophe + "t",

        // Pronoun + verb contractions: apostrophe-less forms that are not
        // standard English words.
        "youre": "you" + apostrophe + "re",
        "youve": "you" + apostrophe + "ve",
        "youll": "you" + apostrophe + "ll",
        "youd": "you" + apostrophe + "d",
        "theyre": "they" + apostrophe + "re",
        "theyve": "they" + apostrophe + "ve",
        "theyll": "they" + apostrophe + "ll",
        "theyd": "they" + apostrophe + "d",
        "maam": "ma" + apostrophe + "am",
        "yall": "y" + apostrophe + "all",
        "tis": apostrophe + "tis",
        "twas": apostrophe + "twas",

        // EXPLICITLY EXCLUDED (real words or ambiguous — DO NOT add):
        //   well (→ we'll), were (→ we're), its (→ it's), lets (→ let's),
        //   whos (→ who's), im (→ I'm), ive (→ I've), ill (→ I'll),
        //   id (→ I'd), hes (→ he's), shes (→ she's), hell (→ he'll),
        //   shell (→ she'll), wed (→ we'd), heres (→ here's),
        //   theres (→ there's), thats (→ that's), whats (→ what's),
        //   cant (→ can't; "cant" = hypocritical talk), cause (→ 'cause),
        //   bout (→ 'bout), em (→ 'em)
        // These rely on the user typing the apostrophe or on SymSpell's
        // edit-distance path.
    ]

    /// Returns the canonical contraction for the given canonicalized-lowercase
    /// apostrophe-less input, or nil if no mapping exists.
    static func expansion(for word: String) -> String? {
        return table[word]
    }
}
