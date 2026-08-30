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

    /// Minimum interval between load attempts after a deferred (memory-gated)
    /// trigram load. The throttle is a pure timestamp comparison at attempt
    /// time — no timers or scheduled work. Bounds the retry rate on the
    /// per-keystroke `suggest()` path while keeping recovery snappy once
    /// memory frees up.
    private static let deferredLoadRetryInterval: TimeInterval = 30.0

    /// One-time warn flag for the first deferred (memory-gated) trigram load
    /// in the process. Reset after a successful load so a future post-shed
    /// deferral warns once again. Touched only on `loadQueue` (serialized).
    private static var hasLoggedDeferralWarning = false

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
    /// Uptime (seconds) of the last deferred (memory-gated) load attempt.
    /// 0 = never deferred. Guarded by `lock`.
    private var _lastDeferredAttemptAt: TimeInterval = 0
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

    /// Whether a lazy load should start now: state is `.cold` AND the last
    /// deferred (memory-gated) attempt was ≥ `deferredLoadRetryInterval` ago.
    /// The throttle is a pure timestamp comparison — no timers, no scheduled work.
    private func shouldStartLazyLoad() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard _state == .cold else { return false }
        return ProcessInfo.processInfo.systemUptime - _lastDeferredAttemptAt >= Self.deferredLoadRetryInterval
    }

    /// Resets state to `.cold` and anchors the retry throttle after a deferred
    /// (memory-gated) load. Runs under the same lock as all state.
    private func markLoadDeferred() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        _state = .cold
        _lastDeferredAttemptAt = ProcessInfo.processInfo.systemUptime
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
        FileLogger.shared.info(.prediction, "trigram load started")
        performLoad(completion: completion)
    }

    /// Starts loading the KenLM model and side index on a background queue.
    /// Lazy-load trigger: called from `suggest(...)` when state is `.cold`.
    /// Logs state transitions.
    func loadAsync() {
        // Throttled: after a deferred (memory-gated) attempt, stay `.cold` and
        // skip re-attempting for `deferredLoadRetryInterval` seconds so the
        // per-keystroke suggest() path does not churn the load (or log) at all.
        guard shouldStartLazyLoad() else { return }

        mutateState { state, _, _ in
            state = .loading
        }
        FileLogger.shared.info(.prediction, "trigram load started")
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

            // Guard against Jetsam: skip trigram load if memory is already near the cap.
            // Uses the trigram-specific threshold (trigramMaxPhysFootprintDuringLoad).
            // The enforced ceiling on the extension is the ~48 MB Jetsam cap; the model
            // adds ~8-10 MB on top of the pre-load footprint, so the 38 MB gate keeps the
            // post-load peak at ≤ ~48 MB. A deferred load resets state to `.cold` so the
            // next suggest() retries — throttled to at most one attempt per 30 s
            // (deferredLoadRetryInterval) — and falls back to the SymSpell+Apple fusion
            // without the LM between attempts.
            let currentFootprint = MemoryMonitor.currentFootprint()
            if currentFootprint > SharedConfig.Defaults.trigramMaxPhysFootprintDuringLoad {
                if SharedConfig.Defaults.predictionDebugLoggingEnabled {
                    FileLogger.shared.debug(.prediction, "trigram load memory gate", payload: [
                        "footprint": currentFootprint,
                        "resident": MemoryMonitor.currentResidentSize(),
                        "limit": SharedConfig.Defaults.trigramMaxPhysFootprintDuringLoad,
                        "result": "deferred"
                    ])
                }
                self.markLoadDeferred()
                let message = "trigram load deferred: phys_footprint \(currentFootprint) > \(SharedConfig.Defaults.trigramMaxPhysFootprintDuringLoad)"
                if !Self.hasLoggedDeferralWarning {
                    Self.hasLoggedDeferralWarning = true
                    FileLogger.shared.warn(.prediction, message)
                } else {
                    FileLogger.shared.debug(.prediction, message)
                }
                DispatchQueue.main.async { completion?(false) }
                return
            }

            // Load side index (quick — ~320 KB JSON).
            let sideIndexStart = SharedConfig.Defaults.predictionDebugLoggingEnabled
                ? DispatchTime.now().uptimeNanoseconds : 0
            let sideIndex = SideIndex()
            if SharedConfig.Defaults.predictionDebugLoggingEnabled {
                FileLogger.shared.debug(.prediction, "trigram side index load complete", payload: [
                    "loaded": sideIndex != nil,
                    "elapsedMs": (DispatchTime.now().uptimeNanoseconds - sideIndexStart) / 1_000_000,
                    "footprint": MemoryMonitor.currentFootprint(),
                    "resident": MemoryMonitor.currentResidentSize()
                ])
            }

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

            let footprintBeforeLoad = MemoryMonitor.currentFootprint()
            let residentBeforeLoad = MemoryMonitor.currentResidentSize()
            let kenlmLoadStart = DispatchTime.now().uptimeNanoseconds
            let model = kenlm_load(url.path)
            let kenlmLoadElapsedMs = (DispatchTime.now().uptimeNanoseconds - kenlmLoadStart) / 1_000_000
            let footprintAfterLoad = MemoryMonitor.currentFootprint()
            let residentAfterLoad = MemoryMonitor.currentResidentSize()
            let loadMethod = model.map { kenlm_model_load_method($0) } ?? -1

            if SharedConfig.Defaults.predictionDebugLoggingEnabled {
                FileLogger.shared.debug(.prediction, "trigram KenLM LAZY load attempt", payload: [
                    "elapsedMs": kenlmLoadElapsedMs,
                    "loaded": model != nil,
                    "loadMethod": loadMethod,
                    "footprintBefore": footprintBeforeLoad,
                    "footprintAfter": footprintAfterLoad,
                    "residentBefore": residentBeforeLoad,
                    "residentAfter": residentAfterLoad
                ])
            }
            if loadMethod == 1 {
                FileLogger.shared.warn(.prediction, "trigram KenLM LAZY load fell back to read", payload: [
                    "loadMethod": loadMethod,
                    "elapsedMs": kenlmLoadElapsedMs
                ])
            }

            if let model {
                FileLogger.shared.info(.prediction, "trigram model loaded", payload: [
                    "loadMethod": loadMethod,
                    "footprintBefore": footprintBeforeLoad,
                    "footprintAfter": footprintAfterLoad,
                    "residentBefore": residentBeforeLoad,
                    "residentAfter": residentAfterLoad
                ])
            }

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
                // Reset the one-time deferral warn so a future post-shed
                // deferral warns once again.
                Self.hasLoggedDeferralWarning = false
                let vocabSize = self.readState { _, model, _ in
                    model.map { kenlm_vocab_size($0) } ?? 0
                }
                FileLogger.shared.info(.prediction, "trigram ready (vocab=\(vocabSize))")
            } else {
                let reason: String
                if model == nil { reason = "kenlm_load returned nil" }
                else if sideIndex == nil { reason = "side index load failed" }
                else { reason = "unknown" }
                FileLogger.shared.error(.prediction, "trigram load failed: \(reason)")
            }

            DispatchQueue.main.async { completion?(isReady) }
        }
    }

    /// Releases the KenLM model and side index to shed memory under pressure.
    /// Transitions state back to `.cold` so the next `suggest()` triggers a fresh lazy load.
    /// Safe to call from any thread. Frees ~8-10 MB of private dirty memory.
    func unload() {
        let diagnosticsEnabled = SharedConfig.Defaults.predictionDebugLoggingEnabled
        let footprintBefore = diagnosticsEnabled ? MemoryMonitor.currentFootprint() : 0
        let residentBefore = diagnosticsEnabled ? MemoryMonitor.currentResidentSize() : 0
        let hadModel: Bool
        if diagnosticsEnabled {
            hadModel = readState { _, model, _ in model != nil }
        } else {
            hadModel = false
        }
        mutateState { state, model, index in
            if let m = model {
                kenlm_free(m)
            }
            model = nil
            index = nil
            state = .cold
        }
        if diagnosticsEnabled {
            let footprintAfter = MemoryMonitor.currentFootprint()
            let residentAfter = MemoryMonitor.currentResidentSize()
            FileLogger.shared.debug(.prediction, "trigram unload complete", payload: [
                "hadModel": hadModel,
                "footprintBefore": footprintBefore,
                "footprintAfter": footprintAfter,
                "footprintFreed": footprintBefore > footprintAfter ? footprintBefore - footprintAfter : 0,
                "residentBefore": residentBefore,
                "residentAfter": residentAfter,
                "residentFreed": residentBefore > residentAfter ? residentBefore - residentAfter : 0
            ])
        }
        FileLogger.shared.warn(.prediction, "trigram unloaded (memory pressure)")
    }

    deinit {
        FileLogger.shared.info(.prediction, "TrigramProvider deinit")
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

    /// Returns the raw log10 probability of `candidate` given the preceding
    /// words. Useful for scoring arbitrary candidates (from SymSpell/Apple)
    /// against the language model without going through the side index.
    ///
    /// Returns nil if the provider is not `.ready` or if the candidate is empty.
    /// The returned value is a log10 probability (always negative, typically -2
    /// to -8).
    func rawLogProb(for candidate: String,
                    previousWord: String?,
                    previousWord2: String?) -> Double? {
        let snapshot = readState { state, model, _ in (state, model) }
        guard snapshot.0 == .ready, let model = snapshot.1 else { return nil }

        var sentence = ""
        if let prev2 = previousWord2?.lowercased(), !prev2.isEmpty {
            sentence += Self.normalizeForKenLM(prev2) + " "
        }
        if let prev1 = previousWord?.lowercased(), !prev1.isEmpty {
            sentence += Self.normalizeForKenLM(prev1) + " "
        }
        sentence += Self.normalizeForKenLM(candidate).lowercased()

        return sentence.withCString { ptr in
            kenlm_score_sentence(model, ptr)
        }
    }

    /// KenLM-specific apostrophe normalization: U+2019/U+2018 → U+0027.
    ///
    /// The shipped trigram model vocabulary is ASCII-only (e.g. "don't" with
    /// the straight apostrophe, zero curly-apostrophe tokens), while prediction
    /// candidates carry the display-canonical U+2019. Without this, every
    /// contraction scores as KenLM <unk> (large negative), which makes the
    /// ambiguous-contraction margin gate provably always-negative and degrades
    /// contraction ranking in fusedPool. Note the direction: the shared
    /// ApostropheNormalizer canonicalizes TOWARDS U+2019 (the display form) —
    /// this goes the opposite way for the KenLM lookup and so stays local here.
    private static func normalizeForKenLM(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\u{2019}" || ch == "\u{2018}" {
                out.append("\u{0027}")
            } else {
                out.append(ch)
            }
        }
        return out
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
            FileLogger.shared.debug(.prediction, "trigram first suggestion: \"\(logPrev2) \(prev)\" → \(followers.prefix(3))")
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
                return Suggestion(text: word, score: normalized, source: .trigram, isUnknownVerbatim: false)
            }
        } else {
            // Mid-word case: filter followers by prefix, score each.
            // Note: KenLM contextual blending for all candidates is handled in
            // PredictionEngine — no additional discount needed here.
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
                    return Suggestion(text: word, score: normalized, source: .trigram, isUnknownVerbatim: false)
                }
        }
    }
}
