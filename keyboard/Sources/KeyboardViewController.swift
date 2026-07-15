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

    // MARK: - Keyboard State

    private var isShifted: Bool = false {
        didSet {
            keyboardView.setShiftState(shifted: isShifted, capsLock: isCapsLock)
        }
    }

    private var isCapsLock: Bool = false {
        didSet {
            keyboardView.setShiftState(shifted: isShifted, capsLock: isCapsLock)
        }
    }

    private var layoutMode: KeyboardLayoutMode = .letters {
        didSet {
            keyboardView.setLayoutMode(layoutMode)
        }
    }

    private var currentWordPrefix: String = "" {
        didSet {
            updateSuggestions()
        }
    }

    private var lastShiftTapTime: Date?

    private lazy var predictionEngine: PredictionEngine? = {
        PredictionEngine()
    }()

    private var darwinToken: DarwinObserverToken?
    private var pendingRequestId: UUID?
    private var waitTimer: Timer?
    private var errorResetWorkItem: DispatchWorkItem?
    private var lastProcessedPayloadId: UUID?
    private var pollTimer: Timer?
    private var pollCount = 0

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
        keyboardView.showFullAccessBanner(!hasFullAccess)
        state = .idle
        updateCurrentWord()
        log("viewDidAppear OK, hasFullAccess: \(hasFullAccess)")
        checkForPendingDictation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        log("viewWillDisappear")
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Recompute current word when text changes externally (e.g., dictation)
        updateCurrentWord()
    }

    deinit {
        darwinToken = nil
        waitTimer?.invalidate()
        pollTimer?.invalidate()
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

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 280)
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

    // MARK: - Current Word Tracking

    private func updateCurrentWord() {
        guard let context = textDocumentProxy.documentContextBeforeInput as String?,
              !context.isEmpty else {
            currentWordPrefix = ""
            return
        }

        // Find the last whitespace or newline boundary
        if let lastSpace = context.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards
        ) {
            let start = context.index(after: lastSpace.lowerBound)
            currentWordPrefix = String(context[start...])
        } else {
            // Entire context before cursor is the current word
            currentWordPrefix = context
        }
    }

    // MARK: - Suggestions

    private func updateSuggestions() {
        guard let engine = predictionEngine else {
            keyboardView.updateSuggestions([])
            return
        }

        let suggestions = engine.suggest(prefix: currentWordPrefix, limit: 3)
        keyboardView.updateSuggestions(suggestions)
    }

    // MARK: - Key Action Handling

    private func handleKeyAction(_ action: KeyAction) {
        switch action {
        case .insertText(let char):
            handleInsertText(char)
        case .backspace:
            handleBackspace()
        case .shift:
            handleShift()
        case .shiftLock:
            isCapsLock.toggle()
            isShifted = isCapsLock
        case .toggleNumber:
            if layoutMode == .letters {
                layoutMode = .numbers
            }
        case .toggleLetters:
            layoutMode = .letters
        case .mic:
            handleMicButtonTap()
        case .space:
            handleSpace()
        case .return:
            handleReturn()
        }
    }

    private func handleInsertText(_ char: String) {
        // Apply shift for the first letter if shifted
        if isShifted && !isCapsLock && char.rangeOfCharacter(from: .letters) != nil {
            textDocumentProxy.insertText(char.uppercased())
            isShifted = false
        } else if isCapsLock && char.rangeOfCharacter(from: .letters) != nil {
            textDocumentProxy.insertText(char.uppercased())
        } else {
            textDocumentProxy.insertText(char)
        }

        currentWordPrefix.append(char)
        log("Inserted: \(char), prefix: \(currentWordPrefix)")
    }

    private func handleBackspace() {
        textDocumentProxy.deleteBackward()

        if !currentWordPrefix.isEmpty {
            currentWordPrefix.removeLast()
        } else {
            // Try to reconstruct prefix from context after backspace
            updateCurrentWord()
        }

        log("Backspace, prefix: \(currentWordPrefix)")
    }

    private func handleShift() {
        let now = Date()
        if let lastTap = lastShiftTapTime, now.timeIntervalSince(lastTap) < 0.3 {
            // Double tap → caps lock
            isCapsLock = true
            isShifted = true
            lastShiftTapTime = nil
            log("Caps lock ON")
        } else {
            isShifted.toggle()
            if !isShifted {
                isCapsLock = false
            }
            lastShiftTapTime = now
            log("Shift: \(isShifted ? "ON" : "OFF")")
        }
    }

    private func handleSpace() {
        textDocumentProxy.insertText(" ")
        currentWordPrefix = ""
        log("Space, prefix reset")
    }

    private func handleReturn() {
        textDocumentProxy.insertText("\n")
        currentWordPrefix = ""
        log("Return")
    }

    // MARK: - Suggestion Handling

    private func handleSuggestionTap(_ word: String) {
        // Delete the current word prefix
        for _ in currentWordPrefix {
            textDocumentProxy.deleteBackward()
        }

        // Insert the suggested word + space
        textDocumentProxy.insertText(word + " ")
        currentWordPrefix = ""

        log("Suggestion tapped: \(word)")
    }

    // MARK: - Mic Button

    private func handleMicButtonTap() {
        switch state {
        case .idle:
            guard hasFullAccess else {
                state = .error("Full Access required. Settings → General → Keyboard → Ritoras → Allow Full Access.")
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

        guard let payload = DictationPayload.current() else {
            state = .error("No dictation result received.")
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
        guard let payload = DictationPayload.current() else { return }

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

    func keyboardView(_ view: KeyboardView, didTapKeyAction action: KeyAction) {
        handleKeyAction(action)
    }

    func keyboardView(_ view: KeyboardView, didTapSuggestion word: String) {
        handleSuggestionTap(word)
    }
}
