import UIKit


private enum BackspacePhase {
    case charRepeat
    case wordRepeat
}

class KeyboardViewController: UIInputViewController {

    // MARK: - State

    private var state: KeyboardState = .idle {
        didSet {
            keyboardView.configure(for: state)
            errorResetWorkItem?.cancel()
            if case .error = state {
                scheduleErrorReset()
            }
            FileLogger.shared.debug(.keyboard, "state: \(String(describing: state))",
                                   payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
        }
    }

    private var shiftState: ShiftState = .lower {
        didSet {
            keyboardView.apply(shift: displayedShiftState, layoutMode: layoutMode)
        }
    }

    private var layoutMode: KeyboardLayoutMode = .letters {
        didSet {
            keyboardView.apply(shift: displayedShiftState, layoutMode: layoutMode)
        }
    }

    // MARK: - Auto-Capitalization (derived state — never mutates shiftState)

    private var autoCapActive = false
    private var userOverrodeAutoCap = false
    private var lastAtSentenceStart = false
    private var lastRecomputedContext: String?

    /// Top-level keyboard surface shown to the user (`.letters` | `.emoji` panel |
    /// `.emojiSearch` overlay). Independent of `KeyboardLayoutMode` (letters/numbers/
    /// symbols), which only governs the key grid inside the `.letters` surface.
    ///
    /// Intentionally NOT reset across hide→show cycles: the user returns to the
    /// surface they left (e.g. the emoji panel). Emoji-recents recording no longer
    /// reads `uiMode` — it is performed at the picker tap handlers in EmojiPanelView
    /// and EmojiSearchOverlay — so the async-search-field focus race cannot corrupt
    /// recents regardless of the value here.
    private var uiMode: UIMode = .letters {
        didSet {
            keyboardView.apply(mode: uiMode)
            updateKeyboardHeight(for: uiMode)
        }
    }

    // MARK: - Input Target (keystroke routing)

    enum InputTarget { case hostApp, emojiSearch }
    private var inputTarget: InputTarget = .hostApp

    private var predictionEngine: PredictionEngine?
    private var trigramProvider: TrigramProvider?
    private var isPredictionEngineReady = false

    /// Identifies the keyboard process across VC instances. Set once per process launch.
    static let processLaunchId: String = UUID().uuidString
    /// Process-wide build counter (main-thread-confined: all build calls originate on the main thread).
    /// Static so multiple KeyboardViewController instances in one process produce buildId 1,2,3,…,
    /// revealing VC accumulation that a per-instance counter would mask.
    private static var buildGeneration: Int = 0
    /// Main-thread-confined in-flight guard. Read/written only on the main thread
    /// (buildPredictionEngine is called from viewDidLoad and the snapshot path,
    /// both main; resets happen in the DispatchQueue.main.async completion callbacks).
    private var isBuildingPrediction = false
    private let predictionBuildQueue = DispatchQueue(
        label: "com.ritoras.prediction.build",
        qos: .userInitiated
    )

    /// Tracks the current server-poll data task so it can be cancelled before
    /// the next poll starts or when transports are stopped.
    private var currentPollTask: URLSessionDataTask?

    private var keyboardView: KeyboardView!

    private var heightConstraint: NSLayoutConstraint?

    // MARK: - Backspace State

    private var backspaceTimer: Timer?
    private var backspacePhase: BackspacePhase?
    private var backspaceSingleCharCount = 0
    private var backspaceNilContextRetries = 0
    // MARK: - Autocorrect-on-space

    private var wordOrigin = WordOriginTracker()
    /// Tracks the most recent autocorrect for potential revert-on-backspace (Phase 4).
    private var lastAutoCorrection: (typed: String, replacement: String)?

    // MARK: - Dictation State

    private var waitTimer: Timer?
    private var errorResetWorkItem: DispatchWorkItem?
    private var suggestionRefreshWorkItem: DispatchWorkItem?
    private var autocorrectWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollCount = 0
    private var confirmStopTimer: Timer?

    // MARK: - Snapshot Polling & Darwin Notifications

    private var snapshotPollTimer: DispatchSourceTimer?
    private var darwinStateChangedToken: DarwinObserverToken?
    /// Tracks consecutive snapshot misses (app-group read returned nil). When this
    /// reaches 6, /jobs server polling starts as an emergency fallback.
    private var consecutiveSnapshotMisses: Int = 0
    /// Stored Task for refreshFromSharedState, cancelled on teardown and
    /// superseded on each new spawn to prevent interleaved concurrent executions.
    private var appearRefreshTask: Task<Void, Never>?

    /// The `documentIdentifier` of the text field that started the current
    /// dictation. Gate on this in `insertDictationResult` to defer results
    /// that arrive after the user switched text fields.
    private var dictationTargetDocId: UUID? = nil

    // Settings cache (refreshed by Darwin notification from container app)
    private let settingsCache = KeyboardSettingsCache()
    private var darwinSettingsChangedToken: DarwinObserverToken?
    private var darwinLearnedWordsChangedToken: DarwinObserverToken?

    // Persisted across keyboard process restarts
    private var lastProcessedPayloadId: UUID? {
        get { UUID(uuidString: UserDefaults.standard.string(forKey: "ritoras_last_pid") ?? "") }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "ritoras_last_pid") }
    }

    // MARK: - Server Polling

    /// In-memory dedup timestamp for server polling (not persisted — only the
    /// id-based dedup guard in handleTerminalResult crosses process restarts).
    private var lastProcessedTimestamp: Double = 0

    /// Tracks the highest revision seen from the app-group snapshot to avoid
    /// re-processing in-progress updates that have already been reflected in the
    /// UI. Reset to 0 when a new dictation starts.
    private var lastSeenSnapshotRevision: UInt64 = 0

    /// The active dictation request ID, persisted so the keyboard can resume
    /// waiting for its result even after iOS terminates the extension process
    /// (which happens routinely when the user switches apps). Setting it to nil
    /// also clears the companion start timestamp so no stale state lingers.
    private var pendingRequestId: UUID? {
        get { UUID(uuidString: UserDefaults.standard.string(forKey: "ritoras_pending_id") ?? "") }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: "ritoras_pending_id")
            } else {
                UserDefaults.standard.removeObject(forKey: "ritoras_pending_id")
                UserDefaults.standard.removeObject(forKey: "ritoras_pending_start")
            }
        }
    }

    /// Wall-clock time the current pending request was started, used to expire
    /// requests that never resolved so they don't haunt every keyboard reappearance.
    private var pendingRequestStart: Double {
        get { UserDefaults.standard.double(forKey: "ritoras_pending_start") }
        set { UserDefaults.standard.set(newValue, forKey: "ritoras_pending_start") }
    }

    private var serverPollTimer: Timer?
    private var serverPollCount = 0
    private var serverPollUnresponsiveCount = 0
    private var serverPollWorkItem: DispatchWorkItem?
    private var lastPollStartTime: Date?

    // MARK: - Prediction Engine

    /// Builds the prediction engine (SymSpell + Trie) on a background queue.
    /// Sets `isPredictionEngineReady = true` on the main queue when done.
    private func buildPredictionEngine() {
        isPredictionEngineReady = false
        guard !isBuildingPrediction else {
            FileLogger.shared.debug(.prediction, "build skipped: prediction build already in flight",
                payload: ["buildId": Self.buildGeneration])
            return
        }
        isBuildingPrediction = true
        Self.buildGeneration &+= 1
        let generation = Self.buildGeneration
        let launchId = KeyboardViewController.processLaunchId

        predictionBuildQueue.async { [weak self] in
            guard let self = self else { return }

            let maxED = SharedConfig.Defaults.symspellMaxEditDistance
            let prefixLen = SharedConfig.Defaults.symspellPrefixLength

            // Build SymSpell index.
            let symSpell = SymSpell(maxEditDistance: maxED, prefixLength: prefixLen)

            // Build trie for completion.
            let trie = Trie()

            let baselineFootprint = MemoryMonitor.currentFootprint()
            let trigramReady = self.trigramProvider?.isReady ?? false
            FileLogger.shared.debug(.prediction, "build start footprint",
                payload: [
                    "launchId": launchId,
                    "buildId": generation,
                    "baselineFootprint": baselineFootprint,
                    "maxFootprint": SharedConfig.Defaults.maxPhysFootprintDuringLoad,
                    "trigramReady": trigramReady,
                    "hadEngineBeforeBuild": self.predictionEngine != nil
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
                FileLogger.shared.debug(.prediction, "build result footprint",
                    payload: [
                        "launchId": launchId,
                        "buildId": generation,
                        "wordsLoaded": loaded,
                        "postLoadFootprint": postLoadFootprint,
                        "baselineFootprint": baselineFootprint,
                        "delta": postLoadFootprint > baselineFootprint ? postLoadFootprint - baselineFootprint : 0,
                        "trigramReady": trigramReady
                    ])
                if loaded < 49000 {
                    FileLogger.shared.info(.dictionary, "prediction engine loaded partial dictionary", payload: ["wordsLoaded": loaded])
                }
            } catch {
                FileLogger.shared.error(.dictionary, "prediction engine failed to load dictionary", payload: ["error": error.localizedDescription])
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isBuildingPrediction = false
                    self.isPredictionEngineReady = true
                    self.predictionEngine = PredictionEngine()
                }
                return
            }

            // Create the SymSpell provider.
            let provider = SymSpellProvider(symSpell: symSpell, trie: trie)

            // Create the Apple UITextChecker provider.
            let appleProvider = AppleSpellCheckerProvider()

            // Build the engine and register providers.
            let engine = PredictionEngine()
            engine.addProvider(provider)
            engine.addProvider(appleProvider)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBuildingPrediction = false
                self.predictionEngine = engine
                self.isPredictionEngineReady = true

                // Register TrigramProvider in .cold state — lazy-loads on first suggest() call.
                // KenLM model (~8-10 MB) is NOT loaded here, keeping steady-state ~38-43 MB
                // (well under the 48 MB Jetsam cap) for short typing sessions.
                let trigram = TrigramProvider()
                self.trigramProvider = trigram
                engine.addProvider(trigram)

                FileLogger.shared.info(.keyboard, "PredictionEngine ready (trigram deferred)")
            }
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        FileLogger.shared.debug(.lifecycle, "boot baseline",
            payload: ["launchId": KeyboardViewController.processLaunchId,
                      "footprint": MemoryMonitor.currentFootprint()])

        // Wire FileLogger broadcast to ship logs to container app via localhost.
        // Set before any log calls so we capture everything from the start.
        FileLogger.broadcast = { level, component, message, payload in
            let entry = LogShipmentEntry(level: level, component: component, message: message, payload: payload)
            KeyboardLogShipper.shared.append(entry)
        }
        KeyboardLogShipper.shared.start()

        // Log the resolved app-group identifier via FileLogger (post-resolution, safe to use FileLogger now).
        // Promoted to .warn so it survives a keyboard process kill (Jetsam) and reaches
        // the DebugLogView via the log shipper — critical for SideStore diagnostic triage.
        FileLogger.shared.warn(.keyboard, "AppGroupResolver outcome", payload: [
            "resolvedIdentifier": SharedConfig.Defaults.appGroupId,
            "bundleId": Bundle.main.bundleIdentifier ?? "?"
        ])

        NSSetUncaughtExceptionHandler { exception in
            let msg = "FATAL: \(exception.name.rawValue): \(exception.reason ?? "unknown")"
            var logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
            logs.append("[FATAL] \(msg)")
            UserDefaults.standard.set(logs, forKey: "ritoras_logs")
        }

        setupKeyboardView()
        HapticsManager.shared.reloadEnabledFromAppGroup()
        settingsCache.refresh()
        darwinSettingsChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinSettingsChangedNotificationName) { [weak self] in
            guard let self = self else { return }
            self.settingsCache.refresh()
            DispatchQueue.main.async {
                HapticsManager.shared.reloadEnabledFromAppGroup()
            }
        }
        darwinLearnedWordsChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinLearnedWordsChangedNotificationName) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                LearnedWordsStore.shared.absorbRemoteSnapshot()
                self.scheduleSuggestionRefresh()
            }
        }
        buildPredictionEngine()
        state = .idle
        FileLogger.shared.debug(.lifecycle, "process launch",
            payload: ["launchId": KeyboardViewController.processLaunchId])
        NetworkChangeMonitor.shared.start()
        FileLogger.shared.info(.keyboard, "viewDidLoad OK",
                               payload: ["hasFullAccess": hasFullAccess])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardView.updateFullAccess(hasFullAccess)

        // App-group snapshot polling (primary transport).
        appearRefreshTask?.cancel()
        appearRefreshTask = Task { [weak self] in
            await self?.refreshFromSharedState()
        }
        startSnapshotPolling()

        // T_wake — diagnostic anchor for the paste-delay timeline: wake event with
        // the pending request (or nil), snapshot revision, and the appear refresh.
        FileLogger.shared.debug(.keyboard, "viewDidAppear — wake",
                                payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil",
                                          "lastSeenRevision": lastSeenSnapshotRevision,
                                          "appearRefresh": true])

        // Absorb any learned-words changes made by the container app while
        // the keyboard was dead (e.g. app-side deletes from DictionaryView).
        LearnedWordsStore.shared.absorbRemoteSnapshot()

        // Defensive: never resume in search mode after keyboard dismiss/reappear
        inputTarget = .hostApp
        if uiMode == .emojiSearch {
            keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
            uiMode = .emoji
        }

        // Clear stale deferred text (Bug 3): if deferred text is older than 300s,
        // discard it before Path A or Path B can act on it.
        let deferredTs = UserDefaults.standard.double(forKey: "ritoras_deferred_ts")
        if deferredTs > 0 {
            let deferredAge = Date().timeIntervalSince1970 - deferredTs
            if deferredAge > 300 {
                clearDeferredResult()
            }
        }

        // Resume a dictation that was in progress when iOS suspended/terminated
        // the extension. pendingRequestId survives in UserDefaults, so even a
        // fully relaunched keyboard process can recover the result.
        if let id = pendingRequestId {
            let age = pendingRequestStart > 0 ? Date().timeIntervalSince1970 - pendingRequestStart : 0
            if age > 300 {  // >5 min — the result is unrecoverable; abandon it
                FileLogger.shared.debug(.keyboard, "viewDidAppear — pending dictation stale",
                                        payload: ["age": age, "pendingRequestId": id.uuidString])
                pendingRequestId = nil
                dictationTargetDocId = nil
                state = .idle
            } else {
                FileLogger.shared.info(.keyboard, "viewDidAppear — resuming pending dictation",
                                       payload: ["pendingRequestId": id.uuidString, "age": age])
                checkForPendingDictation()
            }
        } else {
            // Check for a deferred result — a dictation completed while the keyboard
            // was hidden and the paste was deferred until the keyboard reappears.
            if let deferredText = UserDefaults.standard.string(forKey: "ritoras_deferred_text"),
               !deferredText.isEmpty {
                let deferredTs = UserDefaults.standard.double(forKey: "ritoras_deferred_ts")
                let age = deferredTs > 0 ? Date().timeIntervalSince1970 - deferredTs : 0
                if age < 300 {
                    FileLogger.shared.info(.keyboard, "Inserting deferred dictation result",
                                           payload: ["length": deferredText.count, "age": age])
                    clearDeferredResult()
                    state = .inserting
                    textDocumentProxy.insertText(normalizedDictationInsertion(of: deferredText))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.state = .idle
                    }
                } else {
                    FileLogger.shared.info(.keyboard, "Deferred dictation result expired",
                                           payload: ["age": age])
                    clearDeferredResult()
                    state = .idle
                }
            } else {
                state = .idle
                FileLogger.shared.info(.keyboard, "viewDidAppear — idle",
                                       payload: ["hasFullAccess": hasFullAccess])
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installOrUpdateHeightConstraint()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        installOrUpdateHeightConstraint()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        let before = MemoryMonitor.currentFootprint()
        trigramProvider?.unload()
        predictionEngine = nil
        isPredictionEngineReady = false
        let after = MemoryMonitor.currentFootprint()
        FileLogger.shared.warn(.lifecycle,
            "didReceiveMemoryWarning: phys_footprint \(before) → \(after) (\(before > after ? before - after : 0) bytes freed)")
    }

    /// Sheds the prediction engine + trigram model on keyboard hide. Mirrors
    /// didReceiveMemoryWarning. The next show rebuilds a fresh engine
    /// (new VC → viewDidLoad → buildPredictionEngine), so shedding is safe.
    private func shedPredictionEngine() {
        let before = MemoryMonitor.currentFootprint()
        trigramProvider?.unload()
        trigramProvider = nil
        predictionEngine = nil
        isPredictionEngineReady = false
        let after = MemoryMonitor.currentFootprint()
        FileLogger.shared.debug(.lifecycle, "hide shed: phys_footprint",
            payload: ["before": before, "after": after,
                      "freed": before > after ? before - after : 0])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        shedPredictionEngine()
        FileLogger.shared.info(.keyboard, "viewWillDisappear")

        // Cancel timers so they don't fire across app switches.
        // The Darwin observer is intentionally kept alive: dictation may complete
        // on the server while the keyboard is hidden (e.g. user is recording in
        // the container app), and we want the notification to land immediately
        // when the keyboard reappears without waiting for server polling.
        // The observer auto-unregisters in deinit; stale notifications after a
        // resolved dictation are filtered by pendingRequestId.
        cancelOutstandingAsyncWork()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        FileLogger.shared.info(.keyboard, "viewDidDisappear")
    }

    deinit {
        FileLogger.shared.info(.lifecycle, "KeyboardViewController deinit",
            payload: ["launchId": KeyboardViewController.processLaunchId,
                      "buildId": Self.buildGeneration])
        KeyboardLogShipper.shared.stop()
        FileLogger.broadcast = nil
        cancelOutstandingAsyncWork()
        darwinStateChangedToken = nil
        darwinSettingsChangedToken = nil
        darwinLearnedWordsChangedToken = nil
    }

    // MARK: - Setup

    private func setupKeyboardView() {
        keyboardView = KeyboardView(frame: .zero)
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.delegate = self
        view.addSubview(keyboardView)

        NSLayoutConstraint.activate([
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Wire emoji panel search callbacks
        keyboardView.emojiPanelView.onSearchActivate = { [weak self] in
            guard let self = self else { return }
            self.inputTarget = .emojiSearch
            self.lastAutoCorrection = nil
            self.uiMode = .emojiSearch
        }

        keyboardView.emojiPanelView.onSearchDismiss = { [weak self] in
            guard let self = self else { return }
            self.inputTarget = .hostApp
            self.keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
            self.keyboardView.emojiPanelView.searchField.resignFirstResponder() // resign trigger field so textFieldDidBeginEditing re-fires on next tap
            self.uiMode = .emoji
        }

        keyboardView.emojiPanelView.onSearchReturn = { [weak self] in
            guard let self = self else { return }
            self.inputTarget = .hostApp
            self.keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
            self.keyboardView.emojiPanelView.searchField.resignFirstResponder() // resign trigger field so textFieldDidBeginEditing re-fires on next tap
            self.uiMode = .emoji
        }

        // Wire emoji search overlay callbacks
        keyboardView.emojiSearchOverlay.onSelect = { [weak self] emoji in
            guard let self else { return }
            // Insert directly into host document (NOT via insertTargeted, which would
            // route into the search field since inputTarget == .emojiSearch).
            self.textDocumentProxy.insertText(emoji)
            // EmojiRecents.add is already called inside the overlay on tap.
        }
        keyboardView.emojiSearchOverlay.onDismiss = { [weak self] in
            guard let self = self else { return }
            self.inputTarget = .hostApp
            self.keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
            self.keyboardView.emojiPanelView.searchField.resignFirstResponder() // resign trigger field so textFieldDidBeginEditing re-fires on next tap
            self.uiMode = .emoji
        }

        // Route emoji-panel ABC button dismissal through uiMode so toggle state stays in sync
        keyboardView.onReturnToLetters = { [weak self] in
            self?.uiMode = .letters
        }
    }

    private func installOrUpdateHeightConstraint() {
        if heightConstraint == nil {
            heightConstraint = view.heightAnchor.constraint(equalToConstant: 256)
            heightConstraint?.priority = .defaultHigh
            heightConstraint?.isActive = true
        }
    }

    private func updateKeyboardHeight(for mode: UIMode) {
        installOrUpdateHeightConstraint()
        let base: CGFloat = 256
        heightConstraint?.constant = (mode == .emojiSearch) ? base + EmojiSearchOverlay.overlayHeight : base
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    // MARK: - Mic Button

    private func handleMicButtonTap() {
        switch state {
        case .idle:
            guard hasFullAccess else {
                state = .error("Full Access required. Settings \u{2192} General \u{2192} Keyboard \u{2192} Ritoras \u{2192} Allow Full Access.")
                return
            }
            openContainerAppForDictation()
        case .recording:
            // First tap: enter confirmation state, start 3s timer
            FileLogger.shared.debug(.keyboard, "Mic: .recording -> .waitingConfirm")
            state = .waitingConfirm
            scheduleConfirmStopTimeout()

        case .waiting:
            // First tap: enter confirmation state, start 3s timer
            FileLogger.shared.debug(.keyboard, "Mic: .waiting -> .waitingConfirm")
            state = .waitingConfirm
            scheduleConfirmStopTimeout()
        case .waitingConfirm:
            // Second tap within 3s: cancel dictation
            cancelDictation()
        case .error:
            state = .idle
            serverPollTimer?.invalidate()
        default:
            break   // ignore taps while openingApp/inserting
        }
    }

    // MARK: - Dictation via Container App

    private func openContainerAppForDictation() {
        // Clear any stale data from previous sessions
        clearDeferredResult()
        serverPollTimer?.invalidate()
        serverPollTimer = nil
        serverPollUnresponsiveCount = 0
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        lastSeenSnapshotRevision = 0
        consecutiveSnapshotMisses = 0

        let id = UUID()
        pendingRequestId = id
        pendingRequestStart = Date().timeIntervalSince1970

        // Capture the document identifier of the current text field so
        // insertDictationResult can defer the result if the field changed.
        dictationTargetDocId = textDocumentProxy.documentIdentifier

        FileLogger.shared.debug(.keyboard, "dictation start footprint",
            payload: ["id": id.uuidString, "footprint": MemoryMonitor.currentFootprint()])

        FileLogger.shared.debug(.keyboard, "openContainerApp", payload: [
            "id": id.uuidString
        ])

        // Build URL with id query param
        var components = URLComponents(url: SharedConfig.Defaults.dictateURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        guard let url = components.url else {
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .error("Couldn't create dictation URL.")
            return
        }

        state = .openingApp

        // Use responder chain traversal — extensionContext.open() does NOT work for keyboard extensions
        FileLogger.shared.info(.keyboard, "Opening container app for dictation",
                               payload: ["id": id.uuidString, "url": url.absoluteString])

        let opened = openURL(url, id: id)
        if !opened {
            FileLogger.shared.error(.keyboard, "Failed to traverse responder chain",
                                    payload: ["url": url.absoluteString, "id": id.uuidString])
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .error("Couldn't open Ritoras app. Make sure it's installed.")
        }
    }

    /// Opens a URL by traversing the responder chain to find UIApplication.
    /// This is the ONLY way to open URLs from a keyboard extension.
    /// extensionContext.open() does NOT work for keyboard extensions (returns false by design).
    @discardableResult
    private func openURL(_ url: URL, id: UUID) -> Bool {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                application.open(url, options: [:]) { [weak self] success in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if success {
                            FileLogger.shared.info(.keyboard, "Container app opened successfully, waiting for dictation",
                                                   payload: ["id": id.uuidString])
                            self.state = .waiting
                            self.startWaitingForDictation(id: id)
                        } else {
                            FileLogger.shared.error(.keyboard, "Failed to open container app",
                                                    payload: ["id": id.uuidString])
                            self.state = .error("Couldn't open Ritoras app. Make sure it's installed.")
                        }
                    }
                }
                return true
            }
            responder = r.next
        }
        return false
    }

    private func startWaitingForDictation(id: UUID) {
        FileLogger.shared.debug(.keyboard, "darwin observer registered", payload: [
            "id": id.uuidString
        ])

        // Register state-changed Darwin observer to trigger app-group snapshot refresh
        darwinStateChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinStateChangedNotificationName) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.appearRefreshTask?.cancel()
                self?.appearRefreshTask = Task { [weak self] in
                    await self?.refreshFromSharedState()
                }
            }
        }

        // Start timeout timer
        waitTimer = Timer.scheduledTimer(withTimeInterval: SharedConfig.Defaults.dictationTimeoutSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTimeout()
            }
        }
    }

    // MARK: - App-Group Snapshot Polling

    /// Reads the current dictation snapshot from the app-group UserDefaults and
    /// returns it only if it matches `id` and carries a higher revision than
    /// `lastSeenSnapshotRevision` (preventing re-processing of stale data).
    /// Updates `lastSeenSnapshotRevision` on match so the same snapshot is not
    /// returned twice.
    private func readSharedSnapshot(for id: UUID) -> DictationPayload? {
        // Fast path: terminal-result file in the app-group container.
        // Data(contentsOf:) reads committed filesystem state with no caching layer,
        // bypassing the ~1–2s cfprefsd propagation lag of UserDefaults. Only
        // terminal payloads are written to the file, so a hit here is always
        // terminal. On any miss/stale/id-mismatch, fall through to UserDefaults.
        if let filePayload = SharedConfig.terminalResultFile(),
           filePayload.id == id {
            let fileRev = filePayload.revision ?? 0
            if fileRev > lastSeenSnapshotRevision {
                lastSeenSnapshotRevision = fileRev
                FileLogger.shared.debug(.keyboard, "snapshot read: hit (file fast path)",
                                        payload: ["status": filePayload.status.rawValue,
                                                  "rev": fileRev,
                                                  "id": String(filePayload.id.uuidString.prefix(8))])
                return filePayload
            }
        }
        // Fallback: app-group UserDefaults snapshot (cfprefsd, ~1–2s propagation).
        guard let payload = SharedConfig.dictationSnapshot() else {
            FileLogger.shared.debug(.keyboard, "snapshot read: miss no snapshot")
            return nil
        }
        guard payload.id == id else {
            FileLogger.shared.debug(.keyboard, "snapshot read: miss id mismatch",
                                    payload: ["expected": String(id.uuidString.prefix(8)),
                                              "got": String(payload.id.uuidString.prefix(8))])
            return nil
        }
        let rev = payload.revision ?? 0
        guard rev > lastSeenSnapshotRevision else {
            FileLogger.shared.debug(.keyboard, "snapshot read: miss revision stale",
                                    payload: ["lastSeen": lastSeenSnapshotRevision, "payload": rev])
            return nil
        }
        lastSeenSnapshotRevision = rev
        FileLogger.shared.debug(.keyboard, "snapshot read: hit",
                                payload: ["status": payload.status.rawValue,
                                          "rev": rev,
                                          "id": String(payload.id.uuidString.prefix(8))])
        return payload
    }

    /// Reads the current dictation snapshot from the app-group. Called from
    /// the snapshot poll timer and from the Darwin state-changed notification.
    /// The app-group snapshot (via `readSharedSnapshot`) is the sole channel.
    private func refreshFromSharedState() async {
        guard let id = pendingRequestId else {
            return
        }
        FileLogger.shared.debug(.keyboard, "refreshFromSharedState entry",
                                payload: ["id": String(id.uuidString.prefix(8))])

        // App-group snapshot is the PRIMARY channel
        if let payload = readSharedSnapshot(for: id) {
            switch payload.status {
            case .completed:
                handleTerminalResult(id: payload.id, text: payload.text, errorMessage: nil)
            case .error:
                handleTerminalResult(id: payload.id, text: nil, errorMessage: payload.errorMessage ?? "Transcription failed")
            case .cancelled:
                stopDictationTransports()
                pendingRequestId = nil
                dictationTargetDocId = nil
                state = .idle
            case .recording, .transcribing:
                updateRecordingInProgressUI(phase: payload.status.rawValue)
            }
            consecutiveSnapshotMisses = 0
            return
        }

        // Miss — no matching snapshot this poll cycle. Increment counter and
        // start /jobs server polling if the threshold is reached and polling
        // is not already running.
        consecutiveSnapshotMisses += 1
        FileLogger.shared.debug(.keyboard, "snapshot miss",
                                payload: ["consecutive": consecutiveSnapshotMisses])
        if consecutiveSnapshotMisses >= 6, serverPollWorkItem == nil {
            startServerPolling()
        }
    }

    /// Starts a 0.5s repeating timer that calls `refreshFromSharedState`.
    /// Uses `DispatchSourceTimer` (negligible memory overhead) instead of
    /// `Timer` to avoid RunLoop coupling in the keyboard extension.
    /// This is a safety net against dropped Darwin notifications.
    private func startSnapshotPolling() {
        stopSnapshotPolling()
        // Snapshot poll runs until the dictation resolves or the 900s dictation timeout fires.
        // /jobs server polling starts only after 6 consecutive snapshot misses
        // (container app is not writing snapshots).
        // First fire is at +0.2s to catch an in-flight terminal result quickly
        // after wake (viewDidAppear already did an immediate refresh), then
        // settles to the normal 0.5s cadence.
        let initialDelay: TimeInterval = 0.2
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + initialDelay, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            Task { await self?.refreshFromSharedState() }
        }
        timer.resume()
        snapshotPollTimer = timer
    }

    private func stopSnapshotPolling() {
        snapshotPollTimer?.cancel()
        snapshotPollTimer = nil
    }

    /// Shared terminal handler for both app-group and localhost result paths.
    /// Uses `lastProcessedPayloadId` for idempotency across transports — once
    /// a payload ID is processed, no other path will re-insert or re-state it.
    /// Text takes priority: if non-empty, inserts and transitions via
    /// `insertDictationResult`. Otherwise transitions to the error state
    /// (preventing silent hangs from empty-text results).
    @MainActor
    private func handleTerminalResult(id: UUID, text: String?, errorMessage: String?) {
        guard id != lastProcessedPayloadId else { return }
        lastProcessedPayloadId = id
        SharedConfig.clearTerminalResultFile()   // hygiene — keep file from lingering for next dictation
        stopDictationTransports()
        if let text = text, !text.isEmpty {
            insertDictationResult(text: text)
        } else {
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .error(errorMessage ?? "Transcription failed")
        }
    }

    /// Updates the recording-in-progress UI based on the phase string.
    /// This is the Symptom 4 fix: transitions from `.idle` to `.waiting` when
    /// the server reports "recording" or "transcribing", so the mic button
    /// shows the active state without waiting for a localhost response.
    private func updateRecordingInProgressUI(phase: String) {
        switch phase {
        case "recording":
            state = .recording
        case "transcribing":
            state = .waiting
        case "idle", "done", "error":
            // Don't change state here — handleTerminalResult handles terminal states
            break
        default:
            // Treat any unrecognized non-terminal phase as in-flight rather than
            // leaving the UI stuck in a stale state.
            state = .waiting
        }
    }

    private func handleTimeout() {
        FileLogger.shared.warn(.keyboard, "Dictation timed out",
                               payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
        waitTimer = nil
        pendingRequestId = nil
        dictationTargetDocId = nil
        state = .error("Dictation timed out. Try again.")
    }

    /// Starts a 3-second timeout. If the user does not tap again before it fires,
    /// the keyboard reverts from .waitingConfirm back to .waiting (still polling).
    private func scheduleConfirmStopTimeout() {
        confirmStopTimer?.invalidate()
        FileLogger.shared.debug(.keyboard, "confirmStopTimer scheduled (3s)")
        confirmStopTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.state == .waitingConfirm {
                    FileLogger.shared.debug(.keyboard, "confirmStopTimeout fired — reverting to .waiting")
                    self.state = .waiting  // revert to waiting (still polling)
                }
            }
        }
    }

    // MARK: - Pending Dictation (Recovery on Keyboard Reappear)

    private func checkForPendingDictation() {
        guard let id = pendingRequestId else {
            state = .idle
            return
        }
        FileLogger.shared.info(.keyboard, "Resuming pending dictation",
                               payload: ["pendingRequestId": id.uuidString])
        state = .waiting

        // Re-register the state-changed Darwin observer (it was torn down in viewWillDisappear).
        if darwinStateChangedToken == nil {
            darwinStateChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinStateChangedNotificationName) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.appearRefreshTask?.cancel()
                    self?.appearRefreshTask = Task { [weak self] in
                        await self?.refreshFromSharedState()
                    }
                }
            }
        }

        // Start snapshot polling.
        startSnapshotPolling()

        // Recreate the waitTimer if it was invalidated in viewWillDisappear.
        // Use the remaining time from the original 900s dictation timeout.
        if waitTimer == nil, pendingRequestStart > 0 {
            let elapsed = Date().timeIntervalSince1970 - pendingRequestStart
            let remaining = max(SharedConfig.Defaults.dictationTimeoutSeconds - elapsed, 0)
            if remaining > 0 {
                waitTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.handleTimeout() }
                }
            }
        }

    }

    /// Tears down every active result-transport (timers + Darwin observer) so that
    /// once one path resolves the dictation, no competing path re-inserts the text.
    private func stopDictationTransports() {
        currentPollTask?.cancel()
        currentPollTask = nil
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        serverPollTimer?.invalidate()
        darwinStateChangedToken = nil
        confirmStopTimer?.invalidate()
        confirmStopTimer = nil
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        stopSnapshotPolling()
    }

    /// Cancels the common subset of outstanding async work across both
    /// viewWillDisappear and deinit. Does NOT touch Darwin tokens
    /// (darwinStateChangedToken, darwinSettingsChangedToken), which are
    /// intentionally kept alive across disappear and nilled only in deinit.
    private func cancelOutstandingAsyncWork() {
        // Timers
        waitTimer?.invalidate()
        waitTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        serverPollTimer?.invalidate()
        serverPollTimer = nil
        confirmStopTimer?.invalidate()
        confirmStopTimer = nil

        // DispatchWorkItems
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        errorResetWorkItem?.cancel()
        errorResetWorkItem = nil
        suggestionRefreshWorkItem?.cancel()
        suggestionRefreshWorkItem = nil
        autocorrectWorkItem?.cancel()
        autocorrectWorkItem = nil

        // URLSessionDataTask
        currentPollTask?.cancel()
        currentPollTask = nil

        // Backspace state
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0

        // Snapshot polling
        stopSnapshotPolling()

        // Stored Tasks (supersession-by-cancellation)
        appearRefreshTask?.cancel()
        appearRefreshTask = nil

        // Suggestion lookup (releases the engine-capturing work item)
        keyboardView?.cancelSuggestionLookup()
    }

    /// Cancels the current dictation: stops all polling, clears the pending
    /// request (both in-memory and UserDefaults), and resets the keyboard to
    /// idle. This is a local-only operation — it does NOT attempt to notify
    /// the container app (which may be crashed). The container app cleans up
    /// via its own timeout/error handling.
    private func cancelDictation() {
        confirmStopTimer?.invalidate()
        confirmStopTimer = nil
        stopDictationTransports()
        clearDeferredResult()
        FileLogger.shared.debug(.keyboard, "Dictation cancelled by user",
                                payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
        pendingRequestId = nil
        dictationTargetDocId = nil
        state = .idle
    }

    /// Inserts the transcribed text, clears the pending request, and resets the
    /// keyboard to idle. Centralizes the shared insert+reset flow and guarantees
    /// every other transport is stopped first (prevents double-insert now that the
    /// Darwin observer and server polling can run concurrently on resume).
    private func insertDictationResult(text: String) {
        FileLogger.shared.debug(.keyboard, "dictation stop footprint",
            payload: ["footprint": MemoryMonitor.currentFootprint()])

        let totalElapsed = pendingRequestStart > 0
            ? (Date().timeIntervalSince1970 - pendingRequestStart) * 1000 : 0
        FileLogger.shared.debug(.keyboard, "insert elapsed",
                                payload: ["total_elapsed_ms": totalElapsed])
        FileLogger.shared.info(.keyboard, "insert", payload: [
            "id": pendingRequestId?.uuidString ?? "nil",
            "length": text.count,
            "total_elapsed_ms": totalElapsed
        ])

        // If the keyboard view is not in a window (hidden with no active text field),
        // textDocumentProxy.insertText would silently no-op. Defer the paste until
        // the keyboard reappears.
        guard self.view.window != nil else {
            FileLogger.shared.info(.keyboard, "Deferring dictation insertion — keyboard view is hidden",
                                   payload: ["length": text.count])
            storeDeferredResult(text: text)
            stopDictationTransports()
            pendingRequestId = nil
            dictationTargetDocId = nil
            return
        }

        // Active emoji-search recovery: if the insertion target is the internal emoji
        // search field, redirect to the host app and exit search mode so the dictation
        // result reaches the intended text field.
        if inputTarget != .hostApp {
            FileLogger.shared.warn(.keyboard, "Dictation result arrived while inputTarget != .hostApp — recovering",
                                   payload: ["inputTarget": String(describing: inputTarget)])
            inputTarget = .hostApp
            keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
            if uiMode == .emojiSearch {
                uiMode = .emoji
            }
        }

        // No-field gate: if there is genuinely no focused text field (zero UUID),
        // defer the result so it can be inserted when the user taps into a field.
        if textDocumentProxy.documentIdentifier == UUID() {
            FileLogger.shared.warn(.keyboard, "Dictation result arrived with no focused field — deferring",
                                   payload: ["documentIdentifier": textDocumentProxy.documentIdentifier.uuidString])
            storeDeferredResult(text: text)
            stopDictationTransports()
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .waiting
            return
        }

        FileLogger.shared.info(.keyboard, "insertDictationResult entry",
                               payload: ["length": text.count, "preview": String(text.prefix(30))])
        stopDictationTransports()
        pendingRequestId = nil
        dictationTargetDocId = nil
        if text.isEmpty {
            state = .error("Nothing was heard. Try again.")
            return
        }
        state = .inserting
        textDocumentProxy.insertText(normalizedDictationInsertion(of: text))
        FileLogger.shared.info(.keyboard, "Inserted dictation",
                               payload: ["length": text.count, "preview": String(text.prefix(30))])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            FileLogger.shared.debug(.keyboard, "Dictation insertion complete, resetting to idle")
            self?.state = .idle
        }
    }

    // MARK: - Deferred Result (Keyboard Hidden)

    /// Stores a dictation result in UserDefaults when the keyboard is hidden,
    /// so it can be recovered and auto-pasted on the next viewDidAppear.
    private func storeDeferredResult(text: String) {
        UserDefaults.standard.set(text, forKey: "ritoras_deferred_text")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ritoras_deferred_ts")
    }

    /// Clears the deferred result from UserDefaults. Called when starting
    /// a new dictation or when explicitly cancelling.
    private func clearDeferredResult() {
        UserDefaults.standard.removeObject(forKey: "ritoras_deferred_text")
        UserDefaults.standard.removeObject(forKey: "ritoras_deferred_ts")
    }

    // MARK: - Server Polling (Works when app is backgrounded)

    /// Polls with adaptive backoff: fast (0.3s) for the first 5 polls to catch
    /// quick results, then backs off to 1.2s to limit server load. Each cycle
    /// polls the Whisper /jobs/{id} endpoint directly.
    private func startServerPolling() {
        serverPollCount = 0
        serverPollUnresponsiveCount = 0
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        scheduleNextServerPoll()
    }

    /// Schedules the next server poll with an adaptive interval:
    /// - 0.3s for polls 0-4 (first ~1.5s total) — catches most results sooner.
    /// - 1.2s for poll 5+ — limits server load for long-running transcriptions.
    /// Cancels itself via the `pendingRequestId` guard when the request resolves.
    private func scheduleNextServerPoll() {
        guard pendingRequestId != nil else { return }
        let interval: TimeInterval = serverPollCount < 5 ? 0.3 : 1.2
        let workItem = DispatchWorkItem { [weak self] in
            self?.performServerPollCycle()
        }
        serverPollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    /// One cycle of server polling. Increments the poll counter, polls
    /// the Whisper /jobs/{id} endpoint directly (source of truth), then
    /// schedules the next poll. Cancellation is handled by the
    /// `pendingRequestId` guard in `scheduleNextServerPoll`.
    private func performServerPollCycle() {
        guard let id = pendingRequestId else { return }
        serverPollCount += 1
        serverPollUnresponsiveCount += 1

        if serverPollUnresponsiveCount >= 120 {  // ~140s of unresponsive polls
            stopDictationTransports()
            serverPollWorkItem?.cancel()
            serverPollWorkItem = nil
            FileLogger.shared.warn(.keyboard, "Server polling timed out (120 unresponsive cycles)",
                                   payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil",
                                             "serverPollUnresponsiveCount": serverPollUnresponsiveCount])
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .error("Dictation timed out. Try again.")
            return
        }

        // Whisper /jobs/{id} direct (source of truth).
        pollWhisperJobStatus(id: id)

        scheduleNextServerPoll()
    }



    /// One-shot HTTP GET to Whisper's /jobs/{id} endpoint (source of truth).
    /// On terminal status (ready/failed), resolves the dictation directly.
    /// On non-terminal status (pending/transcribing/404/error), returns
    /// silently — the next poll cycle will retry.
    private func pollWhisperJobStatus(id: UUID) {
        let config = SharedConfig.load()
        // Prefer the probe-selected server (written by the container app on recording
        // start). Fall back to config.servers.first if the probe hasn't run, returned
        // nil, or the selected server is no longer in the configured list (user
        // removed it mid-dictation).
        let selected = SharedConfig.selectedServer().flatMap { s -> String? in
            config.servers.contains(s) ? s : nil
        }
        guard let server = selected ?? config.servers.first else { return }
        guard let url = URL(string: "\(server)/jobs/\(id.uuidString.lowercased())") else { return }

        FileLogger.shared.debug(.network, "poll job direct", payload: [
            "server": server,
            "jobId": id.uuidString.lowercased(),
            "source": selected != nil ? "probe" : "fallback_first"
        ])

        currentPollTask?.cancel()
        var request = URLRequest(url: url)
        request.timeoutInterval = SharedConfig.AsyncTranscription.pollRequestTimeout
        let task = SessionHolder.shared.get().dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let httpT0 = Date()
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            DispatchQueue.main.async {
                // 404 — job not found yet; keep polling.
                if statusCode == 404 {
                    FileLogger.shared.debug(.network, "poll job: 404, retrying next cycle",
                                            payload: ["statusCode": statusCode,
                                                      "jobId": id.uuidString.lowercased()])
                    return
                }

                // Superseded by the next poll cycle.
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    return
                }

                if error != nil {
                    FileLogger.shared.debug(.network, "poll job: network error, retrying next cycle",
                                            payload: ["statusCode": statusCode,
                                                      "error": error?.localizedDescription ?? "nil",
                                                      "jobId": id.uuidString.lowercased()])
                    return
                }

                guard let data = data else {
                    FileLogger.shared.debug(.network, "poll job: empty response, retrying next cycle",
                                            payload: ["jobId": id.uuidString.lowercased()])
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    FileLogger.shared.debug(.network, "poll job: unparseable body, retrying next cycle",
                                            payload: ["jobId": id.uuidString.lowercased(),
                                                      "bodyPreview": String(data: data, encoding: .utf8).map { String($0.prefix(100)) } ?? "?"])
                    return
                }

                let status = json["status"] as? String ?? "none"
                let text = json["text"] as? String
                let elapsed = Date().timeIntervalSince(httpT0) * 1000

                FileLogger.shared.debug(.keyboard, "poll job response", payload: [
                    "statusCode": statusCode,
                    "elapsed_ms": elapsed,
                    "status": status,
                    "hasText": text != nil ? "yes" : "no",
                    "jobId": id.uuidString.lowercased()
                ])

                switch status {
                case "ready":
                    guard self.pendingRequestId != nil else { return }
                    FileLogger.shared.info(.network, "poll job: status=ready",
                                           payload: ["jobId": id.uuidString.lowercased(),
                                                     "textLength": text?.count ?? 0])
                    self.handleTerminalResult(id: id, text: text, errorMessage: nil)

                case "failed":
                    guard self.pendingRequestId != nil else { return }
                    FileLogger.shared.info(.network, "poll job: status=failed",
                                           payload: ["jobId": id.uuidString.lowercased()])
                    self.handleTerminalResult(id: id, text: nil, errorMessage: "Transcription failed.")

                case "pending", "transcribing":
                    self.serverPollUnresponsiveCount = 0
                    FileLogger.shared.debug(.network, "poll job: still processing",
                                            payload: ["status": status, "jobId": id.uuidString.lowercased()])
                    // Next poll cycle will retry

                default:
                    FileLogger.shared.debug(.network, "poll job: unexpected status, retrying next cycle",
                                            payload: ["status": status, "jobId": id.uuidString.lowercased()])
                }
            }
        }
        currentPollTask = task
        task.resume()
    }

    // MARK: - Error Auto-Reset

    private func scheduleErrorReset() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if case .error = self.state {
                if self.pendingRequestId != nil {
                    // Recording still active — resume waiting instead of going idle
                    self.state = .waiting
                } else {
                    self.state = .idle
                }
            }
        }
        errorResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
    }
}

// MARK: - KeyboardViewDelegate

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardView(_ view: KeyboardView, didPerform action: KeyAction) {
        switch action {
        case .insertText(let s):
            let isTriggerPunct = SharedConfig.Defaults.autocorrectTriggerPunctuation.contains(s)
            let shouldAutoCorrect = isTriggerPunct && uiMode != .emoji
            let text = applyShift(to: s)
            insertTargeted(text)
            if shouldAutoCorrect {
                requestAsyncAutocorrect(triggerChar: text)
            }
            if shiftState == .upper {
                shiftState = .lower
            }
            recomputeAutoCap()
            scheduleSuggestionRefresh()
            if shouldAutoCorrect {
                wordOrigin.resetToTyping()
            }

        case .backspace:
            // REVERT-ON-BACKSPACE: If cursor is immediately after "corrected_word " and
            // the previous action was an autocorrect, revert instead of just deleting the space.
            if let correction = lastAutoCorrection,
               isCursorRightAfterTrailingSpaceFollowing(correction.replacement) {
                // Delete the trailing space.
                deleteTargetedBackward()
                // Delete the corrected word.
                for _ in 0..<correction.replacement.count {
                    deleteTargetedBackward()
                }
                // Re-insert the originally-typed word (NO trailing space — cursor lands mid-word).
                insertTargeted(correction.typed)
                // User rejected the autocorrect → keep their spelling (mirrors stock iOS behavior).
                LearnedWordsStore.shared.add(correction.typed)
                lastAutoCorrection = nil
                wordOrigin.resetToTyping()  // user is now back to editing a .typing word
            } else {
                deleteTargetedBackward()
                lastAutoCorrection = nil  // any non-immediate-backspace invalidates revert
            }
            recomputeAutoCap()
            scheduleSuggestionRefresh()

        case .shift:
            if effectiveAutoCapActive && shiftState == .lower {
                userOverrodeAutoCap = true
                refreshShiftVisual()
            } else {
                switch shiftState {
                case .lower: shiftState = .upper
                case .upper: shiftState = .locked
                case .locked: shiftState = .lower
                }
            }

        case .shiftLock:
            shiftState = .locked

        case .space:
            insertTargeted(" ")
            requestAsyncAutocorrect(triggerChar: " ")
            recomputeAutoCap()
            scheduleSuggestionRefresh()
            wordOrigin.resetToTyping()

        case .return:
            if inputTarget == .emojiSearch {
                keyboardView.emojiPanelView.onSearchReturn?()
            } else {
                insertTargeted("\n")
                requestAsyncAutocorrect(triggerChar: "\n")
                recomputeAutoCap()
                wordOrigin.resetToTyping()
                scheduleSuggestionRefresh()
            }

        case .toggleNumber:
            layoutMode = .numbers

        case .toggleLetters:
            layoutMode = .letters

        case .toggleSymbols:
            layoutMode = .symbols

        case .mic:
            handleMicButtonTap()

        case .emoji:
            switch uiMode {
            case .letters:      uiMode = .emoji
            case .emoji:        uiMode = .letters
            case .emojiSearch:
                inputTarget = .hostApp
                keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
                uiMode = .emoji
            }

        case .globe:
            advanceToNextInputMode()
        }
    }

    /// Strips display-only quotes wrapping an unknown-verbatim candidate.
    /// The quotes exist only in the suggestion-bar rendering; the document
    /// and the learned-words store must see the bare word.
    private func deQuotedSuggestion(_ text: String) -> String {
        let isQuoted = text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"")
        return isQuoted ? String(text.dropFirst().dropLast()) : text
    }

    func keyboardView(_ view: KeyboardView, didLongPressSuggestion text: String) {
        let bareWord = deQuotedSuggestion(text)

        // Learn-only gesture — must NOT insert or modify text.
        LearnedWordsStore.shared.add(bareWord)

        // Haptic confirmation so the user knows the word was learned.
        HapticsManager.shared.tapImpact()
    }

    func keyboardView(_ view: KeyboardView, didTapSuggestion text: String) {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""

        // Extract the typed word before deleting it (needed for the learn path).
        let typedWord = CurrentWordExtractor.extract(from: context).currentWord

        // Strip display-only quotes wrapping an unknown-verbatim candidate.
        // The quotes exist only in the suggestion-bar rendering (Step 2.3);
        // the document and the learned-words store must see the bare word.
        let insertText = deQuotedSuggestion(text)
        let isQuotedVerbatim = (insertText != text)

        var deleteCount = 0
        for char in context.reversed() {
            if char.isLetter || char.isNumber {
                deleteCount += 1
            } else {
                break
            }
        }
        for _ in 0..<deleteCount {
            deleteTargetedBackward()
        }
        insertTargeted(insertText + " ")
        wordOrigin.markSuggestionTap()    // Lock persists until the next separator handler clears it
        lastAutoCorrection = nil          // Suggestion tap invalidates any pending revert
        // Refresh is async; the token guard rejects any result whose captured state no longer matches.
        keyboardView.refreshSuggestions()

        // Learn the word the user kept.
        //
        // R1: Tapping the verbatim candidate (the quoted form) learns the
        //     user's typed word immediately.
        // R2: Tapping any candidate that matches the typed word
        //     case-insensitively also learns the typed form (preserves the
        //     user's actual spelling). The store normalizes case on add.
        if isQuotedVerbatim {
            LearnedWordsStore.shared.add(insertText)
        } else if !typedWord.isEmpty,
                  typedWord.lowercased() == insertText.lowercased() {
            LearnedWordsStore.shared.add(typedWord)
        }
    }

    func keyboardViewSuggestionSnapshot(_ view: KeyboardView) -> SuggestionInputSnapshot? {
        guard inputTarget == .hostApp else { return nil }
        if predictionEngine == nil { buildPredictionEngine() }
        guard isPredictionEngineReady, predictionEngine != nil else { return nil }
        let context = textDocumentProxy.documentContextBeforeInput
        let extracted = CurrentWordExtractor.extract(from: context)
        return SuggestionInputSnapshot(
            currentWord: extracted.currentWord,
            lookupWord: extracted.lookupWord,
            previousWord: extracted.previousWord,
            previousWord2: extracted.previousWord2
        )
    }

    func keyboardViewPredictionEngine(_ view: KeyboardView) -> PredictionEngine? {
        return predictionEngine
    }

    func keyboardContextToken(_ view: KeyboardView) -> UInt64 {
        guard inputTarget == .hostApp else { return 0 }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let suffix = String(context.suffix(50))
        let currentWord = CurrentWordExtractor.extract(from: context).currentWord
        return ContextHash.fnv1a("\(suffix)|\(currentWord)")
    }

    /// Debounced suggestion refresh (30ms coalescing window).
    /// Replaces direct `keyboardView.refreshSuggestions()` calls at most typing
    /// call sites so that rapid keystrokes do not re-query the prediction engine
    /// redundantly. The 30ms window is below human perception but effectively
    /// coalesces typematic-repeat bursts.
    private func scheduleSuggestionRefresh(coalescing: TimeInterval = 0.03) {
        suggestionRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.keyboardView.refreshSuggestions()
        }
        suggestionRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + coalescing, execute: workItem)
    }

    func keyboardViewMicState(_ view: KeyboardView) -> KeyboardState {
        return state
    }

    // MARK: - Backspace Long-Press

    func keyboardViewBackspaceDidBegin(_ view: KeyboardView) {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceSingleCharCount = 0
        backspacePhase = nil
        deleteTargetedBackward()
        backspaceSingleCharCount = 1
        scheduleSuggestionRefresh()
        backspacePhase = .charRepeat
        scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceInitialRepeatDelay, repeats: false)
    }

    func keyboardViewBackspaceDidEnd(_ view: KeyboardView) {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
    }

    // MARK: - Text Changes

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)

        lastAutoCorrection = nil  // host text change invalidates any pending revert
        // SYNC: system-signaled textDidChange bypasses debounce so the suggestion bar
        // updates immediately — debounce here would feel laggy after external edits.
        keyboardView.refreshSuggestions()
        recomputeAutoCap()

        // Flush deferred dictation result if one exists (the user has now
        // focused/activated a text field).
        if let deferredText = UserDefaults.standard.string(forKey: "ritoras_deferred_text"),
           !deferredText.isEmpty {
            let deferredTs = UserDefaults.standard.double(forKey: "ritoras_deferred_ts")
            let age = deferredTs > 0 ? Date().timeIntervalSince1970 - deferredTs : 0
            guard age < 300 else {
                clearDeferredResult()
                return
            }
            FileLogger.shared.info(.keyboard, "Inserting deferred dictation result (textDidChange)",
                                   payload: ["length": deferredText.count, "age": age])
            clearDeferredResult()
            state = .inserting
            textDocumentProxy.insertText(normalizedDictationInsertion(of: deferredText))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state = .idle
            }
        }
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        backspaceNilContextRetries = 0
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)

        lastAutoCorrection = nil  // cursor move invalidates any pending revert
        backspaceNilContextRetries = 0
        recomputeAutoCap()

        // Flush deferred dictation result if one exists (the user has now
        // focused/activated a text field).
        if let deferredText = UserDefaults.standard.string(forKey: "ritoras_deferred_text"),
           !deferredText.isEmpty {
            let deferredTs = UserDefaults.standard.double(forKey: "ritoras_deferred_ts")
            let age = deferredTs > 0 ? Date().timeIntervalSince1970 - deferredTs : 0
            guard age < 300 else {
                clearDeferredResult()
                return
            }
            FileLogger.shared.info(.keyboard, "Inserting deferred dictation result (selectionDidChange)",
                                   payload: ["length": deferredText.count, "age": age])
            clearDeferredResult()
            state = .inserting
            textDocumentProxy.insertText(normalizedDictationInsertion(of: deferredText))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state = .idle
            }
        }
    }

    // MARK: - Autocorrect-on-space

    /// Dispatches an async autocorrect evaluation on the prediction build queue.
    ///
    /// The trigger character (space / punct / return) has already been inserted
    /// by the caller. This method captures a snapshot of the word context on
    /// the main thread, runs spell-check + engine lookup + scoring off-main,
    /// then re-validates on the main thread with a strict context guard before
    /// applying the correction.
    ///
    /// Stale results (superseded by further typing, cursor movement, or
    /// suggestion taps) are silently dropped by the application guard.
    private func requestAsyncAutocorrect(triggerChar: String) {
        // --- Synchronous early-return guards (same as today) ---
        guard inputTarget == .hostApp else { return }
        guard settingsCache.autocorrectOnSpace else { return }

        if AutoCorrectTraits.shouldSuppress(
            keyboardType: textDocumentProxy.keyboardType,
            autocorrectionType: textDocumentProxy.autocorrectionType,
            spellCheckingType: textDocumentProxy.spellCheckingType
        ) { return }

        guard wordOrigin.current == .typing else { return }

        // The trigger has already been inserted. Extract the typed word from
        // context BEFORE the trigger char was appended.
        let contextAfterInsert = textDocumentProxy.documentContextBeforeInput ?? ""
        let contextBeforeTrigger = String(contextAfterInsert.dropLast())
        let extracted = CurrentWordExtractor.extract(from: contextBeforeTrigger)

        guard extracted.currentWord == extracted.lookupWord else { return }
        guard !extracted.lookupWord.isEmpty,
              let engine = predictionEngine,
              isPredictionEngineReady else { return }

        // --- Snapshot on main thread (all Sendable) ---
        let typedWord = extracted.lookupWord
        let currentWord = extracted.currentWord
        let previousWord = extracted.previousWord
        let previousWord2 = extracted.previousWord2
        let contextAtDispatch = contextAfterInsert  // ends with typedWord + triggerChar
        let isLearned = LearnedWordsStore.shared.contains(typedWord)
        let originAtDispatch = wordOrigin.current

        // Defensive: the suffix must match what we expect.
        guard contextAtDispatch.hasSuffix(typedWord + triggerChar) else { return }

        // Cancel any in-flight autocorrect evaluation (bounds SymSpell
        // concurrency and avoids wasted CPU).
        autocorrectWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self = self, let engine = engine else { return }

            // --- Off-main: pure compute only ---
            let isMisspelled: Bool = {
                let checker = UITextChecker()
                let nsString = typedWord as NSString
                let range = NSRange(location: 0, length: nsString.length)
                let misspelledRange = checker.rangeOfMisspelledWord(
                    in: typedWord,
                    range: range,
                    startingAt: 0,
                    wrap: false,
                    language: "en-US"
                )
                return misspelledRange.location != NSNotFound
            }()

            let top = engine.topCorrection(
                forCurrentWord: currentWord,
                lookupWord: typedWord,
                previousWord: previousWord,
                previousWord2: previousWord2
            )

            let fusionActive = engine.fusionIsActive(previousWord: previousWord)
            let config = AutocorrectController.Config(
                minWordLength: SharedConfig.Defaults.autocorrectMinWordLength,
                maxWordLength: SharedConfig.Defaults.autocorrectMaxWordLength,
                minConfidenceScore: fusionActive
                    ? SharedConfig.Defaults.autocorrectMinConfidenceScoreFused
                    : SharedConfig.Defaults.autocorrectMinConfidenceScore
            )

            let decision = AutocorrectController.evaluate(
                typedWord: typedWord,
                origin: originAtDispatch,
                topCorrection: top,
                isLearned: isLearned,
                isMisspelled: isMisspelled,
                config: config
            )

            // --- Back to main thread for guard + apply ---
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Liveness gate: if the keyboard is no longer in a window,
                // the textDocumentProxy is dead — reading it in
                // AutocorrectApplicationGuard.shouldApply (which reads
                // documentContextBeforeInput) would crash with SIGSEGV.
                if self.view.window == nil {
                    return
                }

                // Application guard: all three must hold or the result is stale.
                guard AutocorrectApplicationGuard.shouldApply(
                    snapshot: AutocorrectAsyncSnapshot(
                        typedWord: typedWord,
                        triggerChar: triggerChar
                    ),
                    liveContext: textDocumentProxy.documentContextBeforeInput ?? "",
                    isHostApp: inputTarget == .hostApp,
                    wordOrigin: wordOrigin.current
                ) else { return }

                switch decision {
                case .correct(_, let correction):
                    // No word learned here — intentionally.
                    //
                    // The correction target is already a valid dictionary word
                    // (learning it is a no-op), and the user's typed input was a
                    // misspelling that would pollute the dictionary. Only the
                    // revert-on-backspace path (L-revert) or an explicit long-press
                    // (L-longpress) should learn — not passive autocorrect-accept.
                    // Delete typedWord + triggerChar and re-insert correction + triggerChar.
                    // Byte-identical to today's synchronous outcome: document ends with
                    // `correction<triggerChar>` and cursor is at the end.
                    let deleteCount = typedWord.count + triggerChar.count
                    for _ in 0..<deleteCount {
                        deleteTargetedBackward()
                    }
                    insertTargeted(correction + triggerChar)
                    lastAutoCorrection = (typed: typedWord, replacement: correction)
                case .leaveAsIs:
                    lastAutoCorrection = nil
                }
            }
        }

        autocorrectWorkItem = workItem
        predictionBuildQueue.async(execute: workItem)
    }

    /// Returns true if the cursor sits immediately after an autocorrect of `word`,
    /// tolerating UITextProxy quirks (missing/multiple trailing whitespace).
    /// Delegates to `BackspaceRevertMatcher` for the pure logic; see that type's
    /// documentation for the matching contract and revert-path safety analysis.
    private func isCursorRightAfterTrailingSpaceFollowing(_ word: String) -> Bool {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        return BackspaceRevertMatcher.isCursorRightAfter(word: word, inContext: context)
    }

    /// Returns the text to insert so the document never has two consecutive spaces,
    /// regardless of what trailing whitespace the transcription carried or what the
    /// document already ends with.
    private func normalizedDictationInsertion(of text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if context.isEmpty { return trimmedText }
        if context.last?.isWhitespace == true { return trimmedText }
        return trimmedText + " "
    }

    // MARK: - Auto-Capitalization Helpers

    private var effectiveAutoCapActive: Bool { autoCapActive && !userOverrodeAutoCap }

    private var displayedShiftState: ShiftState {
        if shiftState == .lower && effectiveAutoCapActive { return .upper }
        return shiftState
    }

    private func recomputeAutoCap() {
        guard inputTarget == .hostApp else { return }
        // User-facing master toggle (default ON). Read from the App Group on every recompute.
        guard settingsCache.autoCapitalization else {
            autoCapActive = false
            lastAtSentenceStart = false
            lastRecomputedContext = nil
            refreshShiftVisual()
            return
        }

        // Respect the host field's text-input traits — no auto-cap in URL/email/numeric fields
        // or when the host explicitly disables capitalization.
        if AutoCapTraits.shouldSuppress(
            keyboardType: textDocumentProxy.keyboardType,
            autocapitalizationType: textDocumentProxy.autocapitalizationType
        ) {
            autoCapActive = false
            lastAtSentenceStart = false
            lastRecomputedContext = nil
            refreshShiftVisual()
            return
        }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        // Dedup: if context is unchanged since the last recompute, the result will be identical — skip.
        if context == lastRecomputedContext { return }
        let wants = AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: context)
        if wants && !lastAtSentenceStart {
            userOverrodeAutoCap = false
        }
        lastAtSentenceStart = wants
        autoCapActive = wants
        lastRecomputedContext = context
        refreshShiftVisual()
    }

    private func refreshShiftVisual() {
        keyboardView.apply(shift: displayedShiftState, layoutMode: layoutMode)
    }

    // MARK: - Helpers

    private func applyShift(to text: String) -> String {
        guard !text.isEmpty else { return text }
        let wantsCaps = shiftState != .lower || effectiveAutoCapActive
        guard wantsCaps else { return text }
        if text.rangeOfCharacter(from: .letters) != nil {
            return text.uppercased()
        }
        return text
    }

    // MARK: - Input Target Helpers

    private var hasTextInCurrentTarget: Bool {
        switch inputTarget {
        case .hostApp:     return textDocumentProxy.hasText
        case .emojiSearch: return !(keyboardView.emojiSearchOverlay.searchField.text?.isEmpty ?? true)
        }
    }

    private func insertTargeted(_ text: String) {
        switch inputTarget {
        case .hostApp:     textDocumentProxy.insertText(text)
        case .emojiSearch: keyboardView.emojiSearchOverlay.searchField.insertText(text)
        }
    }

    private func deleteTargetedBackward() {
        switch inputTarget {
        case .hostApp:
            textDocumentProxy.deleteBackward()
        case .emojiSearch:
            keyboardView.emojiSearchOverlay.searchField.deleteBackward()
        }
    }

    // MARK: - Backspace Timer

    private func scheduleBackspaceTimer(after interval: TimeInterval, repeats: Bool) {
        backspaceTimer?.invalidate()
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.handleBackspaceTick()
        }
    }

    private func handleBackspaceTick() {
        // In search mode, always use char-repeat (no word-mode) since the
        // search field is a single-line input with no need for word-level deletion.
        if inputTarget == .emojiSearch {
            guard hasTextInCurrentTarget else {
                backspaceTimer?.invalidate()
                backspaceTimer = nil
                backspacePhase = nil
                backspaceNilContextRetries = 0
                return
            }
            deleteTargetedBackward()
            HapticsManager.shared.tapImpact()
            scheduleSuggestionRefresh()
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceCharRepeatInterval, repeats: true)
            return
        }

        switch backspacePhase {
        case .charRepeat:
            deleteTargetedBackward()
            HapticsManager.shared.tapImpact()
            backspaceSingleCharCount += 1
            scheduleSuggestionRefresh()

            let context = textDocumentProxy.documentContextBeforeInput
            if context == nil || context?.isEmpty == true {
                backspaceNilContextRetries += 1
                if backspaceNilContextRetries > SharedConfig.Defaults.backspaceNilContextRetryLimit {
                    backspaceTimer?.invalidate()
                    backspaceTimer = nil
                    backspacePhase = nil
                    backspaceNilContextRetries = 0
                    return
                }
                scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceNilContextRetryInterval, repeats: false)
                return
            }

            backspaceNilContextRetries = 0

            if backspaceSingleCharCount >= SharedConfig.Defaults.backspaceCharsBeforeWordMode {
                backspacePhase = .wordRepeat
                scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceWordRepeatInterval, repeats: false)
            } else {
                scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceCharRepeatInterval, repeats: true)
            }

        case .wordRepeat:
            let context = textDocumentProxy.documentContextBeforeInput
            if context == nil || context?.isEmpty == true {
                // Host withholding context — retry after delay instead of deleting blind.
                backspaceNilContextRetries += 1
                if backspaceNilContextRetries > SharedConfig.Defaults.backspaceNilContextRetryLimit {
                    backspaceTimer?.invalidate()
                    backspaceTimer = nil
                    backspacePhase = nil
                    backspaceNilContextRetries = 0
                    return
                }
                scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceNilContextRetryInterval, repeats: false)
                return
            }

            // Got context — reset retries and do whole-word burst deletion.
            backspaceNilContextRetries = 0
            let n = BackspaceModel.wordUnitLength(for: context)
            guard n > 0 else {
                backspaceTimer?.invalidate()
                backspaceTimer = nil
                backspacePhase = nil
                return
            }
            for _ in 0..<n {
                deleteTargetedBackward()
                HapticsManager.shared.tapImpact()
            }
            scheduleSuggestionRefresh()
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceWordRepeatInterval, repeats: false)

        case nil:
            break
        }
    }
}
