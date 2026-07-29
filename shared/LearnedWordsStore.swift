import Foundation
import UIKit

/// Snapshot payload exchanged via the named pasteboard.
///
/// The pasteboard holds the authoritative versioned set. Each writer
/// read-modify-writes the full set with `version+1`. Readers adopt on
/// `version > localVersion`.
///
/// Accepted limitation: a rare simultaneous (keyboard-add ‖ app-delete-
/// of-different-word) race can drop the keyboard's add until the next
/// mutation re-includes it — vanishingly rare for a personal dictionary,
/// and self-healing on the next mutation.
struct LearnedWordsSnapshot: Codable {
    var version: Int
    var words: [String]
}

/// Persists user-accepted corrections and syncs them across processes
/// via a named pasteboard + Darwin notification.
///
/// Layers (bottom to top):
///   1. Per-process cache in `UserDefaults.standard` — synchronous local
///      source for `contains()`/prediction/autocorrect. Always available.
///   2. Named pasteboard `com.ritoras.learnedWordsSync` — durable
///      cross-process blackboard. Holds the authoritative versioned set.
///   3. Darwin notification `com.ritoras.learnedWordsChanged` — push
///      signal for live refresh.
///
/// Threading: all public methods are designed to be called from the main
/// thread only (KeyboardViewController methods run on the main queue).
/// `absorbRemoteSnapshot()` and the Darwin callback dispatch to main.
final class LearnedWordsStore {

    // MARK: - Shared Instance

    static let shared = LearnedWordsStore()

    // MARK: - State

    private let storeKey = "learnedWords"
    private let versionKey = "learnedWordsVersion"
    private static let maxLearnedWords = 1000
    private let lock = NSLock()
    private var cache: Set<String>
    private var insertionOrder: [String] = []
    /// Local version tracking. Persisted alongside the word array so we
    /// can detect when the pasteboard holds a newer snapshot.
    private var localVersion: Int = 0

    // MARK: - Init

    private init() {
        // Load local cache from UserDefaults.standard (per-process, always
        // available — no app-group dependency, works under SideStore).
        if let stored = UserDefaults.standard.array(forKey: storeKey) as? [String] {
            let trimmed = stored.count > Self.maxLearnedWords
                ? Array(stored.suffix(Self.maxLearnedWords))
                : stored
            let canonicalized = trimmed.map { ApostropheNormalizer.canonicalize($0) }
            self.cache = Set(canonicalized)
            self.insertionOrder = canonicalized
        } else {
            self.cache = []
            self.insertionOrder = []
        }

        self.localVersion = UserDefaults.standard.integer(forKey: versionKey)

        // Absorb any newer snapshot from the pasteboard (cross-process sync).
        absorbRemoteSnapshot()

        // Re-register every persisted word with UITextChecker — learned words
        // are process-local and reset when the keyboard extension is terminated.
        for word in cache {
            UITextChecker.learnWord(word)
        }
    }

    // MARK: - Pasteboard Sync

    /// Returns the shared named pasteboard (created if it doesn't exist).
    /// Named pasteboards are visible across processes within the same team
    /// ID, never touch the user's general clipboard, and trigger no paste banner.
    /// The custom pasteboard type (not a standard UTI) keeps it off Universal
    /// Clipboard as well.
    private var syncPasteboard: UIPasteboard? {
        UIPasteboard(
            name: UIPasteboard.Name(SharedConfig.Defaults.learnedWordsPasteboardName),
            create: true
        )
    }

    /// Publishes the current in-memory state to the named pasteboard as the
    /// authoritative versioned set. Increments the version from the highest
    /// known (remote or local). Posts a Darwin notification so the other
    /// process can absorb immediately.
    ///
    /// Read-modify-write race window is accepted (see the limitation
    /// documented on `LearnedWordsSnapshot`).
    /// Caller MUST hold `lock`.
    private func publish() {
        // Read current pasteboard snapshot to determine remote version.
        var remoteVersion = 0
        if let data = syncPasteboard?.data(forPasteboardType: SharedConfig.Defaults.learnedWordsPasteboardType),
           let snapshot = try? JSONDecoder().decode(LearnedWordsSnapshot.self, from: data) {
            remoteVersion = snapshot.version
        }

        // Our current state is authoritative — write the full set.
        let newVersion = max(remoteVersion, localVersion) + 1
        let snapshot = LearnedWordsSnapshot(version: newVersion, words: insertionOrder)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        syncPasteboard?.setData(data, forPasteboardType: SharedConfig.Defaults.learnedWordsPasteboardType)
        localVersion = newVersion
        UserDefaults.standard.set(localVersion, forKey: versionKey)

        // Notify the other process.
        DarwinNotifier.post(SharedConfig.Defaults.darwinLearnedWordsChangedNotificationName)
    }

    /// Reads the pasteboard snapshot. If `snapshot.version > localVersion`,
    /// adopts `snapshot.words` as the new authoritative set (replace, not
    /// union — so app-side deletes propagate).
    ///
    /// Safe to call from the main thread (all call sites are main-thread).
    /// Darwin callbacks must dispatch to main before calling this.
    func absorbRemoteSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = syncPasteboard?.data(forPasteboardType: SharedConfig.Defaults.learnedWordsPasteboardType),
              let snapshot = try? JSONDecoder().decode(LearnedWordsSnapshot.self, from: data) else {
            return
        }

        guard snapshot.version > localVersion else { return }

        // Diff the old cache vs the new for UITextChecker registration.
        let oldCache = cache

        // Authoritative replace.
        let trimmed = snapshot.words.count > Self.maxLearnedWords
            ? Array(snapshot.words.suffix(Self.maxLearnedWords))
            : snapshot.words
        let canonicalized = trimmed.map { ApostropheNormalizer.canonicalize($0) }
        cache = Set(canonicalized)
        insertionOrder = canonicalized
        localVersion = snapshot.version

        // Persist locally.
        UserDefaults.standard.set(insertionOrder, forKey: storeKey)
        UserDefaults.standard.set(localVersion, forKey: versionKey)

        // Register ONLY newly-seen words with UITextChecker (perf: avoid
        // re-registering all 1000 words under the 48 MB Jetsam cap).
        let newWords = cache.subtracting(oldCache)
        for word in newWords {
            UITextChecker.learnWord(word)
        }
    }

    // MARK: - Persistence

    /// Writes the current insertionOrder to UserDefaults.standard.
    /// Synchronize is deprecated but used defensively — see original code.
    /// Caller MUST hold `lock`.
    private func persist() {
        UserDefaults.standard.set(insertionOrder, forKey: storeKey)
    }

    // MARK: - Public API

    /// Adds a word to the learned-words store.
    ///
    /// The word is lowercased for deduplication. Persisted locally and
    /// published to the cross-process pasteboard. Mirrored to
    /// `UITextChecker.learnWord(_:)` so the system spell checker stops
    /// flagging it for the current session.
    func add(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        let lower = ApostropheNormalizer.canonicalize(word.lowercased().trimmingCharacters(in: .whitespaces))
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
        publish()
    }

    /// Returns `true` when the word has been learned (case-insensitive, canonicalized).
    func contains(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache.contains(ApostropheNormalizer.canonicalize(word.lowercased().trimmingCharacters(in: .whitespaces)))
    }

    /// Returns all learned words in sorted order.
    func allWords() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cache).sorted()
    }

    /// Returns all learned words in most-recently-added-first order.
    ///
    /// Backed by `insertionOrder.reversed()`. The first element is the word
    /// added most recently; the last is the oldest still resident (subject to
    /// the 1000-word cap, which evicts the oldest on overflow — see `add(_:)`).
    /// Words are lowercased (the store normalizes on add), matching `allWords()`.
    func allWordsMostRecentFirst() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return insertionOrder.reversed()
    }

    /// Removes all learned words from the local store, UserDefaults, and
    /// the cross-process pasteboard. Does NOT unlearn from `UITextChecker`
    /// (no bulk-unlearn API exists); the system-resident learned words will
    /// be forgotten when the keyboard extension process is terminated naturally.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        insertionOrder.removeAll()
        UserDefaults.standard.removeObject(forKey: storeKey)
        publish()
    }

    /// Removes a single word from the learned-words store.
    ///
    /// Persists and publishes immediately. Note: `UITextChecker` exposes no
    /// single-word unlearn API, so the system-resident learned word persists
    /// until the keyboard process terminates — same caveat as `clear()`.
    func remove(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        let lower = ApostropheNormalizer.canonicalize(word.lowercased().trimmingCharacters(in: .whitespaces))
        guard cache.contains(lower) else { return }
        cache.remove(lower)
        insertionOrder.removeAll { $0 == lower }
        persist()
        publish()
    }

    /// Re-reads the authoritative word list from the pasteboard (absorbing
    /// any newer snapshot), then falls back to the local cache.
    ///
    /// Call when this process may have been outlived by writes from the
    /// other process (e.g. the container app refreshing its dictionary view
    /// to show words the keyboard recently learned).
    ///
    /// Main-thread-only (same threading contract as the rest of this class).
    func reload() {
        absorbRemoteSnapshot()
    }
}
