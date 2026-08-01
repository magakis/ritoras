import Foundation

/// Process-global holder for the keyboard's prediction stack
/// (SymSpell + Trie + PredictionEngine + TrigramProvider).
///
/// iOS caches the keyboard extension process across show/hide cycles. Before
/// this holder existed, the VC shed the whole engine on hide and rebuilt a
/// fresh ~25 MB SymSpell on the next show; ARC could not reclaim the old
/// instance fast enough in the cached process, so `phys_footprint` climbed
/// each cycle until the load guard aborted the dictionary partway. This
/// singleton loads the stack EXACTLY ONCE per process lifetime and persists it
/// across show/hide cycles. Only the trigram model (~8-10 MB) remains
/// individually sheddable on memory warning; the dictionary + engine +
/// providers persist.
///
/// Thread safety: all state is serialized via an internal `NSLock`; the class
/// is `@unchecked Sendable` because it is touched from the build queue, the
/// main queue, and the suggestion lookup queue.
final class SharedPredictionStack: @unchecked Sendable {

    static let shared = SharedPredictionStack()

    // MARK: - State

    private enum LoadState {
        case cold
        case loading
        case ready
    }

    private let lock = NSLock()
    private var state: LoadState = .cold
    private var engine: PredictionEngine?
    private var trigramProvider: TrigramProvider?

    /// Process-wide build counter. Advanced exactly once per process lifetime
    /// (cold → loading), so `buildSessionId` and log payloads stay stable
    /// across show/hide cycles — a second "build start" log means the
    /// load-once guarantee has regressed.
    private var buildCount: Int = 0

    private let buildQueue = DispatchQueue(
        label: "com.ritoras.prediction.shared-build",
        qos: .userInitiated
    )

    private init() {}

    // MARK: - Accessors

    /// The process-wide build generation (1 after the one-shot load begins).
    /// Mirrors `KeyboardViewController.buildGeneration`.
    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return buildCount
    }

    /// Returns the prediction engine only when the stack is `.ready`; nil otherwise.
    func engineIfReady() -> PredictionEngine? {
        lock.lock(); defer { lock.unlock() }
        guard state == .ready else { return nil }
        return engine
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .ready
    }

    var isLoading: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .loading
    }

    private func mutateState(_ block: (inout LoadState, inout PredictionEngine?, inout TrigramProvider?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        block(&state, &engine, &trigramProvider)
    }

    // MARK: - Load

    /// Idempotent one-shot load of the whole prediction stack.
    ///
    /// If the stack is `.cold`, marks it `.loading` and dispatches the build on
    /// `buildQueue`. Otherwise it is already settled (`.loading` or `.ready`) —
    /// no second build is ever started; the completion is called with the
    /// current readiness instead.
    ///
    /// - Parameter completion: Called on the main queue with `true` when the
    ///                         engine is usable (`.ready`, including the
    ///                         degraded empty-engine fallback), `false`
    ///                         otherwise.
    func loadIfNeeded(completion: @escaping (Bool) -> Void) {
        lock.lock()
        switch state {
        case .cold:
            state = .loading
            buildCount &+= 1
            let generation = buildCount
            lock.unlock()
            buildQueue.async { [weak self] in
                guard let self = self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.performBuild(generation: generation, completion: completion)
            }
        case .loading:
            lock.unlock()
            DispatchQueue.main.async { completion(false) }
        case .ready:
            lock.unlock()
            DispatchQueue.main.async { completion(true) }
        }
    }

    /// Shared build implementation, runs on `buildQueue`.
    /// Mirrors the former per-instance `KeyboardViewController.buildPredictionEngine`
    /// minus per-instance state. Logs at `.warn` so the entries survive a
    /// Jetsam kill and reach DebugLogView via a dictation cycle.
    private func performBuild(generation: Int, completion: @escaping (Bool) -> Void) {
        let maxED = SharedConfig.Defaults.symspellMaxEditDistance
        let prefixLen = SharedConfig.Defaults.symspellPrefixLength

        // Build SymSpell index.
        let symSpell = SymSpell(maxEditDistance: maxED, prefixLength: prefixLen)

        // Build trie for completion.
        let trie = Trie()

        let baselineFootprint = MemoryMonitor.currentFootprint()
        FileLogger.shared.warn(.prediction, "shared prediction build start",
            payload: [
                "buildId": generation,
                "baselineFootprint": baselineFootprint,
                "maxFootprint": SharedConfig.Defaults.maxPhysFootprintDuringLoad
            ])

        // Stream-load the frequency dictionary into both, with memory monitoring.
        do {
            guard let url = WordListLoader.bundledURL() else {
                throw WordListLoader.WordListError.bundledFileNotFound
            }
            let loaded = try WordListLoader.loadStreamed(
                from: url,
                into: symSpell,
                trie: trie,
                buildSessionId: "b\(generation)"
            )
            let postLoadFootprint = MemoryMonitor.currentFootprint()
            FileLogger.shared.warn(.prediction, "shared prediction build result footprint",
                payload: [
                    "buildId": generation,
                    "wordsLoaded": loaded,
                    "postLoadFootprint": postLoadFootprint,
                    "baselineFootprint": baselineFootprint,
                    "delta": postLoadFootprint > baselineFootprint ? postLoadFootprint - baselineFootprint : 0
                ])
            if loaded < 49000 {
                FileLogger.shared.info(.dictionary, "prediction engine loaded partial dictionary", payload: ["wordsLoaded": loaded])
            }
        } catch {
            FileLogger.shared.error(.dictionary, "prediction engine failed to load dictionary", payload: ["error": error.localizedDescription])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mutateState { state, storedEngine, _ in
                    storedEngine = PredictionEngine()
                    state = .ready
                }
                FileLogger.shared.warn(.prediction, "shared prediction ready (degraded empty engine)",
                    payload: ["buildId": generation])
                completion(true)
            }
            return
        }

        // Eagerly load the trigram NOW, while footprint is still just the
        // dictionary (~33 MB) and well under the 40 MB load threshold.
        // If left lazy (first suggest() call), the load fires after the
        // engine is published with footprint > 40 MB, its deferral guard
        // trips, and it NEVER loads — leaving suggestions frequency-only
        // ("I/the/and"). Dictionary-first order is preserved so the
        // dictionary's own 40 MB guard never fires earlier.
        //
        // warmup() delivers its completion on the main queue; this build runs
        // on `buildQueue` (a background queue) and no path blocks the main
        // thread on `buildQueue`, so waiting on the semaphore here cannot
        // deadlock — the completion is guaranteed to run on a free main.
        let trigram = TrigramProvider()
        let trigramDone = DispatchSemaphore(value: 0)
        trigram.warmup { _ in trigramDone.signal() }
        trigramDone.wait()

        let dictionaryFootprint = MemoryMonitor.currentFootprint()
        let trigramState: String
        switch trigram.loadState {
        case .ready: trigramState = "ready"
        case .loading: trigramState = "loading"
        case .cold: trigramState = "deferred"
        case .failed: trigramState = "failed"
        }
        let finalFootprint = MemoryMonitor.currentFootprint()
        FileLogger.shared.warn(.prediction, "shared prediction build trigram loaded",
            payload: [
                "buildId": generation,
                "dictionaryFootprint": dictionaryFootprint,
                "trigramState": trigramState,
                "finalFootprint": finalFootprint
            ])

        // Create the SymSpell provider.
        let provider = SymSpellProvider(symSpell: symSpell, trie: trie)

        // Create the Apple UITextChecker provider.
        let appleProvider = AppleSpellCheckerProvider()

        // Build the engine and register ALL providers before publishing — the
        // engine is published atomically with its provider list so a concurrent
        // suggest() can never read `providers` mid-mutation. The trigram was
        // eagerly loaded right after the dictionary (see above), so it is
        // `.ready` (or otherwise settled) at registration time — NOT `.cold`.
        let engine = PredictionEngine()
        engine.addProvider(provider)
        engine.addProvider(appleProvider)
        engine.addProvider(trigram)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutateState { state, storedEngine, storedTrigram in
                storedEngine = engine
                storedTrigram = trigram
                state = .ready
            }

            FileLogger.shared.warn(.prediction, "shared prediction ready (trigram \(trigramState))",
                payload: ["buildId": generation])
            completion(true)
        }
    }

    // MARK: - Memory Shed

    /// Sheds only the KenLM trigram model + side index under memory pressure.
    /// The dictionary + engine persist — the trigram lazily reloads on the next
    /// suggest() call. Returns the bytes freed (before − after phys_footprint),
    /// or 0 if nothing was shed.
    @discardableResult
    func unloadTrigram() -> UInt64 {
        let before = MemoryMonitor.currentFootprint()
        lock.lock()
        let trigram = trigramProvider
        lock.unlock()
        trigram?.unload()
        let after = MemoryMonitor.currentFootprint()
        return before > after ? before - after : 0
    }

    /// Last-resort full shed: drops the engine + trigram and returns to `.cold`
    /// so the next loadIfNeeded rebuilds from scratch.
    // Phase 2: last-resort only, wired only if device logs demand it.
    func emergencyShed() {
        mutateState { state, storedEngine, storedTrigram in
            storedEngine = nil
            storedTrigram = nil
            state = .cold
        }
    }
}
