import UIKit

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

    private var keyboardView: KeyboardView!

    // MARK: - Dictation State

    private var darwinToken: DarwinObserverToken?
    private var pendingRequestId: UUID?
    private var waitTimer: Timer?
    private var errorResetWorkItem: DispatchWorkItem?
    private var lastProcessedPayloadId: UUID?
    private var pollTimer: Timer?
    private var pollCount = 0
    private var clipboardPollTimer: Timer?
    private var clipboardPollCount = 0

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        var logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
        logs.append(entry)
        if logs.count > 50 { logs.removeFirst(logs.count - 50) }
        UserDefaults.standard.set(logs, forKey: "ritoras_logs")
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
        state = .idle
        log("viewDidAppear OK, hasFullAccess: \(hasFullAccess)")
        checkForPendingDictation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        log("viewWillDisappear")
    }

    deinit {
        darwinToken = nil
        waitTimer?.invalidate()
        pollTimer?.invalidate()
        clipboardPollTimer?.invalidate()
        errorResetWorkItem?.cancel()
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

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 110)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        // Long-press to copy logs (debugging)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        view.addGestureRecognizer(longPress)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            let logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
            UIPasteboard.general.string = logs.joined(separator: "\n")
            state = .error("Logs copied to clipboard! Paste somewhere to share.")
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
        case .error:
            state = .idle   // tap error to dismiss
        default:
            break   // ignore taps while openingApp/waiting/inserting
        }
    }

    // MARK: - Dictation via Container App

    private func openContainerAppForDictation() {
        let id = UUID()
        pendingRequestId = id

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
        darwinToken = nil
        waitTimer?.invalidate()
        waitTimer = nil

        // Try App Group first (works if properly signed)
        guard let payload = DictationPayload.current() else {
            // Try clipboard fallback (works under SideStore)
            tryClipboardDictation()
            return
        }

        // Ignore stale payloads (wrong request ID)
        guard payload.id == pendingRequestId else {
            log("Ignoring stale dictation payload (id mismatch)")
            return
        }

        switch payload.status {
        case .completed:
            let text = payload.text ?? ""
            if text.isEmpty {
                state = .error("Nothing was heard. Try again.")
            } else {
                state = .inserting
                textDocumentProxy.insertText(text + " ")
                log("Inserted dictation: \(text)")
                // Reset to idle after brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.state = .idle
                }
            }
        case .cancelled:
            state = .idle
            log("Dictation cancelled")
        case .error:
            state = .error(payload.errorMessage ?? "Transcription failed.")
        case .recording, .transcribing:
            // Premature signal — keep waiting
            startWaitingForDictation(id: pendingRequestId!)
            return
        }

        pendingRequestId = nil
    }

    private func handleTimeout() {
        darwinToken = nil
        waitTimer = nil
        pendingRequestId = nil
        state = .error("Dictation timed out. Try again.")
        log("Dictation timed out")
    }

    // MARK: - Pending Dictation (Recovery on Keyboard Reappear)

    private func checkForPendingDictation() {
        // Try App Group first (works if properly signed)
        guard let payload = DictationPayload.current() else {
            // Try clipboard (works under SideStore — App Group doesn't)
            tryClipboardDictation()
            return
        }

        // Only process payloads from the last 120 seconds (ignore old ones)
        guard Date().timeIntervalSince(payload.timestamp) < 120 else { return }

        // Don't process the same payload twice — track the last processed payload ID
        if payload.id == lastProcessedPayloadId { return }

        switch payload.status {
        case .completed:
            let text = payload.text ?? ""
            if text.isEmpty {
                state = .error("Nothing was heard. Try again.")
            } else {
                state = .inserting
                textDocumentProxy.insertText(text + " ")
                log("Auto-inserted dictation on keyboard return: \(text)")
            }
            lastProcessedPayloadId = payload.id
            clearDictationPayload()
            // Reset to idle after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state = .idle
            }

        case .recording, .transcribing:
            // User came back while still transcribing — show waiting state and poll
            log("Dictation still in progress, starting poll")
            state = .waiting
            startPollingForDictation(payloadId: payload.id)

        case .error:
            state = .error(payload.errorMessage ?? "Transcription failed.")
            lastProcessedPayloadId = payload.id
            clearDictationPayload()

        case .cancelled:
            clearDictationPayload()
            // Stay idle, no text to insert
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
            clearClipboardDictation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state = .idle
            }

        case "transcribing":
            log("Dictation still transcribing (clipboard), starting poll")
            state = .waiting
            startClipboardPolling()

        case "recording":
            log("Dictation still recording (clipboard), starting poll")
            state = .waiting
            startClipboardPolling()

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

            if self.clipboardPollCount > 30 {
                timer.invalidate()
                self.state = .error("Dictation timed out. Try again.")
                return
            }

            // Re-check clipboard
            self.tryClipboardDictation()

            // If we're no longer in waiting state, the polling found a result — stop
            if case .waiting = self.state {
                // Still waiting, keep polling
            } else {
                timer.invalidate()
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
    func keyboardViewDidTapMicButton(_ view: KeyboardView) {
        handleMicButtonTap()
    }

    func keyboardViewDidTapSwitchButton(_ view: KeyboardView) {
        advanceToNextInputMode()
    }
}
