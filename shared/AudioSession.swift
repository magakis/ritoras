import AVFoundation

struct AudioSessionActivationError: LocalizedError {
    let underlyingError: Error

    var errorDescription: String? {
        "Audio session activation failed: \(underlyingError.localizedDescription)"
    }
}

// `AVAudioSession` is process-wide state. This is the single choke point for
// all category and activation mutations: they are serialized on the private
// queue below. Deactivation is deferred by 250 ms and guarded against stale
// generations so CoreAudio can finish teardown before the session changes.
// This avoids the cross-category active-transition trap seen in build 316 and
// the teardown race trap seen in build 319. Callers must not touch
// `AVAudioSession` directly.

// MARK: - Audio Session Configuration

enum AudioSession {

    private static let queue = DispatchQueue(label: "com.ritoras.audio-session")
    private static var generation: UInt = 0

    /// Configures the shared `AVAudioSession` for clean microphone capture.
    ///
    /// The foreground container app uses `.record`. The keyboard experiment can
    /// explicitly request a mixable `.playAndRecord` session so host playback does
    /// not get interrupted when its UIInputView is active.
    ///
    /// `.record` (not `.playAndRecord`) remains the container app default:
    /// `.playAndRecord` is Apple's
    /// VoIP category and routes the microphone through the voice-processing DSP —
    /// auto-gain control + echo cancellation — which pumps the gain and gates quiet
    /// speech, producing robotic, chopped-up audio that Whisper transcribes poorly.
    /// `.record` yields unprocessed capture ideal for speech-to-text.
    ///
    /// The audio-measurement toggle routes all recording paths (batch, stream,
    /// and tester) through `.measurement`, which strips iOS's hidden AGC/HPF
    /// for stable levels. This changes the absolute level scale, so static
    /// thresholds may need retuning; it pairs best with calibrated or adaptive
    /// VAD modes.
    ///
    /// **Ordering:** callers configure the session after their UI has entered
    /// its recording state; this method then calls `setCategory` →
    /// `setActive(true)` before the recorder queries the input format or starts
    /// the engine. Activating the session before the recorder is configured can
    /// trigger `AVAudioSessionErrorCodeCannotStartRecording` (OSStatus 561145187).
    ///
    /// - Note: `setPreferredSampleRate` is deliberately **not** called — forcing
    /// 16 kHz engages a lower-gain hardware path that captures ~7 dB quieter
    /// than the native 48 kHz rate. Recording at the native rate and letting
    /// `AVAudioRecorder` / `AVAudioConverter` resample preserves full hardware
    /// gain staging, matching iOS Shortcuts. Commit `cb024ca` moved this call
    /// before `setActive` to ensure it was honored; that change inadvertently
    /// caused this gain regression.
    static func configure(mixWithOthers: Bool = false) throws {
        let mode: AVAudioSession.Mode = SharedConfig.audioMeasurementModeEnabled() ? .measurement : .default
        try Self.queue.sync {
            Self.generation &+= 1
            let session = AVAudioSession.sharedInstance()
            let category: AVAudioSession.Category = mixWithOthers ? .playAndRecord : .record
            let options: AVAudioSession.CategoryOptions = mixWithOthers ? [.mixWithOthers] : []
            try session.setCategory(category, mode: mode, options: options)
            do {
                try Self.activate(session, mixWithOthers: mixWithOthers)
            } catch let activationError as AudioSessionActivationError where !mixWithOthers {
                throw activationError.underlyingError
            }
            FileLogger.shared.info(.audio, "session configured", payload: [
                "sampleRate": session.sampleRate,
                "category": session.category.rawValue,
                "mode": mode.rawValue,
                "options": mixWithOthers ? "mixWithOthers" : "none",
                "mixable": mixWithOthers
            ])
        }
    }

    private static func activate(_ session: AVAudioSession, mixWithOthers: Bool) throws {
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            FileLogger.shared.info(.audio, "session activation result", payload: [
                "result": "success",
                "sampleRate": session.sampleRate,
                "category": session.category.rawValue,
                "options": mixWithOthers ? "mixWithOthers" : "none",
                "mixable": mixWithOthers
            ])
        } catch {
            let nsError = error as NSError
            FileLogger.shared.error(.audio, "session activation failed", payload: [
                "domain": nsError.domain,
                "code": nsError.code,
                "mixable": mixWithOthers
            ])
            throw AudioSessionActivationError(underlyingError: error)
        }
    }

    /// Configures the shared `AVAudioSession` for transient audio playback.
    static func configurePlayback() throws {
        try Self.queue.sync {
            Self.generation &+= 1
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        }
    }

    /// Deactivates the shared audio session.
    ///
    /// Called when recording stops or the dictation is aborted, so other apps or the
    /// system can use audio without conflicts. Errors are silently ignored since
    /// deactivation is best-effort during teardown.
    static func deactivate() {
        Self.queue.async {
            Self.generation &+= 1
            let scheduledGeneration = Self.generation
            let session = AVAudioSession.sharedInstance()

            Self.queue.asyncAfter(deadline: .now() + 0.25) {
                guard Self.generation == scheduledGeneration else { return }
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
