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

    // MARK: - Permission

    /// Checks microphone permission without importing AVFoundation in the caller.
    static var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: - Start Recording

    /// Starts recording speech to a persistent M4A/AAC file (16 kHz, mono)
    /// in the app-group container under the given job ID.
    ///
    /// The recording is written directly to `{app-group}/Shared/recordings/{jobId}.m4a`
    /// so the audio survives process death and transcription failures.
    ///
    /// This method:
    /// 1. Checks microphone permission status (must be pre-granted by the container app).
    /// 2. Configures `AVAudioSession` (must happen before creating the recorder
    ///    to avoid `AVAudioSessionErrorCodeCannotStartRecording` / 561145187).
    /// 3. Creates the recorder with Whisper‑friendly settings.
    /// 4. Calls `prepareToRecord()` before `record()` — skipping this is a
    ///    documented cause of `record()` returning false.
    /// 5. Calls `record()` with a single retry on failure: reconfigures the audio
    ///    session and retries once to handle the first-activation race.
    ///
    /// - Parameter jobId: The dictation job ID. The file is named `{jobId}.m4a`.
    /// - Returns: The file URL of the recording in progress.
    /// - Throws: `AudioRecorderError` if permission is denied, session configuration
    ///   fails, or the recorder cannot start.
    func startRecording(jobId: UUID) async throws -> URL {
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

        // 3. Resolve destination URL — write directly to the final path in the
        //    app-group container so audio survives process death.
        let appGroupID = SharedConfig.Defaults.appGroupId
        let recordingsDir: URL
        if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID),
           let dir = RecordingStore.shared.directoryURL {
            recordingsDir = dir
        } else {
            // Fallback: rare, indicates entitlement issue. Log and use temp.
            FileLogger.shared.warn(.audio, "app-group container unavailable; falling back to NSTemporaryDirectory")
            recordingsDir = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let tempURL = recordingsDir.appendingPathComponent("\(jobId.uuidString).m4a")
        currentFileURL = tempURL

        FileLogger.shared.debug(.audio, "recording start", payload: [
            "path": tempURL.path,
            "jobId": jobId.uuidString
        ])

        // 4. Whisper-friendly recording settings: 16 kHz mono AAC
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        // 5. Create recorder
        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
        } catch {
            currentFileURL = nil
            AudioSession.deactivate()
            throw AudioRecorderError.recorderSetupFailed(error)
        }

        // 6. Prepare the recorder before recording — skipping prepareToRecord()
        //    is a documented cause of record() returning false.
        guard newRecorder.prepareToRecord() else {
            currentFileURL = nil
            AudioSession.deactivate()
            throw AudioRecorderError.recorderSetupFailed(
                NSError(domain: "AVAudioRecorder", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "prepareToRecord() returned false"])
            )
        }

        // 7. Start recording with a single retry for first-activation race.
        //    The first setActive(true) after the keyboard appears can silently fail,
        //    causing record() to return false. Reconfiguring the session and retrying
        //    resolves this.
        if !newRecorder.record() {
            do {
                try AudioSession.configure()
            } catch {
                currentFileURL = nil
                AudioSession.deactivate()
                throw AudioRecorderError.invalidSessionConfiguration(error)
            }
            guard newRecorder.record() else {
                currentFileURL = nil
                AudioSession.deactivate()
                throw AudioRecorderError.recorderSetupFailed(
                    NSError(domain: "AVAudioRecorder", code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "record() returned false after retry"])
                )
            }
        }

        recorder = newRecorder

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
            FileLogger.shared.debug(.audio, "recording stop: validation failed — file too short or missing",
                                    payload: ["path": url.path])
            return nil
        }

        FileLogger.shared.debug(.audio, "recording stop: validated",
                                payload: ["path": url.path])
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
