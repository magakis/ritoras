import Foundation

/// A static set of known abbreviations with trailing periods that suppress
/// auto-capitalization (e.g., `"e.g."` → next letter stays lowercase).
///
/// ## Locale extension point
/// To add locale-specific abbreviations, add a new `static` set (e.g.
/// `static let french: Set<String> = [...]`) and update `contains(_:)` to
/// check the appropriate set based on the current locale.
enum AbbreviationSet {

    /// The canonical English abbreviation list. Every entry is lowercase
    /// and includes the trailing period. Use `contains(_:)` for lookups.
    private static let english: Set<String> = [
        // Titles
        "mr.", "mrs.", "ms.", "miss.", "dr.", "prof.", "sr.", "jr.", "st.",
        "rev.", "hon.", "capt.", "lt.", "sgt.", "pres.", "rep.", "sen.",
        "gov.", "esq.",
        // Academic
        "ph.d.", "b.a.", "m.a.", "m.s.", "b.s.", "m.d.",
        // Business
        "inc.", "ltd.", "co.", "corp.", "llc",
        // Latin
        "vs.", "etc.", "e.g.", "i.e.", "cf.", "ca.", "approx.",
        // Time
        "a.m.", "p.m.",
        // Geo
        "u.s.", "u.k.", "u.a.e.",
        // Months
        "jan.", "feb.", "mar.", "apr.", "jun.", "jul.", "aug.", "sep.",
        "sept.", "oct.", "nov.", "dec.",
        // Weekdays
        "mon.", "tue.", "tues.", "wed.", "thu.", "thur.", "fri.", "sat.",
        "sun.",
    ]

    /// Returns `true` if `token` (after lowercasing and trimming trailing
    /// whitespace) is a known abbreviation that should suppress
    /// auto-capitalization.
    static func contains(_ token: String) -> Bool {
        english.contains(token.lowercased().trimmingTrailingWhitespace())
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        String(reversed().drop(while: { $0.isWhitespace }).reversed())
    }
}
