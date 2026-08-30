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
/// Language switching: the stack tracks a `currentLanguage`. English loads
/// lazily at process launch (load-once per language); Greek builds on the
/// first explicit menu selection via `switchLanguageIfNeeded(to:)`. A switch
/// drops the old stack so ARC can reclaim the ~25 MB SymSpell before building
/// the new language's dictionary.
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
    private var currentLanguage: KeyboardLanguage = .english

    /// Process-wide build counter. Advanced once for the cold → loading build
    /// and again on each language switch — every `performBuild` gets a unique
    /// id for `buildSessionId` and log payloads. A second "build start" log
    /// without a preceding language switch means the load-once guarantee has
    /// regressed.
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

    /// The language the prediction stack was last built for. `.english` until
    /// the first explicit language selection triggers a switch.
    var language: KeyboardLanguage {
        lock.lock(); defer { lock.unlock() }
        return currentLanguage
    }

    private func mutateState(_ block: (inout LoadState, inout PredictionEngine?, inout TrigramProvider?, inout KeyboardLanguage) -> Void) {
        lock.lock(); defer { lock.unlock() }
        block(&state, &engine, &trigramProvider, &currentLanguage)
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
            let language = currentLanguage
            lock.unlock()
            buildQueue.async { [weak self] in
                guard let self = self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.performBuild(generation: generation, language: language, completion: completion)
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
    /// minus per-instance state. The degraded-engine fallback logs at `.warn` so
    /// the entry survives a Jetsam kill and reaches DebugLogView via a dictation cycle.
    private func performBuild(generation: Int, language: KeyboardLanguage, completion: @escaping (Bool) -> Void) {
        let diagnosticsEnabled = SharedConfig.Defaults.predictionDebugLoggingEnabled
        let buildStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let maxED = SharedConfig.Defaults.symspellMaxEditDistance
        let prefixLen = SharedConfig.Defaults.symspellPrefixLength

        // Build trie for completion.
        var trie = Trie()

        let baselineFootprint = MemoryMonitor.currentFootprint()
        let baselineResident = diagnosticsEnabled ? MemoryMonitor.currentResidentSize() : 0
        if diagnosticsEnabled {
            FileLogger.shared.debug(.prediction, "shared prediction build start",
                payload: [
                    "buildId": generation,
                    "language": language.rawValue,
                    "mappedEnabled": SharedConfig.Defaults.symspellMappedIndexEnabled,
                    "baselineFootprint": baselineFootprint,
                    "baselineResident": baselineResident,
                    "elapsedMs": (DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000,
                    "maxFootprint": SharedConfig.Defaults.maxPhysFootprintDuringLoad
                ])
        }

        // Stream-load the frequency dictionary into the selected index and trie,
        // with memory monitoring.
        let loadedResult: (query: SymSpellQuerying, wordsLoaded: Int)
        do {
            guard let url = WordListLoader.bundledURL(language: language) else {
                if SharedConfig.Defaults.symspellMappedIndexEnabled {
                    FileLogger.shared.warn(.prediction, "mapped SymSpell fallback",
                        payload: ["buildId": generation, "language": language.rawValue, "reason": "bundled wordlist missing", "path": "legacy-fallback"])
                }
                throw WordListLoader.WordListError.bundledFileNotFound
            }

            func loadLegacy() throws -> (query: SymSpellQuerying, wordsLoaded: Int) {
                let symSpell = SymSpell(maxEditDistance: maxED, prefixLength: prefixLen)
                let streamStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                let loaded = try WordListLoader.loadStreamed(
                    from: url,
                    into: symSpell,
                    trie: trie,
                    pruneBelow: SharedConfig.Defaults.symspellMinWordFreq,
                    buildSessionId: "b\(generation)"
                )
                if diagnosticsEnabled {
                    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000
                    FileLogger.shared.debug(.prediction, "shared prediction trie stream complete", payload: [
                        "buildId": generation,
                        "language": language.rawValue,
                        "path": "legacy",
                        "entriesLoaded": loaded,
                        "elapsedMs": elapsedMs,
                        "footprint": MemoryMonitor.currentFootprint(),
                        "resident": MemoryMonitor.currentResidentSize()
                    ])
                }
                return (query: symSpell, wordsLoaded: loaded)
            }

            if SharedConfig.Defaults.symspellMappedIndexEnabled {
                let blobName = "symspell_index_\(language.rawValue)_v1"
                let blobResolveStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                let blobURL = Bundle.main.url(forResource: blobName, withExtension: "blob")
                if diagnosticsEnabled {
                    let elapsedMs = (DispatchTime.now().uptimeNanoseconds - blobResolveStart) / 1_000_000
                    FileLogger.shared.debug(.prediction, "mapped SymSpell blob resolve", payload: [
                        "buildId": generation,
                        "language": language.rawValue,
                        "resource": blobName,
                        "resolved": blobURL != nil,
                        "pathSuffix": blobURL.map { String($0.path.suffix(96)) } ?? "nil",
                        "elapsedMs": elapsedMs,
                        "footprint": MemoryMonitor.currentFootprint(),
                        "resident": MemoryMonitor.currentResidentSize()
                    ])
                }
                if let blobURL = blobURL {
                    let mappedBeforeFootprint = MemoryMonitor.currentFootprint()
                    let mappedBeforeResident = MemoryMonitor.currentResidentSize()
                    let mappedStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                    let mappedResult = MappedSymSpellIndex.load(from: blobURL, language: language)
                    if diagnosticsEnabled {
                        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - mappedStart) / 1_000_000
                        FileLogger.shared.debug(.prediction, "mapped SymSpell open and validate complete", payload: [
                            "buildId": generation,
                            "language": language.rawValue,
                            "resolved": mappedResult.index != nil,
                            "failureReason": mappedResult.failureReason ?? "none",
                            "elapsedMs": elapsedMs,
                            "footprint": MemoryMonitor.currentFootprint(),
                            "resident": MemoryMonitor.currentResidentSize()
                        ])
                    }
                    if let mappedIndex = mappedResult.index {
                        do {
                            let trieStreamStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                            let trieEntriesLoaded = try WordListLoader.loadStreamed(
                                from: url,
                                into: nil,
                                trie: trie,
                                pruneBelow: SharedConfig.Defaults.symspellMinWordFreq,
                                buildSessionId: "b\(generation)"
                            )
                            if diagnosticsEnabled {
                                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - trieStreamStart) / 1_000_000
                                FileLogger.shared.debug(.prediction, "shared prediction trie stream complete", payload: [
                                    "buildId": generation,
                                    "language": language.rawValue,
                                    "path": "mapped",
                                    "entriesLoaded": trieEntriesLoaded,
                                    "elapsedMs": elapsedMs,
                                    "footprint": MemoryMonitor.currentFootprint(),
                                    "resident": MemoryMonitor.currentResidentSize()
                                ])
                            }
                            let mappedAfterFootprint = MemoryMonitor.currentFootprint()
                            let mappedAfterResident = MemoryMonitor.currentResidentSize()
                            FileLogger.shared.info(.prediction, "mapped SymSpell index loaded", payload: [
                                "buildId": generation,
                                "language": language.rawValue,
                                "wordCount": mappedIndex.wordCount,
                                "deleteKeyCount": mappedIndex.deleteKeyCount,
                                "footprintBefore": mappedBeforeFootprint,
                                "footprintAfter": mappedAfterFootprint,
                                "residentBefore": mappedBeforeResident,
                                "residentAfter": mappedAfterResident
                            ])
                            loadedResult = (query: mappedIndex, wordsLoaded: mappedIndex.wordCount)
                        } catch {
                            FileLogger.shared.warn(.prediction, "mapped SymSpell fallback",
                                payload: [
                                    "buildId": generation,
                                    "language": language.rawValue,
                                    "reason": "trie load failed",
                                    "path": "legacy-fallback",
                                    "error": error.localizedDescription
                                ])
                            trie = Trie()
                            loadedResult = try loadLegacy()
                        }
                    } else {
                        FileLogger.shared.warn(.prediction, "mapped SymSpell fallback",
                            payload: [
                                     "buildId": generation,
                                     "language": language.rawValue,
                                     "reason": mappedResult.failureReason ?? "validation failed",
                                     "path": "legacy-fallback"
                                 ])
                        loadedResult = try loadLegacy()
                    }
                } else {
                    FileLogger.shared.warn(.prediction, "mapped SymSpell fallback",
                        payload: ["buildId": generation, "language": language.rawValue, "reason": "blob resource missing", "path": "legacy-fallback"])
                    loadedResult = try loadLegacy()
                }
            } else {
                loadedResult = try loadLegacy()
            }

            let loaded = loadedResult.wordsLoaded
            let postLoadFootprint = MemoryMonitor.currentFootprint()
            FileLogger.shared.info(.prediction, "shared prediction build result footprint",
                payload: [
                    "buildId": generation,
                    "language": language.rawValue,
                    "wordsLoaded": loaded,
                    "postLoadFootprint": postLoadFootprint,
                    "baselineFootprint": baselineFootprint,
                    "delta": postLoadFootprint > baselineFootprint ? postLoadFootprint - baselineFootprint : 0
                ])
            if diagnosticsEnabled {
                let elapsedMs = (DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000
                FileLogger.shared.debug(.prediction, "shared prediction dictionary stage complete", payload: [
                    "buildId": generation,
                    "language": language.rawValue,
                    "entriesLoaded": loaded,
                    "elapsedMs": elapsedMs,
                    "footprint": postLoadFootprint,
                    "resident": MemoryMonitor.currentResidentSize()
                ])
            }
            if loaded < 49000 {
                FileLogger.shared.info(.dictionary, "prediction engine loaded partial dictionary", payload: ["wordsLoaded": loaded])
            }
        } catch {
            FileLogger.shared.error(.dictionary, "prediction engine failed to load dictionary", payload: ["error": error.localizedDescription])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mutateState { state, storedEngine, _, storedLanguage in
                    storedEngine = PredictionEngine()
                    state = .ready
                    storedLanguage = language
                }
                FileLogger.shared.warn(.prediction, "shared prediction ready (degraded empty engine)",
                    payload: ["buildId": generation, "language": language.rawValue])
                if diagnosticsEnabled {
                    let footprint = MemoryMonitor.currentFootprint()
                    FileLogger.shared.debug(.prediction, "shared prediction engine publish", payload: [
                        "buildId": generation,
                        "language": language.rawValue,
                        "degraded": true,
                        "elapsedMs": (DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000,
                        "footprint": footprint,
                        "resident": MemoryMonitor.currentResidentSize()
                    ])
                    FileLogger.shared.debug(.prediction, "shared prediction build end", payload: [
                        "buildId": generation,
                        "language": language.rawValue,
                        "degraded": true,
                        "totalMs": (DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000,
                        "footprintStart": baselineFootprint,
                        "footprintEnd": footprint,
                        "footprintDelta": footprint > baselineFootprint ? footprint - baselineFootprint : 0,
                        "residentEnd": MemoryMonitor.currentResidentSize()
                    ])
                }
                completion(true)
            }
            return
        }

        // Create the SymSpell provider.
        let providerStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let provider = SymSpellProvider(symSpell: loadedResult.query, trie: trie, language: language)

        // Create the Apple UITextChecker provider.
        let appleProvider = AppleSpellCheckerProvider(language: language.appleSpellTag)

        // Build the engine and register ALL providers before publishing — the
        // engine is published atomically with its provider list so a concurrent
        // suggest() can never read `providers` mid-mutation.
        let engine = PredictionEngine()
        engine.addProvider(provider)
        engine.addProvider(appleProvider)
        // English ships with a KenLM trigram provider; Greek ships without one
        // (Phase 6 deferred) — never register it so its ~8-10 MB model cannot
        // lazy-load in Greek mode.
        var trigram: TrigramProvider?
        if language == .english {
            let englishTrigram = TrigramProvider()
            engine.addProvider(englishTrigram)
            trigram = englishTrigram
        }
        if diagnosticsEnabled {
            FileLogger.shared.debug(.prediction, "shared prediction providers constructed", payload: [
                "buildId": generation,
                "language": language.rawValue,
                "trigramRegistered": trigram != nil,
                "elapsedMs": (DispatchTime.now().uptimeNanoseconds - providerStart) / 1_000_000,
                "footprint": MemoryMonitor.currentFootprint(),
                "resident": MemoryMonitor.currentResidentSize()
            ])
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutateState { state, storedEngine, storedTrigram, storedLanguage in
                storedEngine = engine
                storedTrigram = trigram
                state = .ready
                storedLanguage = language
            }

            if diagnosticsEnabled {
                let footprint = MemoryMonitor.currentFootprint()
                FileLogger.shared.debug(.prediction, "shared prediction engine publish", payload: [
                    "buildId": generation,
                    "language": language.rawValue,
                    "degraded": false,
                    "elapsedMs": (DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000,
                    "footprint": footprint,
                    "resident": MemoryMonitor.currentResidentSize()
                ])
                FileLogger.shared.debug(.prediction, "shared prediction build end", payload: [
                    "buildId": generation,
                    "language": language.rawValue,
                    "degraded": false,
                    "totalMs": (DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000,
                    "footprintStart": baselineFootprint,
                    "footprintEnd": footprint,
                    "footprintDelta": footprint > baselineFootprint ? footprint - baselineFootprint : 0,
                    "residentEnd": MemoryMonitor.currentResidentSize()
                ])
            }

            // English: TrigramProvider registered in .cold state — lazy-loads on
            // first suggest() call. KenLM model (~8-10 MB) is NOT loaded here,
            // keeping steady-state ~38-43 MB (well under the 48 MB Jetsam cap).
            // Greek: no trigram provider at all (Phase 6 deferred).
            FileLogger.shared.info(.prediction, "shared prediction ready (trigram deferred)",
                payload: [
                    "buildId": generation,
                    "language": language.rawValue,
                    "trigram": language == .english ? "deferred" : "none"
                ])
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

    // MARK: - Language Switch

    /// Swaps the prediction stack to `language`, rebuilding SymSpell + Trie +
    /// providers from that language's bundled dictionary. No-op when the stack
    /// is already built for `language`.
    ///
    /// Runs on `buildQueue`. Order matters for the 48 MB Jetsam cap:
    ///   1. `unloadTrigram()` sheds the KenLM model (~8-10 MB) first.
    ///   2. The old engine/trigram/providers are dropped (state → `.loading`),
    ///      releasing the ~25 MB SymSpell for ARC.
    ///   3. `phys_footprint` is polled until the old dictionary is reclaimed
    ///      (~2 s timeout) so the new build starts from the lower baseline —
    ///      peak ≈ one full stack ≈ steady state. If ARC does not reclaim in
    ///      time, `loadStreamed`'s footprint-abort guard is the backstop.
    ///   4. The new language's stack is built via the shared `performBuild`.
    ///
    /// The `.loading` (not `.cold`) intermediate state intentionally mirrors a
    /// cold start: `engineIfReady()` returns nil so the UI shows no stale
    /// suggestions, while `isLoading` blocks the refreshSuggestions fallback
    /// from racing a parallel English `loadIfNeeded` build.
    ///
    /// - Parameters:
    ///   - language: The target language.
    ///   - completion: Called on the main queue with the new stack's readiness.
    func switchLanguageIfNeeded(to language: KeyboardLanguage, completion: @escaping (Bool) -> Void = { _ in }) {
        buildQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.performLanguageSwitch(to: language, completion: completion)
        }
    }

    /// The serialized switch body, runs on `buildQueue`.
    private func performLanguageSwitch(to language: KeyboardLanguage, completion: @escaping (Bool) -> Void) {
        lock.lock()
        // A build is in flight (lazy English load at launch, or a prior switch).
        // performBuild always settles to `.ready`, so retry until it does.
        if state == .loading {
            lock.unlock()
            buildQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.performLanguageSwitch(to: language, completion: completion)
            }
            return
        }
        let alreadyOnLanguage = currentLanguage == language
        let wasReady = state == .ready
        lock.unlock()

        guard !alreadyOnLanguage else {
            DispatchQueue.main.async { completion(wasReady) }
            return
        }

        let beforeFootprint = MemoryMonitor.currentFootprint()

        // a. Shed the trigram first — the model must not straddle the swap.
        let trigramFreed = unloadTrigram()

        // b. Drop the old stack so the old SymSpell/Trie dealloc.
        lock.lock()
        engine = nil
        trigramProvider = nil
        currentLanguage = language
        state = .loading
        lock.unlock()
        buildCount &+= 1
        let generation = buildCount

        // The post-drop footprint still includes the not-yet-deallocated old
        // SymSpell (~25 MB) — it is the baseline the poll below waits against.
        let afterDropFootprint = MemoryMonitor.currentFootprint()

        // c. Poll phys_footprint until the old dictionary is reclaimed
        //    (expect ≈25 MB drop). ARC reclamation is async; give it up to
        //    2 s. On timeout, proceed — loadStreamed's footprint-abort guard
        //    still protects the 48 MB cap.
        let reclaimDeadline = Date().addingTimeInterval(2.0)
        var reclaimed = false
        while Date() < reclaimDeadline {
            if MemoryMonitor.currentFootprint() < afterDropFootprint {
                reclaimed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let afterReclaimFootprint = MemoryMonitor.currentFootprint()
        if !reclaimed {
            FileLogger.shared.warn(.prediction, "old dictionary not reclaimed",
                payload: [
                    "language": language.rawValue,
                    "baselineFootprint": beforeFootprint,
                    "afterDropFootprint": afterDropFootprint,
                    "afterReclaimFootprint": afterReclaimFootprint,
                    "trigramFreed": trigramFreed
                ])
        }

        // d. Rebuild for the new language via the shared build path.
        FileLogger.shared.info(.prediction, "prediction stack switching",
            payload: ["language": language.rawValue, "buildId": generation, "baselineFootprint": beforeFootprint])
        performBuild(generation: generation, language: language) { [weak self] ok in
            guard let self else { return }
            let afterBuildFootprint = MemoryMonitor.currentFootprint()
            FileLogger.shared.info(.prediction, "prediction stack switched",
                payload: [
                    "language": language.rawValue,
                    "buildId": generation,
                    "beforeFootprint": beforeFootprint,
                    "afterFootprint": afterBuildFootprint,
                    "reclaimed": reclaimed
                ])
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
