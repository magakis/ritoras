import AVFoundation
import os

// MARK: - Streaming Recorder Error

enum StreamingRecorderError: LocalizedError {
    case alreadyStreaming
    case engineStartFailed(Error)
    case nativeFormatUnavailable(String)
    case converterSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStreaming:
            return "Streaming recorder is already running."
        case .engineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .nativeFormatUnavailable(let reason):
            return "Audio input native format unavailable: \(reason)"
        case .converterSetupFailed(let reason):
            return "Failed to set up audio converter: \(reason)"
        }
    }
}

// MARK: - VAD Emission

struct VADEmission {
    let chunkId: UInt32
    let samples: [Float]
}

struct EmissionSummary: Sendable {
    let chunkId: UInt32
    let reason: String
    let silenceMs: Double
    let totalMs: Double
    let speechMs: Double
}

struct StreamingVADFrameState: Sendable {
    let endpointState: String
    let evidence: String
    let frameDb: Double
    let thresholdDb: Double
    let continuationThresholdDb: Double
    let silenceThresholdDb: Double
    let floorDb: Double?
    let calibrating: Bool
    let accumulatedSilenceMs: Double
    let silenceTargetMs: Double
    let utteranceDurationMs: Double
    let resumeEvidenceMs: Double
    let lastEmissionReason: String?
    let lastEmissionChunkId: UInt32?
    let lastEmissionSilenceMs: Double
    let lastEmissionTotalMs: Double
    let lastEmissionSpeechMs: Double
}

private final class SampleRingBuffer {
    private let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage = Array(repeating: 0, count: self.capacity)
    }

    func append(contentsOf samples: [Float]) {
        guard capacity > 0 else { return }
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    func append(to destination: inout [Float]) {
        guard count > 0 else { return }
        let firstIndex = (writeIndex - count + capacity) % capacity
        for offset in 0..<count {
            destination.append(storage[(firstIndex + offset) % capacity])
        }
    }

    func removeAll() {
        writeIndex = 0
        count = 0
    }
}

// MARK: - VAD Context (Thread-safe via internal lock)

/// Energy-based Voice Activity Detection state machine.
///
/// Thread safety through internal locking via `os_unfair_lock`.
/// All mutable state is protected — callers call `process()`/`flush()` directly.
private final class VADContext: @unchecked Sendable {
    // MARK: Configuration (constants)
    let gate: VADThresholdGate
    let silenceThresholdSamples: Int
    let minSpeechSamples: Int
    let minChunkSamples: Int
    let maxNoiseSamples: Int
    let noiseGuardSpeechSamples = 1600  // 0.1 s @ 16 kHz — reference client's fixed noise-floor cutoff
    // The 10-ms fallback frames are shorter than the endpoint's 70-ms onset requirement.
    let sustainedContinuingOnsetSeconds = 1.0
    let endpointMachineEnabled: Bool
    let endpoint: StreamingEndpoint
    let preRollSamples: Int
    let analysisHpf: VADHighPassFilter?

    // MARK: Lock
    private var unfairLock = os_unfair_lock()

    // MARK: Mutable state
    var accumulator: [Float] = []
    let preRollBuffer: SampleRingBuffer
    var silenceSamples: Int = 0
    var speechSamples: Int = 0
    var chunkId: UInt32 = 0
    var onCalibrationChange: ((Bool) -> Void)?
    private var wasCalibrating: Bool
    private var didLogFallback = false
    private var diagnosticElapsed = 0.0
    private var lastFrameDb = 0.0
    private var pendingEmissionSummary: EmissionSummary?
    private var sawReanchorDuringUtterance = false
    private var bufferHighWaterSamples = 0
    private var utteranceQuietestStrongDb: Double?
    private var sustainedContinuingMs = 0.0
    private var sustainedContinuingOnsetLatched = false

    init(
        gateConfig: VADGateConfig,
        silenceThresholdSamples: Int,
        minSpeechSamples: Int,
        minChunkSamples: Int,
        maxNoiseSamples: Int,
        endpointMachineEnabled: Bool,
        preRollSamples: Int,
        analysisHpfEnabled: Bool,
        analysisHpfCutoffHz: Double
    ) {
        self.gate = VADThresholdGate(config: gateConfig)
        self.silenceThresholdSamples = silenceThresholdSamples
        self.minSpeechSamples = minSpeechSamples
        self.minChunkSamples = minChunkSamples
        self.maxNoiseSamples = maxNoiseSamples
        self.endpointMachineEnabled = endpointMachineEnabled
        self.endpoint = StreamingEndpoint(configuration: StreamingEndpointConfiguration(
            onsetSamples: Int(Double(SharedConfig.streamVadOnsetMs()) * 16.0),
            endEvidenceSamples: Int(Double(SharedConfig.streamVadEndEvidenceMs()) * 16.0),
            endpointSilenceSamples: silenceThresholdSamples,
            resumeSamples: Int(Double(SharedConfig.streamVadResumeMs()) * 16.0),
            ambiguousRescueSamples: Int(Double(SharedConfig.streamVadAmbiguousRescueMs()) * 16.0),
            preRollSamples: Int(Double(SharedConfig.streamVadPreRollMs()) * 16.0)
        ))
        self.preRollSamples = max(0, preRollSamples)
        self.analysisHpf = analysisHpfEnabled
            ? VADHighPassFilter(cutoffHz: analysisHpfCutoffHz)
            : nil
        self.wasCalibrating = gateConfig.mode == .calibrated
        self.preRollBuffer = SampleRingBuffer(capacity: max(0, preRollSamples))
    }

    func setCalibrationChangeHandler(_ handler: ((Bool) -> Void)?) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        onCalibrationChange = handler
    }

    func resetAnalysisPath() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        analysisHpf?.reset()
    }

    func recalibrateAfterRouteChange() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        analysisHpf?.reset()
        gate.recalibrateFloor()
        utteranceQuietestStrongDb = nil
        sawReanchorDuringUtterance = false
        sustainedContinuingMs = 0
        sustainedContinuingOnsetLatched = false
    }

    func frameState(emissionSummary: EmissionSummary?) -> StreamingVADFrameState {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        let gateSnapshot = gate.snapshot
        return StreamingVADFrameState(
            endpointState: endpoint.state.rawValue,
            evidence: gateSnapshot.evidence.rawValue,
            frameDb: lastFrameDb,
            thresholdDb: gateSnapshot.thresholdDb,
            continuationThresholdDb: gateSnapshot.continuationThresholdDb,
            silenceThresholdDb: gateSnapshot.silenceThresholdDb,
            floorDb: gateSnapshot.floorDb,
            calibrating: gateSnapshot.calibrating,
            accumulatedSilenceMs: Double(endpoint.accumulatedSilenceSamples) / 16.0,
            silenceTargetMs: Double(silenceThresholdSamples) / 16.0,
            utteranceDurationMs: Double(endpoint.utteranceDurationSamples) / 16.0,
            resumeEvidenceMs: Double(endpoint.resumeEvidenceSamples) / 16.0,
            lastEmissionReason: emissionSummary?.reason,
            lastEmissionChunkId: emissionSummary?.chunkId,
            lastEmissionSilenceMs: emissionSummary?.silenceMs ?? 0,
            lastEmissionTotalMs: emissionSummary?.totalMs ?? 0,
            lastEmissionSpeechMs: emissionSummary?.speechMs ?? 0
        )
    }

    func takePendingEmissionSummary() -> EmissionSummary? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        let summary = pendingEmissionSummary
        pendingEmissionSummary = nil
        return summary
    }

    /// Process one audio frame. Returns a `VADEmission` if a silence endpoint
    /// is detected, otherwise `nil`.
    func process(frame: [Float], frameLength: Int) -> VADEmission? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        let analysisFrame = analysisHpf?.process(frame) ?? frame
        let rms = AudioMath.dcCorrectedRMS(analysisFrame)
        let frameDb = Double(AudioMath.dbFromRms(rms))
        lastFrameDb = frameDb
        pendingEmissionSummary = nil
        let frameDuration = Double(frameLength) / 16000.0
        let out = gate.process(frameDb: frameDb, frameDuration: frameDuration)
        let reanchorEvent = gate.takePendingReanchorEvent()

        if out.usedFallback && !didLogFallback {
            didLogFallback = true
            var payload: [String: Any] = ["thresholdDb": out.thresholdDb]
            if let floorDb = out.floorDb {
                payload["floorDb"] = floorDb
            }
            FileLogger.shared.warn(.audio, "VAD: calibration contaminated — adaptive fallback",
                                   payload: payload)
        }

        if wasCalibrating && !out.calibrating {
            var payload: [String: Any] = ["thresholdDb": out.thresholdDb]
            if let floorDb = out.floorDb {
                payload["floorDb"] = floorDb
            }
            FileLogger.shared.info(.audio, "VAD: calibration complete", payload: payload)
            onCalibrationChange?(false)
        }
        wasCalibrating = out.calibrating

        if out.retroactiveSpeechMs > 0 {
            speechSamples += Int(out.retroactiveSpeechMs * 16.0)
        }
        if let trailingSilenceMs = out.trailingSilenceMs {
            silenceSamples = Int(trailingSilenceMs * 16.0)
        }

        if out.isSpeech {
            speechSamples += frameLength
        }

        let decision: StreamingEndpointDecision
        if endpointMachineEnabled {
            let previousState = endpoint.state
            let endpointWasIdle = previousState == .idle
            if reanchorEvent,
               previousState == .speechActive || previousState == .endPending {
                sawReanchorDuringUtterance = true
            }
            let evidence = StreamingEndpointEvidence(rawValue: out.evidence.rawValue) ?? .silence
            let adaptivePath = out.floorDb != nil
            if adaptivePath && out.evidence == .continuing && endpointWasIdle {
                sustainedContinuingMs += frameDuration * 1000.0
            } else if !sustainedContinuingOnsetLatched {
                let lostStreakMs = sustainedContinuingMs
                if lostStreakMs >= 500.0 {  // 0.5 s — avoid per-frame ambient-noise logs
                    FileLogger.shared.debug(.audio, "VAD: continuing onset streak lost before latch",
                                            payload: ["streakMs": lostStreakMs])
                }
                sustainedContinuingMs = 0
            }

            if adaptivePath &&
               out.evidence == .continuing &&
               endpointWasIdle &&
               sustainedContinuingMs >= sustainedContinuingOnsetSeconds * 1000.0 {
                sustainedContinuingOnsetLatched = true
            }
            let endpointInOnsetLimb = endpointWasIdle || previousState == .onsetPending
            if sustainedContinuingOnsetLatched &&
               (!adaptivePath || !endpointInOnsetLimb || out.evidence == .ambiguous || out.evidence == .silence) {
                sustainedContinuingOnsetLatched = false
                sustainedContinuingMs = 0
            }
            let latchedContinuingOnset = sustainedContinuingOnsetLatched &&
                                         out.evidence == .continuing &&
                                         endpointInOnsetLimb
            let endpointEvidence = adaptivePath && latchedContinuingOnset
                ? StreamingEndpointEvidence.strong
                : evidence
            decision = endpoint.process(evidence: endpointEvidence, durationSamples: frameLength)
            let decisionSilenceSamples = endpoint.accumulatedSilenceSamples
            if previousState != endpoint.state {
                FileLogger.shared.debug(.audio, "VAD state \(previousState.rawValue) → \(endpoint.state.rawValue)")
            }
            gate.updateFloorTracking(
                frameDb: frameDb,
                duration: frameDuration,
                machineIsIdle: previousState == .idle && endpoint.state == .idle
            )

            switch decision {
            case .startUtterance:
                utteranceQuietestStrongDb = nil
                sustainedContinuingMs = 0
                sustainedContinuingOnsetLatched = false
                accumulator.removeAll(keepingCapacity: true)
                preRollBuffer.append(to: &accumulator)
                preRollBuffer.removeAll()
                appendLiveFrame(frame)
            case .continueUtterance, .finalizeUtterance:
                appendLiveFrame(frame)
            case .none:
                appendToPreRoll(frame)
            }

            if adaptivePath, out.evidence == .strong, endpoint.state != .idle {
                utteranceQuietestStrongDb = min(utteranceQuietestStrongDb ?? frameDb, frameDb)
            }

            if case .finalizeUtterance(let kind) = decision {
                guard accumulator.count >= minChunkSamples,
                      speechSamples >= minSpeechSamples else {
                    FileLogger.shared.info(.audio, "VAD: finalize discarded - below minimum speech or chunk duration",
                                           payload: ["sampleCount": accumulator.count,
                                                     "speechSamples": speechSamples])
                    accumulator.removeAll(keepingCapacity: true)
                    speechSamples = 0
                    silenceSamples = 0
                    sawReanchorDuringUtterance = false
                    bufferHighWaterSamples = 0
                    return nil
                }
                if sawReanchorDuringUtterance {
                    FileLogger.shared.debug(.audio, "VAD: kept utterance after mid-utterance re-anchor",
                                            payload: ["quietestStrongDb": utteranceQuietestStrongDb ?? NSNull(),
                                                      "floorDb": gate.snapshot.floorDb ?? NSNull()])
                }
                let silenceMs = Double(decisionSilenceSamples) / 16.0
                let totalMs = Double(accumulator.count) / 16.0
                let speechMs = Double(speechSamples) / 16.0
                FileLogger.shared.info(.audio, "VAD: \(kind.rawValue) → emit",
                                       payload: ["silenceMs": silenceMs,
                                                 "totalMs": totalMs,
                                                 "speechMs": speechMs,
                                                 "sampleCount": accumulator.count])
                return emit(reason: kind.rawValue,
                            silenceMs: silenceMs,
                            totalMs: totalMs,
                            speechMs: speechMs)
            }
        } else {
            // Legacy kill-switch path: retain the former consecutive-silence
            // behavior while the endpoint state machine is disabled.
            gate.updateFloorTracking(
                frameDb: frameDb,
                duration: frameDuration,
                machineIsIdle: accumulator.isEmpty
            )
            accumulator.append(contentsOf: frame)
            bufferHighWaterSamples = max(bufferHighWaterSamples, accumulator.count)
            if out.isSpeech {
                silenceSamples = 0
            } else {
                silenceSamples += frame.count
            }
            if silenceSamples >= silenceThresholdSamples,
               accumulator.count >= minChunkSamples,
               speechSamples >= minSpeechSamples {
                let silenceMs = Double(silenceSamples) / 16.0
                let totalMs = Double(accumulator.count) / 16.0
                let speechMs = Double(speechSamples) / 16.0
                FileLogger.shared.info(.audio, "VAD: pause → emit",
                                       payload: ["silenceMs": silenceMs,
                                                 "totalMs": totalMs,
                                                 "speechMs": speechMs,
                                                 "sampleCount": accumulator.count])
                return emit(reason: "pause",
                            silenceMs: silenceMs,
                            totalMs: totalMs,
                            speechMs: speechMs)
            }

            // Noise guard: less than 0.1 s of speech within the max-noise
            // window is discarded so ambient noise never ships.
            if speechSamples < noiseGuardSpeechSamples && accumulator.count > maxNoiseSamples {
                accumulator = []
                silenceSamples = 0
                speechSamples = 0
                FileLogger.shared.debug(.audio, "VAD: noise guard discard")
            }
        }

        diagnosticElapsed += frameDuration
        if diagnosticElapsed >= 1.0 {
            diagnosticElapsed = 0
            let snapshot = gate.snapshot
            FileLogger.shared.debug(.audio, "VAD summary", payload: [
                "state": endpoint.state.rawValue,
                "floorDb": snapshot.floorDb ?? snapshot.thresholdDb,
                "onsetDb": snapshot.thresholdDb,
                "continueDb": snapshot.continuationThresholdDb,
                "silenceDb": snapshot.silenceThresholdDb,
                "silenceMs": Double(endpoint.accumulatedSilenceSamples) / 16.0,
                "resumeMs": Double(endpoint.resumeEvidenceSamples) / 16.0,
                "bufferHighWaterSamples": bufferHighWaterSamples
            ])
        }

        return nil
    }

    private func appendToPreRoll(_ frame: [Float]) {
        preRollBuffer.append(contentsOf: frame)
    }

    private func appendLiveFrame(_ frame: [Float]) {
        accumulator.append(contentsOf: frame)
        bufferHighWaterSamples = max(bufferHighWaterSamples, accumulator.count)
    }

    /// Emit current accumulator and reset all VAD state.
    /// - parameter reason: Label for log distinguishability ("pause", "flush").
    func emit(
        reason: String,
        silenceMs: Double,
        totalMs: Double,
        speechMs: Double
    ) -> VADEmission {
        let snapshot = accumulator
        let id = chunkId
        chunkId &+= 1
        pendingEmissionSummary = EmissionSummary(
            chunkId: id,
            reason: reason,
            silenceMs: silenceMs,
            totalMs: totalMs,
            speechMs: speechMs
        )
        accumulator = []
        preRollBuffer.removeAll()
        silenceSamples = 0
        speechSamples = 0
        endpoint.reset()
        sawReanchorDuringUtterance = false
        bufferHighWaterSamples = 0
        gate.noteUtteranceEnded(quietestStrongDb: utteranceQuietestStrongDb)
        utteranceQuietestStrongDb = nil
        sustainedContinuingMs = 0
        sustainedContinuingOnsetLatched = false
        return VADEmission(chunkId: id, samples: snapshot)
    }

    /// Flush any remaining accumulator into an emission (for `stop()`).
    /// Trailing audio without enough speech is discarded as noise.
    func flush() -> VADEmission? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        sustainedContinuingMs = 0
        sustainedContinuingOnsetLatched = false
        _ = endpoint.forceFinalize(kind: .stop)
        guard !accumulator.isEmpty else { return nil }
        guard speechSamples >= minSpeechSamples else {
            FileLogger.shared.debug(.audio, "VAD: flush discarded trailing noise",
                                    payload: ["sampleCount": accumulator.count,
                                              "speechSamples": speechSamples])
            accumulator.removeAll(keepingCapacity: true)
            preRollBuffer.removeAll()
            bufferHighWaterSamples = 0
            return nil
        }
        FileLogger.shared.info(.audio, "VAD: stop → emit",
                               payload: ["count": accumulator.count])
        return emit(reason: "flush",
                    silenceMs: 0,
                    totalMs: Double(accumulator.count) / 16.0,
                    speechMs: Double(speechSamples) / 16.0)
    }
}

// MARK: - Converter Holder (Thread-safe via internal lock)

/// Thread-safe holder for the shared `AVAudioConverter`, protected by
/// `os_unfair_lock`. Mirrors the `VADContext` locking pattern so the
/// converter can be read/written from `vadQueue` without actor-isolation
/// violations or data races against `teardownEngine()`.
private final class ConverterHolder: @unchecked Sendable {
    private var unfairLock = os_unfair_lock()
    private var converter: AVAudioConverter?

    /// Returns the existing converter if its input format matches
    /// `inputFormat`; otherwise builds a new `AVAudioConverter(from:to:)`,
    /// stores it, and returns it. Returns `nil` if construction fails.
    func getOrCreate(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioConverter? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        if let existing = converter, existing.inputFormat == inputFormat {
            return existing
        }
        guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            converter = nil
            return nil
        }
        converter = c
        return c
    }

    /// Returns the current converter's input format, or `nil` if no
    /// converter exists yet. Used only for diagnostic logging.
    func currentInputFormat() -> AVAudioFormat? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return converter?.inputFormat
    }

    /// Nils out the stored converter. Safe to call from any thread
    /// (including the actor's `teardownEngine()`).
    func invalidate() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        converter = nil
    }
}

// MARK: - Disk Writer Holder (access via vadQueue serialization)

/// Thread-safe holder for the WAV file writer used during streaming disk
/// recording. All access is from `vadQueue` (serial), so no lock is needed.
/// Writes every resampled buffer (including silence) to disk so the full
/// session is available for batch transcription if the stream fails.
/// On write error, logs once at `.error` and disables further writes;
/// the network streaming path is unaffected.
private final class DiskWriterHolder: @unchecked Sendable {
    private var audioFile: AVAudioFile?
    private var disabled = false

    /// Opens a WAV file for writing with the given format settings.
    /// Returns `false` on failure (sets the disabled flag internally).
    func open(url: URL, settings: [String: Any]) -> Bool {
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else {
            audioFile = nil
            disabled = true
            return false
        }
        audioFile = file
        disabled = false
        return true
    }

    /// Writes one PCM buffer to disk. Safe to call from `vadQueue` only.
    /// On write error, logs once and disables all future writes.
    func write(from buffer: AVAudioPCMBuffer) {
        guard let file = audioFile, !disabled else { return }
        do {
            try file.write(from: buffer)
        } catch {
            FileLogger.shared.error(.audio, "stream WAV write failed — disabling disk recording")
            disabled = true
            audioFile = nil
        }
    }

    /// Closes the file (finalizes WAV header on dealloc). Safe to call
    /// multiple times. Call from `vadQueue` after `vad.flush()`.
    func close() {
        audioFile = nil
        disabled = true
    }
}

// MARK: - Stopped Flag (access via vadQueue serialization)

/// Lockless stopped flag for preventing orphaned tap callbacks after stop().
/// All access is from `vadQueue` (serial), so no lock is needed.
/// Set in stop()'s vadQueue.async block, read in processTapBuffer (also on vadQueue).
private final class StoppedFlag: @unchecked Sendable {
    private var stopped = false
    func set(_ value: Bool) { stopped = value }
    var isStopped: Bool { stopped }
}

// MARK: - Converter Accounting (access via vadQueue serialization)

/// Per-session converter accounting. Access is vadQueue-only, so no lock is needed.
private final class ConverterAccounting: @unchecked Sendable {
    var inputFramesTotal = 0
    var outputFramesTotal = 0
    var expectedOutputTotal = 0.0
    var debugLoggedBuffers = 0
}

// MARK: - Streaming Audio Recorder

/// Captures microphone audio via `AVAudioEngine`, runs an energy-based VAD
/// state machine, and emits pause-bounded float32 PCM chunks via a callback.
///
/// Chunks are delivered as `[Float]` at 16 kHz mono, one chunk per detected
/// speech segment. The caller should forward them to a Whisper streaming server
/// (e.g. via WebSocket).
///
/// ## Thread safety
/// The audio-tap callback runs on a real-time audio thread. The callback is
/// minimal — it reads the buffer, copies samples, and dispatches all heavy
/// work (RMS, VAD, chunk emission) to a dedicated serial `vadQueue`. VAD
/// state is protected internally by `os_unfair_lock`.
actor StreamingAudioRecorder {
    typealias ChunkHandler = @Sendable (UInt32, [Float]) -> Void

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private var isRecording = false
    private var onChunk: ChunkHandler?
    private var onVADState: ((StreamingVADFrameState) -> Void)?

    /// Thread-safe holder for the lazy `AVAudioConverter`; access only
    /// through its lock-protected methods (never actor-isolated `var`).
    private let converterHolder = ConverterHolder()

    /// Thread-safe holder for the WAV disk writer; accessed only from
    /// `vadQueue` (serial) — no additional locking needed.
    private let diskWriter = DiskWriterHolder()

    /// Lockless stopped flag; set on vadQueue in stop(), read on vadQueue in processTapBuffer.
    private let stoppedFlag = StoppedFlag()

    /// Per-session converter accounting; accessed only from `vadQueue` (serial).
    private let accounting = ConverterAccounting()

    /// Tracks whether a tap is installed, enabling idempotent teardown.
    private var tapInstalled = false

    /// Route changes reset the VAD baseline and analysis filter without touching
    /// the captured PCM stream.
    private var routeChangeObserver: NSObjectProtocol?

    /// Serial queue for audio processing off the real-time audio thread.
    private let vadQueue = DispatchQueue(label: "com.ritoras.streaming-vad", qos: .userInitiated)

    /// VAD state machine; accessed only via `process()`/`flush()` which lock internally.
    private let vad: VADContext
    private let vadGateConfig: VADGateConfig

    // MARK: - Initialization

    init() {
        let silenceSamples = Int(Double(SharedConfig.streamVadSilenceMs()) * 16.0)
        let minSpeechSamples = Int(Double(SharedConfig.streamVadMinSpeechMs()) * 16.0)
        let minChunkSamples = Int(Double(SharedConfig.streamVadMinChunkMs()) * 16.0)
        let maxNoiseSamples = Int(SharedConfig.streamVadMaxNoiseSec() * 16000.0)
        let vadGateConfig = VADGateConfig(
            mode: SharedConfig.streamVadMode(),
            staticRms: SharedConfig.streamVadSpeechRms(),
            calibrationMs: SharedConfig.streamVadCalibrationMs(),
            calibratedOffsetDb: SharedConfig.streamVadCalibratedOffsetDb(),
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb(),
            adaptiveRiseSpeedMultiplier: SharedConfig.streamVadAdaptationSpeed(),
            adaptiveSilenceDeltaDb: SharedConfig.streamVadAdaptiveSilenceDeltaDb(),
            adaptiveStaleFloorSeconds: SharedConfig.streamVadStaleFloorSeconds(),
            adaptiveFallTauSeconds: SharedConfig.streamVadFallTauSeconds()
        )
        self.vadGateConfig = vadGateConfig
        vad = VADContext(
            gateConfig: vadGateConfig,
            silenceThresholdSamples: silenceSamples,
            minSpeechSamples: minSpeechSamples,
            minChunkSamples: minChunkSamples,
            maxNoiseSamples: maxNoiseSamples,
            endpointMachineEnabled: SharedConfig.streamEndpointMachineEnabled(),
            preRollSamples: Int(Double(SharedConfig.streamVadPreRollMs()) * 16.0),
            analysisHpfEnabled: SharedConfig.streamVadAnalysisHpfEnabled(),
            analysisHpfCutoffHz: SharedConfig.Defaults.streamVadHpfCutoffHzDefault
        )
    }

    // MARK: - Start

    /// Begins streaming audio capture.
    ///
    /// - Parameter onVADCalibration: Called when calibrated VAD finishes its
    ///   calibration window. The argument is the current calibration state.
    /// - Parameter onChunk: Called on vadQueue for each detected speech
    ///   segment. The first argument is a monotonically increasing chunk ID
    ///   (starting at 0); the second is float32 PCM samples at 16 kHz mono.
    /// - Parameter onVADState: Called on vadQueue after each processed audio
    ///   frame with the current VAD and endpoint state.
    /// - Throws: `AudioRecorder.AudioRecorderError.permissionDenied` or `.permissionNotRequested`
    ///   if mic access is unavailable; `AudioRecorder.AudioRecorderError.invalidSessionConfiguration`
    ///   if session setup fails; `StreamingRecorderError.engineStartFailed` if
    ///   the audio engine cannot start.
    func start(fileURL: URL? = nil, onVADCalibration: ((Bool) -> Void)? = nil, onChunk: @escaping ChunkHandler, onVADState: ((StreamingVADFrameState) -> Void)? = nil) async throws {
        guard !isRecording else {
            throw StreamingRecorderError.alreadyStreaming
        }

        // 1. Check microphone permission
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            break
        case .denied:
            throw AudioRecorder.AudioRecorderError.permissionDenied
        case .undetermined:
            throw AudioRecorder.AudioRecorderError.permissionNotRequested
        @unknown default:
            throw AudioRecorder.AudioRecorderError.permissionNotRequested
        }

        // 2. Configure audio session (must be before engine start)
        do {
            try AudioSession.configure()
        } catch {
            throw AudioRecorder.AudioRecorderError.invalidSessionConfiguration(error)
        }

        self.onChunk = onChunk
        self.onVADState = onVADState

        // 3. Build the 16 kHz mono target format (converter output)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            FileLogger.shared.error(.audio, "CRASH-PROOF: Could not create 16kHz mono float32 audio format")
            throw StreamingRecorderError.engineStartFailed(
                NSError(domain: "StreamingAudioRecorder", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create 16kHz mono float32 audio format"])
            )
        }

        // Optionally open disk WAV writer for continuous recording
        if let wavURL = fileURL {
            if !diskWriter.open(url: wavURL, settings: targetFormat.settings) {
                FileLogger.shared.error(.audio, "stream WAV open failed — disk recording disabled")
            }
        }

        let inputNode = engine.inputNode

        // 4. Get the input node's NATIVE format
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            FileLogger.shared.error(.audio, "CRASH-PROOF: Audio input unavailable (no microphone route)")
            throw StreamingRecorderError.engineStartFailed(
                NSError(domain: "StreamingAudioRecorder", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio input unavailable (no microphone route)"])
            )
        }
        guard nativeFormat.channelCount >= 1 else {
            FileLogger.shared.error(.audio, "CRASH-PROOF: Audio input has no channels")
            throw StreamingRecorderError.nativeFormatUnavailable(
                "Input node has \(nativeFormat.channelCount) channels"
            )
        }

        // Capture references for the closure (no actor self capture).
        let handler = onChunk
        let stateHandler = onVADState
        let vad = self.vad
        vad.setCalibrationChangeHandler(onVADCalibration)
        let vadQueue = self.vadQueue
        let converterHolder = self.converterHolder
        let diskWriter = self.diskWriter
        let stoppedFlag = self.stoppedFlag
        let accounting = self.accounting

        // 6. Install tap with NATIVE format (REMOVES the format-mismatch crash)
        let tapBlock: AVAudioNodeTapBlock = { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0,
                  let channelData = buffer.floatChannelData else {
                FileLogger.shared.debug(.audio, "tap callback: invalid buffer",
                                        payload: ["frameLength": frameLength,
                                                  "hasChannelData": buffer.floatChannelData != nil])
                return
            }

            // Capture the delivered buffer's format — this is the ground truth
            // for what the hardware actually delivered.
            let deliveredFormat = buffer.format
            let deliveredSampleRate = deliveredFormat.sampleRate
            let deliveredChannelCount = Int(deliveredFormat.channelCount)

            // A degenerate delivered format (sampleRate 0) would produce
            // NaN/Inf in the output capacity calculation — guard it out.
            guard deliveredSampleRate > 0 else { return }

            // Copy all channel samples into a flat array (bounded, acceptable on audio thread)
            var samples = [Float]()
            samples.reserveCapacity(frameLength * deliveredChannelCount)
            for ch in 0..<deliveredChannelCount {
                let ptr = UnsafeBufferPointer(start: channelData[ch], count: frameLength)
                samples.append(contentsOf: ptr)
            }

            // Dispatch ALL heavy work (resampling, RMS, VAD, emission) to the serial queue
            vadQueue.async {
                Self.processTapBuffer(
                    samples: samples,
                    frameLength: frameLength,
                    deliveredFormat: deliveredFormat,
                    deliveredSampleRate: deliveredSampleRate,
                    deliveredChannelCount: deliveredChannelCount,
                    converterHolder: converterHolder,
                    targetFormat: targetFormat,
                    vad: vad,
                    handler: handler,
                    stateHandler: stateHandler,
                    diskWriter: diskWriter,
                    stoppedFlag: stoppedFlag,
                    accounting: accounting
                )
            }
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat,
            block: tapBlock
        )
        tapInstalled = true

        // 7. Prepare and start engine
        vad.resetAnalysisPath()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            self.onChunk = nil
            self.onVADState = nil
            AudioSession.deactivate()
            throw StreamingRecorderError.engineStartFailed(error)
        }

        isRecording = true
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { _ in
            vad.recalibrateAfterRouteChange()
        }

        var startedPayload: [String: Any] = [
            "rms": vadGateConfig.staticRms,
            "mode": vadGateConfig.mode.rawValue,
            "silenceMs": SharedConfig.streamVadSilenceMs(),
            "minSpeechMs": SharedConfig.streamVadMinSpeechMs(),
            "minChunkMs": SharedConfig.streamVadMinChunkMs(),
            "maxNoiseSec": SharedConfig.streamVadMaxNoiseSec(),
            "analysisHpf": SharedConfig.streamVadAnalysisHpfEnabled(),
            "hpfCutoffHz": SharedConfig.Defaults.streamVadHpfCutoffHzDefault
        ]
        switch vadGateConfig.mode {
        case .staticMode:
            break
        case .calibrated:
            startedPayload["calibrationMs"] = vadGateConfig.calibrationMs
            startedPayload["offsetDb"] = vadGateConfig.calibratedOffsetDb
        case .adaptive:
            startedPayload["deltaDb"] = vadGateConfig.adaptiveDeltaDb
        }
        FileLogger.shared.info(.audio, "Started", payload: startedPayload)
        if vadGateConfig.mode == .calibrated {
            FileLogger.shared.debug(.audio, "VAD: calibration start")
        }
    }

    // MARK: - Process Tap Buffer

    /// Processes one buffer of captured audio on the vadQueue: lazily builds or
    /// reuses an AVAudioConverter, resamples to 16 kHz mono, runs RMS + VAD,
    /// and emits chunks via the handler. This is a static method so the type
    /// checker can resolve it independently of the tap closure.
    private static func processTapBuffer(
        samples: [Float],
        frameLength: Int,
        deliveredFormat: AVAudioFormat,
        deliveredSampleRate: Double,
        deliveredChannelCount: Int,
        converterHolder: ConverterHolder,
        targetFormat: AVAudioFormat,
        vad: VADContext,
        handler: ChunkHandler,
        stateHandler: ((StreamingVADFrameState) -> Void)?,
        diskWriter: DiskWriterHolder,
        stoppedFlag: StoppedFlag,
        accounting: ConverterAccounting
    ) {
        // Discard any emission from a late tap callback that runs after stop() set the flag.
        guard !stoppedFlag.isStopped else { return }

        // --- Lazy converter construction / route-change rebuild ---
        // Log a warning if the format changed since the previous buffer.
        let oldFormat = converterHolder.currentInputFormat()
        guard let converter = converterHolder.getOrCreate(
            inputFormat: deliveredFormat,
            outputFormat: targetFormat
        ) else {
            FileLogger.shared.error(.audio,
                "Failed to build AVAudioConverter from delivered format \(deliveredFormat)")
            return
        }
        if oldFormat == nil {
            FileLogger.shared.info(.audio, "converter session formats",
                                   payload: ["nativeHz": Int(deliveredSampleRate),
                                             "nativeCh": deliveredChannelCount,
                                             "targetHz": 16000,
                                             "targetCh": 1])
        } else if let old = oldFormat, old != deliveredFormat {
            FileLogger.shared.info(.audio,
                "Format change detected — rebuilt converter",
                payload: ["old": "\(old)", "new": "\(deliveredFormat)"])
        }

        // Build input AVAudioPCMBuffer using the delivered format
        // (must be `isEqual:` to converter.inputFormat).
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: deliveredFormat,
            frameCapacity: AVAudioFrameCount(frameLength)
        ) else {
            FileLogger.shared.error(.audio, "Failed to allocate converter input buffer")
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameLength)
        for ch in 0..<deliveredChannelCount {
            let offset = ch * frameLength
            let dst = inputBuffer.floatChannelData![ch]
            for i in 0..<frameLength {
                dst[i] = samples[offset + i]
            }
        }

        // Allocate output buffer in target format (16 kHz mono float32)
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(frameLength) * 16000.0 / deliveredSampleRate) + 128
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            FileLogger.shared.error(.audio, "Failed to allocate converter output buffer")
            return
        }

        // Convert native → 16 kHz mono using the block-based API
        // (the simple convert(to:from:) cannot perform sample-rate conversion,
        // per Apple's AVAudioConverter.h and TN3136).
        var convError: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return inputBuffer
        }

        var drained = [Float]()
        drained.reserveCapacity(Int(outputCapacity))
        var iterations = 0
        var statusChars = ""
        let maxDrainIterations = 16

        drainLoop: while true {
            guard iterations < maxDrainIterations else {
                FileLogger.shared.warn(.audio, "converter drain hit iteration cap")
                break drainLoop
            }

            iterations += 1
            convError = nil
            let status = converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
            let n = Int(outputBuffer.frameLength)
            if n > 0 {
                // Write every converted buffer to disk (incl. silence) so the full
                // session is available for batch transcription if the stream fails.
                diskWriter.write(from: outputBuffer)

                // Copy before the next convert call overwrites the output buffer.
                let outputPtr = UnsafeBufferPointer(
                    start: outputBuffer.floatChannelData![0],
                    count: n
                )
                drained.append(contentsOf: outputPtr)
            }

            switch status {
            case .haveData:
                statusChars.append("H")
                continue drainLoop
            case .inputRanDry:
                statusChars.append("R")
                break drainLoop
            case .endOfStream:
                statusChars.append("S")
                FileLogger.shared.debug(.audio, "converter returned unexpected endOfStream")
                break drainLoop
            case .error:
                statusChars.append("E")
                let detail = convError.map { $0.localizedDescription } ?? "unknown error"
                FileLogger.shared.error(.audio, "Converter error: \(detail)")
                break drainLoop
            @unknown default:
                statusChars.append("X")
                FileLogger.shared.debug(.audio, "converter returned unknown status")
                break drainLoop
            }
        }

        guard !drained.isEmpty else { return }

        let expectedOutput = Double(frameLength) * 16000.0 / deliveredSampleRate
        accounting.inputFramesTotal += frameLength
        accounting.outputFramesTotal += drained.count
        accounting.expectedOutputTotal += expectedOutput

        if accounting.debugLoggedBuffers < 10 {
            accounting.debugLoggedBuffers += 1
            let inputChannelSamples = Array(samples.prefix(frameLength))
            FileLogger.shared.debug(.audio, "converter buffer accounting",
                                    payload: ["inFrames": frameLength,
                                              "outFrames": drained.count,
                                              "expected": Int(expectedOutput.rounded()),
                                              "iterations": iterations,
                                              "statuses": statusChars,
                                              "inRms": AudioMath.dcCorrectedRMS(inputChannelSamples),
                                              "outRms": AudioMath.dcCorrectedRMS(drained)])
        }

        // RMS computation (off audio thread) — DC-corrected (mean-subtracted),
        // matching the reference client: rms = sqrt(mean((s - mean(s))^2)).
        // VAD processing (locks internally via os_unfair_lock)
        // frameLength = post-conversion (16 kHz) — VAD tunables are in 16 kHz samples
        let emission = vad.process(frame: drained, frameLength: drained.count)

        if let stateHandler = stateHandler {
            let emissionSummary = vad.takePendingEmissionSummary()
            stateHandler(vad.frameState(emissionSummary: emissionSummary))
        }

        // Emit chunk if ready (handler runs synchronously on vadQueue)
        if let emission = emission {
            FileLogger.shared.debug(.audio, "vadQueue: emission",
                                    payload: ["chunkId": emission.chunkId,
                                              "sampleCount": emission.samples.count])
            handler(emission.chunkId, emission.samples)
        }
    }

    // MARK: - Teardown

    /// Idempotent engine teardown: removes the tap (if installed) and stops the
    /// engine. Safe to call multiple times; `removeTap` does not raise an
    /// NSException when no tap is installed.
    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        converterHolder.invalidate()
    }

    // MARK: - Stop

    /// Stops streaming audio capture and flushes any in-progress accumulator
    /// as a final chunk.
    func stop() async {
        guard isRecording else { return }
        isRecording = false

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        // Tear down engine and tap idempotently
        teardownEngine()
        AudioSession.deactivate()

        // Flush any in-progress accumulator. Route through vadQueue so it
        // runs AFTER all pending process() blocks complete (serial ordering).
        let vadQueue = self.vadQueue
        let vad = self.vad
        let diskWriter = self.diskWriter
        let stateHandler = self.onVADState
        let stoppedFlag = self.stoppedFlag
        let accounting = self.accounting
        let emission: VADEmission? = await withCheckedContinuation { continuation in
            vadQueue.async {
                stoppedFlag.set(true)
                let result = vad.flush()
                if let stateHandler = stateHandler {
                    let emissionSummary = vad.takePendingEmissionSummary()
                    stateHandler(vad.frameState(emissionSummary: emissionSummary))
                }
                diskWriter.close()
                let ratio = accounting.outputFramesTotal > 0
                    ? Double(accounting.inputFramesTotal) / Double(accounting.outputFramesTotal)
                    : 0.0
                let driftFrames = Int(Double(accounting.outputFramesTotal) - accounting.expectedOutputTotal)
                FileLogger.shared.info(.audio, "converter session accounting",
                                       payload: ["inFrames": accounting.inputFramesTotal,
                                                 "outFrames": accounting.outputFramesTotal,
                                                 "ratio": ratio,
                                                 "driftFrames": driftFrames,
                                                 "driftMs": Double(driftFrames) / 16.0])
                accounting.inputFramesTotal = 0
                accounting.outputFramesTotal = 0
                accounting.expectedOutputTotal = 0.0
                accounting.debugLoggedBuffers = 0
                continuation.resume(returning: result)
            }
        }

        // Dispatch final chunk (synchronous call — stoppedFlag is already set)
        if let emission = emission, let handler = onChunk {
            handler(emission.chunkId, emission.samples)
        }

        onChunk = nil
        onVADState = nil

        FileLogger.shared.info(.audio, "Stopped")
    }
}
