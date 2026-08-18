import UIKit


private enum BackspacePhase {
    case charRepeat
    case wordRepeat
}

/// Fully-resolved retroactive candidate captured on main: the ring record plus
/// its live document offset and per-candidate spell-check state. The background
/// scan consumes ONLY this snapshot — it never touches the ring buffer or the
/// document off-main.
private struct RetroactiveCandidateSnapshot {
    let typedWord: String
    let lookupWord: String
    let offsetFromCursorEnd: Int
    let isLearned: Bool
    let isMisspelled: Bool
    let origin: WordOrigin
    let commitContextSuffix: String
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
            // Lean tag — avoids large strings under Jetsam cap
            FileLogger.shared.info(.keyboard, "state →", payload: ["state": KeyboardState.shortTag(state), "pendingId": String(pendingRequestId?.uuidString.prefix(8) ?? "nil")])
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
    private var inputTarget: InputTarget = .hostApp {
        didSet {
            // Any input-target switch invalidates a pending deferred autocorrect.
            keystrokeEpoch &+= 1
            recentWordBuffer.clear()
        }
    }

    /// Read-through shims: the prediction stack is process-global and persists
    /// across show/hide cycles (see SharedPredictionStack). Downstream call
    /// sites keep working unchanged while the real storage lives in the stack.
    private var predictionEngine: PredictionEngine? { SharedPredictionStack.shared.engineIfReady() }
    private var isPredictionEngineReady: Bool { SharedPredictionStack.shared.isReady }

    /// Identifies the keyboard process across VC instances. Set once per process launch.
    static let processLaunchId: String = UUID().uuidString
    /// Process-wide build counter. Owned by SharedPredictionStack (the
    /// process-global holder): advances exactly once per process lifetime,
    /// so this reads 1 from the first build onward — never 2, 3, … per show.
    private static var buildGeneration: Int { SharedPredictionStack.shared.generation }

    /// One-shot flag: set the first time the active spell language is
    /// unavailable on this device, so the `.debug` diagnostic fires at most
    /// once per process. Touched only on the main thread (applyLanguageSetting).
    private static var spellLanguageUnavailableLogged = false

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

    /// The word whose trailing σ was auto-converted to ς (Greek final sigma).
    /// Set when the conversion applies on a commit trigger; the next backspace
    /// that lands directly after the ς reverts it to σ (Apple system-keyboard
    /// behavior). Cleared by any other keystroke, navigation, external text
    /// change, language switch, or teardown.
    private var lastSigmaConvertedWord: String?

    // MARK: - Deferred Autocorrect (background compute)

    /// Monotonic keystroke epoch. Bumped by every document mutation, selection
    /// change, input-target switch, and teardown. Any background autocorrect
    /// result whose captured epoch no longer matches is dropped on the main-hop.
    /// This is the supersession guard for the background→main hop (GCD, not
    /// async/await — re-entrancy arrives via nested run-loop turns, and the
    /// epoch check covers it).
    private var keystrokeEpoch: UInt64 = 0

    /// Detects documentIdentifier churn (host input-session flapping, e.g.
    /// WKWebView+React) so the retroactive-correction apply path can pause
    /// while the host re-anchors the selection. Main-thread-only; must never
    /// be read inside a background work item.
    private var identityMonitor = DocumentIdentityMonitor()

    /// Serial background queue for the heavy autocorrect compute
    /// (PredictionEngine.topCorrection + AutocorrectController.evaluate),
    /// keeping SymSpell/LM scoring off the keystroke hot path.
    private let keyboardProcessingQueue = DispatchQueue(
        label: "com.ritoras.keyboard.processing",
        qos: .userInitiated
    )

    /// Cancellable handle for the deferred autocorrect compute + main apply hop.
    private var deferredKeystrokeWorkItem: DispatchWorkItem?

    /// Bounded ring of recently committed words eligible for retroactive
    /// autocorrect (≤4 entries, well under 1 KB — Jetsam-safe).
    private var recentWordBuffer = RecentWordBuffer()

    // MARK: - Dictation State

    private var waitTimer: Timer?
    private var errorResetWorkItem: DispatchWorkItem?
    private var suggestionRefreshWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollCount = 0

    /// Cancellable handle for the deferred-dictation flush so it can be
    /// torn down on disappear / context change. See scheduleDeferredDictationFlush.
    private var deferredFlushWorkItem: DispatchWorkItem?

    /// Identity gate for scheduleDeferredDictationFlush: remembers the last
    /// checked field identity so repeated textDidChange/selectionDidChange on
    /// the same field skip the UserDefaults read + work-item churn. Reset in
    /// viewDidAppear so a fresh appear always re-checks.
    private var deferredFlushLastCheckedDocId: UUID?
    private var deferredFlushHasChecked = false

    // MARK: - Snapshot Polling & Darwin Notifications

    private var snapshotPollTimer: DispatchSourceTimer?
    private var darwinStateChangedToken: DarwinObserverToken?

    /// Miss-streak thresholds for the snapshot fallback tiers. Internal
    /// constants, not user-tunable runtime parameters.
    private enum SnapshotThresholds {
        /// After this many consecutive app-group misses, poll the localhost
        /// /state endpoint. Deliberately 1: on SideStore the app-group
        /// container is structurally nil and cfprefsd lags ~1–2s, but the
        /// container app's in-memory payload holder is populated synchronously
        /// before the Darwin post — so localhost already holds the fresh
        /// payload when the first Darwin-driven refresh fires. Waiting one
        /// more cycle would miss the transient `.recording` phase.
        static let localhostFallbackMisses = 1
        /// After this many consecutive misses, start /jobs server polling as
        /// an emergency fallback (container app is not writing snapshots).
        static let serverPollMisses = 6
        /// After this many consecutive dead/no-session localhost probes while
        /// the keyboard is in `.recording`, treat the session as lost and reset
        /// to idle. ~3s of sustained probes at the 0.5s poll cadence, chosen to
        /// outlast transient listener restarts while the app's 10s health timer
        /// heals.
        static let sessionLostMisses = 6
    }

    /// Tracks consecutive snapshot misses (app-group read returned nil).
    /// The localhost /state fallback fires after
    /// `SnapshotThresholds.localhostFallbackMisses` miss(es); /jobs server
    /// polling starts after `SnapshotThresholds.serverPollMisses`.
    private var consecutiveSnapshotMisses: Int = 0
    /// Tracks consecutive localhost /state probes that returned no session or
    /// unreachable while the keyboard believed a recording was active. Reset on
    /// any positive payload, on a fresh dictation, and on keyboard reappear.
    private var consecutiveSessionEvidenceMiss: Int = 0
    /// Stored Task for refreshFromSharedState, cancelled on teardown and
    /// superseded on each new spawn to prevent interleaved concurrent executions.
    private var appearRefreshTask: Task<Void, Never>?

    /// The `documentIdentifier` of the text field that started the current
    /// dictation. Gate on this in `insertDictationResult` to defer results
    /// that arrive after the user switched text fields.
    private var dictationTargetDocId: UUID? = nil

    /// Dedup token: while a /stop or /cancel POST is in flight, ignore further
    /// stop/cancel requests. Set synchronously (before the Task) so a rapid
    /// double-tap is observed by the second call.
    private var stopCancelRequestInFlight = false

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

    /// Kicks the one-shot prediction stack load. The stack is process-global
    /// (SharedPredictionStack) and persists across show/hide cycles, so this
    /// is a no-op once the load has begun — no per-show rebuild.
    ///
    /// Gated on cold state: the completion fires for EVERY settled state
    /// (including `.ready`), so an ungated kick from viewDidLoad would
    /// refreshSuggestions → snapshot → loadIfNeeded(.ready) → refresh … on
    /// every run-loop cycle once the stack is ready.
    private func buildPredictionEngine() {
        guard !SharedPredictionStack.shared.isReady, !SharedPredictionStack.shared.isLoading else { return }
        SharedPredictionStack.shared.loadIfNeeded { [weak self] ok in
            DispatchQueue.main.async {
                self?.keyboardView?.refreshSuggestions()
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
        FileLogger.shared.debug(.keyboard, "AppGroupResolver outcome", payload: [
            "resolvedIdentifier": SharedConfig.Defaults.appGroupId,
            "strategy": AppGroupResolver.shared.resolvedStrategy,
            "bundleId": Bundle.main.bundleIdentifier ?? "?",
            "path": SharedConfig.snapshotFilePathDescription(),
            "containerAvailable": AppGroupResolver.shared.containerAvailable,
            "resolutionTrace": AppGroupResolver.shared.resolutionTrace
        ])
        // Full resolution diagnostics incl. ALTAppGroups.
        SharedConfig.logAppGroupDiagnostics(component: .keyboard)

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
                self.applyLanguageSetting()
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
        consecutiveSessionEvidenceMiss = 0
        appearRefreshTask?.cancel()
        appearRefreshTask = Task { @MainActor [weak self] in
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

        // Reset the deferred-flush identity gate: a fresh appear can observe a
        // new field identity, so the next flush check must run unconditionally.
        deferredFlushHasChecked = false

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
            if UserDefaults.standard.string(forKey: "ritoras_deferred_text")?.isEmpty == false {
                scheduleDeferredDictationFlush(reason: "viewDidAppear")
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
        applyLanguageSetting()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        installOrUpdateHeightConstraint()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Applies the active keyboard language as the runtime `primaryLanguage`,
    /// superseding the plist's `PrimaryLanguage` value (which stays "en-US").
    /// Called on appear (fresh cache) and on the settings-changed Darwin
    /// notification (after `settingsCache.refresh()`), on the main thread.
    ///
    /// Also syncs the key grid to the persisted language. Without this, a
    /// persisted Greek setting shows an English grid until the menu is used
    /// (the grid defaults to `.english` at construction). `setLanguage` is a
    /// no-op when the grid already matches, and only then resets to the
    /// letters layout — correct for a genuine language change.
    private func applyLanguageSetting() {
        let language = settingsCache.language
        primaryLanguage = language.bcp47Tag
        keyboardView.setLanguage(language)
        SharedPredictionStack.shared.switchLanguageIfNeeded(to: language) { [weak self] _ in
            DispatchQueue.main.async {
                self?.keyboardView?.refreshSuggestions()
            }
        }
        logSpellLanguageUnavailableIfNeeded()
        FileLogger.shared.info(.keyboard, "keyboard language set",
                               payload: ["language": language.rawValue])
    }

    /// One-time `.debug` log when the active spell language has no lexicon on
    /// this device (e.g. Greek without the Greek UITextChecker dictionary).
    /// `rangeOfMisspelledWord` then reports no misspellings, which is acceptable
    /// degradation: SymSpell still drives suggestions and autocorrect.
    private func logSpellLanguageUnavailableIfNeeded() {
        guard settingsCache.language == .greek,
              !UITextChecker.availableLanguages.contains(KeyboardLanguage.greek.appleSpellTag),
              !Self.spellLanguageUnavailableLogged else { return }
        Self.spellLanguageUnavailableLogged = true
        FileLogger.shared.debug(.keyboard, "UITextChecker unavailable for spell language",
            payload: ["language": KeyboardLanguage.greek.appleSpellTag])
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Tiered shed: drop only the KenLM trigram (~8-10 MB). The dictionary +
        // engine persist — rebuilding SymSpell (~25 MB) per memory warning would
        // reintroduce the per-cycle footprint climb this architecture removes.
        let before = MemoryMonitor.currentFootprint()
        let freed = SharedPredictionStack.shared.unloadTrigram()
        let after = MemoryMonitor.currentFootprint()
        FileLogger.shared.warn(.lifecycle,
            "didReceiveMemoryWarning: trigram shed \(before) → \(after) (\(freed) freed)")

        // Under memory pressure, shed restartable background work. When a dictation
        // is in flight, preserve its recovery path (waitTimer, polling, snapshot) so
        // the in-flight request can still complete or time out; shed only the
        // suggestion lookup, which is the heaviest restartable per-keystroke work.
        // When no dictation is active, the full teardown is safe.
        if pendingRequestId != nil {
            keyboardView.cancelSuggestionLookup()
        } else {
            cancelOutstandingAsyncWork()
        }
    }

    /// Keyboard hide: the prediction stack is retained (load-once per process).
    /// Nothing is shed here — the trigram is only shed on memory warning, and
    /// the dictionary + engine persist across show/hide cycles so the next show
    /// reuses the already-loaded stack instead of rebuilding ~25 MB.
    private func shedPredictionEngine() {
        FileLogger.shared.debug(.lifecycle, "hide — prediction stack retained",
            payload: ["buildId": Self.buildGeneration])
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

        // Wire the language picker: the suggestion-bar button presents the menu;
        // selection persists + applies the language; backdrop taps dismiss.
        keyboardView.languageTapped = { [weak self] in
            guard let self = self else { return }
            self.presentLanguageMenu()
        }
        keyboardView.languageMenu.onSelect = { [weak self] language in
            guard let self = self else { return }
            self.handleLanguageSelection(language)
        }
        keyboardView.languageMenu.onDismiss = { [weak self] in
            guard let self = self else { return }
            self.keyboardView.languageMenu.dismiss()
        }
    }

    // MARK: - Language Picker

    /// Shows the reusable language picker overlay, marked with the active language.
    private func presentLanguageMenu() {
        let menu = keyboardView.languageMenu
        guard menu.isHidden else { return }
        // The accent picker and the language menu are mutually exclusive
        // surfaces; dismiss the picker defensively before the menu opens.
        keyboardView.accentPicker.hide()
        menu.show(activeLanguage: keyboardView.currentLanguage)
    }

    /// Applies a menu selection: persists it, switches the key grid, resets to
    /// the letters layout, applies the runtime primaryLanguage, and swaps the
    /// prediction stack (SymSpell + providers) to the selected language.
    private func handleLanguageSelection(_ language: KeyboardLanguage) {
        keyboardView.languageMenu.dismiss()
        lastSigmaConvertedWord = nil  // a language switch closes the sigma revert window
        // Proceed when the selection differs from the grid OR the prediction
        // stack. They are tracked independently: at launch the grid may already
        // show the persisted language (see applyLanguageSetting's grid sync)
        // while the stack is still English (lazy Greek build) — re-selecting
        // that language must still swap the prediction stack.
        guard language != keyboardView.currentLanguage
            || language != SharedPredictionStack.shared.language else { return }
        SharedConfig.setKeyboardLanguage(language)
        keyboardView.setLanguage(language)
        layoutMode = .letters
        settingsCache.refresh()
        applyLanguageSetting()
        // Swap the prediction stack off the main thread (heavy dictionary build
        // for Greek; English is a no-op). Suggestions go cold during the swap
        // and come back when the new stack is ready.
        SharedPredictionStack.shared.switchLanguageIfNeeded(to: language) { [weak self] _ in
            DispatchQueue.main.async {
                self?.keyboardView?.refreshSuggestions()
            }
        }
        FileLogger.shared.info(.keyboard, "keyboard language switched",
                               payload: ["language": language.rawValue])
    }

    private func installOrUpdateHeightConstraint() {
        if heightConstraint == nil {
            heightConstraint = view.heightAnchor.constraint(equalToConstant: 265)
            heightConstraint?.priority = .defaultHigh
            heightConstraint?.isActive = true
        }
    }

    private func updateKeyboardHeight(for mode: UIMode) {
        installOrUpdateHeightConstraint()
        let base: CGFloat = 265
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
            FileLogger.shared.info(.keyboard, "Mic: .recording -> POST /stop")
            requestStop()

        case .waiting:
            FileLogger.shared.info(.keyboard, "Mic: .waiting -> POST /stop")
            requestStop()
        case .error:
            cancelOutstandingAsyncWork()
            state = .idle
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
        consecutiveSessionEvidenceMiss = 0

        let id = UUID()
        pendingRequestId = id
        FileLogger.shared.debug(.keyboard, "dictation start appgroup",
            payload: ["id": String(id.uuidString.prefix(8)),
                      "group": SharedConfig.Defaults.appGroupId,
                      "path": SharedConfig.snapshotFilePathDescription(),
                      "containerAvailable": AppGroupResolver.shared.containerAvailable])
        pendingRequestStart = Date().timeIntervalSince1970

        // Capture the document identifier of the current text field so
        // insertDictationResult can defer the result if the field changed.
        dictationTargetDocId = safeDocumentIdentifier()

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
                self?.appearRefreshTask = Task { @MainActor [weak self] in
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
        // Fast path: snapshot file in the app-group container.
        // Data(contentsOf:) reads committed filesystem state with no caching layer,
        // bypassing the ~1–2s cfprefsd propagation lag of UserDefaults. Any status
        // (recording, transcribing, completed, error, cancelled) may be present;
        // refreshFromSharedState dispatches by status. On any miss/stale/id-mismatch,
        // fall through to UserDefaults.
        if let filePayload = SharedConfig.snapshotFile(),
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

    /// Reads the current dictation snapshot on keyboard reappear, BYPASSING the
    /// revision guard of `readSharedSnapshot(for:)`. A concurrent Darwin-driven
    /// or appearRefreshTask `refreshFromSharedState` may have already consumed
    /// the current revision before this runs, so gating on `revision >
    /// lastSeenSnapshotRevision` would return nil and mask an in-progress
    /// recording. Still advances `lastSeenSnapshotRevision` so the poller does
    /// not reprocess the same snapshot. Terminal re-reads are deduplicated by
    /// `lastProcessedPayloadId` in `handleTerminalResult`. Used ONLY on
    /// reappear, never during continuous polling.
    private func readSharedSnapshotForReappear(for id: UUID) -> DictationPayload? {
        // Fast path: snapshot file in the app-group container.
        if let filePayload = SharedConfig.snapshotFile(),
           filePayload.id == id {
            lastSeenSnapshotRevision = max(lastSeenSnapshotRevision, filePayload.revision ?? 0)
            FileLogger.shared.debug(.keyboard, "snapshot reappear read: hit (file)",
                                    payload: ["status": filePayload.status.rawValue,
                                              "rev": filePayload.revision ?? 0,
                                              "id": String(filePayload.id.uuidString.prefix(8))])
            return filePayload
        }
        // Fallback: app-group UserDefaults snapshot.
        guard let payload = SharedConfig.dictationSnapshot(),
              payload.id == id else {
            FileLogger.shared.debug(.keyboard, "snapshot reappear read: miss no snapshot")
            FileLogger.shared.debug(.keyboard, "snapshot reappear miss", payload: ["group": SharedConfig.Defaults.appGroupId, "containerAvailable": AppGroupResolver.shared.containerAvailable, "id": String(id.uuidString.prefix(8))])
            return nil
        }
        lastSeenSnapshotRevision = max(lastSeenSnapshotRevision, payload.revision ?? 0)
        FileLogger.shared.debug(.keyboard, "snapshot reappear read: hit (defaults)",
                                payload: ["status": payload.status.rawValue,
                                          "rev": payload.revision ?? 0,
                                          "id": String(payload.id.uuidString.prefix(8))])
        return payload
    }

    /// Reads the current dictation snapshot from the app-group. Called from
    /// the snapshot poll timer and from the Darwin state-changed notification.
    /// The app-group snapshot (via `readSharedSnapshot`) is the primary channel;
    /// after 1 consecutive miss the localhost /state endpoint is polled as a
    /// fallback (container app still alive, app-group container nil under
    /// SideStore). The threshold is 1 because on SideStore the app-group
    /// container is structurally nil and cfprefsd lags ~1–2s, but the container
    /// app's in-memory payload holder is populated synchronously before the
    /// Darwin post — so localhost already holds the fresh payload on the first
    /// Darwin-driven refresh. Waiting for a second miss would let the transient
    /// `.recording` phase advance to `.transcribing`.
    private func refreshFromSharedState() async {
        guard let id = pendingRequestId else {
            return
        }
        FileLogger.shared.debug(.keyboard, "refreshFromSharedState entry",
                                payload: ["id": String(id.uuidString.prefix(8))])

        // App-group snapshot is the PRIMARY channel
        if let payload = readSharedSnapshot(for: id) {
            applySnapshotPayload(payload, source: "appgroup")
            return
        }

        // Miss — no matching snapshot this poll cycle. Increment counter.
        consecutiveSnapshotMisses += 1
        FileLogger.shared.debug(.keyboard, "snapshot miss",
                                payload: ["consecutive": consecutiveSnapshotMisses])

        // Localhost fallback tier: after 1 consecutive app-group miss, poll the
        // container app's localhost /state endpoint. Local and instant — the same
        // payload the app-group path would deliver (id + revision dedup identical).
        // On SideStore the app-group container is structurally nil and cfprefsd
        // lags ~1–2s, but lastPayloadHolder is populated synchronously before the
        // Darwin post, so localhost already holds the fresh payload on the first
        // Darwin-driven refresh. Waiting one more cycle would miss the transient
        // `.recording` phase.
        if consecutiveSnapshotMisses >= SnapshotThresholds.localhostFallbackMisses {
            switch await LocalhostClient.probeState() {
            case .payload(let httpPayload):
                if httpPayload.id == pendingRequestId,
                   (httpPayload.revision ?? 0) > lastSeenSnapshotRevision {
                    lastSeenSnapshotRevision = httpPayload.revision ?? 0
                    applySnapshotPayload(httpPayload, source: "localhost")
                    return
                }
                // id-mismatched or stale-revision payload: fall through to the
                // /jobs tier unchanged — do not broaden that behavior.
            case .malformed:
                // App is alive but its payload failed to decode — not miss
                // evidence; fall through to the /jobs tier unchanged.
                break
            case .noSession, .unreachable:
                consecutiveSessionEvidenceMiss += 1
                if resetIfSessionLost() { return }
            }
        }

        // Start /jobs server polling if the threshold is reached and polling
        // is not already running.
        if consecutiveSnapshotMisses >= SnapshotThresholds.serverPollMisses, serverPollWorkItem == nil {
            FileLogger.shared.warn(.keyboard, "snapshot miss streak",
                payload: ["consecutive": consecutiveSnapshotMisses,
                          "id": String(id.uuidString.prefix(8)),
                          "group": SharedConfig.Defaults.appGroupId,
                          "containerAvailable": AppGroupResolver.shared.containerAvailable,
                          "path": SharedConfig.snapshotFilePathDescription()])
            startServerPolling()
        }
    }

    /// Applies a received snapshot payload: dispatches by status, then resets
    /// the miss counter. Shared by the app-group (file + defaults) and the
    /// localhost /state fallback transports.
    private func applySnapshotPayload(_ payload: DictationPayload, source: String) {
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
            FileLogger.shared.info(.keyboard, "refreshFromSharedState — in-progress",
                                   payload: ["status": payload.status.rawValue])
            updateRecordingInProgressUI(phase: payload.status.rawValue)
        }
        consecutiveSnapshotMisses = 0
        consecutiveSessionEvidenceMiss = 0
        FileLogger.shared.debug(.keyboard, "snapshot hit",
                                payload: ["src": source,
                                          "status": payload.status.rawValue,
                                          "rev": payload.revision ?? 0,
                                          "id": String(payload.id.uuidString.prefix(8))])
    }

    /// Conservatively-gated silent reset for a session the keyboard positively
    /// saw as `.recording` but the container app now affirms is gone (sustained
    /// dead/no-session probes). The container app declares `UIBackgroundModes:
    /// audio`, so a live recording keeps it running and the listener answering —
    /// sustained unreachability means no recording can still be active. All
    /// conditions must hold:
    /// - `state == .recording` only — never `.waiting`, which protects the
    ///   mic-permission / pre-first-snapshot window where 204 is normal, and
    ///   the transcribing phase (`.waiting` set by `updateRecordingInProgressUI`),
    ///   where an app death mid-transcription is deliberately NOT covered by
    ///   this fast reset — it relies on the pre-existing `/jobs` tier plus the
    ///   900s timeout.
    /// - `consecutiveSessionEvidenceMiss` at threshold (~3s of dead probes)
    /// - the pending request started more than 20s ago
    /// Returns `true` when the reset fired (dictation cancelled), `false` when
    /// a guard blocked it.
    @discardableResult
    private func resetIfSessionLost() -> Bool {
        guard state == .recording,
              consecutiveSessionEvidenceMiss >= SnapshotThresholds.sessionLostMisses else { return false }
        let age = pendingRequestStart > 0 ? Date().timeIntervalSince1970 - pendingRequestStart : 0
        guard age > 20 else { return false }
        FileLogger.shared.warn(.keyboard, "session lost — resetting to idle",
                               payload: ["id": String(pendingRequestId?.uuidString.prefix(8) ?? "nil"),
                                         "misses": consecutiveSessionEvidenceMiss])
        cancelDictation()
        return true
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
            Task { @MainActor [weak self] in await self?.refreshFromSharedState() }
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
        SharedConfig.clearSnapshotFile()   // hygiene — keep file from lingering for next dictation
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
        stopDictationTransports()
        // Backspace auto-repeat has no dictation-state guard, so a timeout during a
        // held backspace would leave backspaceTimer firing deleteBackward() into the
        // next focused field. Tear it down here (teardown-full-cleanup skill).
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
        waitTimer = nil
        pendingRequestId = nil
        dictationTargetDocId = nil
        state = .error("Dictation timed out. Try again.")
    }

    // MARK: - Pending Dictation (Recovery on Keyboard Reappear)

    private func checkForPendingDictation() {
        guard let id = pendingRequestId else {
            state = .idle
            return
        }
        FileLogger.shared.info(.keyboard, "Resuming pending dictation",
                               payload: ["pendingRequestId": id.uuidString])

        // Read the snapshot to set the correct initial state instead of
        // defaulting to .waiting, which masks the recording phase. Uses the
        // reappear reader (revision-agnostic) because the appear refresh may
        // have already consumed the current revision.
        if let payload = readSharedSnapshotForReappear(for: id) {
            FileLogger.shared.info(.keyboard, "checkForPendingDictation snapshot",
                                   payload: ["status": payload.status.rawValue,
                                             "rev": payload.revision ?? 0])
            switch payload.status {
            case .recording, .transcribing:
                updateRecordingInProgressUI(phase: payload.status.rawValue)
            case .completed:
                handleTerminalResult(id: payload.id, text: payload.text, errorMessage: nil)
                return
            case .error:
                handleTerminalResult(id: payload.id, text: nil, errorMessage: payload.errorMessage ?? "Transcription failed")
                return
            case .cancelled:
                stopDictationTransports()
                pendingRequestId = nil
                dictationTargetDocId = nil
                state = .idle
                return
            }
        } else {
            FileLogger.shared.debug(.keyboard,
                "checkForPendingDictation — no snapshot for id; defaulting to .waiting",
                payload: ["priorState": String(describing: state)])
            switch state {
            case .recording, .waiting, .inserting:
                break   // keep a concrete in-progress state; poll will catch the next snapshot
            default:
                state = .waiting   // .idle / .openingApp / .error → genuinely unknown
            }
        }

        // Re-register the state-changed Darwin observer (it was torn down in viewWillDisappear).
        if darwinStateChangedToken == nil {
            darwinStateChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinStateChangedNotificationName) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.appearRefreshTask?.cancel()
                    self?.appearRefreshTask = Task { @MainActor [weak self] in
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

        // DispatchWorkItems
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        errorResetWorkItem?.cancel()
        errorResetWorkItem = nil
        suggestionRefreshWorkItem?.cancel()
        suggestionRefreshWorkItem = nil
        deferredFlushWorkItem?.cancel()
        deferredFlushWorkItem = nil
        deferredKeystrokeWorkItem?.cancel()
        deferredKeystrokeWorkItem = nil

        // Invalidate any background autocorrect compute that already started
        // (an executing DispatchWorkItem cannot be cancelled) so it drops at
        // the main-hop.
        keystrokeEpoch &+= 1
        recentWordBuffer.clear()

        // Greek final-sigma revert tracking is session-scoped; a teardown
        // closes the window.
        lastSigmaConvertedWord = nil

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
        stopDictationTransports()
        clearDeferredResult()
        FileLogger.shared.debug(.keyboard, "Dictation cancelled by user",
                                payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
        pendingRequestId = nil
        dictationTargetDocId = nil
        state = .idle
    }

    /// Requests the container app to stop dictation via POST /stop. The
    /// app-group pipeline delivers the terminal phase; no local state change
    /// happens here — the dots keep showing until the transcript lands.
    private func requestStop() {
        FileLogger.shared.info(.keyboard, "Mic: requesting stop via /stop")
        guard !stopCancelRequestInFlight else { return }
        stopCancelRequestInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.stopCancelRequestInFlight = false }
            let ok = await LocalhostClient.postStop()
            guard let self = self else { return }
            guard ok else {
                // Only fall back if we're still actively dictating — a concurrent
                // teardown (dismiss/cancel) may have already reset the state.
                guard self.state == .recording || self.state == .waiting else { return }
                FileLogger.shared.warn(.keyboard, "POST /stop failed — local fallback cancel")
                self.requestFallbackCancel()
                return
            }
            // App-group pipeline drives the terminal state; nothing to do here.
        }
    }

    /// Requests the container app to cancel dictation via POST /cancel. The
    /// app-group pipeline delivers `.cancelled` and resets the keyboard to idle.
    private func requestCancel() {
        FileLogger.shared.info(.keyboard, "Mic: requesting cancel via /cancel")
        guard !stopCancelRequestInFlight else { return }
        stopCancelRequestInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.stopCancelRequestInFlight = false }
            let ok = await LocalhostClient.postCancel()
            guard let self = self else { return }
            guard ok else {
                // Only fall back if we're still actively dictating — a concurrent
                // teardown (dismiss/cancel) may have already reset the state.
                guard self.state == .recording || self.state == .waiting else { return }
                FileLogger.shared.warn(.keyboard, "POST /cancel failed — local fallback cancel")
                self.requestFallbackCancel()
                return
            }
            // Pipeline delivers .cancelled → refreshFromSharedState resets to idle.
        }
    }

    /// Server unreachable (app not running / crashed). Reset locally;
    /// the container app, if alive, cleans up via its own timeout.
    private func requestFallbackCancel() {
        FileLogger.shared.warn(.keyboard, "fallback cancel reached", payload: ["state": KeyboardState.shortTag(state)])
        cancelDictation()
        state = .error("Couldn't reach Ritoras app. Stopped locally.")
    }

    /// Reads `textDocumentProxy.documentIdentifier` without trapping.
    ///
    /// `documentIdentifier` is declared `UUID` (nonnull) in Swift, but the
    /// underlying Objective-C `NSUUID *` is nil during keyboard transitions,
    /// field switches, and rapid controller recycling (a UIKit annotation bug
    /// shipped since iOS 16). Direct access traps in
    /// `UUID._unconditionallyBridgeFromObjectiveC` with `brk 1` (SIGTRAP).
    /// KVC reads the `NSUUID` as an optional and returns nil instead. Callers
    /// treat nil as "keyboard transitional" and defer the result — the same
    /// shape as the existing `view.window == nil` deferral.
    private func safeDocumentIdentifier() -> UUID? {
        guard let nsObject = textDocumentProxy as? NSObject,
              let nsUuid = nsObject.value(forKey: "documentIdentifier") as? NSUUID else {
            return nil
        }
        return UUID(uuidString: nsUuid.uuidString)
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

        // Safe accessor: documentIdentifier is nonnull in Swift but nil during
        // keyboard transitions (UIKit bug) — direct access traps. Nil here means
        // the keyboard is transitional even though view.window != nil. Defer the
        // result so it flushes when the user taps into a field.
        guard let currentDocId = safeDocumentIdentifier() else {
            FileLogger.shared.warn(.keyboard, "documentIdentifier nil — keyboard transitional, deferring",
                                   payload: ["text_length": text.count])
            storeDeferredResult(text: text)
            stopDictationTransports()
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .waiting
            return
        }

        // No-field gate: if there is genuinely no focused text field (zero UUID),
        // defer the result so it can be inserted when the user taps into a field.
        if currentDocId == UUID() {
            FileLogger.shared.warn(.keyboard, "Dictation result arrived with no focused field — deferring",
                                   payload: ["documentIdentifier": currentDocId.uuidString])
            storeDeferredResult(text: text)
            stopDictationTransports()
            pendingRequestId = nil
            dictationTargetDocId = nil
            state = .waiting
            return
        }

        // Target-bound insertion: if the user switched text fields while the
        // transcription was in flight, do NOT insert into the wrong field. Preserve
        // the text + target so it flushes when they return to the original field
        // (mirrors scheduleDeferredDictationFlush's mismatch handling).
        if let targetId = dictationTargetDocId, targetId != UUID(),
           currentDocId != targetId {
            FileLogger.shared.warn(.keyboard, "Dictation target mismatch — deferring",
                                   payload: ["target": targetId.uuidString,
                                             "current": currentDocId.uuidString])
            storeDeferredResult(text: text, docId: targetId)
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
        clearDeferredResult()
        deferredFlushWorkItem?.cancel()
        deferredFlushWorkItem = nil
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
    private func storeDeferredResult(text: String, docId: UUID? = nil, ts: TimeInterval? = nil) {
        let idToStore = docId ?? dictationTargetDocId
        UserDefaults.standard.set(text, forKey: "ritoras_deferred_text")
        UserDefaults.standard.set(ts ?? Date().timeIntervalSince1970, forKey: "ritoras_deferred_ts")
        UserDefaults.standard.set(idToStore?.uuidString ?? "", forKey: "ritoras_deferred_doc_id")
    }

    /// Clears the deferred result from UserDefaults. Called when starting
    /// a new dictation or when explicitly cancelling.
    private func clearDeferredResult() {
        UserDefaults.standard.removeObject(forKey: "ritoras_deferred_text")
        UserDefaults.standard.removeObject(forKey: "ritoras_deferred_ts")
        UserDefaults.standard.removeObject(forKey: "ritoras_deferred_doc_id")
    }

    /// Reads + age-checks + clears the deferred dictation text synchronously
    /// (so a re-entrant textDidChange/selectionDidChange cannot double-flush),
    /// then inserts it on the NEXT run-loop turn so the mutation does not run
    /// inside the host's own change/selection callback (caret snap-back fix).
    /// Called from textDidChange / selectionDidChange and from viewDidAppear:
    /// the appear path also defers one run-loop turn because the host's input
    /// session (caret anchoring included) is still establishing during the
    /// appearance callback.
    private func scheduleDeferredDictationFlush(reason: String) {
        guard let deferredText = UserDefaults.standard.string(forKey: "ritoras_deferred_text"),
              !deferredText.isEmpty else { return }
        let currentDocId = safeDocumentIdentifier()
        if deferredFlushHasChecked, currentDocId == deferredFlushLastCheckedDocId { return }
        deferredFlushHasChecked = true
        deferredFlushLastCheckedDocId = currentDocId
        let deferredTs = UserDefaults.standard.double(forKey: "ritoras_deferred_ts")
        let storedDocIdString = UserDefaults.standard.string(forKey: "ritoras_deferred_doc_id") ?? ""
        let targetDocId = UUID(uuidString: storedDocIdString)
        let age = deferredTs > 0 ? Date().timeIntervalSince1970 - deferredTs : 0
        if age >= 300 {
            FileLogger.shared.info(.keyboard, "Deferred dictation result expired on flush check",
                                   payload: ["age": age])
            clearDeferredResult()
            return
        }
        clearDeferredResult()
        let textToInsert = deferredText
        FileLogger.shared.info(.keyboard, "Scheduling deferred dictation flush",
                               payload: ["reason": reason, "length": textToInsert.count, "age": age])
        deferredFlushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.view.window != nil else { return }
            guard let currentDocId = self.safeDocumentIdentifier() else {
                self.storeDeferredResult(text: textToInsert, docId: targetDocId, ts: deferredTs)
                FileLogger.shared.warn(.keyboard, "Deferred flush — documentIdentifier nil, re-deferring",
                                       payload: ["target": targetDocId?.uuidString ?? "nil",
                                                 "length": textToInsert.count])
                return
            }
            if let targetId = targetDocId, targetId != UUID(),
               currentDocId != targetId {
                // Original dictation field no longer focused — preserve text + target
                // so it flushes when the user returns to that field. Do NOT discard.
                self.storeDeferredResult(text: textToInsert, docId: targetId, ts: deferredTs)
                FileLogger.shared.warn(.keyboard, "Deferred flush skipped — original field not focused",
                                       payload: ["target": targetId.uuidString,
                                                 "current": currentDocId.uuidString])
                return
            }
            self.state = .inserting
            self.textDocumentProxy.insertText(self.normalizedDictationInsertion(of: textToInsert))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state = .idle
            }
        }
        deferredFlushWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
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
            if shouldAutoCorrect {
                // Final-sigma conversion runs BEFORE the commit trigger lands,
                // at the same sites autocorrect-on-space evaluates the word.
                applyFinalSigmaToCommittedWord()
            } else {
                lastSigmaConvertedWord = nil  // any other keystroke clears the revert window
            }
            insertTargeted(text)
            if shouldAutoCorrect {
                applyAutocorrectForTrigger(triggerChar: text)
                recordRecentWordForTrigger(triggerChar: text)
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
                lastSigmaConvertedWord = nil  // the word region was rewritten
                wordOrigin.resetToTyping()  // user is now back to editing a .typing word
            } else if revertSigmaIfNeeded() {
                // The backspace was consumed by the final-sigma revert (ς → σ).
            } else {
                deleteTargetedBackward()
                lastAutoCorrection = nil  // any non-immediate-backspace invalidates revert
            }
            recomputeAutoCap()
            scheduleSuggestionRefresh()

        case .shift:
            lastSigmaConvertedWord = nil  // any other keystroke clears the revert window
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
            lastSigmaConvertedWord = nil  // any other keystroke clears the revert window
            shiftState = .locked

        case .space:
            applyFinalSigmaToCommittedWord()
            insertTargeted(" ")
            applyAutocorrectForTrigger(triggerChar: " ")
            recordRecentWordForTrigger(triggerChar: " ")
            recomputeAutoCap()
            scheduleSuggestionRefresh()
            wordOrigin.resetToTyping()

        case .return:
            if inputTarget == .emojiSearch {
                keyboardView.emojiPanelView.onSearchReturn?()
            } else {
                applyFinalSigmaToCommittedWord()
                insertTargeted("\n")
                applyAutocorrectForTrigger(triggerChar: "\n")
                recordRecentWordForTrigger(triggerChar: "\n")
                recomputeAutoCap()
                wordOrigin.resetToTyping()
                scheduleSuggestionRefresh()
            }

        case .toggleNumber:
            lastSigmaConvertedWord = nil  // surface navigation clears the revert window
            layoutMode = .numbers

        case .toggleLetters:
            lastSigmaConvertedWord = nil  // surface navigation clears the revert window
            layoutMode = .letters

        case .toggleSymbols:
            lastSigmaConvertedWord = nil  // surface navigation clears the revert window
            layoutMode = .symbols

        case .mic:
            lastSigmaConvertedWord = nil  // surface navigation clears the revert window
            handleMicButtonTap()

        case .emoji:
            lastSigmaConvertedWord = nil  // surface navigation clears the revert window
            switch uiMode {
            case .letters:      uiMode = .emoji
            case .emoji:        uiMode = .letters
            case .emojiSearch:
                inputTarget = .hostApp
                keyboardView.emojiSearchOverlay.searchField.resignFirstResponder()
                uiMode = .emoji
            }

        case .globe:
            lastSigmaConvertedWord = nil  // surface navigation clears the revert window
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
        lastSigmaConvertedWord = nil      // Suggestion tap rewrites the word region
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
        // Kick the one-time load ONLY while the stack is still cold. Once
        // `.ready` (or `.loading`), refreshSuggestions must not re-enter here —
        // loadIfNeeded fires its completion for every settled state including
        // `.ready`, so an ungated kick would loop
        // refresh → snapshot → loadIfNeeded(.ready) → refresh → … forever.
        // Every subsequent show finds the stack `.ready` and reuses it — no rebuild.
        if !SharedPredictionStack.shared.isReady, !SharedPredictionStack.shared.isLoading {
            SharedPredictionStack.shared.loadIfNeeded { [weak self] _ in
                DispatchQueue.main.async {
                    self?.keyboardView?.refreshSuggestions()
                }
            }
        }
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

    func keyboardViewDidRequestCancelDictation(_ view: KeyboardView) {
        guard state == .recording || state == .waiting else { return }
        requestCancel()
    }

    // MARK: - Backspace Long-Press

    func keyboardViewBackspaceDidBegin(_ view: KeyboardView) {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceSingleCharCount = 0
        backspacePhase = nil
        // The single-backspace final-sigma revert (ς → σ) consumes this press;
        // otherwise the normal delete runs. The revert is checked only on the
        // first press of a fresh sequence, never inside the repeat timer.
        if !revertSigmaIfNeeded() {
            deleteTargetedBackward()
        }
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

    /// One KVC read + in-place ring update per host callback. Main-thread only.
    private func observeIdentityForFlapDetection() {
        let wasDefensive = identityMonitor.isDefensive
        let isDefensive = identityMonitor.observe(safeDocumentIdentifier(),
                                                  at: Date().timeIntervalSince1970)
        if !wasDefensive && isDefensive {
            FileLogger.shared.warn(.keyboard, "identity flap detected — defensive mode")
        } else if wasDefensive && !isDefensive {
            FileLogger.shared.info(.keyboard, "identity stable — defensive mode exited")
            deferredFlushHasChecked = false   // let the next callback re-attempt a flush
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        observeIdentityForFlapDetection()

        keystrokeEpoch &+= 1  // any text change invalidates a pending deferred autocorrect
        lastAutoCorrection = nil  // host text change invalidates any pending revert
        lastSigmaConvertedWord = nil  // external text change invalidates the sigma revert window
        recentWordBuffer.clear()  // committed-word records are stale once the doc changes
        // SYNC: system-signaled textDidChange bypasses debounce so the suggestion bar
        // updates immediately — debounce here would feel laggy after external edits.
        keyboardView.refreshSuggestions()
        recomputeAutoCap()

        // Flush deferred dictation result if one exists (the user has now
        // focused/activated a text field).
        scheduleDeferredDictationFlush(reason: "textDidChange")
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        observeIdentityForFlapDetection()
        backspaceNilContextRetries = 0
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        observeIdentityForFlapDetection()
        keystrokeEpoch &+= 1  // any selection change invalidates a pending deferred autocorrect
        recentWordBuffer.clear()  // cursor moves invalidate committed-word offsets
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        observeIdentityForFlapDetection()

        keystrokeEpoch &+= 1  // any selection change invalidates a pending deferred autocorrect
        lastAutoCorrection = nil  // cursor move invalidates any pending revert
        lastSigmaConvertedWord = nil  // cursor move invalidates the sigma revert window
        recentWordBuffer.clear()  // committed-word records are stale once the cursor moves
        backspaceNilContextRetries = 0
        recomputeAutoCap()

        // Flush deferred dictation result if one exists (the user has now
        // focused/activated a text field).
        scheduleDeferredDictationFlush(reason: "selectionDidChange")
    }

    // MARK: - Autocorrect-on-space

    /// Snapshots the autocorrect context on the main thread and defers the heavy
    /// compute (PredictionEngine.topCorrection + AutocorrectController.evaluate)
    /// to a background serial queue so the trigger character lands instantly and
    /// no keystroke is lost under fast typing.
    ///
    /// The trigger character (space / punct / return) has already been inserted
    /// by the caller. UITextChecker is a UIKit API and must run on the main
    /// thread, so spell-check runs here in the snapshot phase; the engine lookup
    /// + scoring run off-main. The main apply hop re-validates the result with
    /// the monotonic keystroke epoch, the content-hash token, the document id,
    /// and AutocorrectApplicationGuard before mutating the document, so any
    /// state change since the keystroke silently drops the result.
    private func applyAutocorrectForTrigger(triggerChar: String) {
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
        let languageAtDispatch = settingsCache.language

        // Defensive: the suffix must match what we expect.
        guard contextAtDispatch.hasSuffix(typedWord + triggerChar) else { return }

        // --- Main-thread spell-check (UITextChecker is a UIKit API) ---
        let computeStart = Date()
        let isMisspelled: Bool = {
            let checker = UITextChecker()
            let nsString = typedWord as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let misspelledRange = checker.rangeOfMisspelledWord(
                in: typedWord,
                range: range,
                startingAt: 0,
                wrap: false,
                language: languageAtDispatch.appleSpellTag
            )
            return misspelledRange.location != NSNotFound
        }()
        FileLogger.shared.debug(.keyboard, "autocorrect snapshot",
            payload: ["uitextcheckerMs": Int(Date().timeIntervalSince(computeStart) * 1000)])

        // Two-layer invalidation captured at dispatch: the monotonic keystroke
        // epoch and the content-hash context token. Both are re-checked on the
        // main-hop so stale background results are dropped.
        let capturedEpoch = keystrokeEpoch
        guard let capturedDocId = safeDocumentIdentifier() else { return }
        let capturedToken = keyboardContextToken(keyboardView)

        // --- Retroactive candidate snapshot (all main-thread work) ---
        // Resolve the ring's candidates NOW: per-candidate spell-check state
        // (UITextChecker is UIKit, main-only) and each word's live offset come
        // from the document on main. The background scan consumes only this
        // snapshot, so the ring buffer and the document are never touched
        // off-main. The current trigger's word is handled by the inline path;
        // it enters the ring via recordRecentWordForTrigger and is scanned on
        // the NEXT trigger.
        let retroactiveCandidates = resolveRetroactiveCandidates(
            candidates: recentWordBuffer.candidates,
            liveContext: contextAfterInsert
        )

        scheduleDeferredKeystrokeWork(
            typedWord: typedWord,
            currentWord: currentWord,
            previousWord: previousWord,
            previousWord2: previousWord2,
            isLearned: isLearned,
            isMisspelled: isMisspelled,
            originAtDispatch: originAtDispatch,
            languageAtDispatch: languageAtDispatch,
            triggerChar: triggerChar,
            retroactiveCandidates: retroactiveCandidates,
            engine: engine,
            capturedEpoch: capturedEpoch,
            capturedToken: capturedToken,
            capturedDocId: capturedDocId
        )
    }

    /// Appends the just-committed word (the token before `triggerChar`) to the
    /// retroactive-autocorrect ring. Runs on main right after the inline
    /// trigger snapshot: the document ends with `typedWord + triggerChar`, so
    /// the typed word is the extracted current word and the commit context is
    /// the last ~50 characters of that same context. The origin is whatever
    /// `wordOrigin` held at commit time; non-`.typing` records are never
    /// re-scanned by the candidates filter.
    private func recordRecentWordForTrigger(triggerChar: String) {
        guard inputTarget == .hostApp else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        guard context.hasSuffix(triggerChar) else { return }
        let contextBeforeTrigger = String(context.dropLast())
        // Stored in canonical form (apostrophes normalized) so it matches the
        // extractor's lookupWord and the engine's lookup key.
        let typedWord = CurrentWordExtractor.extract(from: contextBeforeTrigger).lookupWord
        guard !typedWord.isEmpty else { return }
        let commitContextSuffix = String(context.suffix(50))
        recentWordBuffer.append(RecentWordRecord(
            typedWord: typedWord,
            origin: wordOrigin.current,
            evaluatedAndSkipped: false,
            commitContextSuffix: commitContextSuffix
        ))
    }

    /// Resolves the ring's candidates into a snapshot for the background scan:
    /// each word's live `offsetFromCursorEnd` comes from the document (via
    /// RecentWordsExtractor on the captured context), and its OWN
    /// `isLearned`/`isMisspelled` are computed here on main (UITextChecker is a
    /// UIKit API). Candidates whose committed context no longer appears in the
    /// live context are dropped — they are simply not scanned this pass and
    /// remain eligible for a later trigger. Newest first, at most 3 (the
    /// extractor walks back at most 3 committed words).
    private func resolveRetroactiveCandidates(
        candidates: [RecentWordRecord],
        liveContext: String
    ) -> [RetroactiveCandidateSnapshot] {
        guard !candidates.isEmpty else { return [] }
        let recentWords = RecentWordsExtractor.extract(from: liveContext, maxCount: 3)
        var resolved: [RetroactiveCandidateSnapshot] = []
        resolved.reserveCapacity(candidates.count)
        for candidate in candidates.reversed() {
            guard let live = recentWords.first(where: {
                $0.lookupWord == candidate.typedWord || $0.word == candidate.typedWord
            }) else { continue }
            // The committed context (~50 chars before the word) must still be
            // present, proving the word's region has not been edited.
            guard liveContext.contains(candidate.commitContextSuffix) else { continue }
            resolved.append(RetroactiveCandidateSnapshot(
                typedWord: candidate.typedWord,
                lookupWord: live.lookupWord,
                offsetFromCursorEnd: live.offsetFromCursorEnd,
                isLearned: LearnedWordsStore.shared.contains(live.lookupWord),
                isMisspelled: isWordMisspelled(live.lookupWord),
                origin: candidate.origin,
                commitContextSuffix: candidate.commitContextSuffix
            ))
        }
        return resolved
    }

    /// Main-thread spell-check (UITextChecker is a UIKit API). Mirrors the
    /// inline snapshot's spell-check block.
    private func isWordMisspelled(_ word: String) -> Bool {
        let checker = UITextChecker()
        let nsString = word as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let misspelledRange = checker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: settingsCache.language.appleSpellTag
        )
        return misspelledRange.location != NSNotFound
    }

    /// Schedules the deferred autocorrect compute on the background processing
    /// queue (mirrors scheduleSuggestionRefresh's cancel-previous + asyncAfter
    /// shape, but dispatches to keyboardProcessingQueue so the heavy engine
    /// work never runs on the keystroke hot path). The compute hops back to
    /// main for the guarded apply.
    private func scheduleDeferredKeystrokeWork(
        typedWord: String,
        currentWord: String,
        previousWord: String?,
        previousWord2: String?,
        isLearned: Bool,
        isMisspelled: Bool,
        originAtDispatch: WordOrigin,
        languageAtDispatch: KeyboardLanguage,
        triggerChar: String,
        retroactiveCandidates: [RetroactiveCandidateSnapshot],
        engine: PredictionEngine,
        capturedEpoch: UInt64,
        capturedToken: UInt64,
        capturedDocId: UUID,
        coalescing: TimeInterval = 0.016
    ) {
        deferredKeystrokeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self = self, let engine = engine else { return }

            // --- Off-main compute (engine lookup + scoring are pure) ---
            let computeStart = Date()
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
                language: languageAtDispatch,
                config: config
            )
            FileLogger.shared.debug(.keyboard, "autocorrect compute",
                payload: ["ms": Int(Date().timeIntervalSince(computeStart) * 1000)])

            DispatchQueue.main.async { [weak self] in
                self?.applyAutocorrectResultIfNeeded(
                    decision: decision,
                    typedWord: typedWord,
                    triggerChar: triggerChar,
                    capturedEpoch: capturedEpoch,
                    capturedToken: capturedToken,
                    capturedDocId: capturedDocId
                )
            }

            // --- Retroactive autocorrect scan (additive to inline) ---
            // Pure compute over the main-thread snapshot ONLY: per-candidate
            // spell-check state and offsets were resolved at dispatch, so the
            // ring buffer and the document are never touched off-main. At most
            // one correction is queued per trigger (the scan breaks on the
            // first .correct); the remaining candidates stay eligible and retry
            // on the next trigger.
            if !retroactiveCandidates.isEmpty {
                let retroactiveStart = Date()
                var evaluatedTypedWords: [String] = []
                var pendingCorrection: (plan: RetroactiveApplyPlan.Plan, typedWord: String)?
                for entry in retroactiveCandidates {
                    guard pendingCorrection == nil else { break }
                    evaluatedTypedWords.append(entry.typedWord)

                    let retroactiveTop = engine.topCorrection(
                        forCurrentWord: entry.lookupWord,
                        lookupWord: entry.lookupWord
                    )
                    let retroactiveDecision = AutocorrectController.evaluate(
                        typedWord: entry.lookupWord,
                        origin: entry.origin,
                        topCorrection: retroactiveTop,
                        isLearned: entry.isLearned,
                        isMisspelled: entry.isMisspelled,
                        language: languageAtDispatch,
                        config: config
                    )
                    guard case .correct(_, let correction) = retroactiveDecision else { continue }

                    let plan = RetroactiveApplyPlan.plan(
                        typedWord: entry.lookupWord,
                        correction: correction,
                        offsetFromCursorEnd: entry.offsetFromCursorEnd
                    )
                    pendingCorrection = (plan, entry.lookupWord)
                    break
                }

                if let correction = pendingCorrection {
                    DispatchQueue.main.async { [weak self] in
                        self?.applyRetroactiveCorrection(
                            plan: correction.plan,
                            typedWord: correction.typedWord,
                            capturedEpoch: capturedEpoch,
                            capturedDocId: capturedDocId,
                            capturedToken: capturedToken
                        )
                    }
                }
                if !evaluatedTypedWords.isEmpty {
                    let evaluated = evaluatedTypedWords
                    DispatchQueue.main.async { [weak self] in
                        self?.markRecentWordsEvaluated(
                            evaluated,
                            capturedEpoch: capturedEpoch,
                            capturedDocId: capturedDocId,
                            capturedToken: capturedToken
                        )
                    }
                }
                FileLogger.shared.debug(.keyboard, "retroactive scan",
                    payload: ["candidates": retroactiveCandidates.count,
                              "corrected": pendingCorrection == nil ? 0 : 1,
                              "ms": Int(Date().timeIntervalSince(retroactiveStart) * 1000)])
            }
        }
        deferredKeystrokeWorkItem = workItem
        keyboardProcessingQueue.asyncAfter(deadline: .now() + coalescing, execute: workItem)
    }

    /// Main-thread apply for a deferred autocorrect result. Every guard runs
    /// BEFORE any shared-state access or document mutation: the keyboard
    /// liveness gate, the monotonic keystroke epoch (supersession guard — this
    /// GCD background→main hop is re-entrant via nested run-loop turns), the
    /// target-bound document id, the content-hash token, and the application
    /// guard. Once past them the delete-burst + re-insert runs synchronously,
    /// byte-identical to the pre-FIX B outcome.
    private func applyAutocorrectResultIfNeeded(
        decision: AutocorrectController.Decision,
        typedWord: String,
        triggerChar: String,
        capturedEpoch: UInt64,
        capturedToken: UInt64,
        capturedDocId: UUID
    ) {
        // Liveness gate: if the keyboard is no longer in a window,
        // the textDocumentProxy is dead — reading it in the guards below
        // would crash with SIGSEGV.
        if self.view.window == nil {
            return
        }

        // Supersession guard (monotonic epoch): any text/selection/target
        // mutation since dispatch bumped keystrokeEpoch — the result is stale.
        guard keystrokeEpoch == capturedEpoch else { return }

        // Target-bound guard: the first-responder field must be unchanged.
        guard safeDocumentIdentifier() == capturedDocId else { return }

        // Content-hash guard: the live context must still match dispatch.
        let liveToken = keyboardContextToken(keyboardView)
        guard shouldApplyLookupResult(capturedToken: capturedToken, liveToken: liveToken) else { return }

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

    /// Main-thread synchronous apply of a retroactive autocorrect plan: move the
    /// cursor back to the typed word, delete it, insert the correction, and
    /// return the cursor to its relative spot — all in ONE synchronous block
    /// with no suspension between proxy mutations. Guards run before any
    /// mutation: the keyboard liveness gate, the document-identity defensive
    /// mode (flapping host sessions), the monotonic keystroke epoch
    /// (supersession guard), the target-bound document id, and the content-hash
    /// context token. The context is re-read after the mutations to verify;
    /// there is no retry on failure. The tail epoch bump drops any retroactive
    /// or inline hop still queued for this dispatch — the document changed.
    private func applyRetroactiveCorrection(
        plan: RetroactiveApplyPlan.Plan,
        typedWord: String,
        capturedEpoch: UInt64,
        capturedDocId: UUID,
        capturedToken: UInt64
    ) {
        if self.view.window == nil { return }

        // Defensive mode: the host is flapping document identities (input-session
        // churn, e.g. WKWebView+React), so the cursor-reanchoring retroactive
        // mutation pattern would fight the re-anchoring host. Pause until stable.
        guard !identityMonitor.isDefensive else {
            FileLogger.shared.debug(.keyboard, "retroactive correction suppressed — defensive mode")
            return
        }

        // Supersession guard (monotonic epoch): if the inline apply or any other
        // mutation ran first, the epoch moved and this stale plan is dropped.
        guard keystrokeEpoch == capturedEpoch else { return }

        // Target-bound guard: the first-responder field must be unchanged.
        guard safeDocumentIdentifier() == capturedDocId else { return }

        // Content-hash guard: the live context must still match dispatch.
        let liveToken = keyboardContextToken(keyboardView)
        guard shouldApplyLookupResult(capturedToken: capturedToken, liveToken: liveToken) else { return }

        textDocumentProxy.adjustTextPosition(byCharacterOffset: plan.backMove)
        for _ in 0..<plan.deleteCount {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(plan.insert)
        textDocumentProxy.adjustTextPosition(byCharacterOffset: plan.forwardMove)

        // Re-read the context to verify the correction landed; no retry.
        let verifyContext = textDocumentProxy.documentContextBeforeInput ?? ""
        let verified = verifyContext.contains(plan.insert)
        if verified {
            FileLogger.shared.debug(.keyboard, "retroactive autocorrect",
                payload: ["typed": typedWord,
                          "insert": plan.insert,
                          "verified": true])
        } else {
            FileLogger.shared.warn(.keyboard, "retroactive autocorrect did not land",
                payload: ["typed": typedWord,
                          "insert": plan.insert,
                          "verified": false])
        }

        // Defense-in-depth: any hop queued after this one (retroactive or
        // inline) now fails its epoch guard — the document was mutated.
        keystrokeEpoch &+= 1
    }

    /// Main-thread bookkeeping for a retroactive scan batch. Runs the same
    /// guards as the apply hop so words are marked evaluated ONLY when the
    /// epoch still matches at main-hop time — a dropped batch (fast typing)
    /// leaves every scanned word eligible for the next trigger's scan instead
    /// of permanently suppressing it.
    private func markRecentWordsEvaluated(
        _ typedWords: [String],
        capturedEpoch: UInt64,
        capturedDocId: UUID,
        capturedToken: UInt64
    ) {
        if self.view.window == nil { return }
        guard keystrokeEpoch == capturedEpoch else { return }
        guard safeDocumentIdentifier() == capturedDocId else { return }
        let liveToken = keyboardContextToken(keyboardView)
        guard shouldApplyLookupResult(capturedToken: capturedToken, liveToken: liveToken) else { return }
        for typedWord in typedWords {
            recentWordBuffer.markEvaluated(typedWord: typedWord)
        }
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

    // MARK: - Greek Final Sigma

    /// Applies the Greek final-sigma rule to the just-completed word: a
    /// trailing `σ` becomes `ς`. Runs BEFORE the commit trigger (space /
    /// punctuation / return) is inserted, at the same sites autocorrect-on-space
    /// evaluates the word. Only in Greek mode and only when the keyboard is the
    /// input target. Rewrites via backspace-and-retype of the single final
    /// character — no second rewriting path is invented.
    private func applyFinalSigmaToCommittedWord() {
        guard settingsCache.language == .greek, inputTarget == .hostApp else {
            lastSigmaConvertedWord = nil  // a commit trigger outside Greek closes the window
            return
        }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let currentWord = CurrentWordExtractor.extract(from: context).currentWord
        let converted = GreekText.finalSigma(atWordEnd: currentWord)
        guard converted != currentWord else {
            lastSigmaConvertedWord = nil  // nothing to convert — the window is closed
            return
        }
        // The word ends in σ: replace the trailing σ with ς before the trigger
        // lands. The cursor sits after the word, so one backspace removes the σ.
        deleteTargetedBackward()
        insertTargeted("ς")
        lastSigmaConvertedWord = converted
    }

    /// Backspace revert for the Greek final sigma: when the cursor sits directly
    /// after an auto-converted ς, replace it with the typed σ instead of deleting
    /// (Apple system-keyboard behavior), then consume the tracking. The tracking
    /// is deliberately KEPT when the shape check fails — the first backspace
    /// after a space/punctuation commit deletes the trigger character, leaving
    /// the cursor directly after the ς for the next backspace to revert.
    /// No logging on this hot path (Jetsam; docs/LOGGING.md).
    private func revertSigmaIfNeeded() -> Bool {
        guard settingsCache.language == .greek else {
            lastSigmaConvertedWord = nil
            return false
        }
        guard lastSigmaConvertedWord != nil else { return false }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        guard GreekText.shouldRevertSigma(before: context) else { return false }
        deleteTargetedBackward()   // remove the ς
        insertTargeted("σ")        // put the typed form back
        lastSigmaConvertedWord = nil
        return true
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
        let wants = AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: context, language: settingsCache.language)
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
        // Greek letters-layout carry-forward: the `;` key's shifted label is `:`
        // (GreekLayout row 1). `;` contains no letters, so the generic
        // uppercase rule below would leave it unshifted — map it explicitly.
        // English symbols layout has its own `:` key and is untouched.
        if settingsCache.language == .greek, text == ";" {
            return ":"
        }
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
        keystrokeEpoch &+= 1  // any document mutation invalidates a pending deferred autocorrect
        switch inputTarget {
        case .hostApp:     textDocumentProxy.insertText(text)
        case .emojiSearch: keyboardView.emojiSearchOverlay.searchField.insertText(text)
        }
    }

    private func deleteTargetedBackward() {
        keystrokeEpoch &+= 1  // any document mutation invalidates a pending deferred autocorrect
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
