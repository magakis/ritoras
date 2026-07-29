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

    /// Starts recording speech to the configured audio format (AAC or WAV, 16 kHz mono)
    /// in the Application Support directory under the given job ID.
    ///
    /// The recording is written directly to `{application-support}/Recordings/{jobId}.{ext}`
    /// where `ext` follows the user's `AudioFormat` setting, so the audio survives process
    /// death and transcription failures.
    ///
    /// This method:
    /// 1. Checks microphone permission status (must be pre-granted by the container app).
    /// 2. Configures `AVAudioSession` (must happen before creating the recorder
    ///    to avoid `AVAudioSessionErrorCodeCannotStartRecording` / 561145187).
    /// 3. Reads the user's `AudioFormat` setting (AAC or WAV) for the encoder settings.
    /// 4. Resolves the destination URL with the correct file extension.
    /// 5. Creates the recorder with Whisper‑friendly settings matching the format.
    /// 6. Calls `prepareToRecord()` before `record()` — skipping this is a
    ///    documented cause of `record()` returning false.
    /// 7. Calls `record()` with a single retry on failure: reconfigures the audio
    ///    session and retries once to handle the first-activation race.
    ///
    /// - Parameter jobId: The dictation job ID. The file is named `{jobId}.{ext}`
    ///   where ext follows the `AudioFormat` setting.
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

        // 3. Read the user's AudioFormat setting (AAC or WAV) ONCE — the format,
        //    file extension, and encoder settings for this recording are now fixed.
        let format = SharedConfig.audioFormat()

        // 4. Resolve destination URL — write directly to the persistent
        //    Application Support directory so audio survives process death.
        guard let recordingsDir = RecordingStore.shared.directoryURL else {
            // Application Support should NEVER be unavailable. If it is, fail loudly.
            FileLogger.shared.error(.audio, "Application Support unavailable — cannot record safely")
            throw AudioRecorderError.recorderSetupFailed(
                NSError(domain: "AudioRecorder", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "storage unavailable"]))
        }
        let tempURL = recordingsDir.appendingPathComponent("\(jobId.uuidString).\(format.fileExtension)")
        currentFileURL = tempURL

        FileLogger.shared.debug(.audio, "recording started", payload: [
            "jobId": jobId.uuidString,
            "path": tempURL.path
        ])

        // 5. Recording settings — 16 kHz mono. Format follows the user's AudioFormat
        //    setting; the Whisper server re-encodes to 16 kHz mono WAV regardless, so
        //    the choice affects file size / losslessness, not transcription accuracy.
        //      .aac: MPEG-4 AAC, quality .high → measured ~25 kbps at 16 kHz mono
        //            (despite .high's nominal ~64 kbps).
        //      .wav: 16-bit little-endian PCM → ~256 kbps, lossless.
        let settings: [String: Any]
        switch format {
        case .aac:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }

        // 6. Create recorder
        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
        } catch {
            currentFileURL = nil
            AudioSession.deactivate()
            throw AudioRecorderError.recorderSetupFailed(error)
        }

        // 7. Prepare the recorder before recording — skipping prepareToRecord()
        //    is a documented cause of record() returning false.
        guard newRecorder.prepareToRecord() else {
            currentFileURL = nil
            AudioSession.deactivate()
            throw AudioRecorderError.recorderSetupFailed(
                NSError(domain: "AVAudioRecorder", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "prepareToRecord() returned false"])
            )
        }

        // 8. Start recording with a single retry for first-activation race.
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
