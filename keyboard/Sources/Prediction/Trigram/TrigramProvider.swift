import Foundation
import os

/// Predicts the next word using a 3-gram KenLM model with a pre-computed
/// side index of top-N followers.
///
/// **State machine**: `.cold → .loading → .ready | .failed`
/// - `.cold`: no load attempted yet. `suggest(...)` returns `[]`.
/// - `.loading`: load is in progress (triggered by `warmup()` or first
///   `suggest(...)` call).
/// - `.ready`: KenLM model + side index are loaded and usable.
/// - `.failed`: load failed (resource not found or corrupt). Permanent for
///   the session — no retry.
///
/// All state transitions are logged via `FileLogger` under the `.prediction`
/// component, once per session.
///
/// **Thread safety**: `state` is protected by `os_unfair_lock`. All state
/// transitions and reads happen under the lock.
final class TrigramProvider: SuggestionProvider {

    // MARK: - Constants

    /// ln(10) — converts log10 differences to natural-log domain for exp().
    private static let ln10 = log(10.0)

    /// Tracks whether we have logged the first successful suggestion (one-time
    /// diagnostic to confirm the end-to-end trigram → unigram path works).
    private static var hasLoggedFirstSuggestion = false

    // MARK: - State

    enum LoadState {
        case cold
        case loading
        case ready
        case failed
    }

    private var _state: LoadState = .cold
    private var _model: kenlm_model_t?
    private var _sideIndex: SideIndex?
    private var lock = os_unfair_lock()

    private let loadQueue = DispatchQueue(label: "com.ritoras.trigram.load", qos: .utility)

    private static let modelName = "trigram_en_v1"
    private static let modelExtension = "klm"

    // MARK: - Thread-Safe Accessors

    private func mutateState(_ block: (inout LoadState, inout kenlm_model_t?, inout SideIndex?) -> Void) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        block(&_state, &_model, &_sideIndex)
    }

    private func readState<Result>(_ block: (LoadState, kenlm_model_t?, SideIndex?) -> Result) -> Result {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return block(_state, _model, _sideIndex)
    }

    // MARK: - Loading

    /// Public API to explicitly start loading the KenLM model and side index
    /// on a background queue. Idempotent: subsequent calls are no-ops if
    /// state is not `.cold`. Logs state transitions.
    ///
    /// - Parameter completion: Called with `true` on `.ready`, `false` otherwise.
    ///                         Called on the main queue.
    func warmup(completion: ((Bool) -> Void)? = nil) {
        let currentState = readState { state, _, _ in state }
        guard currentState == .cold else {
            let ready = isReady
            DispatchQueue.main.async { completion?(ready) }
            return
        }

        mutateState { state, _, _ in
            state = .loading
        }
        FileLogger.shared.warn(.prediction, "trigram load started")
        performLoad(completion: completion)
    }

    /// Starts loading the KenLM model and side index on a background queue.
    /// Lazy-load trigger: called from `suggest(...)` when state is `.cold`.
    /// Logs state transitions.
    func loadAsync() {
        let currentState = readState { state, _, _ in state }
        guard currentState == .cold else { return }

        mutateState { state, _, _ in
            state = .loading
        }
        FileLogger.shared.warn(.prediction, "trigram load started")
        performLoad()
    }

    /// Shared loading implementation. Runs on `loadQueue`.
    /// Double-checks state is still `.loading` before doing work (prevents
    /// duplicate loads when both `loadAsync()` and `warmup()` race).
    private func performLoad(completion: ((Bool) -> Void)? = nil) {
        loadQueue.async { [weak self] in
            guard let self = self else { return }

            // Double-check: skip if already .ready or .failed (e.g. from
            // a concurrent call that completed first).
            let shouldLoad = self.readState { state, _, _ in state == .loading }
            guard shouldLoad else {
                DispatchQueue.main.async { completion?(self.isReady) }
                return
            }

            // Load side index (quick — ~320 KB JSON).
            let sideIndex = SideIndex()

            // Load KenLM model.
            guard let url = Bundle.main.url(forResource: Self.modelName,
                                            withExtension: Self.modelExtension) else {
                self.mutateState { state, model, _ in
                    model = nil
                    state = .failed
                }
                FileLogger.shared.warn(.prediction, "trigram load failed: model file not found")
                DispatchQueue.main.async { completion?(false) }
                return
            }

            let model = kenlm_load(url.path)

            self.mutateState { state, storedModel, storedIndex in
                if let m = model, let si = sideIndex {
                    storedModel = m
                    storedIndex = si
                    state = .ready
                } else {
                    // Free the model if it loaded but side index didn't.
                    if let m = model { kenlm_free(m) }
                    storedModel = nil
                    storedIndex = nil
                    state = .failed
                }
            }

            let isReady = self.isReady
            if isReady {
                let vocabSize = self.readState { _, model, _ in
                    model.map { kenlm_vocab_size($0) } ?? 0
                }
                FileLogger.shared.warn(.prediction, "trigram ready (vocab=\(vocabSize))")
            } else {
                let reason: String
                if model == nil { reason = "kenlm_load returned nil" }
                else if sideIndex == nil { reason = "side index load failed" }
                else { reason = "unknown" }
                FileLogger.shared.warn(.prediction, "trigram load failed: \(reason)")
            }

            DispatchQueue.main.async { completion?(isReady) }
        }
    }

    deinit {
        let modelToFree = readState { _, model, _ in model }
        if let m = modelToFree {
            kenlm_free(m)
        }
    }

    // MARK: - Re-rank Helper

    /// Returns the follower word set from the side index for the given bigram
    /// context. Used by `PredictionEngine` to re-rank candidates from other
    /// providers during mid-word typing.
    func followerWordSet(previousWord2: String?, previousWord: String?) -> Set<String>? {
        readState { state, _, index in
            guard state == .ready, let idx = index else { return nil }
            let followers = idx.followers(for: previousWord2, previousWord: previousWord)
            return followers.isEmpty ? nil : Set(followers)
        }
    }

    // MARK: - Helpers

    /// Returns the log10 probability of a word given a 2-word context, by
    /// calling the KenLM C bridge with a NULL-terminated array.
    private func scoreTrigram(prev2: String, prev1: String, candidate: String) -> Double {
        readState { state, model, _ in
            guard state == .ready, let m = model else { return 0.0 }

            // Build a NULL-terminated C string array: [prev2, prev1, candidate, nil]
            var cArgs: [UnsafePointer<CChar>?] = [
                (prev2 as NSString).utf8String,
                (prev1 as NSString).utf8String,
                (candidate as NSString).utf8String,
                nil
            ]

            return kenlm_score(m, &cArgs)
        }
    }

    // MARK: - SuggestionProvider

    var isReady: Bool {
        readState { state, _, _ in state == .ready }
    }

    func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion] {
        // Trigger lazy load on first call.
        let snapshot = readState { state, model, index in
            (state, model, index)
        }

        if snapshot.0 == .cold {
            loadAsync()
            return []
        }

        guard snapshot.0 == .ready,
              let model = snapshot.1,
              let index = snapshot.2 else {
            return []
        }

        guard let prev = context.previousWord?.lowercased(), !prev.isEmpty else {
            return []
        }

        // Try trigram context first (two preceding words)
        var prev2 = ""
        var followers: [String] = []
        if let p2 = context.previousWord2?.lowercased(), !p2.isEmpty {
            prev2 = p2
            followers = index.followers(for: prev2, previousWord: prev)
        }

        // Fall back to unigram context (one preceding word) if trigram missed
        // or no trigram context is available.
        if followers.isEmpty {
            followers = index.followersUnigram(for: prev)
        }

        guard !followers.isEmpty else { return [] }

        // One-time diagnostic: log the first successful suggestion context
        if !Self.hasLoggedFirstSuggestion {
            Self.hasLoggedFirstSuggestion = true
            let logPrev2 = context.previousWord2?.lowercased() ?? "(nil)"
            FileLogger.shared.warn(.prediction, "trigram first suggestion: \"\(logPrev2) \(prev)\" → \(followers.prefix(3))")
        }

        if context.lookupWord.isEmpty {
            // Empty-prefix case: score all followers (or up to a reasonable
            // limit) and return the top-N by trigram score.
            let scored = followers.map { word -> (String, Double) in
                let prob = scoreTrigram(prev2: prev2, prev1: prev, candidate: word)
                return (word, prob)
            }

            let maxProb = scored.map(\.1).max() ?? 0.0

            let sorted = scored.sorted { $0.1 > $1.1 }
            return sorted.prefix(limit).map { word, prob in
                let normalized: Double
                if maxProb >= 0 {
                    normalized = 1.0
                } else if maxProb < -20 {
                    normalized = max(SharedConfig.Defaults.trigramReadyMinScore, exp((prob - maxProb) * Self.ln10))
                } else {
                    normalized = max(SharedConfig.Defaults.trigramReadyMinScore,
                                     min(1.0, exp((prob - maxProb) * Self.ln10)))
                }
                return Suggestion(text: word, score: normalized, source: .trigram)
            }
        } else {
            // Mid-word case: filter followers by prefix, score each, apply
            // 0.5 multiplier (mirroring BigramPredictor's mid-word discount).
            let prefix = context.lookupWord.lowercased()
            let scored = followers
                .filter { $0.hasPrefix(prefix) }
                .map { word -> (String, Double) in
                    let prob = scoreTrigram(prev2: prev2, prev1: prev, candidate: word)
                    return (word, prob)
                }

            let maxProb = scored.map(\.1).max() ?? 0.0

            return scored
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { word, prob in
                    let normalized: Double
                    if maxProb >= 0 {
                        normalized = 1.0
                    } else if maxProb < -20 {
                        normalized = max(SharedConfig.Defaults.trigramReadyMinScore, exp((prob - maxProb) * Self.ln10))
                    } else {
                        normalized = max(SharedConfig.Defaults.trigramReadyMinScore,
                                         min(1.0, exp((prob - maxProb) * Self.ln10)))
                    }
                    return Suggestion(text: word, score: normalized * 0.5, source: .trigram)
                }
        }
    }
}
