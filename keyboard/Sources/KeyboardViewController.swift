import UIKit
import AVFoundation

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
        // Keep only last 50 entries
        if logs.count > 50 { logs.removeFirst(logs.count - 50) }
        UserDefaults.standard.set(logs, forKey: "ritoras_logs")
    }

    private func copyLogsToClipboard() {
        let logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
        let text = logs.joined(separator: "\n")
        UIPasteboard.general.string = text
        state = .error("Logs copied to clipboard! Paste somewhere to share.")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Install global exception handler as last-resort crash catcher
        NSSetUncaughtExceptionHandler { exception in
            let msg = "FATAL: \(exception.name.rawValue): \(exception.reason ?? "unknown")\n\(exception.callStackSymbols.prefix(10).joined(separator: "\n"))"
            var logs = UserDefaults.standard.array(forKey: "ritoras_logs") as? [String] ?? []
            logs.append("[FATAL] \(msg)")
            UserDefaults.standard.set(logs, forKey: "ritoras_logs")
        }

        setupKeyboardView()
        state = .idle
        log("Keyboard viewDidLoad — hasFullAccess: \(hasFullAccess)")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keyboardView.showFullAccessBanner(!hasFullAccess)
        state = .idle
        log("Keyboard viewDidAppear — hasFullAccess: \(hasFullAccess), recordPermission: \(AVAudioSession.sharedInstance().recordPermission.rawValue)")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        log("Keyboard viewWillDisappear — cleaning up")
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

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 300)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        // Long-press on the view to copy logs (for debugging)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        view.addGestureRecognizer(longPress)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            copyLogsToClipboard()
        }
    }

    // MARK: - State Transitions

    private func handleMicButtonTap() {
        log("Mic button tapped, state: \(state)")

        switch state {
        case .idle:
            guard hasFullAccess else {
                state = .error("Full Access required. Go to Settings → General → Keyboard → Ritoras → Allow Full Access.")
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

        // Check mic permission BEFORE doing anything
        let micPermission = AVAudioSession.sharedInstance().recordPermission
        log("Microphone permission: \(micPermission.rawValue) (0=undetermined, 1=denied, 2=granted)")

        if micPermission != .granted {
            log("ERROR: Microphone not granted. User must open Ritoras app first.")
            state = .error("Microphone not granted. Open the Ritoras app first to grant access, then try again.")
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
                self.log("Recording started successfully at \(url.path)")
                self.state = .recording
            } catch {
                self.log("ERROR starting recording: \(error)")
                self.state = .error("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transcription

    private func stopAndTranscribe() {
        log("Stopping recording, starting transcription...")

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // 1. Stop recording
            let url = await self.audioRecorder.stopRecording()
            guard let url = url else {
                self.log("ERROR: Recording was empty or too short")
                await self.audioRecorder.cleanup()
                self.state = .error("Recording too short. Please try again.")
                return
            }

            self.log("Recording saved: \(url.lastPathComponent)")
            self.pendingAudioURL = url
            self.state = .transcribing

            // 2. Load config
            let config = SharedConfig.load()
            self.log("Config: baseUrl=\(config.baseUrl), timeout=\(config.timeoutSeconds)s")

            // 3. Transcribe
            do {
                self.log("Sending to Whisper server...")
                let transcript = try await WhisperClient.transcribe(audioURL: url, config: config)

                guard self.state == .transcribing else {
                    self.cleanupPendingAudio()
                    return
                }

                self.log("Transcription received: \(transcript.prefix(50))...")

                // 4. Insert text
                let proxy = self.textDocumentProxy
                proxy.insertText(transcript + " ")
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .idle

            } catch {
                self.log("ERROR during transcription: \(error)")
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cleanup

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
}
