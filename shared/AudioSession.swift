import AVFoundation
import Foundation

// `AVAudioSession` is process-wide state. This is the single choke point for
// all category and activation mutations: they are serialized on the private
// queue below. Deactivation is deferred by 250 ms and guarded against stale
// generations so CoreAudio can finish teardown before the session changes.
// This avoids the cross-category active-transition trap seen in build 316 and
// the teardown race trap seen in build 319. Configuration also waits out the
// remaining teardown window and retries transient setup failures; it never
// cancels deactivation early. Callers must not touch `AVAudioSession` directly.

// MARK: - Audio Session Configuration

enum AudioSession {

    private static let queue = DispatchQueue(label: "com.ritoras.audio-session")
    private static var generation: UInt = 0
    private static var deactivationDeadline: DispatchTime?
    private static let activationAttemptCount = 3
    private static let activationRetryDelay: TimeInterval = 0.02

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
    /// The audio-measurement toggle routes all recording paths (batch, stream,
    /// and tester) through `.measurement`, which strips iOS's hidden AGC/HPF
    /// for stable levels. This changes the absolute level scale, so static
    /// thresholds may need retuning; adaptive VAD adjusts to the new level
    /// scale automatically.
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
        let mode: AVAudioSession.Mode = SharedConfig.audioMeasurementModeEnabled() ? .measurement : .default
        try Self.queue.sync {
            Self.generation &+= 1
            Self.waitForTeardownIfNeeded()
            let session = AVAudioSession.sharedInstance()
            try Self.activateWithRetry {
                try session.setCategory(.record, mode: mode)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            FileLogger.shared.info(.audio, "session configured", payload: [
                "sampleRate": session.sampleRate,
                "category": session.category.rawValue,
                "mode": mode.rawValue
            ])
        }
    }

    /// Configures the shared `AVAudioSession` for transient audio playback.
    static func configurePlayback() throws {
        try Self.queue.sync {
            Self.generation &+= 1
            Self.waitForTeardownIfNeeded()
            let session = AVAudioSession.sharedInstance()
            try Self.activateWithRetry {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            }
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
            let deadline = DispatchTime.now() + 0.25
            Self.deactivationDeadline = deadline

            Self.queue.asyncAfter(deadline: deadline) {
                guard Self.generation == scheduledGeneration else { return }
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // Sleeping here does not wait for work on this queue: the deadline is
    // monotonic time, and the queued deactivation runs after this block returns.
    private static func waitForTeardownIfNeeded() {
        guard let deadline = Self.deactivationDeadline else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return }
        let remaining = deadline.uptimeNanoseconds - now
        Thread.sleep(forTimeInterval: Double(remaining) / 1_000_000_000)
    }

    private static func activateWithRetry(_ configureAndActivate: () throws -> Void) throws {
        for attempt in 1...Self.activationAttemptCount {
            do {
                try configureAndActivate()
                return
            } catch {
                FileLogger.shared.debug(.audio, "session activation retry failed", payload: [
                    "attempt": attempt
                ])
                if attempt == Self.activationAttemptCount {
                    FileLogger.shared.warn(.audio, "session activation retries exhausted")
                    throw error
                }
                Thread.sleep(forTimeInterval: Self.activationRetryDelay)
            }
        }
    }
}
