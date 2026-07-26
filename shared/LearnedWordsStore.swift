import Foundation
import UIKit

/// Persists user-accepted corrections to App Group UserDefaults and mirrors
/// them to `UITextChecker` for the current process lifetime.
///
/// Threading: all public methods are designed to be called from the main
/// thread only (KeyboardViewController methods run on the main queue).
final class LearnedWordsStore {

    // MARK: - Shared Instance

    static let shared = LearnedWordsStore()

    // MARK: - State

    private let defaults: UserDefaults
    private let storeKey = "learnedWords"
    private static let maxLearnedWords = 1000
    private var cache: Set<String>
    private var insertionOrder: [String] = []

    // MARK: - Init

    private init() {
        // Fall back to standard UserDefaults when the app group suite is
        // unavailable (e.g. in the test bundle without the host app).
        self.defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
            ?? UserDefaults.standard

        if let stored = defaults.array(forKey: storeKey) as? [String] {
            // The persisted array is in insertion order (written by
            // persist()). During migration from the old unbounded version
            // the order is arbitrary; suffix simply keeps the first N for
            // the cap. Either way, trimming is safe — the cap holds and
            // subsequent persist() calls will write ordered data.
            let trimmed = stored.count > Self.maxLearnedWords
                ? Array(stored.suffix(Self.maxLearnedWords))
                : stored
            self.cache = Set(trimmed)
            self.insertionOrder = trimmed
        } else {
            self.cache = []
            self.insertionOrder = []
        }

        // Re-register every persisted word with UITextChecker — learned words
        // are process-local and reset when the keyboard extension is terminated.
        for word in cache {
            UITextChecker.learnWord(word)
        }
    }

    // MARK: - Persistence

    /// Writes the current cache to UserDefaults, synchronizes, and verifies
    /// the write succeeded by reading back. Logs an error on failure.
    ///
    /// `synchronize()` is deprecated on modern iOS but is used defensively
    /// here because in keyboard extension contexts (App Group containers),
    /// it can surface write failures that would otherwise be silently lost.
    private func persist() {
        defaults.set(insertionOrder, forKey: storeKey)
    }

    // MARK: - Public API

    /// Adds a word to the learned-words store.
    ///
    /// The word is lowercased for deduplication. Persisted to App Group
    /// UserDefaults (write-through) and mirrored to `UITextChecker.learnWord(_:)`
    /// so the system spell checker stops flagging it for the current session.
    func add(_ word: String) {
        let lower = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return }
        if cache.contains(lower) { return }

        cache.insert(lower)
        insertionOrder.append(lower)

        if cache.count > Self.maxLearnedWords {
            let oldest = insertionOrder.removeFirst()
            cache.remove(oldest)
        }

        persist()
        UITextChecker.learnWord(lower)
    }

    /// Returns `true` when the word has been learned (case-insensitive).
    func contains(_ word: String) -> Bool {
        return cache.contains(word.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// Returns all learned words in sorted order.
    func allWords() -> [String] {
        return Array(cache).sorted()
    }

    /// Returns all learned words in most-recently-added-first order.
    ///
    /// Backed by `insertionOrder.reversed()`. The first element is the word
    /// added most recently; the last is the oldest still resident (subject to
    /// the 1000-word cap, which evicts the oldest on overflow — see `add(_:)`).
    /// Words are lowercased (the store normalizes on add), matching `allWords()`.
    func allWordsMostRecentFirst() -> [String] {
        return insertionOrder.reversed()
    }

    /// Removes all learned words from the local store and UserDefaults.
    /// Does NOT unlearn from `UITextChecker` (no bulk-unlearn API exists);
    /// the system-resident learned words will be forgotten when the keyboard
    /// extension process is terminated naturally.
    func clear() {
        cache.removeAll()
        insertionOrder.removeAll()
        defaults.removeObject(forKey: storeKey)
    }

    /// Removes a single word from the learned-words store.
    ///
    /// Persists immediately. Note: `UITextChecker` exposes no single-word
    /// unlearn API, so the system-resident learned word persists until the
    /// keyboard process terminates — same caveat as `clear()`.
    func remove(_ word: String) {
        let lower = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard cache.contains(lower) else { return }
        cache.remove(lower)
        insertionOrder.removeAll { $0 == lower }
        persist()
    }

    /// Re-reads the persisted word list from App Group UserDefaults into the
    /// in-memory cache. Use when this process may have been outlived by
    /// writes from the other process (e.g. the container app refreshing its
    /// dictionary view to show words the keyboard recently learned).
    ///
    /// Does NOT re-register words with `UITextChecker` (unlike `init`). Today
    /// only the container app calls this, and the app never queries
    /// `UITextChecker` — so the omission is harmless. A future keyboard-side
    /// caller would desync the store's `cache` (used for `isLearned` in the
    /// autocorrect path) from `UITextChecker`'s resident state (used for
    /// `isMisspelled`). Do not call this from the keyboard process without
    /// also re-registering with `UITextChecker.learnWord`.
    ///
    /// Main-thread-only (same threading contract as the rest of this class).
    func reload() {
        if let stored = defaults.array(forKey: storeKey) as? [String] {
            let trimmed = stored.count > Self.maxLearnedWords
                ? Array(stored.suffix(Self.maxLearnedWords))
                : stored
            cache = Set(trimmed)
            insertionOrder = trimmed
        } else {
            cache = []
            insertionOrder = []
        }
    }
}
