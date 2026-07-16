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
        }
    }

    private var shiftState: ShiftState = .lower {
        didSet {
            keyboardView.apply(shift: shiftState, layoutMode: layoutMode)
        }
    }

    private var layoutMode: KeyboardLayoutMode = .letters {
        didSet {
            keyboardView.apply(shift: shiftState, layoutMode: layoutMode)
        }
    }

    private var uiMode: UIMode = .letters {
        didSet {
            keyboardView.apply(mode: uiMode)
        }
    }

    private lazy var predictionEngine = PredictionEngine()

    private var keyboardView: KeyboardView!

    // MARK: - Backspace State

    private var backspaceTimer: Timer?
    private var backspacePhase: BackspacePhase?
    private var backspaceSingleCharCount = 0
    private var backspaceNilContextRetries = 0

    // MARK: - Dictation State

    private var darwinToken: DarwinObserverToken?
    private var waitTimer: Timer?
    private var errorResetWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollCount = 0
    private var clipboardPollTimer: Timer?
    private var clipboardPollCount = 0

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

    // MARK: - Logging

    /// Serial queue so the read-modify-write of the log buffer is safe across the
    /// main thread and the URLSession completion-handler thread.
    private let logQueue = DispatchQueue(label: "ritoras.kb.log", qos: .utility)

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        logQueue.sync {
            var logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
            logs.append(entry)
            if logs.count > 120 { logs.removeFirst(logs.count - 120) }
            UserDefaults.standard.set(logs, forKey: "ritoras_logs")
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        NSSetUncaughtExceptionHandler { exception in
            let msg = "FATAL: \(exception.name.rawValue): \(exception.reason ?? "unknown")"
            var logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
            logs.append("[FATAL] \(msg)")
            UserDefaults.standard.set(logs, forKey: "ritoras_logs")
        }

        setupKeyboardView()
        state = .idle
        log("viewDidLoad OK, hasFullAccess: \(hasFullAccess)")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardView.updateFullAccess(hasFullAccess)

        // Resume a dictation that was in progress when iOS suspended/terminated
        // the extension. pendingRequestId survives in UserDefaults, so even a
        // fully relaunched keyboard process can recover the result.
        if let id = pendingRequestId {
            let age = pendingRequestStart > 0 ? Date().timeIntervalSince1970 - pendingRequestStart : 0
            if age > 300 {  // >5 min — the result is unrecoverable; abandon it
                log("viewDidAppear \u{2014} pending dictation stale (\(Int(age))s), discarding")
                pendingRequestId = nil
                state = .idle
            } else {
                log("viewDidAppear \u{2014} resuming pending dictation: \(id)")
                checkForPendingDictation()
            }
        } else {
            state = .idle
            log("viewDidAppear \u{2014} idle, hasFullAccess: \(hasFullAccess)")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        log("viewWillDisappear")

        // Cancel ALL timers so they don't fire across app switches.
        // The dictation may still complete on the server while we're away;
        // when the keyboard reappears, viewDidAppear will resume polling
        // if pendingRequestId is still set.
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        serverPollTimer?.invalidate()
        errorResetWorkItem?.cancel()
        darwinToken = nil
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspacePhase = nil
        backspaceSingleCharCount = 0
        backspaceNilContextRetries = 0
    }

    deinit {
        darwinToken = nil
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        serverPollTimer?.invalidate()
        errorResetWorkItem?.cancel()
        backspaceTimer?.invalidate()
        backspaceNilContextRetries = 0
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

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 256)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
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
        case .error:
            state = .idle
            clipboardPollTimer?.invalidate()
            serverPollTimer?.invalidate()
            clearClipboardDictation()
        default:
            break   // ignore taps while openingApp/waiting/inserting
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

        let id = UUID()
        pendingRequestId = id
        pendingRequestStart = Date().timeIntervalSince1970

        // Build URL with id query param
        var components = URLComponents(url: SharedConfig.Defaults.dictateURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        guard let url = components.url else {
            state = .error("Couldn't create dictation URL.")
            return
        }

        state = .openingApp
        log("Opening container app for dictation, id: \(id)")

        // Use responder chain traversal — extensionContext.open() does NOT work for keyboard extensions
        let opened = openURL(url, id: id)
        if !opened {
            log("Failed to traverse responder chain — UIApplication not found")
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
                            self.log("Container app opened successfully, waiting for dictation")
                            self.state = .waiting
                            self.startWaitingForDictation(id: id)
                        } else {
                            self.log("Failed to open container app (application.open returned false)")
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
        // Register Darwin notification observer
        darwinToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinNotificationName) { [weak self] in
            DispatchQueue.main.async {
                self?.handleDictationCompleted()
            }
        }

        // Start timeout timer
        waitTimer = Timer.scheduledTimer(withTimeInterval: SharedConfig.Defaults.dictationTimeoutSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTimeout()
            }
        }
    }

    private func handleDictationCompleted() {
        stopDictationTransports()

        // Try App Group first (works if properly signed)
        guard let payload = DictationPayload.current() else {
            // No payload yet \u{2014} poll the server and keep polling.
            pollServerForDictation()
            if state == .idle {
                state = .waiting
                startServerPolling()
            }
            return
        }

        // Ignore stale payloads (wrong request ID, or no pending request at all)
        guard let id = pendingRequestId, payload.id == id else {
            log("Ignoring stale dictation payload (id mismatch)")
            return
        }

        switch payload.status {
        case .completed:
            insertDictationResult(text: payload.text ?? "")
            return
        case .cancelled:
            pendingRequestId = nil
            state = .idle
            log("Dictation cancelled")
        case .error:
            pendingRequestId = nil
            state = .error(payload.errorMessage ?? "Transcription failed.")
        case .recording, .transcribing:
            // Premature signal \u{2014} keep waiting
            startWaitingForDictation(id: id)
            return
        }
    }

    private func handleTimeout() {
        darwinToken = nil
        waitTimer = nil
        pendingRequestId = nil
        state = .error("Dictation timed out. Try again.")
        log("Dictation timed out")
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
    private func clipboardPayload() -> [String: Any]? {
        guard let data = UIPasteboard.general.data(forPasteboardType: "org.ritoras.dictation") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard json["source"] as? String == "ritoras" else { return nil }
        return json
    }

    /// Checks the clipboard (primary under SideStore) and the App Group payload for
    /// a terminal result matching `id`. On a terminal status it performs the
    /// insert / state change and returns true; returns false while still in
    /// progress or when no matching data exists yet.
    @discardableResult
    private func tryResolveFromStores(id: UUID) -> Bool {
        // 1. App Group payload (file + UserDefaults) \u{2014} works on App Store builds.
        if let payload = DictationPayload.current(), payload.id == id {
            switch payload.status {
            case .completed:
                log("resolve: appgroup completed \u{2192} insert")
                insertDictationResult(text: payload.text ?? "")
                return true
            case .error:
                stopDictationTransports(); pendingRequestId = nil
                state = .error(payload.errorMessage ?? "Transcription failed.")
                log("resolve: appgroup error")
                return true
            case .cancelled:
                stopDictationTransports(); pendingRequestId = nil
                state = .idle
                log("resolve: appgroup cancelled")
                return true
            case .recording, .transcribing:
                break
            }
        }

        // 2. Clipboard (primary channel under SideStore).
        if let clip = clipboardPayload() {
            let clipId = UUID(uuidString: clip["id"] as? String ?? "")
            let status = clip["status"] as? String ?? ""
            let ts = clip["timestamp"] as? Double ?? 0
            let age = ts > 0 ? Date().timeIntervalSince1970 - ts : 0
            if clipId == id, age < 300 {
                switch status {
                case "completed":
                    log("resolve: clipboard completed (age \(Int(age))s) \u{2192} insert")
                    insertDictationResult(text: clip["text"] as? String ?? "")
                    return true
                case "error":
                    stopDictationTransports(); pendingRequestId = nil
                    state = .error(clip["errorMessage"] as? String ?? "Transcription failed.")
                    log("resolve: clipboard error")
                    return true
                case "cancelled":
                    stopDictationTransports(); pendingRequestId = nil
                    state = .idle
                    log("resolve: clipboard cancelled")
                    return true
                default:
                    break  // recording/transcribing \u{2014} keep polling
                }
            } else if clipId != id {
                log("resolve: clipboard id mismatch (\(clipId?.uuidString ?? "nil") != \(id))")
            }
        }

        return false
    }

    private func checkForPendingDictation() {
        guard let id = pendingRequestId else {
            state = .idle
            return
        }
        state = .waiting
        log("Resuming pending dictation: \(id)")

        // Re-register the Darwin observer (it was torn down in viewWillDisappear).
        if darwinToken == nil {
            darwinToken = DarwinNotifier.observe(SharedConfig.Defaults.darwinNotificationName) { [weak self] in
                DispatchQueue.main.async { self?.handleDictationCompleted() }
            }
        }

        // Clipboard (primary under SideStore) + App Group payload.
        if tryResolveFromStores(id: id) { return }

        // Fallback: poll the server.
        startServerPolling()
    }

    /// Tears down every active result-transport (timers + Darwin observer) so that
    /// once one path resolves the dictation, no competing path re-inserts the text.
    private func stopDictationTransports() {
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        serverPollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        darwinToken = nil
    }

    /// Inserts the transcribed text, clears the pending request, and resets the
    /// keyboard to idle. Centralizes the shared insert+reset flow and guarantees
    /// every other transport is stopped first (prevents double-insert now that the
    /// Darwin observer and server polling can run concurrently on resume).
    private func insertDictationResult(text: String) {
        stopDictationTransports()
        pendingRequestId = nil
        if text.isEmpty {
            state = .error("Nothing was heard. Try again.")
            return
        }
        state = .inserting
        textDocumentProxy.insertText(text + " ")
        log("Inserted dictation: \(text)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.state = .idle
        }
    }

    private func startPollingForDictation(payloadId: UUID) {
        pollCount = 0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.pollCount += 1

            // Timeout after 30 seconds
            if self.pollCount > 30 {
                timer.invalidate()
                self.state = .error("Dictation timed out. Try again.")
                self.clearDictationPayload()
                return
            }

            guard let payload = DictationPayload.current() else { return }
            guard payload.id == payloadId else { return }  // Ignore different payloads

            switch payload.status {
            case .completed:
                timer.invalidate()
                let text = payload.text ?? ""
                if text.isEmpty {
                    self.state = .error("Nothing was heard. Try again.")
                } else {
                    self.state = .inserting
                    self.textDocumentProxy.insertText(text + " ")
                    self.log("Inserted dictation after polling: \(text)")
                }
                self.lastProcessedPayloadId = payload.id
                self.clearDictationPayload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.state = .idle
                }

            case .error:
                timer.invalidate()
                self.state = .error(payload.errorMessage ?? "Transcription failed.")
                self.lastProcessedPayloadId = payload.id
                self.clearDictationPayload()

            case .cancelled:
                timer.invalidate()
                self.clearDictationPayload()
                self.state = .idle

            case .recording, .transcribing:
                break  // Keep polling
            }
        }
    }

    private func clearDictationPayload() {
        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) else { return }
        defaults.removeObject(forKey: SharedConfig.Defaults.dictationPayloadKey)
    }

    // MARK: - Server Polling (Works when app is backgrounded)

    /// Polls every ~1.2s for up to ~60s. Each cycle checks the clipboard + App
    /// Group payload FIRST (the clipboard is the reliable channel under SideStore),
    /// then the server as a fallback. Resolves as soon as ANY yields a terminal
    /// status.
    private func startServerPolling() {
        serverPollCount = 0
        serverPollTimer?.invalidate()
        serverPollTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] timer in
            guard let self = self, let id = self.pendingRequestId else { timer.invalidate(); return }
            self.serverPollCount += 1

            if self.serverPollCount > 50 {  // ~60 seconds
                timer.invalidate()
                self.stopDictationTransports()
                self.pendingRequestId = nil
                self.state = .error("Dictation timed out. Try again.")
                self.log("Polling timed out after 60s \u{2014} no result from clipboard/App Group/server")
                return
            }

            // Primary channels: clipboard + App Group payload.
            if self.tryResolveFromStores(id: id) {
                timer.invalidate()
                return
            }

            // Fallback channel: the server.
            self.pollServerForDictation()
        }
    }

    /// One-shot HTTP GET to the server for the current dictation result.
    private func pollServerForDictation() {
        let config = SharedConfig.load()
        guard let server = config.servers.first else { return }
        guard let url = URL(string: "\(server)/dictation_result/latest") else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.log("poll: network error \(error.localizedDescription)")
                return
            }
            guard let data = data else { self.log("poll: empty response"); return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.log("poll: unparseable body \(String(data: data, encoding: .utf8) ?? "?")")
                return
            }

            let status = json["status"] as? String ?? "none"
            let timestamp = json["timestamp"] as? Double ?? 0

            // If the server returned {"detail":"Not Found"} (404), keep polling silently.
            if status == "none" && json["detail"] != nil {
                self.log("poll: 404/detail \(json["detail"] ?? "")")
                return
            }

            DispatchQueue.main.async {
                // If this dictation was already resolved via the App Group / Darwin
                // path, ignore the stale server response (prevents double-insert).
                guard self.pendingRequestId != nil else { return }

                guard timestamp > 0 else { self.log("poll: timestamp 0"); return }
                let age = Date().timeIntervalSince1970 - timestamp
                guard age < 120 else { self.log("poll: result stale (\(Int(age))s)"); return }
                if timestamp <= self.lastProcessedTimestamp { return }

                self.log("poll: server status=\(status) age=\(Int(age))s")

                switch status {
                case "completed":
                    self.lastProcessedTimestamp = timestamp
                    self.insertDictationResult(text: json["text"] as? String ?? "")

                case "error":
                    self.stopDictationTransports()
                    self.lastProcessedTimestamp = timestamp
                    self.pendingRequestId = nil
                    self.state = .error(json["errorMessage"] as? String ?? "Transcription failed.")

                case "cancelled":
                    self.stopDictationTransports()
                    self.lastProcessedTimestamp = timestamp
                    self.pendingRequestId = nil
                    self.state = .idle

                case "transcribing", "recording":
                    break  // keep polling

                default:
                    self.log("poll: unknown status '\(status)'")
                }
            }
        }
        task.resume()
    }

    // MARK: - Clipboard Transport (SideStore fallback)

    /// Reads a dictation payload from the system pasteboard and processes it.
    /// Called when the App Group path returns nothing (SideStore signing).
    private func tryClipboardDictation() {
        guard let clipboardStr = UIPasteboard.general.string else { return }
        guard let data = clipboardStr.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard json["source"] as? String == "ritoras" else { return }

        guard let timestamp = json["timestamp"] as? Double else { return }
        guard Date().timeIntervalSince1970 - timestamp < 120 else { return }  // Only recent payloads

        let status = json["status"] as? String ?? ""
        let payloadIdString = json["id"] as? String ?? ""
        let payloadId = UUID(uuidString: payloadIdString)

        // Prevent double-processing
        if payloadId == lastProcessedPayloadId { return }

        switch status {
        case "completed":
            let text = json["text"] as? String ?? ""
            if text.isEmpty {
                state = .error("Nothing was heard. Try again.")
            } else {
                state = .inserting
                textDocumentProxy.insertText(text + " ")
                log("Auto-inserted dictation from clipboard: \(text)")
            }
            lastProcessedPayloadId = payloadId
            pendingRequestId = nil
            clearClipboardDictation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state = .idle
            }

        case "transcribing", "recording":
            // Check if this is stale data from a previous session
            let age = Date().timeIntervalSince1970 - timestamp
            if age > 15 {
                // Stale — the app should have progressed by now. Clear and ignore.
                log("Ignoring stale clipboard data (age: \(Int(age))s)")
                clearClipboardDictation()
                return  // Stay in current state (idle)
            }
            log("Dictation still \(status) (clipboard), starting poll")
            state = .waiting
            if clipboardPollTimer == nil {
                startClipboardPolling()
            }
            return

        case "error":
            let errorMessage = json["errorMessage"] as? String ?? "Transcription failed."
            state = .error(errorMessage)
            lastProcessedPayloadId = payloadId
            clearClipboardDictation()

        case "cancelled":
            clearClipboardDictation()
            // Stay idle

        default:
            break
        }
    }

    /// Polls the clipboard every second for up to 30 seconds while the
    /// container app is still transcribing or recording.
    private func startClipboardPolling() {
        clipboardPollCount = 0
        clipboardPollTimer?.invalidate()
        clipboardPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.clipboardPollCount += 1

            // Timeout after 30 seconds
            if self.clipboardPollCount > 30 {
                timer.invalidate()
                self.clipboardPollTimer = nil
                self.state = .error("Dictation timed out. Try again.")
                self.clearClipboardDictation()
                return
            }

            // Directly check clipboard — do NOT call tryClipboardDictation() (causes infinite recursion)
            guard let clipboardStr = UIPasteboard.general.string,
                  let data = clipboardStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["source"] as? String == "ritoras" else {
                return  // No ritoras payload, keep polling
            }

            guard let timestamp = json["timestamp"] as? Double else { return }
            guard Date().timeIntervalSince1970 - timestamp < 120 else { return }

            let status = json["status"] as? String ?? ""
            let payloadId = UUID(uuidString: json["id"] as? String ?? "")

            if payloadId == self.lastProcessedPayloadId { return }

            switch status {
            case "completed":
                timer.invalidate()
                self.clipboardPollTimer = nil
                let text = json["text"] as? String ?? ""
                if text.isEmpty {
                    self.state = .error("Nothing was heard. Try again.")
                } else {
                    self.state = .inserting
                    self.textDocumentProxy.insertText(text + " ")
                    self.log("Inserted dictation from clipboard poll: \(text)")
                }
                self.lastProcessedPayloadId = payloadId
                self.pendingRequestId = nil
                self.clearClipboardDictation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.state = .idle
                }

            case "error":
                timer.invalidate()
                self.clipboardPollTimer = nil
                let errorMessage = json["errorMessage"] as? String ?? "Transcription failed."
                self.state = .error(errorMessage)
                self.lastProcessedPayloadId = payloadId
                self.clearClipboardDictation()

            case "cancelled":
                timer.invalidate()
                self.clipboardPollTimer = nil
                self.clearClipboardDictation()
                self.state = .idle

            case "transcribing", "recording":
                // Still in progress — keep polling (DO NOT reset counter, DO NOT restart polling)
                self.log("Still transcribing (poll \(self.clipboardPollCount)/30)")
                break

            default:
                break
            }
        }
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
            let text = applyShift(to: s)
            textDocumentProxy.insertText(text)
            if shiftState == .upper {
                shiftState = .lower
            }
            keyboardView.refreshSuggestions()

        case .backspace:
            textDocumentProxy.deleteBackward()
            keyboardView.refreshSuggestions()

        case .shift:
            switch shiftState {
            case .lower: shiftState = .upper
            case .upper: shiftState = .locked
            case .locked: shiftState = .lower
            }

        case .shiftLock:
            shiftState = .locked

        case .space:
            textDocumentProxy.insertText(" ")
            keyboardView.refreshSuggestions()

        case .return:
            textDocumentProxy.insertText("\n")

        case .toggleNumber:
            layoutMode = .numbers

        case .toggleLetters:
            layoutMode = .letters

        case .toggleSymbols:
            layoutMode = .symbols

        case .mic:
            handleMicButtonTap()

        case .emoji:
            uiMode = uiMode == .letters ? .emoji : .letters

        case .globe:
            advanceToNextInputMode()
        }
    }

    func keyboardView(_ view: KeyboardView, didTapSuggestion text: String) {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        var deleteCount = 0
        for char in context.reversed() {
            if char.isLetter || char.isNumber {
                deleteCount += 1
            } else {
                break
            }
        }
        for _ in 0..<deleteCount {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(text + " ")
        keyboardView.refreshSuggestions()
    }

    func keyboardViewNeedsSuggestions(_ view: KeyboardView) -> [String] {
        guard let context = textDocumentProxy.documentContextBeforeInput else { return [] }
        let currentWord = context
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .last ?? ""
        return predictionEngine.suggest(prefix: currentWord, limit: 3)
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

        guard textDocumentProxy.hasText else { return }

        textDocumentProxy.deleteBackward()
        backspaceSingleCharCount = 1
        keyboardView.refreshSuggestions()

        guard textDocumentProxy.hasText else { return }

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
        keyboardView.refreshSuggestions()
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
        backspaceNilContextRetries = 0
    }

    // MARK: - Helpers

    private func applyShift(to text: String) -> String {
        guard !text.isEmpty, shiftState != .lower else { return text }
        if text.rangeOfCharacter(from: .letters) != nil {
            return text.uppercased()
        }
        return text
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
        guard textDocumentProxy.hasText else {
            backspaceTimer?.invalidate()
            backspaceTimer = nil
            backspacePhase = nil
            return
        }

        switch backspacePhase {
        case .charRepeat:
            textDocumentProxy.deleteBackward()
            backspaceSingleCharCount += 1
            keyboardView.refreshSuggestions()

            guard textDocumentProxy.hasText else {
                backspaceTimer?.invalidate()
                backspaceTimer = nil
                backspacePhase = nil
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
                guard textDocumentProxy.hasText else { break }
                textDocumentProxy.deleteBackward()
            }
            keyboardView.refreshSuggestions()
            scheduleBackspaceTimer(after: SharedConfig.Defaults.backspaceWordRepeatInterval, repeats: false)

        case nil:
            break
        }
    }
}
