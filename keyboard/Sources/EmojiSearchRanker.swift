import Foundation

// MARK: - EmojiSearchRanker

enum EmojiSearchRanker {

    /// Filters `entries` to those whose lowercased name/keywords match every
    /// space-split token of `query` (AND semantics — same match set as the
    /// existing keyboard search), then ranks them best-first by match strictness.
    /// Deterministic; stable tiebreak is the original input order of `entries`.
    static func rankedSearch(_ query: String, in entries: [EmojiEntry]) -> [EmojiEntry] {
        let lowerQuery = query.lowercased()
        let tokens = lowerQuery.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        // Single pass: enumerate, compute per-entry score, filter non-matching.
        let scored = entries.enumerated().compactMap { idx, entry -> (entry: EmojiEntry, minTier: Int, nameLength: Int, index: Int)? in
            let nameLower = entry.name.lowercased()
            let nameWords = nameLower.split(separator: " ").map(String.init)

            var minTier = Int.max
            for token in tokens {
                let t = tier(for: token, nameLower: nameLower, nameWords: nameWords, keywords: entry.keywords)
                guard t > 0 else { return nil }  // token didn't match → exclude entry
                if t < minTier { minTier = t }
            }

            return (entry, minTier, entry.name.count, idx)
        }

        // Sort: best tier first, then shorter name first, then original index first.
        return scored.sorted { a, b in
            if a.minTier != b.minTier { return a.minTier > b.minTier }
            if a.nameLength != b.nameLength { return a.nameLength < b.nameLength }
            return a.index < b.index
        }.map { $0.entry }
    }

    // MARK: - Per-Token Tier Computation

    /// Returns the best tier (6–1) for a single lowercased token against an entry,
    /// or 0 if the token does not match the entry at all.
    private static func tier(for token: String, nameLower: String, nameWords: [String], keywords: [String]) -> Int {
        // Tier 6: token exactly equals a whitespace-split word of entry.name
        if nameWords.contains(token) { return 6 }

        // Tier 5: entry.name hasPrefix(token)
        if nameLower.hasPrefix(token) { return 5 }

        // Tiers 4, 3, 1 via keywords
        var kwExact = false
        var kwPrefix = false
        var kwContains = false
        for kw in keywords {
            let kwLower = kw.lowercased()
            if kwLower == token { kwExact = true; break }
            if kwLower.hasPrefix(token) { kwPrefix = true }
            if kwLower.contains(token) { kwContains = true }
        }
        if kwExact { return 4 }
        if kwPrefix { return 3 }

        // Tier 2: entry.name contains token (non-prefix — prefix was already checked at tier 5)
        if nameLower.contains(token) { return 2 }

        // Tier 1: some keyword contains token
        if kwContains { return 1 }

        return 0
    }
}
