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
    private var cache: Set<String>

    // MARK: - Init

    private init() {
        // Fall back to standard UserDefaults when the app group suite is
        // unavailable (e.g. in the test bundle without the host app).
        self.defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
            ?? UserDefaults.standard

        if let stored = defaults.array(forKey: storeKey) as? [String] {
            self.cache = Set(stored)
        } else {
            self.cache = []
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
        let array = Array(cache)
        defaults.set(array, forKey: storeKey)
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

    /// Removes all learned words from the local store and UserDefaults.
    /// Does NOT unlearn from `UITextChecker` (no bulk-unlearn API exists);
    /// the system-resident learned words will be forgotten when the keyboard
    /// extension process is terminated naturally.
    func clear() {
        cache.removeAll()
        defaults.removeObject(forKey: storeKey)
    }
}
