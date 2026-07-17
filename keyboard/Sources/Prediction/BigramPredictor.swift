import Foundation
import os

/// Predicts the next word using a bigram frequency dictionary.
///
/// Loads `frequency_bigramdictionary_en_243_342.txt` lazily on a background
/// queue with configurable pruning. Provides top-N follower suggestions when
/// the cursor is after whitespace, and prefix-filtered re-rank signals when a
/// word is being typed.
///
/// **Thread safety**: `isReady` and `bigrams` are protected by `os_unfair_lock`
/// to ensure that a write on the load queue is fully visible before any read
/// on the main queue (`suggest` is called from `keyboardViewNeedsSuggestions`,
/// which is main-thread only).
final class BigramPredictor: SuggestionProvider {

    // MARK: - State

    private var _bigrams: [String: [(word: String, count: Int)]] = [:]
    private var _isReady = false
    private var lock = os_unfair_lock()

    private let loadQueue = DispatchQueue(label: "com.ritoras.bigram.load", qos: .utility)
    private let minCount: Int

    private static let resourceName = "frequency_bigramdictionary_en_243_342"
    private static let resourceExtension = "txt"

    // MARK: - Init

    init(minCount: Int = SharedConfig.Defaults.bigramMinCount) {
        self.minCount = minCount
    }

    // MARK: - Thread-Safe Accessors

    /// Atomically sets both `isReady` and `bigrams` under the lock.
    private func setReady(_ value: Bool, bigrams: [String: [(word: String, count: Int)]]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        _isReady = value
        _bigrams = bigrams
    }

    /// Atomically reads both `isReady` and `bigrams` under the lock.
    private func getReadyAndBigrams() -> (Bool, [String: [(word: String, count: Int)]]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (_isReady, _bigrams)
    }

    // MARK: - Loading

    /// Starts loading the bigram dictionary on a background queue.
    /// `completion` is called on the main queue when finished.
    func loadAsync(completion: @escaping () -> Void = {}) {
        loadQueue.async { [weak self] in
            guard let self = self else { return }
            self.loadSync()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// Parses an array of lines into the bigram map. The canonical format is
    /// `word1 word2 count` per line. Lines that do not match are skipped.
    ///
    /// This is `internal` so tests can inject synthetic data without requiring
    /// the on-disk resource.
    func loadFromLines(_ lines: [String]) {
        var raw: [String: [(word: String, count: Int)]] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: .whitespaces)
            guard parts.count >= 3 else { continue }

            let word1 = parts[0].lowercased()
            let word2 = parts[1].lowercased()
            guard let count = Int(parts[2]), count >= minCount else { continue }

            raw[word1, default: []].append((word: word2, count: count))
        }

        // Sort each follower list by count descending for O(1) top-N.
        for (key, followers) in raw {
            raw[key] = followers.sorted { $0.count > $1.count }
        }

        setReady(true, bigrams: raw)
    }

    /// Synchronous load from the bundled resource file.
    private func loadSync() {
        guard let url = Bundle.main.url(forResource: Self.resourceName,
                                        withExtension: Self.resourceExtension) else {
            return
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        loadFromLines(content.components(separatedBy: .newlines))
    }

    // MARK: - Re-rank Helper

    /// Returns a set of the top-20 follower words for a given `previousWord`.
    /// Used by `PredictionEngine` to re-rank candidates from other providers.
    func followerWordSet(for previousWord: String) -> Set<String>? {
        let (ready, map) = getReadyAndBigrams()
        guard ready else { return nil }
        guard let followers = map[previousWord.lowercased()] else { return nil }
        let topWords = followers.prefix(20).map { $0.word }
        return Set(topWords)
    }

    // MARK: - SuggestionProvider

    func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion] {
        let (ready, map) = getReadyAndBigrams()
        guard ready else { return [] }
        guard let prev = context.previousWord?.lowercased(), !prev.isEmpty else {
            return []
        }
        guard let followers = map[prev] else { return [] }

        let maxCount = Double(followers.first?.count ?? 1)

        if context.lookupWord.isEmpty {
            // Empty-prefix case: top N followers as primary suggestions.
            return followers.prefix(limit).map {
                Suggestion(
                    text: $0.word,
                    score: Double($0.count) / maxCount,
                    source: .bigram
                )
            }
        } else {
            // Mid-word case: followers that start with lookupWord — re-rank signal.
            let prefix = context.lookupWord.lowercased()
            return followers
                .filter { $0.word.hasPrefix(prefix) }
                .prefix(limit)
                .map {
                    Suggestion(
                        text: $0.word,
                        score: (Double($0.count) / maxCount) * 0.5,
                        source: .bigram
                    )
                }
        }
    }
}
