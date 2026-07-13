import UIKit

class KeyboardViewController: UIInputViewController {

    // MARK: - State

    private var state: KeyboardState = .idle {
        didSet {
            keyboardView.configure(for: state)
        }
    }

    private var keyboardView: KeyboardView!
    private let audioRecorder = AudioRecorder()
    private var pendingAudioURL: URL?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupKeyboardView()
        state = .idle
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Gate: check Full Access — the user may have revoked it since last use.
        keyboardView.showFullAccessBanner(!hasFullAccess)

        // Always reset to idle on appear. The OS can kill and restart the
        // extension at any time; we must not assume state survives.
        state = .idle
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // If recording or transcribing, tear down audio and delete temp files.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.audioRecorder.cleanup()
            self.cleanupPendingAudio()
        }
    }

    deinit {
        // Synchronous cleanup: delete any leftover temp file.
        // Actor-based cleanup is handled by the OS reclaiming the process.
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

        // Target height close to system keyboard (~300pt)
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 300)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
    }

    // MARK: - State Transitions

    private func handleMicButtonTap() {
        switch state {
        case .idle:
            guard hasFullAccess else {
                showFullAccessAlert()
                return
            }
            startRecording()

        case .recording:
            stopAndTranscribe()

        case .transcribing:
            // No action while transcribing.
            break

        case .error:
            state = .idle
        }
    }

    // MARK: - Recording

    private func startRecording() {
        Task { @MainActor [weak self] in
            guard let self = self, self.state == .idle else { return }

            do {
                _ = try await self.audioRecorder.startRecording()
                // Confirm we are still expecting this result (the user may have
                // dismissed the keyboard during the permission dialog).
                guard self.state == .idle else {
                    await self.audioRecorder.cleanup()
                    return
                }
                self.state = .recording
            } catch let error as AudioRecorder.AudioRecorderError {
                self.state = .error(error.localizedDescription ?? "Could not start recording")
            } catch {
                self.state = .error("Could not start recording")
            }
        }
    }

    // MARK: - Transcription

    private func stopAndTranscribe() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // 1. Stop recording and validate the audio file.
            let url = await self.audioRecorder.stopRecording()
            guard let url = url else {
                // Recording was empty or too short.
                await self.audioRecorder.cleanup()
                self.state = .error("Recording too short. Please try again.")
                return
            }

            // Track the URL so we can clean it up in all exit paths.
            self.pendingAudioURL = url
            self.state = .transcribing

            // 2. Load config at the start of each attempt — never cache it,
            //    because the user may have changed settings in the container app.
            let config = SharedConfig.load()

            // 3. Transcribe via WhisperClient.
            do {
                let transcript = try await WhisperClient.transcribe(audioURL: url, config: config)

                // Guard: ensure still in transcribing state (user may have
                // dismissed the keyboard or tapped error→idle while we were
                // awaiting the network).
                guard self.state == .transcribing else {
                    self.cleanupPendingAudio()
                    return
                }

                // 4. Insert transcribed text into the text field.
                guard let proxy = self.textDocumentProxy else {
                    // Keyboard dismissed — clean up silently.
                    self.cleanupPendingAudio()
                    await self.audioRecorder.cleanup()
                    self.state = .idle
                    return
                }

                proxy.insertText(transcript + " ")
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .idle

            } catch let error as WhisperError {
                // WhisperError provides user-friendly localized descriptions.
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .error(error.localizedDescription ?? "Transcription failed")

            } catch {
                self.cleanupPendingAudio()
                await self.audioRecorder.cleanup()
                self.state = .error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cleanup Helpers

    private func cleanupPendingAudio() {
        if let url = pendingAudioURL {
            try? FileManager.default.removeItem(at: url)
            pendingAudioURL = nil
        }
    }

    // MARK: - Full-Access Alert

    private func showFullAccessAlert() {
        let alert = UIAlertController(
            title: "Full Access Required",
            message: "Please enable Full Access in:\nSettings → General → Keyboard → Ritoras → Allow Full Access",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - KeyboardViewDelegate

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardViewDidTapMicButton(_ view: KeyboardView) {
        handleMicButtonTap()
    }
}
