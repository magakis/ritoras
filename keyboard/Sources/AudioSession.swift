import AVFoundation

// MARK: - Audio Session Configuration

enum AudioSession {

    /// Configures the shared `AVAudioSession` for recording in a keyboard extension.
    ///
    /// The known-working configuration for avoiding `AVAudioSessionErrorCodeCannotStartRecording`
    /// (OSStatus 561145187) in keyboard extensions:
    /// - `.playAndRecord` category
    /// - `.default` mode (NOT `.spokenAudio` — that mode is implicated in 561145187)
    /// - `[.defaultToSpeaker]` only — `.allowBluetooth` is excluded as it can cause
    ///   `record()` to return `false` when no HFP Bluetooth device is paired.
    ///
    /// **Critical ordering:** `setActive(true)` must be called BEFORE initializing
    /// `AVAudioRecorder`. If the recorder is created first and then the session is activated,
    /// 561145187 will occur.
    static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try session.setPreferredSampleRate(16000)
    }

    /// Deactivates the shared audio session.
    ///
    /// Must be called when the keyboard disappears (`viewWillDisappear`) so other apps
    /// or the system can use audio without conflicts. Errors are silently ignored since
    /// deactivation is best-effort during teardown.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
