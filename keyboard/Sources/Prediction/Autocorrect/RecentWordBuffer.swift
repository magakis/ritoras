import Foundation

/// A record of a recently committed word eligible for retroactive autocorrect.
struct RecentWordRecord {
    /// The word as typed (punctuation-stripped, apostrophe-canonicalized) — the
    /// value the autocorrect decision runs against.
    let typedWord: String
    /// Where the word came from; only `.typing` records are re-evaluated.
    let origin: WordOrigin
    /// True once the word has been evaluated (corrected or intentionally left
    /// alone) — it is never re-scanned.
    var evaluatedAndSkipped: Bool
    /// The ~50 characters of document context immediately preceding this word,
    /// captured at commit time for re-validation at apply time.
    let commitContextSuffix: String
}

/// Bounded ring buffer of the most recently committed words.
///
/// Fixed capacity (4 entries, worst case well under 1 KB) so the keyboard's
/// 48 MB Jetsam budget is unaffected. Oldest entries are evicted first.
struct RecentWordBuffer {

    /// Ring storage, oldest → newest.
    private var entries: [RecentWordRecord] = []
    private let capacity = 4

    init() {}

    /// Appends a record, evicting the oldest entry when the buffer is full.
    mutating func append(_ record: RecentWordRecord) {
        if entries.count == capacity {
            entries.removeFirst()
        }
        entries.append(record)
    }

    /// Removes all records.
    mutating func clear() {
        entries.removeAll()
    }

    /// Marks the first not-yet-evaluated record whose `typedWord` matches as
    /// evaluated. Identity-based so callers never need to track ring indices
    /// across evictions; calling it once per candidate handles duplicate
    /// `typedWord`s correctly. No-op when no match exists.
    mutating func markEvaluated(typedWord: String) {
        guard let index = entries.firstIndex(where: { $0.typedWord == typedWord && !$0.evaluatedAndSkipped }) else { return }
        entries[index].evaluatedAndSkipped = true
    }

    /// Records still eligible for a retroactive autocorrect pass: user-typed
    /// origin, not yet evaluated, and within the autocorrect length bounds.
    var candidates: [RecentWordRecord] {
        entries.filter { record in
            record.origin == .typing
                && !record.evaluatedAndSkipped
                && record.typedWord.count >= SharedConfig.Defaults.autocorrectMinWordLength
                && record.typedWord.count <= SharedConfig.Defaults.autocorrectMaxWordLength
        }
    }
}
