import Foundation

enum RecentWordVerdict: UInt8, Equatable, Sendable {
    case notEvaluated
    case pending
    case evaluatedAndRejected
    case evaluatedAndApplied
}

/// A record of a recently committed word eligible for retroactive autocorrect.
struct RecentWordRecord {
    /// The word as typed (punctuation-stripped, apostrophe-canonicalized) — the
    /// value the autocorrect decision runs against.
    let typedWord: String
    /// Where the word came from; only `.typing` records are re-evaluated.
    let origin: WordOrigin
    /// True once the retroactive scan has consumed this record; separate from
    /// the inline verdict below.
    var evaluatedAndSkipped: Bool
    /// Inline evaluation status; only `.notEvaluated` records are retro-eligible.
    var verdict: RecentWordVerdict
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

    /// Marks a retro-eligible record as consumed by the scan. The context suffix
    /// disambiguates repeated words without storing a ring index in async work.
    mutating func markEvaluated(typedWord: String, commitContextSuffix: String) {
        guard let index = entries.lastIndex(where: {
            $0.typedWord == typedWord
                && $0.commitContextSuffix == commitContextSuffix
                && !$0.evaluatedAndSkipped
                && $0.verdict == .notEvaluated
        }) else { return }
        entries[index].evaluatedAndSkipped = true
    }

    /// Records the result of an inline evaluation for the matching scheduled entry.
    /// Only whitelisted evaluation rejections and landed corrections settle it.
    mutating func recordInlineEvaluation(
        typedWord: String,
        commitContextSuffix: String,
        decision: AutocorrectController.Decision,
        settledRejection: Bool,
        correctionApplied: Bool
    ) {
        let verdict: RecentWordVerdict
        switch decision {
        case .leaveAsIs:
            verdict = settledRejection ? .evaluatedAndRejected : .notEvaluated
        case .correct(_, _):
            verdict = correctionApplied ? .evaluatedAndApplied : .notEvaluated
        }
        updatePendingRecord(
            typedWord: typedWord,
            commitContextSuffix: commitContextSuffix,
            verdict: verdict
        )
    }

    /// Re-opens a scheduled entry when its compute aborts before evaluation.
    mutating func markInlineEvaluationAborted(typedWord: String, commitContextSuffix: String) {
        updatePendingRecord(
            typedWord: typedWord,
            commitContextSuffix: commitContextSuffix,
            verdict: .notEvaluated
        )
    }

    private mutating func updatePendingRecord(
        typedWord: String,
        commitContextSuffix: String,
        verdict: RecentWordVerdict
    ) {
        guard let index = entries.lastIndex(where: {
            $0.typedWord == typedWord
                && $0.commitContextSuffix == commitContextSuffix
                && $0.verdict == .pending
        }) else { return }
        entries[index].verdict = verdict
    }

    /// Records still eligible for a retroactive autocorrect pass: user-typed
    /// origin, no inline verdict yet, not already retro-scanned, and within the
    /// autocorrect length bounds.
    var candidates: [RecentWordRecord] {
        entries.filter { record in
            record.origin == .typing
                && !record.evaluatedAndSkipped
                && record.verdict == .notEvaluated
                && record.typedWord.count >= SharedConfig.Defaults.autocorrectMinWordLength
                && record.typedWord.count <= SharedConfig.Defaults.autocorrectMaxWordLength
        }
    }
}
