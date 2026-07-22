import Foundation

/// Loads the pre-computed top-N followers JSON for trigram queries.
///
/// The side index maps `"previousWord2 previousWord"` bigram keys to an ordered
/// array of up to 20 follower words. This allows TrigramProvider to narrow the
/// candidate set without scanning the entire KenLM vocabulary.
struct SideIndex {
    private let entries: [String: [String]]
    let isLoaded: Bool

    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "trigram_side_index_v1", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return nil
        }
        self.entries = decoded
        self.isLoaded = true
    }

    func followers(for previousWord2: String?, previousWord: String?) -> [String] {
        guard let prev2 = previousWord2, let prev1 = previousWord else { return [] }
        return entries["\(prev2.lowercased()) \(prev1.lowercased())"] ?? []
    }

    /// Returns followers for a single previous word (bigram fallback when trigram
    /// context is unavailable or misses). Looks up the lowercased word directly
    /// in the side index, which now contains unigram entries alongside bigrams.
    func followersUnigram(for previousWord: String) -> [String] {
        return entries[previousWord.lowercased()] ?? []
    }
}
