import UIKit


private enum BackspacePhase {
    case charRepeat
    case wordRepeat
    case staleHasTextRetry
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

    private var uiMode: UIMode = .letters {
        didSet {
            keyboardView.apply(mode: uiMode)
        }
    }

    // MARK: - Input Target (keystroke routing)

    enum InputTarget { case hostApp, emojiSearch }
    private var inputTarget: InputTarget = .hostApp

    private var predictionEngine: PredictionEngine?
    private var isPredictionEngineReady = false
    private let predictionBuildQueue = DispatchQueue(
        label: "com.ritoras.prediction.build",
        qos: .userInitiated
    )

    private var keyboardView: KeyboardView!

    private var heightConstraint: NSLayoutConstraint?

    // MARK: - Backspace State

    private var backspaceTimer: Timer?
    private var backspacePhase: BackspacePhase?
    private var backspaceSingleCharCount = 0
    private var backspaceNilContextRetries = 0
    private var backspaceStaleHasTextRetries = 0

    // MARK: - Autocorrect-on-space

    private var wordOrigin = WordOriginTracker()
    /// Tracks the most recent autocorrect for potential revert-on-backspace (Phase 4).
    private var lastAutoCorrection: (typed: String, replacement: String)?

    // MARK: - Dictation State

    private var darwinToken: DarwinObserverToken?
    private var waitTimer: Timer?
    private var errorResetWorkItem: DispatchWorkItem?
    private var suggestionRefreshWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollCount = 0
    private var clipboardPollTimer: Timer?
    private var clipboardPollCount = 0
    private var confirmStopTimer: Timer?

    // MARK: - Localhost Transport (Phase 2)

    private var localhostPollTimer: DispatchSourceTimer?
    private var lastSeenPhase: String = ""
    private var consecutiveConnectionFailures: Int = 0
    private var darwinStateChangedToken: DarwinObserverToken?

    // Persisted across keyboard process restarts
    private var lastProcessedPayloadId: UUID? {
        get { UUID(uuidString: UserDefaults.standard.string(forKey: "ritoras_last_pid") ?? "") }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "ritoras_last_pid") }
    }

    // MARK: - Server Polling

    // Persisted across keyboard process restarts to prevent re-processing
    // the same dictation result when the user switches apps.
    private var lastProcessedTimestamp: Double {
        get { UserDefaults.standard.double(forKey: "ritoras_last_ts") }
        set { UserDefaults.standard.set(newValue, forKey: "ritoras_last_ts") }
    }

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
    private var serverPollWorkItem: DispatchWorkItem?
    private var lastPollStartTime: Date?

    // MARK: - Prediction Engine

    /// Builds the prediction engine (SymSpell + Trie) on a background queue.
    /// Sets `isPredictionEngineReady = true` on the main queue when done.
    private func buildPredictionEngine() {
        isPredictionEngineReady = false

        predictionBuildQueue.async { [weak self] in
            guard let self = self else { return }

            let maxED = SharedConfig.Defaults.symspellMaxEditDistance
            let prefixLen = SharedConfig.Defaults.symspellPrefixLength

            // Build SymSpell index.
            let symSpell = SymSpell(maxEditDistance: maxED, prefixLength: prefixLen)

            // Build trie for completion.
            let trie = Trie()

            // Stream-load the frequency dictionary into both, with memory monitoring.
            do {
                guard let url = WordListLoader.bundledURL() else {
                    throw WordListLoader.WordListError.bundledFileNotFound
                }
                let loaded = try WordListLoader.loadStreamed(
                    from: url,
                    into: symSpell,
                    trie: trie
                )
                if loaded < 82765 {
                    FileLogger.shared.info(.dictionary, "prediction engine loaded partial dictionary", payload: ["wordsLoaded": loaded])
                }
            } catch {
                FileLogger.shared.error(.dictionary, "prediction engine failed to load dictionary", payload: ["error": error.localizedDescription])
                DispatchQueue.main.async {
                    self.isPredictionEngineReady = true
                    self.predictionEngine = PredictionEngine()
                }
                return
            }

            // Create the SymSpell provider.
            let provider = SymSpellProvider(symSpell: symSpell, trie: trie)

            // Create the Apple UITextChecker provider.
            let appleProvider = AppleSpellCheckerProvider()

            // Create the BigramPredictor (lazy-loaded after a delay).
            let bigramProvider = BigramPredictor(minCount: SharedConfig.Defaults.bigramMinCount)

            // Build the engine and register providers.
            let engine = PredictionEngine()
            engine.addProvider(provider)
            engine.addProvider(appleProvider)
            engine.addProvider(bigramProvider)

            DispatchQueue.main.async {
                self.predictionEngine = engine
                self.isPredictionEngineReady = true
                FileLogger.shared.info(.keyboard, "PredictionEngine ready")

                // Lazy-load bigram map after a short delay for memory headroom.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    bigramProvider.loadAsync {
                        FileLogger.shared.info(.keyboard, "BigramPredictor ready")
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Wire FileLogger broadcast to ship logs to container app via localhost.
        // Set before any log calls so we capture everything from the start.
        FileLogger.broadcast = { level, component, message, payload in
            let entry = LogShipmentEntry(level: level, component: component, message: message, payload: payload)
            KeyboardLogShipper.shared.append(entry)
        }
        KeyboardLogShipper.shared.start()

        // Log the resolved app-group identifier via FileLogger (post-resolution, safe to use FileLogger now).
        FileLogger.shared.info(.keyboard, "AppGroupResolver outcome", payload: [
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
        buildPredictionEngine()
        state = .idle
        FileLogger.shared.info(.keyboard, "viewDidLoad OK",
                               payload: ["hasFullAccess": hasFullAccess])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardView.updateFullAccess(hasFullAccess)

        // Localhost transport (primary under SideStore where app group is broken).
        Task { await self.refreshStateFromLocalhost() }
        startLocalhostPolling()

        // Defensive: never resume in search mode after keyboard dismiss/reappear
        inputTarget = .hostApp
        if uiMode == .emojiSearch {
            keyboardView.emojiPanelView.searchField.resignFirstResponder()
            uiMode = .emoji
        }

        // Resume a dictation that was in progress when iOS suspended/terminated
        // the extension. pendingRequestId survives in UserDefaults, so even a
        // fully relaunched keyboard process can recover the result.
        if let id = pendingRequestId {
            let age = pendingRequestStart > 0 ? Date().timeIntervalSince1970 - pendingRequestStart : 0
            if age > 300 {  // >5 min — the result is unrecoverable; abandon it
                FileLogger.shared.warn(.keyboard, "viewDidAppear — pending dictation stale",
                                       payload: ["age": age, "pendingRequestId": id.uuidString])
                pendingRequestId = nil
                state = .idle
            } else {
                FileLogger.shared.info(.keyboard, "viewDidAppear — resuming pending dictation",
                                       payload: ["pendingRequestId": id.uuidString, "age": age])
                checkForPendingDictation()
            }
        } else {
            state = .idle
            FileLogger.shared.info(.keyboard, "viewDidAppear — idle",
                                   payload: ["hasFullAccess": hasFullAccess])
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installOrUpdateHeightConstraint()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        installOrUpdateHeightConstraint()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        FileLogger.shared.info(.keyboard, "viewWillDisappear")

        // Cancel timers so they don't fire across app switches.
        // The Darwin observer is intentionally kept alive: dictation may complete
        // on the server while the keyboard is hidden (e.g. user is recording in
        // the container app), and we want the notification to land immediately
        // when the keyboard reappears without waiting for server polling.
        // The observer auto-unregisters in deinit; stale notifications after a
        // resolved dictation are filtered by pendingRequestId.
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        serverPollTimer?.invalidate()
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        confirmStopTimer?.invalidate()
        confirmStopTimer = nil
        errorResetWorkItem?.cancel()
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
        backspaceStaleHasTextRetries = 0
        stopLocalhostPolling()
    }

    deinit {
        KeyboardLogShipper.shared.stop()
        FileLogger.broadcast = nil
        darwinToken = nil
        darwinStateChangedToken = nil
        stopLocalhostPolling()
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        serverPollTimer?.invalidate()
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        confirmStopTimer?.invalidate()
        confirmStopTimer = nil
        errorResetWorkItem?.cancel()
        backspaceTimer?.invalidate()
        backspaceNilContextRetries = 0
        backspaceStaleHasTextRetries = 0
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
            self.keyboardView.emojiPanelView.searchField.resignFirstResponder()
            self.uiMode = .emoji
        }

        keyboardView.emojiPanelView.onSearchReturn = { [weak self] in
            guard let self = self else { return }
            self.inputTarget = .hostApp
            self.keyboardView.emojiPanelView.searchField.resignFirstResponder()
            self.uiMode = .emoji
        }
    }

    private func installOrUpdateHeightConstraint() {
        if heightConstraint == nil {
            heightConstraint = view.heightAnchor.constraint(equalToConstant: 256)
            heightConstraint?.priority = .defaultHigh
            heightConstraint?.isActive = true
        }
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
            clipboardPollTimer?.invalidate()
            serverPollTimer?.invalidate()
            clearClipboardDictation()
        default:
            break   // ignore taps while openingApp/inserting
        }
    }

    // MARK: - Dictation via Container App

    private func openContainerAppForDictation() {
        // Clear any stale clipboard/server data from previous sessions
        clearClipboardDictation()
        lastProcessedTimestamp = 0
        clipboardPollTimer?.invalidate()
        clipboardPollTimer = nil
        serverPollTimer?.invalidate()
        serverPollTimer = nil
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil

        let id = UUID()
        pendingRequestId = id
        pendingRequestStart = Date().timeIntervalSince1970

        FileLogger.shared.debug(.keyboard, "openContainerApp", payload: [
            "id": id.uuidString
        ])

        // Build URL with id query param
        var components = URLComponents(url: SharedConfig.Defaults.dictateURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        guard let url = components.url else {
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

        // Register Darwin notification observer
        darwinToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinNotificationName) { [weak self] in
            Task { await self?.refreshStateFromLocalhost() }
        }

        // Register localhost state-changed observer
        darwinStateChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinStateChangedNotificationName) { [weak self] in
            // State-changed notification: poll localhost for updated state.
            Task { await self?.refreshStateFromLocalhost() }
        }

        // Start timeout timer
        waitTimer = Timer.scheduledTimer(withTimeInterval: SharedConfig.Defaults.dictationTimeoutSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTimeout()
            }
        }
    }

    /// Called when a Darwin notification fires. The payload should be pre-fetched
    /// on a background queue (see Darwin observer registration) — if nil, falls
    /// back to a synchronous read for the legacy code path.
    private func handleDictationCompleted(payload preFetchedPayload: DictationPayload? = nil) {
        let elapsedSincePost = pendingRequestStart > 0
            ? (Date().timeIntervalSince1970 - pendingRequestStart) * 1000 : 0
        FileLogger.shared.info(.keyboard, "darwin received", payload: [
            "id": pendingRequestId?.uuidString ?? "nil",
            "elapsed_ms_since_post": elapsedSincePost
        ])
        stopDictationTransports()

        // Try pre-fetched payload first (works if properly signed)
        guard let payload = preFetchedPayload else {
            // No payload yet — poll the server and keep polling.
            FileLogger.shared.debug(.keyboard, "handleDictationCompleted — no payload yet, falling back to server poll")
            pollServerForDictation()
            if state == .idle {
                state = .waiting
                startServerPolling()
            }
            return
        }

        // Ignore stale payloads (wrong request ID, or no pending request at all)
        guard let id = pendingRequestId, payload.id == id else {
            FileLogger.shared.warn(.keyboard, "Ignoring stale dictation payload",
                                   payload: ["payloadId": payload.id.uuidString,
                                             "pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
            return
        }

        switch payload.status {
        case .completed:
            insertDictationResult(text: payload.text ?? "")
            return
        case .cancelled:
            FileLogger.shared.info(.keyboard, "Dictation cancelled",
                                   payload: ["pendingRequestId": id.uuidString])
            pendingRequestId = nil
            state = .idle
        case .error:
            FileLogger.shared.error(.keyboard, "Dictation completed with error",
                                    payload: ["pendingRequestId": id.uuidString,
                                              "errorMessage": payload.errorMessage ?? "unknown"])
            pendingRequestId = nil
            state = .error(payload.errorMessage ?? "Transcription failed.")
        case .recording, .transcribing:
            // Premature signal \u{2014} keep waiting
            startWaitingForDictation(id: id)
            return
        }
    }

    // MARK: - Localhost Transport (Phase 2)

    /// Polls the localhost server for the current dictation state. Called from
    /// the polling timer and from the Darwin state-changed notification.
    /// Falls back to legacy server polling after 3 consecutive connection
    /// failures (container app not running).
    private func refreshStateFromLocalhost() async {
        guard let id = pendingRequestId else { return }
        do {
            let snapshot = try await LocalhostClient.getState(id: id)
            consecutiveConnectionFailures = 0
            guard let snapshot = snapshot else { return }
            await MainActor.run {
                self.lastSeenPhase = snapshot.phase
                self.updateRecordingInProgressUI(phase: snapshot.phase)
            }
            if snapshot.phase == "done" || snapshot.phase == "error" {
                // Terminal — fetch the result
                do {
                    if let result = try await LocalhostClient.getResult(id: id) {
                        await MainActor.run {
                            self.handleLocalhostResult(result)
                        }
                    }
                } catch {
                    FileLogger.shared.warn(.keyboard, "Failed to fetch result from localhost", payload: [
                        "id": id.uuidString,
                        "error": String(describing: error)
                    ])
                }
            }
        } catch LocalhostClient.LocalhostError.connectionRefused {
            consecutiveConnectionFailures += 1
            if consecutiveConnectionFailures >= 3 {
                // Container app is dead — fall back to legacy server polling
                stopLocalhostPolling()
                startServerPolling()
            }
        } catch {
            // Other errors — log and continue polling
            FileLogger.shared.warn(.keyboard, "LocalhostClient error", payload: ["error": String(describing: error)])
        }
    }

    /// Starts a 0.5s repeating timer that calls `refreshStateFromLocalhost`.
    /// Uses `DispatchSourceTimer` (negligible memory overhead) instead of
    /// `Timer` to avoid RunLoop coupling in the keyboard extension.
    private func startLocalhostPolling() {
        stopLocalhostPolling()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            Task { await self?.refreshStateFromLocalhost() }
        }
        timer.resume()
        localhostPollTimer = timer
    }

    private func stopLocalhostPolling() {
        localhostPollTimer?.cancel()
        localhostPollTimer = nil
    }

    /// Processes a terminal `DictationResultSnapshot` received from the
    /// localhost server. Idempotent: checks `lastProcessedTimestamp` to
    /// prevent double-insertion.
    @MainActor
    private func handleLocalhostResult(_ result: DictationResultSnapshot) {
        // Idempotency guard
        let lastTimestamp = lastProcessedTimestamp
        if result.timestamp.timeIntervalSince1970 <= lastTimestamp {
            return  // already processed
        }

        switch result.status {
        case "completed":
            if let text = result.text, !text.isEmpty {
                lastProcessedTimestamp = result.timestamp.timeIntervalSince1970
                lastProcessedPayloadId = UUID(uuidString: result.id)
                stopDictationTransports()
                insertDictationResult(text: text)  // existing method
            }
        case "error":
            lastProcessedTimestamp = result.timestamp.timeIntervalSince1970
            lastProcessedPayloadId = UUID(uuidString: result.id)
            stopDictationTransports()
            state = .error(result.errorMessage ?? "Transcription failed")
        default:
            break
        }
    }

    /// Updates the recording-in-progress UI based on the localhost phase string.
    /// This is the Symptom 4 fix: transitions from `.idle` to `.waiting` when
    /// the server reports "recording" or "transcribing", so the mic button
    /// shows the active state without waiting for a localhost response.
    private func updateRecordingInProgressUI(phase: String) {
        switch phase {
        case "recording", "transcribing":
            state = .waiting  // unconditional — was guarded on .idle which never matched
        case "idle", "done", "error":
            // Don't change state here — handleLocalhostResult will handle terminal states
            break
        default:
            break
        }
    }

    private func handleTimeout() {
        FileLogger.shared.warn(.keyboard, "Dictation timed out",
                               payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
        darwinToken = nil
        waitTimer = nil
        pendingRequestId = nil
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

    /// Resumes waiting for an in-progress dictation after the keyboard process was
    /// suspended/terminated and relaunched \u{2014} e.g. the user switched apps and came
    /// back. `pendingRequestId` survives in UserDefaults, so a fully relaunched
    /// keyboard process can still recover the result.
    /// Reads the tagged Ritoras dictation payload from the clipboard. The
    /// clipboard is the reliable cross-process channel under SideStore (where the
    /// App Group is NOT shared), so the container app writes the result here as a
    /// custom `org.ritoras.dictation` pasteboard type alongside the plain text.
    /// Reads the Ritoras clipboard payload synchronously. Safe to call from any
    /// queue (UIPasteboard reads are thread-safe on iOS 10+).
    private static func clipboardPayloadSync() -> [String: Any]? {
        guard let data = UIPasteboard.general.data(forPasteboardType: "org.ritoras.dictation") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard json["source"] as? String == "ritoras" else { return nil }
        return json
    }

    private func clipboardPayload() -> [String: Any]? {
        Self.clipboardPayloadSync()
    }

    /// Checks the clipboard (primary under SideStore) and the App Group payload for
    /// a terminal result matching `id`. Reads both stores on a background queue,
    /// dispatches to main for UI updates, and calls `completion(true)` on a terminal
    /// status or `completion(false)` while still in progress.
    private func tryResolveFromStores(id: UUID, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(false); return }
            let t0 = Date()

            // Read both stores on background (synchronous I/O: file + UserDefaults + UIPasteboard).
            let appGroupPayload: DictationPayload? = nil
            let clipPayload = KeyboardViewController.clipboardPayloadSync()

            let elapsed = Date().timeIntervalSince(t0) * 1000

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.pendingRequestId != nil else {
                    completion(false)
                    return
                }

                var didHitAppGroup = false
                var didHitClipboard = false
                if let payload = appGroupPayload, payload.id == id {
                    didHitAppGroup = true
                }
                if let clip = clipPayload, let clipId = UUID(uuidString: clip["id"] as? String ?? ""),
                   clipId == id {
                    let ts = clip["timestamp"] as? Double ?? 0
                    let age = ts > 0 ? Date().timeIntervalSince1970 - ts : 0
                    if age < 300 { didHitClipboard = true }
                }

                FileLogger.shared.debug(.keyboard, "stores check", payload: [
                    "appGroupHit": didHitAppGroup,
                    "clipboardHit": didHitClipboard,
                    "elapsed_ms": elapsed,
                    "id": id.uuidString
                ])

                // 1. App Group payload (file + UserDefaults) \u{2014} works on App Store builds.
                if let payload = appGroupPayload, payload.id == id {
                    switch payload.status {
                    case .completed:
                        FileLogger.shared.info(.keyboard, "resolve: appgroup completed → insert",
                                               payload: ["id": id.uuidString, "length": payload.text?.count ?? 0])
                        self.insertDictationResult(text: payload.text ?? "")
                        completion(true); return
                    case .error:
                        FileLogger.shared.warn(.keyboard, "resolve: appgroup error",
                                               payload: ["id": id.uuidString, "errorMessage": payload.errorMessage ?? "unknown"])
                        self.stopDictationTransports(); self.pendingRequestId = nil
                        self.state = .error(payload.errorMessage ?? "Transcription failed.")
                        completion(true); return
                    case .cancelled:
                        FileLogger.shared.info(.keyboard, "resolve: appgroup cancelled",
                                               payload: ["id": id.uuidString])
                        self.stopDictationTransports(); self.pendingRequestId = nil
                        self.state = .idle
                        completion(true); return
                    case .recording, .transcribing:
                        break
                    }
                }

                // 2. Clipboard (primary channel under SideStore).
                if let clip = clipPayload {
                    let clipId = UUID(uuidString: clip["id"] as? String ?? "")
                    let status = clip["status"] as? String ?? ""
                    let ts = clip["timestamp"] as? Double ?? 0
                    let age = ts > 0 ? Date().timeIntervalSince1970 - ts : 0
                    if clipId == id, age < 300 {
                        didHitClipboard = true
                        switch status {
                        case "completed":
                            FileLogger.shared.info(.keyboard, "resolve: clipboard completed → insert",
                                                   payload: ["id": id.uuidString])
                            self.insertDictationResult(text: clip["text"] as? String ?? "")
                            completion(true); return
                        case "error":
                            FileLogger.shared.warn(.keyboard, "resolve: clipboard error",
                                                   payload: ["id": id.uuidString])
                            self.stopDictationTransports(); self.pendingRequestId = nil
                            self.state = .error(clip["errorMessage"] as? String ?? "Transcription failed.")
                            completion(true); return
                        case "cancelled":
                            FileLogger.shared.info(.keyboard, "resolve: clipboard cancelled",
                                                   payload: ["id": id.uuidString])
                            self.stopDictationTransports(); self.pendingRequestId = nil
                            self.state = .idle
                            completion(true); return
                        default:
                            break  // recording/transcribing — keep polling
                        }
                    } else if clipId != id {
                        FileLogger.shared.warn(.keyboard, "resolve: clipboard id mismatch",
                                               payload: ["expected": id.uuidString,
                                                         "actual": clipId?.uuidString ?? "nil",
                                                         "age": age])
                    }
                }

                completion(false)
            }
        }
    }

    private func checkForPendingDictation() {
        guard let id = pendingRequestId else {
            state = .idle
            return
        }
        FileLogger.shared.info(.keyboard, "Resuming pending dictation",
                               payload: ["pendingRequestId": id.uuidString])
        state = .waiting

        // Re-register the Darwin observer (it was torn down in viewWillDisappear).
        if darwinToken == nil {
            darwinToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinNotificationName) { [weak self] in
                Task { await self?.refreshStateFromLocalhost() }
            }
        }

        // Re-register the localhost state-changed observer.
        if darwinStateChangedToken == nil {
            darwinStateChangedToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinStateChangedNotificationName) { [weak self] in
                Task { await self?.refreshStateFromLocalhost() }
            }
        }

        // Start localhost polling.
        startLocalhostPolling()

        // Clipboard (primary under SideStore) + App Group payload.
        tryResolveFromStores(id: id) { [weak self] resolved in
            guard let self = self else { return }
            if resolved { return }
            // Fallback: poll the server.
            self.startServerPolling()
        }
    }

    /// Tears down every active result-transport (timers + Darwin observer) so that
    /// once one path resolves the dictation, no competing path re-inserts the text.
    private func stopDictationTransports() {
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        serverPollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        darwinToken = nil
        darwinStateChangedToken = nil
        confirmStopTimer?.invalidate()
        confirmStopTimer = nil
        serverPollWorkItem?.cancel()
        serverPollWorkItem = nil
        stopLocalhostPolling()
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
        FileLogger.shared.debug(.keyboard, "Dictation cancelled by user",
                                payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
        pendingRequestId = nil
        state = .idle
    }

    /// Inserts the transcribed text, clears the pending request, and resets the
    /// keyboard to idle. Centralizes the shared insert+reset flow and guarantees
    /// every other transport is stopped first (prevents double-insert now that the
    /// Darwin observer and server polling can run concurrently on resume).
    private func insertDictationResult(text: String) {
        let totalElapsed = pendingRequestStart > 0
            ? (Date().timeIntervalSince1970 - pendingRequestStart) * 1000 : 0
        FileLogger.shared.info(.keyboard, "insert", payload: [
            "id": pendingRequestId?.uuidString ?? "nil",
            "length": text.count,
            "total_elapsed_ms": totalElapsed
        ])

        if inputTarget != .hostApp {
            FileLogger.shared.warn(.keyboard, "dictation result arrived but inputTarget is not .hostApp",
                                   payload: ["inputTarget": String(describing: inputTarget)])
        }
        FileLogger.shared.info(.keyboard, "insertDictationResult entry",
                               payload: ["length": text.count, "preview": String(text.prefix(30))])
        stopDictationTransports()
        pendingRequestId = nil
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

    // MARK: - Server Polling (Works when app is backgrounded)

    /// Polls with adaptive backoff: fast (0.3s) for the first 5 polls to catch
    /// quick results, then backs off to 1.2s to limit server load. Each cycle
    /// checks the clipboard + App Group payload FIRST, then the server as a
    /// fallback. Resolves as soon as ANY yields a terminal status.
    private func startServerPolling() {
        serverPollCount = 0
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

    /// One cycle of server polling. Increments the poll counter, checks local
    /// stores first (clipboard + App Group), and falls back to the HTTP server.
    /// Always schedules the next poll at the end; cancellation is handled by
    /// the `pendingRequestId` guard in `scheduleNextServerPoll`.
    private func performServerPollCycle() {
        guard let id = pendingRequestId else { return }
        serverPollCount += 1

        if serverPollCount > 50 {  // ~60 seconds
            stopDictationTransports()
            serverPollWorkItem?.cancel()
            serverPollWorkItem = nil
            FileLogger.shared.warn(.keyboard, "Server polling timed out after 60s",
                                   payload: ["pendingRequestId": pendingRequestId?.uuidString ?? "nil"])
            pendingRequestId = nil
            state = .error("Dictation timed out. Try again.")
            return
        }

        // Primary channels: clipboard + App Group payload.
        tryResolveFromStores(id: id) { [weak self] resolved in
            guard let self = self else { return }
            if !resolved {
                // Fallback channel: the server.
                self.pollServerForDictation()
            }
        }

        // Schedule the next poll regardless of resolution — if the request was
        // resolved by the async tryResolveFromStores completion handler, the
        // guard inside scheduleNextServerPoll will cancel this cascade.
        scheduleNextServerPoll()
    }

    /// One-shot HTTP GET to the server for the current dictation result.
    private func pollServerForDictation() {
        let config = SharedConfig.load()
        // Prefer the probe-selected server (written by the container app on recording
        // start). Fall back to config.servers.first if the probe hasn't run, returned
        // nil, or the selected server is no longer in the configured list (user
        // removed it mid-dictation).
        let selected = SharedConfig.selectedServer().flatMap { s -> String? in
            config.servers.contains(s) ? s : nil
        }
        guard let server = selected ?? config.servers.first else { return }
        guard let url = URL(string: "\(server)/dictation_result/latest") else { return }

        let now = Date()
        let elapsedSinceLastPoll = lastPollStartTime.map { now.timeIntervalSince($0) * 1000 } ?? 0
        lastPollStartTime = now
        FileLogger.shared.debug(.keyboard, "server poll", payload: [
            "pollCount": serverPollCount,
            "elapsed_ms_since_last_poll": elapsedSinceLastPoll,
            "id": pendingRequestId?.uuidString ?? "nil"
        ])
        FileLogger.shared.debug(.network, "poll target", payload: [
            "server": server,
            "source": selected != nil ? "probe" : "fallback_first"
        ])

        let task = WhisperClient.session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            let httpT0 = Date()
            if let error = error {
                FileLogger.shared.warn(.network, "poll: network error",
                                       payload: ["url": url.absoluteString, "error": error.localizedDescription])
                return
            }
            guard let data = data else {
                FileLogger.shared.warn(.network, "poll: empty response",
                                       payload: ["url": url.absoluteString])
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                FileLogger.shared.warn(.network, "poll: unparseable body",
                                       payload: ["url": url.absoluteString,
                                                 "bodyPreview": String(data: data, encoding: .utf8).map { String($0.prefix(100)) } ?? "?"])
                return
            }

            let status = json["status"] as? String ?? "none"
            let timestamp = json["timestamp"] as? Double ?? 0
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let pollElapsed = Date().timeIntervalSince(httpT0) * 1000

            FileLogger.shared.debug(.keyboard, "server poll response", payload: [
                "statusCode": statusCode,
                "elapsed_ms": pollElapsed,
                "status": status,
                "id": self.pendingRequestId?.uuidString ?? "nil"
            ])

            // If the server returned {"detail":"Not Found"} (404), keep polling silently.
            if status == "none" && json["detail"] != nil {
                FileLogger.shared.debug(.network, "poll: 404/detail",
                                        payload: ["url": url.absoluteString])
                return
            }

            DispatchQueue.main.async {
                // If this dictation was already resolved via the App Group / Darwin
                // path, ignore the stale server response (prevents double-insert).
                guard self.pendingRequestId != nil else { return }

                guard timestamp > 0 else {
                    FileLogger.shared.warn(.network, "poll: timestamp 0",
                                           payload: ["url": url.absoluteString])
                    return
                }
                let age = Date().timeIntervalSince1970 - timestamp
                guard age < 120 else {
                    FileLogger.shared.debug(.network, "poll: result stale",
                                            payload: ["age": age, "url": url.absoluteString])
                    return
                }
                if timestamp <= self.lastProcessedTimestamp { return }

                switch status {
                case "completed":
                    FileLogger.shared.info(.network, "poll: server status=completed",
                                           payload: ["url": url.absoluteString,
                                                     "textLength": (json["text"] as? String)?.count ?? 0,
                                                     "timestamp": timestamp])
                    self.lastProcessedTimestamp = timestamp
                    self.insertDictationResult(text: json["text"] as? String ?? "")

                case "error":
                    FileLogger.shared.warn(.network, "poll: server status=error",
                                           payload: ["url": url.absoluteString,
                                                     "errorMessage": json["errorMessage"] as? String ?? "unknown"])
                    self.stopDictationTransports()
                    self.lastProcessedTimestamp = timestamp
                    self.pendingRequestId = nil
                    self.state = .error(json["errorMessage"] as? String ?? "Transcription failed.")

                case "cancelled":
                    FileLogger.shared.info(.network, "poll: server status=cancelled",
                                           payload: ["url": url.absoluteString])
                    self.stopDictationTransports()
                    self.lastProcessedTimestamp = timestamp
                    self.pendingRequestId = nil
                    self.state = .idle

                case "transcribing", "recording":
                    break  // keep polling

                default:
                    FileLogger.shared.debug(.network, "poll: unknown status",
                                            payload: ["status": status, "url": url.absoluteString])
                    break
                }
            }
        }
        task.resume()
    }



    /// Clears the clipboard dictation payload to prevent re-processing.
    private func clearClipboardDictation() {
        UIPasteboard.general.string = ""
    }

    // MARK: - Error Auto-Reset

    private func scheduleErrorReset() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if case .error = self.state {
                self.state = .idle
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
            if uiMode == .emoji {
                EmojiRecents.add(s)
            }
            let isTriggerPunct = SharedConfig.Defaults.autocorrectTriggerPunctuation.contains(s)
            let shouldAutoCorrect = isTriggerPunct && uiMode != .emoji
            if shouldAutoCorrect {
                applyAutocorrectIfNeeded()
            }
            let text = applyShift(to: s)
            insertTargeted(text)
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
            applyAutocorrectIfNeeded()
            insertTargeted(" ")
            recomputeAutoCap()
            scheduleSuggestionRefresh()
            wordOrigin.resetToTyping()

        case .return:
            if inputTarget == .emojiSearch {
                keyboardView.emojiPanelView.onSearchReturn?()
            } else {
                applyAutocorrectIfNeeded()
                insertTargeted("\n")
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
                keyboardView.emojiPanelView.searchField.resignFirstResponder()
                uiMode = .emoji
            }

        case .globe:
            advanceToNextInputMode()
        }
    }

    func keyboardView(_ view: KeyboardView, didTapSuggestion text: String) {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""

        // Extract the typed word before deleting it (needed for learnWord).
        let typedWord = CurrentWordExtractor.extract(from: context).currentWord

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
        insertTargeted(text + " ")
        wordOrigin.markSuggestionTap()    // Lock persists until the next separator handler clears it
        lastAutoCorrection = nil          // Suggestion tap invalidates any pending revert
        // Refresh is async; the token guard rejects any result whose captured state no longer matches.
        keyboardView.refreshSuggestions()

        // If the user accepted a suggestion that differs from their typed word,
        // learn the typed word so the system spell checker stops flagging it.
        if !typedWord.isEmpty, typedWord.lowercased() != text.lowercased() {
            LearnedWordsStore.shared.add(typedWord)
        }
    }

    func keyboardViewSuggestionSnapshot(_ view: KeyboardView) -> SuggestionInputSnapshot? {
        guard inputTarget == .hostApp else { return nil }
        guard isPredictionEngineReady, predictionEngine != nil else { return nil }
        let context = textDocumentProxy.documentContextBeforeInput
        let extracted = CurrentWordExtractor.extract(from: context)
        return SuggestionInputSnapshot(
            currentWord: extracted.currentWord,
            lookupWord: extracted.lookupWord,
            previousWord: extracted.previousWord
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

        guard hasTextInCurrentTarget else {
            backspacePhase = .staleHasTextRetry
            backspaceStaleHasTextRetries = 1
            // DIAGNOSTIC — strip after fix verification (Phase 3)
            FileLogger.shared.debug(.keyboard, "backspace didBegin-pre: stale hasText — entering .staleHasTextRetry", payload: [
                "site": "didBegin-pre",
                "hasText": hasTextInCurrentTarget,
                "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                "staleRetries": backspaceStaleHasTextRetries,
                "nilCtxRetries": backspaceNilContextRetries,
                "phase": String(describing: backspacePhase)
            ])
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceStaleHasTextRetryInterval, repeats: false)
            return
        }

        deleteTargetedBackward()
        backspaceSingleCharCount = 1
        scheduleSuggestionRefresh()

        guard hasTextInCurrentTarget else {
            backspacePhase = .staleHasTextRetry
            backspaceStaleHasTextRetries = 1
            // DIAGNOSTIC — strip after fix verification (Phase 3)
            FileLogger.shared.debug(.keyboard, "backspace didBegin-post: stale hasText after initial delete — entering .staleHasTextRetry", payload: [
                "site": "didBegin-post",
                "hasText": hasTextInCurrentTarget,
                "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                "staleRetries": backspaceStaleHasTextRetries,
                "nilCtxRetries": backspaceNilContextRetries,
                "phase": String(describing: backspacePhase)
            ])
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceStaleHasTextRetryInterval, repeats: false)
            return
        }

        backspacePhase = .charRepeat
        scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceInitialRepeatDelay, repeats: false)
    }

    func keyboardViewBackspaceDidEnd(_ view: KeyboardView) {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
        backspaceStaleHasTextRetries = 0
    }

    // MARK: - Text Changes

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        lastAutoCorrection = nil  // host text change invalidates any pending revert
        // SYNC: system-signaled textDidChange bypasses debounce so the suggestion bar
        // updates immediately — debounce here would feel laggy after external edits.
        keyboardView.refreshSuggestions()
        recomputeAutoCap()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        backspaceNilContextRetries = 0
        backspaceStaleHasTextRetries = 0
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
        backspaceStaleHasTextRetries = 0
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        lastAutoCorrection = nil  // cursor move invalidates any pending revert
        backspaceNilContextRetries = 0
        backspaceStaleHasTextRetries = 0
        recomputeAutoCap()
    }

    // MARK: - Autocorrect-on-space

    private func applyAutocorrectIfNeeded() {
        guard inputTarget == .hostApp else { return }
        // User-facing master toggle (read fresh every call, like autoCapitalizationEnabled).
        guard SharedConfig.autocorrectOnSpaceEnabled() else { return }

        // Host-field gate (password/search/email/URL fields etc.)
        if AutoCorrectTraits.shouldSuppress(
            keyboardType: textDocumentProxy.keyboardType,
            autocorrectionType: textDocumentProxy.autocorrectionType,
            spellCheckingType: textDocumentProxy.spellCheckingType
        ) { return }

        // Only re-evaluate words the user typed char-by-char.
        guard wordOrigin.current == .typing else { return }

        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let extracted = CurrentWordExtractor.extract(from: context)

        // Skip autocorrect when the word has surrounding punctuation (e.g., `hello"` or `"hello`).
        guard extracted.currentWord == extracted.lookupWord else { return }

        guard !extracted.lookupWord.isEmpty,
              let engine = predictionEngine,
              isPredictionEngineReady else { return }

        let isMisspelled: Bool = {
            let checker = UITextChecker()
            let nsString = extracted.lookupWord as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let misspelledRange = checker.rangeOfMisspelledWord(
                in: extracted.lookupWord,
                range: range,
                startingAt: 0,
                wrap: false,
                language: "en-US"
            )
            return misspelledRange.location != NSNotFound
        }()

        let top = engine.topCorrection(
            forCurrentWord: extracted.currentWord,
            lookupWord: extracted.lookupWord,
            previousWord: extracted.previousWord
        )

        let decision = AutocorrectController.evaluate(
            typedWord: extracted.lookupWord,
            origin: wordOrigin.current,
            topCorrection: top,
            isLearned: LearnedWordsStore.shared.contains(extracted.lookupWord),
            isMisspelled: isMisspelled
        )

        switch decision {
        case .correct(let typed, let correction):
            // Delete the typed word and insert the correction.
            // Same pattern as suggestion-tap handler (lines ~970-976).
            let deleteCount = typed.count
            for _ in 0..<deleteCount {
                deleteTargetedBackward()
            }
            insertTargeted(correction)
            wordOrigin.markAutocorrectApplied()
            lastAutoCorrection = (typed: typed, replacement: correction)
        case .leaveAsIs:
            lastAutoCorrection = nil
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

    // MARK: - Auto-Capitalization Helpers

    private var effectiveAutoCapActive: Bool { autoCapActive && !userOverrodeAutoCap }

    private var displayedShiftState: ShiftState {
        if shiftState == .lower && effectiveAutoCapActive { return .upper }
        return shiftState
    }

    private func recomputeAutoCap() {
        guard inputTarget == .hostApp else { return }
        // User-facing master toggle (default ON). Read from the App Group on every recompute.
        guard SharedConfig.autoCapitalizationEnabled() else {
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
        case .emojiSearch: return !(keyboardView.emojiPanelView.searchField.text?.isEmpty ?? true)
        }
    }

    private func insertTargeted(_ text: String) {
        switch inputTarget {
        case .hostApp:     textDocumentProxy.insertText(text)
        case .emojiSearch: keyboardView.emojiPanelView.searchField.insertText(text)
        }
    }

    private func deleteTargetedBackward() {
        switch inputTarget {
        case .hostApp:
            guard textDocumentProxy.hasText else {
                // DIAGNOSTIC — strip after fix verification (Phase 3)
                FileLogger.shared.warn(.keyboard, "deleteTargetedBackward: inner guard aborted (stale hasText race)", payload: [
                    "site": "deleteTargetedBackward-abort",
                    "hasText": textDocumentProxy.hasText,
                    "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                    "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                    "staleRetries": backspaceStaleHasTextRetries,
                    "nilCtxRetries": backspaceNilContextRetries,
                    "phase": String(describing: backspacePhase)
                ])
                return
            }
            textDocumentProxy.deleteBackward()
        case .emojiSearch:
            keyboardView.emojiPanelView.searchField.deleteBackward()
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
        guard hasTextInCurrentTarget else {
            backspaceStaleHasTextRetries += 1
            if backspaceStaleHasTextRetries > SharedConfig.Defaults.backspaceStaleHasTextRetryLimit {
                backspaceTimer?.invalidate()
                backspaceTimer = nil
                backspacePhase = nil
                backspaceStaleHasTextRetries = 0
                return
            }
            // DIAGNOSTIC — strip after fix verification (Phase 3)
            FileLogger.shared.debug(.keyboard, "backspace tick-top: stale hasText — entering .staleHasTextRetry", payload: [
                "site": "tick-top",
                "hasText": hasTextInCurrentTarget,
                "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                "staleRetries": backspaceStaleHasTextRetries,
                "nilCtxRetries": backspaceNilContextRetries,
                "phase": String(describing: backspacePhase)
            ])
            backspacePhase = .staleHasTextRetry
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceStaleHasTextRetryInterval, repeats: false)
            return
        }

        // In search mode, always use char-repeat (no word-mode) since the
        // search field is a single-line input with no need for word-level deletion.
        if inputTarget == .emojiSearch {
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

            guard hasTextInCurrentTarget else {
                backspaceStaleHasTextRetries += 1
                if backspaceStaleHasTextRetries > SharedConfig.Defaults.backspaceStaleHasTextRetryLimit {
                    backspaceTimer?.invalidate()
                    backspaceTimer = nil
                    backspacePhase = nil
                    backspaceStaleHasTextRetries = 0
                    return
                }
                // DIAGNOSTIC — strip after fix verification (Phase 3)
                FileLogger.shared.debug(.keyboard, "backspace tick-charRepeat: stale hasText — entering .staleHasTextRetry", payload: [
                    "site": "tick-charRepeat",
                    "hasText": hasTextInCurrentTarget,
                    "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                    "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                    "staleRetries": backspaceStaleHasTextRetries,
                    "nilCtxRetries": backspaceNilContextRetries,
                    "phase": String(describing: backspacePhase)
                ])
                backspacePhase = .staleHasTextRetry
                scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceStaleHasTextRetryInterval, repeats: false)
                return
            }

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
                guard hasTextInCurrentTarget else { break }
                deleteTargetedBackward()
                HapticsManager.shared.tapImpact()
            }
            scheduleSuggestionRefresh()
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceWordRepeatInterval, repeats: false)

        case .staleHasTextRetry:
            guard hasTextInCurrentTarget else {
                backspaceStaleHasTextRetries += 1
                if backspaceStaleHasTextRetries > SharedConfig.Defaults.backspaceStaleHasTextRetryLimit {
                    // DIAGNOSTIC — strip after fix verification (Phase 3)
                    FileLogger.shared.warn(.keyboard, "backspace retry: gave up after limit", payload: [
                        "site": "tick-staleRetry-giveup",
                        "hasText": hasTextInCurrentTarget,
                        "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                        "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                        "staleRetries": backspaceStaleHasTextRetries,
                        "nilCtxRetries": backspaceNilContextRetries,
                        "phase": String(describing: backspacePhase)
                    ])
                    backspaceTimer?.invalidate()
                    backspaceTimer = nil
                    backspacePhase = nil
                    backspaceStaleHasTextRetries = 0
                    return
                }
                // DIAGNOSTIC — strip after fix verification (Phase 3)
                FileLogger.shared.debug(.keyboard, "backspace retry: still stale, scheduling retry \(backspaceStaleHasTextRetries)/\(SharedConfig.Defaults.backspaceStaleHasTextRetryLimit)", payload: [
                    "site": "tick-staleRetry-retrying",
                    "hasText": hasTextInCurrentTarget,
                    "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                    "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                    "staleRetries": backspaceStaleHasTextRetries,
                    "nilCtxRetries": backspaceNilContextRetries,
                    "phase": String(describing: backspacePhase)
                ])
                scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceStaleHasTextRetryInterval, repeats: false)
                return
            }
            // Recovered: do exactly what a normal .charRepeat tick does, then resume .charRepeat.
            backspaceStaleHasTextRetries = 0
            // DIAGNOSTIC — strip after fix verification (Phase 3)
            FileLogger.shared.debug(.keyboard, "backspace retry: recovered, resuming .charRepeat", payload: [
                "site": "tick-staleRetry-recovering",
                "hasText": hasTextInCurrentTarget,
                "contextBeforeLen": textDocumentProxy.documentContextBeforeInput?.count as Any,
                "proxyId": String(ObjectIdentifier(textDocumentProxy).hashValue, radix: 16),
                "staleRetries": backspaceStaleHasTextRetries,
                "nilCtxRetries": backspaceNilContextRetries,
                "phase": String(describing: backspacePhase)
            ])
            deleteTargetedBackward()
            HapticsManager.shared.tapImpact()
            backspaceSingleCharCount += 1
            scheduleSuggestionRefresh()
            backspacePhase = .charRepeat
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceCharRepeatInterval, repeats: true)

        case nil:
            break
        }
    }
}
