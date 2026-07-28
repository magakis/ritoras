import AVFoundation

// MARK: - Audio Session Configuration

enum AudioSession {

    /// Configures the shared `AVAudioSession` for clean microphone capture.
    ///
    /// Recording happens in the container app (`DictationViewModel`), never in the
    /// keyboard extension and never alongside audio playback, so the `.record`
    /// category is the correct choice.
    ///
    /// `.record` (not `.playAndRecord`) is deliberate: `.playAndRecord` is Apple's
    /// VoIP category and routes the microphone through the voice-processing DSP —
    /// auto-gain control + echo cancellation — which pumps the gain and gates quiet
    /// speech, producing robotic, chopped-up audio that Whisper transcribes poorly.
    /// `.record` yields unprocessed capture ideal for speech-to-text.
    ///
    /// **Ordering:** `setCategory` → `setActive(true)`, then construct
    /// `AVAudioRecorder` / start the engine. Activating the session before the
    /// recorder is configured can trigger
    /// `AVAudioSessionErrorCodeCannotStartRecording` (OSStatus 561145187).
    ///
    /// - Note: `setPreferredSampleRate` is deliberately **not** called — forcing
    /// 16 kHz engages a lower-gain hardware path that captures ~7 dB quieter
    /// than the native 48 kHz rate. Recording at the native rate and letting
    /// `AVAudioRecorder` / `AVAudioConverter` resample preserves full hardware
    /// gain staging, matching iOS Shortcuts. Commit `cb024ca` moved this call
    /// before `setActive` to ensure it was honored; that change inadvertently
    /// caused this gain regression.
    static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        FileLogger.shared.info(.audio, "session configured", payload: [
            "sampleRate": session.sampleRate,
            "category": session.category.rawValue
        ])
    }

    /// Deactivates the shared audio session.
    ///
    /// Called when recording stops or the dictation is aborted, so other apps or the
    /// system can use audio without conflicts. Errors are silently ignored since
    /// deactivation is best-effort during teardown.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
