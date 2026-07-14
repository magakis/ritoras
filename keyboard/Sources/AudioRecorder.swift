import AVFoundation

// MARK: - Audio Recorder

actor AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?

    // MARK: - Errors

    enum AudioRecorderError: LocalizedError {
        case permissionDenied
        case permissionNotRequested
        case recordingEmpty
        case invalidSessionConfiguration(Error)
        case recorderSetupFailed(Error)
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission was denied. Enable it in Settings."
            case .permissionNotRequested:
                return "Open the Ritoras app first to grant microphone access, then try again."
            case .recordingEmpty:
                return "Recording was too short or empty. Please try again."
            case .invalidSessionConfiguration(let error):
                return "Audio session configuration failed: \(error.localizedDescription)"
            case .recorderSetupFailed(let error):
                return "Failed to start recorder: \(error.localizedDescription)"
            case .alreadyRecording:
                return "Already recording."
            }
        }
    }

    // MARK: - Start Recording

    /// Starts recording speech to a temporary M4A/AAC file (16 kHz, mono).
    ///
    /// This method:
    /// 1. Requests microphone permission (iOS 17+ `AVAudioApplication` API).
    /// 2. Configures `AVAudioSession` (must happen before creating the recorder
    ///    to avoid `AVAudioSessionErrorCodeCannotStartRecording` / 561145187).
    /// 3. Creates the recorder with Whisper‑friendly settings.
    ///
    /// - Returns: The file URL of the recording in progress.
    /// - Throws: `AudioRecorderError` if permission is denied, session configuration
    ///   fails, or the recorder cannot start.
    func startRecording() async throws -> URL {
        guard recorder == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        // 1. Check permission — do NOT call requestRecordPermission() from the keyboard!
        // That would show a system dialog and dismiss the keyboard.
        // The container app is responsible for requesting permission.
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            break // Proceed with recording
        case .denied:
            throw AudioRecorderError.permissionDenied
        case .undetermined:
            throw AudioRecorderError.permissionNotRequested
        @unknown default:
            throw AudioRecorderError.permissionNotRequested
        }

        // 2. Configure audio session (must be BEFORE creating AVAudioRecorder)
        do {
            try AudioSession.configure()
        } catch {
            throw AudioRecorderError.invalidSessionConfiguration(error)
        }

        // 3. Create temp file URL
        let tempDir = NSTemporaryDirectory()
        let tempURL = URL(fileURLWithPath: tempDir)
            .appendingPathComponent("ritoras-\(UUID().uuidString).m4a")
        currentFileURL = tempURL

        // 4. Whisper-friendly recording settings: 16 kHz mono AAC
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        // 5. Create and start recorder
        do {
            let newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            guard newRecorder.record() else {
                // record() returned false — clean up and throw
                currentFileURL = nil
                AudioSession.deactivate()
                throw AudioRecorderError.recorderSetupFailed(
                    NSError(domain: "AVAudioRecorder", code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "record() returned false"])
                )
            }
            recorder = newRecorder
        } catch {
            currentFileURL = nil
            AudioSession.deactivate()
            throw AudioRecorderError.recorderSetupFailed(error)
        }

        return tempURL
    }

    // MARK: - Stop Recording

    /// Stops the ongoing recording and validates the output file.
    ///
    /// The file must exist and be larger than 1 KB to be considered valid.
    /// If validation fails the file is deleted and `nil` is returned.
    ///
    /// - Returns: The file URL of the completed recording, or `nil` if the
    ///   recording was empty or no recording was in progress.
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil

        guard let url = currentFileURL else { return nil }
        currentFileURL = nil

        // Validate file exists and is non-trivial (> 1 KB)
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? UInt64,
              fileSize > 1024 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return url
    }

    // MARK: - Cleanup

    /// Cancels the recording and tears down the audio session.
    ///
    /// Call this when the keyboard disappears or the recording is otherwise
    /// aborted. The temp file (if any) is deleted and the audio session is
    /// deactivated to avoid conflicts with other apps.
    func cleanup() {
        recorder?.stop()
        recorder = nil

        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
            currentFileURL = nil
        }

        AudioSession.deactivate()
    }
}
