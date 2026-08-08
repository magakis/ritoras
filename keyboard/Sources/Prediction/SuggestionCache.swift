import Foundation

// MARK: - Context Hash

/// FNV-1a 64-bit hashing for context tokens.
/// Fully deterministic across processes (unlike `Hasher` which seeds per-process).
enum ContextHash {

    /// Computes the FNV-1a 64-bit hash of the given UTF-8 string.
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

// MARK: - Suggestion Display Cache

/// Caches the displayed suggestion array together with a context token
/// so that a tap closure can detect stale reads caused by rapid typing.
struct SuggestionDisplayCache {

    private(set) var displayed: [String] = []
    private(set) var token: UInt64 = 0

    /// Stores a snapshot of the suggestions + the context token at display time.
    mutating func update(_ suggestions: [String], token: UInt64) {
        self.displayed = suggestions
        self.token = token
    }

    /// Returns the suggestion at `index` if the cache is still valid.
    ///
    /// A cache is valid when:
    ///   - `index` is in range, AND
    ///   - `liveToken` matches the stored `token`, OR stored `token == 0`
    ///     (the backward-compat escape hatch — disables stale-check).
    ///
    /// - Returns: The cached suggestion string, or `nil` if stale / out of range.
    func suggestion(at index: Int, matchingLiveToken liveToken: UInt64) -> String? {
        guard index >= 0, index < displayed.count else { return nil }
        // Token == 0 disables the stale-check entirely (backward-compat escape hatch).
        if token != 0, token != liveToken { return nil }
        return displayed[index]
    }
}

// MARK: - Merged Pool LRU Cache

/// Thread-safe 3-entry LRU cache for the merged provider pool.
///
/// Keyed by an FNV-1a hash of the four-word context
/// `(currentWord, lookupWord, previousWord, previousWord2)`. Stores the raw
/// `[Suggestion]` array returned by `mergedPool()` — the cached value does
/// NOT include KenLM re-scoring or dedup, which still run on every
/// `suggestions()` call.
///
/// `PredictionEngine` is a non-isolated `final class` called concurrently
/// from the `suggestionLookupQueue` and from the main thread (the synchronous
/// autocorrect path). `@unchecked Sendable` + internal `NSLock` provides safe
/// cross-thread access without an actor hop (which would serialize the hot path).
final class MergedPoolLRU: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt64: [Suggestion]] = [:]
    private var order: [UInt64] = []
    private let capacity = 3

    /// Returns the cached pool for `key`, or nil on miss.
    /// On hit, promotes `key` to the most-recently-used position.
    func get(_ key: UInt64) -> [Suggestion]? {
        lock.lock(); defer { lock.unlock() }
        guard let value = entries[key] else { return nil }
        // Promote to MRU
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    /// Stores `value` for `key`. Evicts the least-recently-used entry when
    /// the cache exceeds capacity. Re-inserting an existing key promotes it
    /// to the most-recently-used position.
    func set(_ key: UInt64, _ value: [Suggestion]) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] != nil {
            // Update existing — promote to MRU
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
            }
            entries[key] = value
            order.append(key)
            return
        }
        // Evict LRU when at capacity
        if order.count >= capacity {
            let lru = order.removeFirst()
            entries.removeValue(forKey: lru)
        }
        entries[key] = value
        order.append(key)
    }
}

// MARK: - Pure Decision Function

/// Pure function: the single entry point for the suggestion-tap closure.
/// No UIKit dependencies — fully testable.
///
/// - Returns: The suggestion string if the cache is valid, or `nil` if stale.
func decideSuggestionTap(cache: SuggestionDisplayCache, liveToken: UInt64, index: Int) -> String? {
    cache.suggestion(at: index, matchingLiveToken: liveToken)
}

/// Pure function: decides whether a background-computed suggestion result
/// should be applied to the suggestion bar, based on whether the token
/// captured at lookup-start still matches the live token at lookup-complete.
/// A non-zero captured token that mismatches the live token means the user
/// typed more while the lookup was in flight → drop the stale result.
/// `capturedToken == 0` disables the guard (backward-compat escape hatch,
/// same convention as `SuggestionDisplayCache.suggestion(at:matchingLiveToken:)`).
func shouldApplyLookupResult(capturedToken: UInt64, liveToken: UInt64) -> Bool {
    if capturedToken == 0 { return true }
    return capturedToken == liveToken
}
