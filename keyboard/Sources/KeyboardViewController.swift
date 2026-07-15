import UIKit

class KeyboardViewController: UIInputViewController {

    // MARK: - State

    private var state: KeyboardState = .idle {
        didSet {
            keyboardView.configure(for: state)
        }
    }

    private var keyboardView: KeyboardView!
    private lazy var audioRecorder = AudioRecorder()
    private var pendingAudioURL: URL?

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
        log("viewDidAppear OK, hasFullAccess: \(hasFullAccess)")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        log("viewWillDisappear")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.audioRecorder.cleanup()
            self.cleanupPendingAudio()
        }
    }

    deinit {
        if let url = pendingAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
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

    // MARK: - Mic Button

    private func handleMicButtonTap() {
        log("Mic tapped, state: \(state)")

        switch state {
        case .idle:
            guard hasFullAccess else {
                state = .error("Full Access required. Settings → General → Keyboard → Ritoras → Allow Full Access.")
                return
            }
            startRecording()

        case .recording:
            stopAndTranscribe()

        case .transcribing:
            break

        case .error:
            state = .idle
        }
    }

    // MARK: - Recording

    private func startRecording() {
        log("Starting recording...")

        // Check mic permission via AudioRecorder (avoids importing AVFoundation here)
        guard AudioRecorder.hasMicrophonePermission else {
            log("ERROR: Mic permission not granted")
            state = .error("Microphone not granted. Open the Ritoras app first to grant access.")
            return
        }

        Task { @MainActor [weak self] in
            guard let self = self, self.state == .idle else { return }

            do {
                let url = try await self.audioRecorder.startRecording()
                guard self.state == .idle else {
                    await self.audioRecorder.cleanup()
                    return
                }
                self.log("Recording started: \(url.lastPathComponent)")
                self.state = .recording
            } catch {
                self.log("Recording error: \(error)")
                self.state = .error("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transcription

    private func stopAndTranscribe() {
        log("Stopping, transcribing...")

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let url = await self.audioRecorder.stopRecording()
            guard let url = url else {
                self.log("Recording too short")
                await self.audioRecorder.cleanup()
                self.state = .error("Recording too short. Try again.")
                return
            }

            self.pendingAudioURL = url
            self.state = .transcribing

            let config = SharedConfig.load()
            self.log("Sending to \(config.baseUrl)...")

            do {
                let transcript = try await WhisperClient.transcribe(audioURL: url, config: config)
                guard self.state == .transcribing else {
                    self.cleanupPendingAudio()
                    return
                }

                self.log("Got transcript: \(transcript.prefix(50))")
                self.textDocumentProxy.insertText(transcript + " ")
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .idle

            } catch {
                self.log("Transcription error: \(error)")
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func cleanupPendingAudio() {
        if let url = pendingAudioURL {
            try? FileManager.default.removeItem(at: url)
            pendingAudioURL = nil
        }
    }
}

// MARK: - KeyboardViewDelegate

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardViewDidTapMicButton(_ view: KeyboardView) {
        handleMicButtonTap()
    }

    func keyboardViewDidTapNextKeyboard(_ view: KeyboardView) {
        advanceToNextInputMode()
    }
}
