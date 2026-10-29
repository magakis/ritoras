import AVFoundation
import Foundation
import os

// This chunk splitter segments a continuous
// audio stream into chunks for streaming ASR while retaining all audio except
// voiceless slabs over maxNoiseSec. Speech is never trimmed from chunks; do not
// add silence-stripping or aggressive speech-gating here.

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

// MARK: - Chunk Splitter Emission

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

/// Receives per-frame and lifecycle observations from the streaming chunk splitter.
protocol VADTelemetrySink: AnyObject, Sendable {
    func frame(_ record: VADTelemetryFrame)
    func event(_ record: VADTelemetryEvent)
}

/// Optional file-flush seam used by sinks that buffer observations in memory.
protocol VADTelemetryFlushable: AnyObject, Sendable {
    func flushIfNeeded()
    func flush()
}

struct VADTelemetryFrame: @unchecked Sendable {
    let seq: UInt64
    // Half-open source coordinates; frame duration and all sample counts are at 16 kHz.
    let sourceStartSample: Int
    let sourceEndSample: Int
    let frameDuration: Double
    let frameDb: Double
    let evidence: String
    let isSpeech: Bool
    let floorDb: Double?
    let floorConverged: Bool
    let strongThresholdDb: Double
    let continuationThresholdDb: Double
    let silenceThresholdDb: Double
    let dynamicsSpreadDb: Double?
    let shortSpreadDb: Double?
    let speechShaped: Bool
    let highBandRatioDb: Double?
    let endpointPreviousState: String
    let endpointState: String
    let endpointDecision: String
    let decisionSilenceSamples: Int
    let utteranceDurationSamples: Int
    let isLoudRegime: Bool
}

enum VADTelemetryEventKind: String, Sendable {
    case sessionStart = "session_start"
    case startUtterance = "start_utterance"
    case emit
    case discard
    case stopFlush = "stop_flush"
    case sessionEnd = "session_end"
    case outcome
    case fullRecordingUpload = "full_recording_upload"
    case chunkReceived = "chunk_received"
    case flatTerminate = "flat_terminate"
    case reanchor
    case preRoll = "pre_roll"
    case spill
    case primingComplete = "priming_complete"
    case split

    var defaultReason: String {
        switch self {
        case .sessionStart: return "started"
        case .startUtterance: return "onset_confirmed"
        case .emit: return "endpoint"
        case .discard: return "discarded"
        case .stopFlush: return "stop"
        case .sessionEnd: return "ended"
        case .outcome: return "completed"
        case .fullRecordingUpload: return "completed"
        case .chunkReceived: return "response_received"
        case .flatTerminate: return "flat_spread"
        case .reanchor: return "floor_moved"
        case .preRoll: return "ring_buffer"
        case .spill: return "created"
        case .primingComplete: return "priming-complete"
        case .split: return "split-gap"
        }
    }
}

struct VADTelemetryEvent: @unchecked Sendable {
    let kind: VADTelemetryEventKind
    let chunkId: UInt32?
    let samples: Int?
    let reason: String?
    let speechMs: Double?
    let totalMs: Double?
    let config: [String: Any]?
    let startMs: Double?
    let endMs: Double?
    // New timeline fields are additive; startMs/endMs retain their legacy meaning.
    let timestampMs: Double?
    let wallTimestampMs: Double?
    let sourceStartSample: Int?
    let sourceEndSample: Int?
    let endpointState: String?
    let latencyMs: Double?
    let chars: Int?
    let metadata: [String: Any]?

    init(
        kind: VADTelemetryEventKind,
        chunkId: UInt32? = nil,
        samples: Int? = nil,
        reason: String? = nil,
        speechMs: Double? = nil,
        totalMs: Double? = nil,
        config: [String: Any]? = nil,
        startMs: Double? = nil,
        endMs: Double? = nil,
        timestampMs: Double? = nil,
        wallTimestampMs: Double? = nil,
        sourceStartSample: Int? = nil,
        sourceEndSample: Int? = nil,
        endpointState: String? = nil,
        latencyMs: Double? = nil,
        chars: Int? = nil,
        metadata: [String: Any]? = nil
    ) {
        self.kind = kind
        self.chunkId = chunkId
        self.samples = samples
        self.reason = reason ?? kind.defaultReason
        self.speechMs = speechMs
        self.totalMs = totalMs
        self.config = config
        self.startMs = startMs
        self.endMs = endMs
        self.timestampMs = timestampMs
        self.wallTimestampMs = wallTimestampMs
        self.sourceStartSample = sourceStartSample
        self.sourceEndSample = sourceEndSample
        self.endpointState = endpointState
        self.latencyMs = latencyMs
        self.chars = chars
        self.metadata = metadata
    }
}

struct ChunkSplitterFrameState: Sendable {
    let endpointState: String
    let evidence: String
    let frameDb: Double
    let thresholdDb: Double
    let continuationThresholdDb: Double
    let silenceThresholdDb: Double
    let floorDb: Double?
    let accumulatedSilenceMs: Double
    let silenceTargetMs: Double
    let endEvidenceMs: Double
    let utteranceDurationMs: Double
    let resumeEvidenceMs: Double
    let lastEmissionReason: String?
    let lastEmissionChunkId: UInt32?
    let lastEmissionSilenceMs: Double
    let lastEmissionTotalMs: Double
    let lastEmissionSpeechMs: Double
}

// MARK: - VAD Context (Thread-safe via internal lock)

/// This chunk splitter retains all audio except voiceless slabs over maxNoiseSec
/// and finalizes utterances only at silence endpoints or an explicit stop.
/// Speech is never trimmed from chunks; do not add silence-stripping or
/// aggressive speech-gating here. During capture, the spill path keeps long
/// utterances bounded in memory. This runs in the container app process, not the
/// keyboard extension.
///
/// Thread safety through internal locking via `os_unfair_lock`.
/// All mutable state is protected — callers call `process()`/`flush()` directly.
private final class VADContext: @unchecked Sendable {
    private static let maximumStrongGustFrameDurationSeconds = 0.02

    // MARK: Configuration (constants)
    let gate: VADThresholdGate
    let silenceThresholdSamples: Int
    let minSpeechSamples: Int
    let minChunkSamples: Int
    let maxNoiseSamples: Int
    let minimumVoiceEvidenceToRetainSamples = 100 * 16
    let endpointMachineEnabled: Bool
    let endpoint: StreamingEndpoint
    let loudFlatSpreadDb: Double
    let loudFlatTerminateSeconds: Double
    let loudFlatTerminateEnabled: Bool
    let accumulatorSpillSamples: Int
    let postRollSamples = 400 * 16
    let analysisHpf: VADHighPassFilter?
    let whisperAnalysisHpf: VADHighPassFilter

    // MARK: Lock
    private var unfairLock = os_unfair_lock()

    // MARK: Mutable state
    var accumulator: [Float] = []
    // This gap buffer stays near maxNoiseSamples (~6 s / 384 KB float32);
    // evidence-qualified audio moves to the spill-capable accumulator.
    private var retainedGapBuffer: [Float] = []
    private var retainedGapStartSessionSamples: Int?
    private var retainedGapEvidenceSamples = 0
    private var accumulatorSpillURL: URL?
    private var accumulatorSpillHandle: FileHandle?
    private var spilledSampleCount = 0
    private var contiguousTrailingSilenceSamples = 0
    private var contiguousTrailingSilenceMinimumDb: Double?
    private var contiguousTrailingSilencePeakAboveFloorDb: Double?
    private var retainedGapPeakAboveFloorDb: Double?
    private var accumulatorPeakAboveFloorDb: Double?
    private var accumulatorHasSpeechEvidence = false
    private var chunkStartSessionSamples: Int?
    private var chunkEndSessionSamples: Int?
    var silenceSamples: Int = 0
    var speechSamples: Int = 0
    var chunkId: UInt32 = 0
    private var sessionElapsedSamples = 0
    private var diagnosticElapsed = 0.0
    private var lastFrameDb = 0.0
    private var previousFrameDbForClassification: Double?
    private var pendingEmissionSummary: EmissionSummary?
    private var sawReanchorDuringUtterance = false
    private var bufferHighWaterSamples = 0
    private var utteranceQuietestStrongDb: Double?
    private var loudFlatStreakMs = 0.0
    private var loudFlatStreakStartSeconds: Double?
    private var loudFlatTerminatorActive = false
    private var telemetrySequence: UInt64 = 0
    private var telemetrySink: VADTelemetrySink?
    private var primingComplete = false
    private var idleGapRunSamples = 0
    private var idleGapStartSessionSamples: Int?
    private var idleGapEndSessionSamples: Int?
    private var idleGapPeakLevelDb: Double?
    private var idleGapFloorDbAtPeak: Double?
    private var idleGapStrongThresholdDbAtPeak: Double?
    private var idleGapContinuationThresholdDbAtPeak: Double?
    private var idleGapEvidenceAboveFloor5Samples = 0

    init(
        gateConfig: VADGateConfig,
        silenceThresholdSamples: Int,
        minSpeechSamples: Int,
        minChunkSamples: Int,
        maxNoiseSamples: Int,
        endpointMachineEnabled: Bool,
        loudFlatSpreadDb: Double,
        loudFlatTerminateSeconds: Double,
        loudFlatTerminateEnabled: Bool,
        analysisHpfEnabled: Bool,
        analysisHpfCutoffHz: Double
    ) {
        let gate = VADThresholdGate(config: gateConfig)
        self.gate = gate
        self.primingComplete = gate.snapshot.floorDb == nil
        self.silenceThresholdSamples = silenceThresholdSamples
        self.minSpeechSamples = minSpeechSamples
        self.minChunkSamples = minChunkSamples
        self.maxNoiseSamples = maxNoiseSamples
        self.accumulatorSpillSamples = SharedConfig.streamVadAccumulatorSpillSamples()
        self.endpointMachineEnabled = endpointMachineEnabled
        self.endpoint = StreamingEndpoint(configuration: StreamingEndpointConfiguration(
            onsetSamples: Int(Double(SharedConfig.streamVadOnsetMs()) * 16.0),
            endEvidenceSamples: Int(Double(SharedConfig.streamVadEndEvidenceMs()) * 16.0),
            endpointSilenceSamples: silenceThresholdSamples,
            resumeSamples: Int(Double(SharedConfig.streamVadResumeMs()) * 16.0),
            ambiguousRescueSamples: Int(Double(SharedConfig.streamVadAmbiguousRescueMs()) * 16.0)
        ))
        self.loudFlatSpreadDb = max(0, loudFlatSpreadDb)
        self.loudFlatTerminateSeconds = max(0, loudFlatTerminateSeconds)
        self.loudFlatTerminateEnabled = loudFlatTerminateEnabled
        self.analysisHpf = analysisHpfEnabled
            ? VADHighPassFilter(cutoffHz: analysisHpfCutoffHz)
            : nil
        self.whisperAnalysisHpf = VADHighPassFilter(
            cutoffHz: SharedConfig.Defaults.streamVadWhisperHighPassCutoffHzDefault
        )
    }

    deinit {
        try? accumulatorSpillHandle?.close()
        if let accumulatorSpillURL {
            try? FileManager.default.removeItem(at: accumulatorSpillURL)
        }
    }

    func setTelemetrySink(_ sink: VADTelemetrySink?) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        telemetrySink = sink
        telemetrySequence = 0
        sessionElapsedSamples = 0
        chunkStartSessionSamples = nil
        chunkEndSessionSamples = nil
        previousFrameDbForClassification = nil
        resetIdleGapRun()
        guard let sink else { return }

        var config = gate.effectiveParameters
        config["endpointMachineEnabled"] = endpointMachineEnabled
        config["endpointOnsetMs"] = Double(endpoint.configuration.onsetSamples) / 16.0
        config["endpointEndEvidenceMs"] = Double(endpoint.configuration.endEvidenceSamples) / 16.0
        config["endpointSilenceMs"] = Double(endpoint.configuration.endpointSilenceSamples) / 16.0
        config["endpointResumeMs"] = Double(endpoint.configuration.resumeSamples) / 16.0
        config["endpointAmbiguousRescueMs"] = Double(endpoint.configuration.ambiguousRescueSamples) / 16.0
        config["idleGapMinSeconds"] = SharedConfig.Defaults.streamVadIdleGapMinimumSecondsDefault
        config["idleGapPeakAboveFloorDb"] = SharedConfig.Defaults.streamVadIdleGapPeakAboveFloorDbDefault
        config["idleGapEvidenceAboveFloorDb"] = SharedConfig.Defaults.streamVadIdleGapEvidenceAboveFloorDbDefault
        config["loudFlatTerminateEnabled"] = loudFlatTerminateEnabled
        config["loudFlatSpreadDb"] = loudFlatSpreadDb
        config["loudFlatTerminateSeconds"] = loudFlatTerminateSeconds
        config["loudFlatStreakMs"] = loudFlatStreakMs
        config["loudFlatTerminatorActive"] = loudFlatTerminatorActive
        config["accumulatorSpillSamples"] = accumulatorSpillSamples
        config["maxChunkMs"] = 0
        config["splitSearchWindowMs"] = 0
        config["minSilenceAtSplitMs"] = 0
        config["silenceMs"] = Double(silenceThresholdSamples) / 16.0
        config["minSpeechMs"] = Double(minSpeechSamples) / 16.0
        config["minChunkMs"] = Double(minChunkSamples) / 16.0
        config["maxNoiseSec"] = Double(maxNoiseSamples) / 16000.0
        config["analysisHpfEnabled"] = analysisHpf != nil
        config["analysisHpfCutoffHz"] = SharedConfig.Defaults.streamVadHpfCutoffHzDefault
        config["whisperHighPassCutoffHz"] = SharedConfig.Defaults.streamVadWhisperHighPassCutoffHzDefault
        config["whisperModulationSpreadDb"] =
            SharedConfig.Defaults.streamVadWhisperModulationSpreadDbDefault
        config["whisperContextMs"] = SharedConfig.Defaults.streamVadWhisperContextMsDefault
        config["gapSpeechPeakAboveFloorDb"] = SharedConfig.Defaults.streamVadGapSpeechPeakAboveFloorDbDefault
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            config["appShortVersion"] = appVersion
        }
        if let appBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            config["appBuildNumber"] = appBuildNumber
        }
        sink.event(VADTelemetryEvent(kind: .sessionStart, config: config))
    }

    func endTelemetrySession() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        telemetrySink?.event(VADTelemetryEvent(kind: .sessionEnd))
    }

    func resetAnalysisPath() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        analysisHpf?.reset()
        whisperAnalysisHpf.reset()
        previousFrameDbForClassification = nil
    }

    func resetAfterRouteChange() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        analysisHpf?.reset()
        whisperAnalysisHpf.reset()
        previousFrameDbForClassification = nil
        gate.resetFloorAfterRouteChange()
        primingComplete = gate.snapshot.floorDb == nil
        utteranceQuietestStrongDb = nil
        sawReanchorDuringUtterance = false
        loudFlatStreakMs = 0
        loudFlatStreakStartSeconds = nil
        loudFlatTerminatorActive = false
        contiguousTrailingSilenceSamples = 0
        contiguousTrailingSilenceMinimumDb = nil
        contiguousTrailingSilencePeakAboveFloorDb = nil
    }

    func frameState(emissionSummary: EmissionSummary?) -> ChunkSplitterFrameState {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        let gateSnapshot = gate.snapshot
        return ChunkSplitterFrameState(
            endpointState: endpoint.state.rawValue,
            evidence: gateSnapshot.evidence.rawValue,
            frameDb: lastFrameDb,
            thresholdDb: gateSnapshot.thresholdDb,
            continuationThresholdDb: gateSnapshot.continuationThresholdDb,
            silenceThresholdDb: gateSnapshot.silenceThresholdDb,
            floorDb: gateSnapshot.floorDb,
            accumulatedSilenceMs: Double(endpoint.accumulatedSilenceSamples) / 16.0,
            silenceTargetMs: Double(silenceThresholdSamples) / 16.0,
            endEvidenceMs: Double(endpoint.configuration.endEvidenceSamples) / 16.0,
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

    private func telemetryDecisionLabel(_ decision: StreamingEndpointDecision) -> String {
        switch decision {
        case .none:
            return "none"
        case .startUtterance:
            return "start_utterance"
        case .continueUtterance:
            return "continue_utterance"
        case .finalizeUtterance(let kind):
            return "finalize_\(kind.rawValue)"
        }
    }

    private func recordTelemetryFrame(
        output: VADGateOutput,
        sourceStartSample: Int,
        sourceEndSample: Int,
        frameDuration: Double,
        previousEndpointState: StreamingEndpointState,
        decision: StreamingEndpointDecision,
        decisionSilenceSamples: Int
    ) {
        guard let sink = telemetrySink else { return }
        let record = VADTelemetryFrame(
            seq: telemetrySequence,
            sourceStartSample: sourceStartSample,
            sourceEndSample: sourceEndSample,
            frameDuration: frameDuration,
            frameDb: lastFrameDb,
            evidence: output.evidence.rawValue,
            isSpeech: output.isSpeech,
            floorDb: output.floorDb,
            floorConverged: output.floorConverged,
            strongThresholdDb: output.thresholdDb,
            continuationThresholdDb: output.continuationThresholdDb,
            silenceThresholdDb: output.silenceThresholdDb,
            dynamicsSpreadDb: output.dynamicsSpreadDb,
            shortSpreadDb: output.shortSpreadDb,
            speechShaped: output.speechShaped,
            highBandRatioDb: output.highBandRatioDb,
            endpointPreviousState: previousEndpointState.rawValue,
            endpointState: endpoint.state.rawValue,
            endpointDecision: telemetryDecisionLabel(decision),
            decisionSilenceSamples: decisionSilenceSamples,
            utteranceDurationSamples: endpoint.utteranceDurationSamples,
            isLoudRegime: output.isLoudRegime
        )
        telemetrySequence &+= 1
        sink.frame(record)
    }

    private func trackIdleGapFrame(
        frameDb: Double,
        frameStartSamples: Int,
        frameLength: Int,
        output: VADGateOutput
    ) {
        guard telemetrySink != nil else { return }
        if idleGapRunSamples == 0 {
            idleGapStartSessionSamples = frameStartSamples
        }
        idleGapRunSamples += frameLength
        idleGapEndSessionSamples = frameStartSamples + frameLength
        guard let floorDb = output.floorDb else { return }

        if frameDb >= floorDb + SharedConfig.Defaults.streamVadIdleGapEvidenceAboveFloorDbDefault {
            idleGapEvidenceAboveFloor5Samples += frameLength
        }
        if let currentPeak = idleGapPeakLevelDb, frameDb <= currentPeak { return }
        idleGapPeakLevelDb = frameDb
        idleGapFloorDbAtPeak = floorDb
        idleGapStrongThresholdDbAtPeak = output.thresholdDb
        idleGapContinuationThresholdDbAtPeak = output.continuationThresholdDb
    }

    private func finishIdleGapRun() {
        defer { resetIdleGapRun() }
        let durationMs = Double(idleGapRunSamples) / 16.0
        guard durationMs >= SharedConfig.Defaults.streamVadIdleGapMinimumSecondsDefault * 1_000.0,
              let peakLevelDb = idleGapPeakLevelDb,
              let floorDbAtPeak = idleGapFloorDbAtPeak,
              peakLevelDb - floorDbAtPeak >= SharedConfig.Defaults.streamVadIdleGapPeakAboveFloorDbDefault,
              let strongThresholdDbAtPeak = idleGapStrongThresholdDbAtPeak,
              let continuationThresholdDbAtPeak = idleGapContinuationThresholdDbAtPeak else {
            return
        }

        let evidenceAboveFloor5Ms = Double(idleGapEvidenceAboveFloor5Samples) / 16.0
        telemetrySink?.event(VADTelemetryEvent(
            kind: .discard,
            reason: "idle_gap",
            timestampMs: Double(sessionElapsedSamples) / 16.0,
            wallTimestampMs: Date().timeIntervalSince1970 * 1_000.0,
            sourceStartSample: idleGapStartSessionSamples,
            sourceEndSample: idleGapEndSessionSamples,
            metadata: [
                "durationMs": durationMs,
                "peakLevelDbFS": peakLevelDb,
                "floorDbFSAtPeak": floorDbAtPeak,
                "strongThresholdDbFSAtPeak": strongThresholdDbAtPeak,
                "continuationThresholdDbFSAtPeak": continuationThresholdDbAtPeak,
                "evidenceAboveFloor5Ms": evidenceAboveFloor5Ms
            ]
        ))
        FileLogger.shared.debug(.audio, "Chunk splitter: reported never-onset idle gap",
                                payload: ["durationMs": durationMs,
                                          "peakLevelDbFS": peakLevelDb,
                                          "evidenceAboveFloor5Ms": evidenceAboveFloor5Ms])
    }

    private func resetIdleGapRun() {
        idleGapRunSamples = 0
        idleGapStartSessionSamples = nil
        idleGapEndSessionSamples = nil
        idleGapPeakLevelDb = nil
        idleGapFloorDbAtPeak = nil
        idleGapStrongThresholdDbAtPeak = nil
        idleGapContinuationThresholdDbAtPeak = nil
        idleGapEvidenceAboveFloor5Samples = 0
    }

    private func recordDiscard(
        samples: Int,
        reason: String,
        sourceStartSample: Int?,
        sourceEndSample: Int?
    ) {
        telemetrySink?.event(VADTelemetryEvent(
            kind: .discard,
            samples: samples,
            reason: reason,
            timestampMs: Double(sessionElapsedSamples) / 16.0,
            wallTimestampMs: Date().timeIntervalSince1970 * 1_000.0,
            sourceStartSample: sourceStartSample,
            sourceEndSample: sourceEndSample
        ))
    }

    /// Process one frame into the continuous pending chunk buffer.
    func process(frame: [Float], frameLength: Int) -> VADEmission? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        sessionElapsedSamples += frameLength
        let frameStartSamples = sessionElapsedSamples - frameLength
        let analysisFrame = analysisHpf?.process(frame) ?? frame
        let analysisRms = AudioMath.dcCorrectedRMS(analysisFrame)
        let frameDb = Double(AudioMath.dbFromRms(analysisRms))
        let adjacentStepDb = previousFrameDbForClassification.map { abs(frameDb - $0) }
        previousFrameDbForClassification = frameDb
        let previousGateEvidence = gate.snapshot.evidence
        let highBandRms = whisperAnalysisHpf.rms(analysisFrame)
        let highBandRatioDb = analysisRms > 1e-10
            ? Double(AudioMath.dbFromRms(highBandRms / analysisRms))
            : -100.0
        lastFrameDb = frameDb
        pendingEmissionSummary = nil
        let frameDuration = Double(frameLength) / 16_000.0
        let previousEndpointState = endpoint.state
        let withinUtteranceContext = previousEndpointState == .speechActive
            || previousEndpointState == .endPending
        let output = gate.process(
            frameDb: frameDb,
            frameDuration: frameDuration,
            highBandRatioDb: highBandRatioDb,
            withinUtteranceContext: withinUtteranceContext
        )
        if output.didCompletePriming {
            telemetrySink?.event(VADTelemetryEvent(
                kind: .primingComplete,
                reason: output.primingEndedAtCap ? "duration_cap" : "quiet_floor_seed",
                totalMs: output.primingDurationSeconds * 1_000.0
            ))
        }
        primingComplete = primingComplete || output.didCompletePriming

        let reanchorEvent = output.didReanchor
        _ = gate.takePendingReanchorEvent()
        if reanchorEvent {
            telemetrySink?.event(VADTelemetryEvent(kind: .reanchor, reason: "floor_moved"))
            if previousEndpointState == .speechActive || previousEndpointState == .endPending {
                sawReanchorDuringUtterance = true
            }
        }

        let frameIsInPendingGap = endpointMachineEnabled
            && (previousEndpointState == .idle || previousEndpointState == .onsetPending)
        if frameIsInPendingGap {
            appendRetainedGapFrame(
                frame,
                startSamples: frameStartSamples,
                evidence: output.isSpeech || output.speechShaped ? .continuing : output.evidence,
                frameDb: frameDb,
                floorDb: output.floorDb
            )
        } else {
            if accumulatorSampleCount == 0 {
                chunkStartSessionSamples = frameStartSamples
            }
            appendAccumulator(frame)
            chunkEndSessionSamples = frameStartSamples + frameLength
            trackAccumulatorSpeechEvidence(frameDb: frameDb, floorDb: output.floorDb, output: output)
            bufferHighWaterSamples = max(bufferHighWaterSamples, accumulatorSampleCount)
        }
        if output.isSpeech {
            speechSamples += frameLength
            contiguousTrailingSilenceSamples = 0
            contiguousTrailingSilenceMinimumDb = nil
        }

        var decision: StreamingEndpointDecision = .none
        var endpointEvidence = StreamingEndpointEvidence(rawValue: output.evidence.rawValue) ?? .silence
        var decisionSilenceSamples = endpoint.accumulatedSilenceSamples
        if endpointMachineEnabled {
            let previousState = previousEndpointState
            let flatTerminatorStateEligible = previousState == .speechActive
                || (loudFlatTerminatorActive && previousState == .endPending)
            let isLoudFlatFrame = loudFlatTerminateEnabled
                && output.isLoudRegime
                && flatTerminatorStateEligible
                && output.dynamicsSpreadDb.map { $0 < loudFlatSpreadDb } == true
                && output.shortSpreadDb.map { $0 < loudFlatSpreadDb } == true
            if isLoudFlatFrame {
                if !loudFlatTerminatorActive {
                    loudFlatStreakStartSeconds = loudFlatStreakStartSeconds
                        ?? Double(frameStartSamples) / 16_000.0
                    loudFlatStreakMs += frameDuration * 1_000.0
                    if loudFlatStreakMs >= loudFlatTerminateSeconds * 1_000.0 {
                        loudFlatTerminatorActive = true
                        if endpointEvidence != .silence {
                            telemetrySink?.event(VADTelemetryEvent(
                                kind: .flatTerminate,
                                samples: Int(loudFlatStreakMs * 16.0),
                                reason: "flat_spread",
                                startMs: (loudFlatStreakStartSeconds ?? 0) * 1_000.0,
                                endMs: Double(sessionElapsedSamples) / 16.0,
                                endpointState: previousState.rawValue
                            ))
                        }
                    }
                }
                if loudFlatTerminatorActive {
                    if previousState != .endPending || output.evidence != .strong {
                        endpointEvidence = .silence
                    }
                }
            } else {
                loudFlatStreakMs = 0
                loudFlatStreakStartSeconds = nil
                loudFlatTerminatorActive = false
            }

            // Keep gate/floor evidence level-based; shape only controls the endpoint silence clock.
            if output.speechShaped, endpointEvidence == .silence {
                endpointEvidence = .continuing
            }

            // Bound wind suppression to one short strong edge after a non-strong frame.
            let isTransientStrongGust = previousState == .endPending
                && output.evidence == .strong
                && previousGateEvidence != .strong
                && !output.speechShaped
                && adjacentStepDb.map {
                    $0 >= VADThresholdGate.adaptiveEndPendingWindDispersionDb
                } == true
                && output.dynamicsSpreadDb.map {
                    $0 >= VADThresholdGate.adaptiveEndPendingWindDispersionDb
                } == true
                && output.shortSpreadDb.map { $0 >= gate.effectiveFlatSpreadDb } == true
                && frameDuration <= Self.maximumStrongGustFrameDurationSeconds
            if isTransientStrongGust {
                // Only the first short, abrupt strong edge is suppressed; a sustained run passes.
                endpointEvidence = .silence
            } else if previousState == .endPending,
               output.shortSpreadDb != nil,
               output.dynamicsSpreadDb != nil,
               !output.speechShaped,
               (endpointEvidence == .continuing || endpointEvidence == .ambiguous) {
                endpointEvidence = .silence
            }

            if endpointEvidence == .silence {
                contiguousTrailingSilenceSamples += frameLength
                contiguousTrailingSilenceMinimumDb = min(
                    contiguousTrailingSilenceMinimumDb ?? frameDb,
                    frameDb
                )
                if let floorDb = output.floorDb {
                    let peakAboveFloorDb = frameDb - floorDb
                    if contiguousTrailingSilencePeakAboveFloorDb.map({ peakAboveFloorDb > $0 }) ?? true {
                        contiguousTrailingSilencePeakAboveFloorDb = peakAboveFloorDb
                    }
                }
            } else {
                contiguousTrailingSilenceSamples = 0
                contiguousTrailingSilenceMinimumDb = nil
                contiguousTrailingSilencePeakAboveFloorDb = nil
            }

            let silenceBeforeDecision = endpoint.accumulatedSilenceSamples
            decision = endpoint.process(evidence: endpointEvidence, durationSamples: frameLength)
            if loudFlatTerminatorActive && endpoint.state == .idle {
                loudFlatStreakMs = 0
                loudFlatStreakStartSeconds = nil
                loudFlatTerminatorActive = false
            }
            if case .finalizeUtterance = decision, endpointEvidence == .silence {
                decisionSilenceSamples = silenceBeforeDecision + frameLength
            } else {
                decisionSilenceSamples = endpoint.accumulatedSilenceSamples
            }
            if previousState != endpoint.state {
                FileLogger.shared.debug(.audio, "Chunk splitter: \(previousState.rawValue) → \(endpoint.state.rawValue)")
            }
            gate.updateFloorTracking(
                frameDb: frameDb,
                duration: frameDuration,
                machineIsIdle: previousState == .idle && endpoint.state == .idle,
                machineIsEnding: previousState == .endPending || endpoint.state == .endPending
            )

            if case .startUtterance = decision {
                utteranceQuietestStrongDb = nil
                silenceSamples = 0
            }
            if output.evidence == .strong, endpoint.state != .idle {
                utteranceQuietestStrongDb = min(utteranceQuietestStrongDb ?? frameDb, frameDb)
            }
        } else {
            gate.updateFloorTracking(
                frameDb: frameDb,
                duration: frameDuration,
                machineIsIdle: accumulatorSampleCount == frameLength
            )
            if output.isSpeech {
                silenceSamples = 0
                contiguousTrailingSilenceSamples = 0
                contiguousTrailingSilenceMinimumDb = nil
                contiguousTrailingSilencePeakAboveFloorDb = nil
            } else {
                contiguousTrailingSilenceSamples += frameLength
                contiguousTrailingSilenceMinimumDb = min(
                    contiguousTrailingSilenceMinimumDb ?? frameDb,
                    frameDb
                )
                if let floorDb = output.floorDb {
                    let peakAboveFloorDb = frameDb - floorDb
                    if contiguousTrailingSilencePeakAboveFloorDb.map({ peakAboveFloorDb > $0 }) ?? true {
                        contiguousTrailingSilencePeakAboveFloorDb = peakAboveFloorDb
                    }
                }
                silenceSamples += frameLength
            }
            decisionSilenceSamples = silenceSamples
            if silenceSamples >= silenceThresholdSamples {
                decision = .finalizeUtterance(kind: .endpoint)
                silenceSamples = 0
            }
        }

        recordTelemetryFrame(
            output: output,
            sourceStartSample: frameStartSamples,
            sourceEndSample: sessionElapsedSamples,
            frameDuration: frameDuration,
            previousEndpointState: previousEndpointState,
            decision: decision,
            decisionSilenceSamples: decisionSilenceSamples
        )
        if endpointMachineEnabled {
            if case .startUtterance = decision {
                moveRetainedGapToAccumulator()
                finishIdleGapRun()
                telemetrySink?.event(VADTelemetryEvent(
                    kind: .startUtterance,
                    samples: accumulatorSampleCount
                ))
            } else if previousEndpointState == .idle, endpoint.state == .idle {
                trackIdleGapFrame(
                    frameDb: frameDb,
                    frameStartSamples: frameStartSamples,
                    frameLength: frameLength,
                    output: output
                )
            }
        }

        if case .finalizeUtterance(let kind) = decision {
            gate.noteUtteranceEnded(
                quietestStrongDb: utteranceQuietestStrongDb,
                trailingSilenceDb: contiguousTrailingSilenceMinimumDb
            )
            if sawReanchorDuringUtterance {
                FileLogger.shared.debug(.audio, "Chunk splitter kept utterance after mid-utterance re-anchor",
                                        payload: ["quietestStrongDb": utteranceQuietestStrongDb ?? NSNull(),
                                                  "floorDb": gate.snapshot.floorDb ?? NSNull()])
            }
            utteranceQuietestStrongDb = nil
            sawReanchorDuringUtterance = false
            if accumulatorSampleCount < minChunkSamples || speechSamples < minSpeechSamples {
                telemetrySink?.event(VADTelemetryEvent(
                    kind: .outcome,
                    samples: accumulatorSampleCount,
                    reason: "below_minimums_held",
                    speechMs: Double(speechSamples) / 16.0,
                    totalMs: Double(accumulatorSampleCount) / 16.0,
                    endpointState: previousEndpointState.rawValue
                ))
                FileLogger.shared.info(.audio, "Chunk splitter: finalize held below minimum chunk gates",
                                       payload: ["sampleCount": accumulatorSampleCount,
                                                 "speechSamples": speechSamples])
            } else {
                let silenceMs = Double(decisionSilenceSamples) / 16.0
                let totalMs = Double(accumulatorSampleCount) / 16.0
                let speechMs = Double(speechSamples) / 16.0
                FileLogger.shared.info(.audio, "Chunk splitter: \(kind.rawValue) → emit",
                                       payload: ["silenceMs": silenceMs,
                                                 "totalMs": totalMs,
                                                 "speechMs": speechMs,
                                                 "sampleCount": accumulatorSampleCount])
                return emit(
                    reason: kind.rawValue,
                    silenceMs: silenceMs,
                    speechMs: speechMs,
                    endpointState: previousEndpointState.rawValue,
                    trimToPostRoll: true
                )
            }
        }

        if endpointMachineEnabled,
           (endpoint.state == .idle || endpoint.state == .onsetPending),
           retainedGapBuffer.count > maxNoiseSamples {
            if !retainedGapHasSpeechEvidence {
                shedRetainedGap()
            } else {
                moveRetainedGapToAccumulator()
            }
        } else if !endpointMachineEnabled,
                  endpoint.state == .idle,
                  accumulatorSampleCount > maxNoiseSamples,
                  speechSamples < minimumVoiceEvidenceToRetainSamples,
                  !accumulatorHasPlausibleSpeech {
            recordDiscard(
                samples: accumulatorSampleCount,
                reason: "noise_guard",
                sourceStartSample: chunkStartSessionSamples,
                sourceEndSample: chunkEndSessionSamples
            )
            clearAccumulator()
            chunkStartSessionSamples = nil
            speechSamples = 0
            silenceSamples = 0
            contiguousTrailingSilenceSamples = 0
            contiguousTrailingSilenceMinimumDb = nil
            contiguousTrailingSilencePeakAboveFloorDb = nil
            bufferHighWaterSamples = 0
            FileLogger.shared.debug(.audio, "Chunk splitter: shed voiceless pending audio")
            return nil
        }

        diagnosticElapsed += frameDuration
        if diagnosticElapsed >= 1.0 {
            diagnosticElapsed = 0
            let snapshot = gate.snapshot
        FileLogger.shared.debug(.audio, "Chunk splitter summary", payload: [
                "state": endpoint.state.rawValue,
                "floorDb": snapshot.floorDb ?? snapshot.thresholdDb,
                "onsetDb": snapshot.thresholdDb,
                "continueDb": snapshot.continuationThresholdDb,
                "silenceDb": snapshot.silenceThresholdDb,
                "noSilenceS": gate.secondsSinceSilenceEvidence,
                "silenceMs": Double(endpoint.accumulatedSilenceSamples) / 16.0,
                "resumeMs": Double(endpoint.resumeEvidenceSamples) / 16.0,
                "bufferHighWaterSamples": bufferHighWaterSamples
            ])
        }
        return nil
    }

    private var accumulatorSampleCount: Int {
        accumulator.count + spilledSampleCount
    }

    private func appendRetainedGapFrame(
        _ samples: [Float],
        startSamples: Int,
        evidence: VADEvidence,
        frameDb: Double,
        floorDb: Double?
    ) {
        if retainedGapBuffer.isEmpty {
            retainedGapStartSessionSamples = startSamples
        }
        retainedGapBuffer.append(contentsOf: samples)
        if let floorDb {
            let peakAboveFloorDb = frameDb - floorDb
            if retainedGapPeakAboveFloorDb.map({ peakAboveFloorDb > $0 }) ?? true {
                retainedGapPeakAboveFloorDb = peakAboveFloorDb
            }
        }
        if evidence == .strong || evidence == .continuing {
            retainedGapEvidenceSamples += samples.count
        }
        bufferHighWaterSamples = max(
            bufferHighWaterSamples,
            accumulatorSampleCount + retainedGapBuffer.count
        )
    }

    private var retainedGapHasSpeechEvidence: Bool {
        if retainedGapEvidenceSamples > 0 { return true }
        if let retainedGapPeakAboveFloorDb,
           retainedGapPeakAboveFloorDb >= SharedConfig.Defaults.streamVadGapSpeechPeakAboveFloorDbDefault {
            return true
        }
        // A held, VAD-accepted accumulator remains part of the un-emitted span.
        return accumulatorHasSpeechEvidence
    }

    private var accumulatorHasPlausibleSpeech: Bool {
        if accumulatorHasSpeechEvidence { return true }
        return accumulatorPeakAboveFloorDb.map {
            $0 >= SharedConfig.Defaults.streamVadGapSpeechPeakAboveFloorDbDefault
        } ?? false
    }

    private func trackAccumulatorSpeechEvidence(
        frameDb: Double,
        floorDb: Double?,
        output: VADGateOutput
    ) {
        accumulatorHasSpeechEvidence = accumulatorHasSpeechEvidence
            || output.evidence == .strong
            || output.evidence == .continuing
            || output.speechShaped
        if let floorDb {
            let peakAboveFloorDb = frameDb - floorDb
            if accumulatorPeakAboveFloorDb.map({ peakAboveFloorDb > $0 }) ?? true {
                accumulatorPeakAboveFloorDb = peakAboveFloorDb
            }
        }
    }

    private func moveRetainedGapToAccumulator() {
        guard !retainedGapBuffer.isEmpty else { return }
        if accumulatorSampleCount == 0 {
            chunkStartSessionSamples = retainedGapStartSessionSamples
        }
        accumulatorHasSpeechEvidence = accumulatorHasSpeechEvidence || retainedGapEvidenceSamples > 0
        if let retainedGapStartSessionSamples {
            chunkEndSessionSamples = retainedGapStartSessionSamples + retainedGapBuffer.count
        }
        appendAccumulator(retainedGapBuffer)
        retainedGapBuffer.removeAll(keepingCapacity: true)
        retainedGapStartSessionSamples = nil
        retainedGapEvidenceSamples = 0
        retainedGapPeakAboveFloorDb = nil
        bufferHighWaterSamples = max(bufferHighWaterSamples, accumulatorSampleCount)
    }

    private func shedRetainedGap() {
        let sampleCount = retainedGapBuffer.count
        let sourceStartSample = retainedGapStartSessionSamples
        let sourceEndSample = sourceStartSample.map { $0 + sampleCount }
        recordDiscard(
            samples: sampleCount,
            reason: "noise_guard",
            sourceStartSample: sourceStartSample,
            sourceEndSample: sourceEndSample
        )
        retainedGapBuffer.removeAll(keepingCapacity: true)
        retainedGapStartSessionSamples = nil
        retainedGapEvidenceSamples = 0
        retainedGapPeakAboveFloorDb = nil
        if accumulatorSampleCount == 0 {
            chunkStartSessionSamples = nil
            chunkEndSessionSamples = nil
            accumulatorPeakAboveFloorDb = nil
            accumulatorHasSpeechEvidence = false
            speechSamples = 0
            silenceSamples = 0
            contiguousTrailingSilenceSamples = 0
            contiguousTrailingSilenceMinimumDb = nil
            contiguousTrailingSilencePeakAboveFloorDb = nil
            bufferHighWaterSamples = 0
        }
        FileLogger.shared.debug(.audio, "Chunk splitter: shed voiceless pending audio")
    }

    private func sampleData(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.size)
        }
    }

    private func restoreAccumulatorAfterSpillFailure() {
        guard let url = accumulatorSpillURL else { return }
        try? accumulatorSpillHandle?.close()
        accumulatorSpillHandle = nil
        do {
            let data = try Data(contentsOf: url)
            let restored = data.withUnsafeBytes { $0.bindMemory(to: Float.self) }
            accumulator.append(contentsOf: restored)
        } catch {
            FileLogger.shared.error(.audio, "Chunk splitter spill restore failed; audio lost",
                                    payload: ["spilledSamples": spilledSampleCount])
            telemetrySink?.event(VADTelemetryEvent(
                kind: .spill,
                samples: spilledSampleCount,
                reason: "restore_failed"
            ))
        }
        try? FileManager.default.removeItem(at: url)
        accumulatorSpillURL = nil
        spilledSampleCount = 0
    }

    private func clearAccumulator() {
        try? accumulatorSpillHandle?.close()
        accumulatorSpillHandle = nil
        if let url = accumulatorSpillURL {
            try? FileManager.default.removeItem(at: url)
        }
        accumulatorSpillURL = nil
        spilledSampleCount = 0
        accumulator.removeAll(keepingCapacity: true)
        accumulatorPeakAboveFloorDb = nil
        accumulatorHasSpeechEvidence = false
        chunkEndSessionSamples = nil
    }

    private func appendAccumulator(_ samples: [Float]) {
        if let handle = accumulatorSpillHandle {
            do {
                try handle.write(contentsOf: sampleData(samples))
                spilledSampleCount += samples.count
                telemetrySink?.event(VADTelemetryEvent(kind: .spill, samples: samples.count, reason: "append"))
                return
            } catch {
                restoreAccumulatorAfterSpillFailure()
                accumulator.append(contentsOf: samples)
                telemetrySink?.event(VADTelemetryEvent(kind: .spill, samples: samples.count, reason: "write_failed"))
                FileLogger.shared.warn(.audio, "Chunk splitter accumulator spill failed; retaining audio in memory")
                return
            }
        }
        accumulator.append(contentsOf: samples)
        guard accumulator.count > accumulatorSpillSamples else { return }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else {
            telemetrySink?.event(VADTelemetryEvent(kind: .spill, samples: accumulator.count, reason: "container_unavailable"))
            FileLogger.shared.warn(.audio, "Chunk splitter accumulator spill unavailable; retaining audio in memory")
            return
        }
        let url = container.appendingPathComponent("chunk-splitter-accumulator-\(UUID().uuidString).tmp")
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: sampleData(accumulator))
            spilledSampleCount = accumulator.count
            telemetrySink?.event(VADTelemetryEvent(kind: .spill, samples: accumulator.count, reason: "created"))
            accumulator.removeAll(keepingCapacity: false)
            accumulatorSpillURL = url
            accumulatorSpillHandle = handle
        } catch {
            try? FileManager.default.removeItem(at: url)
            telemetrySink?.event(VADTelemetryEvent(kind: .spill, samples: accumulator.count, reason: "create_failed"))
            FileLogger.shared.warn(.audio, "Chunk splitter accumulator spill failed; retaining audio in memory")
        }
    }

    private func assembledAccumulator() -> [Float] {
        guard let url = accumulatorSpillURL else {
            return accumulator
        }
        try? accumulatorSpillHandle?.synchronize()
        try? accumulatorSpillHandle?.close()
        accumulatorSpillHandle = nil
        guard let data = try? Data(contentsOf: url) else { return accumulator }
        let spilled = data.withUnsafeBytes { $0.bindMemory(to: Float.self) }
        var samples: [Float] = []
        samples.reserveCapacity(spilled.count + accumulator.count)
        samples.append(contentsOf: spilled)
        samples.append(contentsOf: accumulator)
        return samples
    }

    /// Emit the retained accumulator, carrying post-roll-trimmed silence into the next span.
    func emit(
        reason: String,
        silenceMs: Double,
        speechMs: Double,
        endpointState: String,
        trimToPostRoll: Bool = false
    ) -> VADEmission {
        var snapshot = assembledAccumulator()
        let id = chunkId
        var sampleCount = accumulatorSampleCount
        let startSamples = chunkStartSessionSamples ?? (sessionElapsedSamples - sampleCount)
        var sourceEndSamples = chunkEndSessionSamples ?? sessionElapsedSamples
        if trimToPostRoll {
            let trailingSamples = min(contiguousTrailingSilenceSamples, sampleCount)
            let excessTrailingSamples = max(0, trailingSamples - postRollSamples)
            let retainedTailSamples = min(excessTrailingSamples, snapshot.count)
            if retainedTailSamples > 0 {
                let trimmedTail = Array(snapshot.suffix(retainedTailSamples))
                snapshot.removeLast(retainedTailSamples)
                sampleCount -= retainedTailSamples
                sourceEndSamples -= retainedTailSamples
                // Keep the post-roll-trimmed silence contiguous with the next chunk.
                retainedGapBuffer = trimmedTail
                retainedGapStartSessionSamples = sourceEndSamples
                retainedGapEvidenceSamples = 0
                retainedGapPeakAboveFloorDb = contiguousTrailingSilencePeakAboveFloorDb
            }
        }
        let emittedTotalMs = Double(sampleCount) / 16.0
        let startMs = Double(startSamples) / 16.0
        // Preserve legacy count-based endMs; sourceEndSamples is gap-aware.
        let endMs = startMs + Double(sampleCount) / 16.0
        chunkId &+= 1
        pendingEmissionSummary = EmissionSummary(
            chunkId: id,
            reason: reason,
            silenceMs: silenceMs,
            totalMs: emittedTotalMs,
            speechMs: speechMs
        )
        clearAccumulator()
        contiguousTrailingSilenceSamples = 0
        contiguousTrailingSilenceMinimumDb = nil
        contiguousTrailingSilencePeakAboveFloorDb = nil
        chunkStartSessionSamples = nil
        silenceSamples = 0
        speechSamples = 0
        endpoint.reset()
        sawReanchorDuringUtterance = false
        bufferHighWaterSamples = retainedGapBuffer.count
        utteranceQuietestStrongDb = nil
        loudFlatStreakMs = 0
        loudFlatStreakStartSeconds = nil
        loudFlatTerminatorActive = false
        telemetrySink?.event(VADTelemetryEvent(
            kind: .emit,
            chunkId: id,
            samples: sampleCount,
            reason: reason,
            speechMs: speechMs,
            totalMs: emittedTotalMs,
            startMs: startMs,
            endMs: endMs,
            sourceStartSample: startSamples,
            sourceEndSample: sourceEndSamples,
            endpointState: endpointState
        ))
        if retainedGapBuffer.count > maxNoiseSamples, !retainedGapHasSpeechEvidence {
            shedRetainedGap()
        }
        return VADEmission(chunkId: id, samples: snapshot)
    }

    /// Flush every retained stop tail of at least 250 ms, regardless of voice evidence.
    func flush() -> VADEmission? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        loudFlatStreakMs = 0
        loudFlatStreakStartSeconds = nil
        loudFlatTerminatorActive = false
        let decisionTimeEndpointState = endpoint.state.rawValue
        moveRetainedGapToAccumulator()
        finishIdleGapRun()
        _ = endpoint.forceFinalize(kind: .stop)
        let sampleCount = accumulatorSampleCount
        let trailingSpeechMs = Double(speechSamples) / 16.0
        let startSamples = chunkStartSessionSamples ?? (sessionElapsedSamples - sampleCount)
        let sourceEndSamples = chunkEndSessionSamples ?? sessionElapsedSamples
        let startMs = Double(startSamples) / 16.0
        let endMs = startMs + Double(sampleCount) / 16.0
        let flushReason: String
        if accumulatorSampleCount == 0 {
            flushReason = primingComplete ? "empty" : "priming_window"
        } else if sampleCount < 250 * 16 {
            flushReason = "tail_floor"
        } else {
            flushReason = "flush"
        }
        telemetrySink?.event(VADTelemetryEvent(
            kind: .stopFlush,
            samples: sampleCount,
            reason: flushReason,
            speechMs: trailingSpeechMs,
            totalMs: Double(sampleCount) / 16.0,
            startMs: sampleCount > 0 ? startMs : nil,
            endMs: endMs,
            timestampMs: Double(sessionElapsedSamples) / 16.0,
            wallTimestampMs: Date().timeIntervalSince1970 * 1_000.0,
            sourceStartSample: sampleCount > 0 ? startSamples : nil,
            sourceEndSample: sampleCount > 0 ? sourceEndSamples : nil,
            endpointState: decisionTimeEndpointState
        ))
        if !primingComplete, accumulatorSampleCount == 0 { return nil }
        guard accumulatorSampleCount > 0 else { return nil }
        // Sub-250 ms cannot contain an intelligible word, so the tail floor
        // prevents hallucinated tokens.
        guard sampleCount >= 250 * 16 else {
            recordDiscard(
                samples: sampleCount,
                reason: "tail_floor",
                sourceStartSample: startSamples,
                sourceEndSample: sourceEndSamples
            )
            FileLogger.shared.debug(.audio, "Chunk splitter: flush dropped sub-250 ms tail",
                                    payload: ["sampleCount": sampleCount])
            clearAccumulator()
            chunkStartSessionSamples = nil
            speechSamples = 0
            silenceSamples = 0
            bufferHighWaterSamples = 0
            return nil
        }
        FileLogger.shared.info(.audio, "Chunk splitter: stop → emit",
                               payload: ["count": accumulatorSampleCount])
        if speechSamples > 0 {
            gate.noteUtteranceEnded(
                quietestStrongDb: utteranceQuietestStrongDb,
                trailingSilenceDb: contiguousTrailingSilenceMinimumDb
            )
        }
        return emit(reason: "flush",
                    silenceMs: Double(contiguousTrailingSilenceSamples) / 16.0,
                    speechMs: Double(speechSamples) / 16.0,
                    endpointState: decisionTimeEndpointState)
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

/// Captures microphone audio via `AVAudioEngine`, runs a level- and shape-based voice detector
/// state machine, and emits pause-bounded float32 PCM chunks via a callback.
///
/// Chunks are delivered as `[Float]` at 16 kHz mono, one chunk per detected
/// speech segment. The caller should forward them to a Whisper streaming server
/// (e.g. via WebSocket).
///
/// ## Thread safety
/// The audio-tap callback runs on a real-time audio thread. The callback is
/// minimal — it reads the buffer, copies samples, and dispatches all heavy
/// work (RMS, voice detection, chunk emission) to a dedicated serial `vadQueue`. Detector
/// state is protected internally by `os_unfair_lock`.
actor StreamingAudioRecorder {
    typealias ChunkHandler = @Sendable (UInt32, [Float]) -> Void

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private var isRecording = false
    private var onChunk: ChunkHandler?
    private var onChunkSplitterState: ((ChunkSplitterFrameState) -> Void)?

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

    /// Route changes reset the voice detector baseline and analysis filter without touching
    /// the captured PCM stream.
    private var routeChangeObserver: NSObjectProtocol?

    /// Serial queue for audio processing off the real-time audio thread.
    private let vadQueue = DispatchQueue(label: "com.ritoras.chunk-splitter", qos: .userInitiated)

    /// Voice detector state machine; accessed only via `process()`/`flush()` which lock internally.
    private let vad: VADContext
    private let vadGateConfig: VADGateConfig
    private var telemetryFlushable: VADTelemetryFlushable?

    // MARK: - Initialization

    init() {
        let silenceSamples = Int(Double(SharedConfig.chunkSplitterSilenceMs()) * 16.0)
        let minSpeechSamples = Int(Double(SharedConfig.streamVadMinSpeechMs()) * 16.0)
        let minChunkSamples = Int(Double(SharedConfig.streamVadMinChunkMs()) * 16.0)
        let maxNoiseSamples = Int(SharedConfig.streamVadMaxNoiseSec() * 16000.0)
        let vadGateConfig = VADGateConfig(
            mode: SharedConfig.streamVadMode(),
            staticRms: SharedConfig.streamVadSpeechRms(),
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb(),
            adaptiveAbsoluteSpeechFloorDb: SharedConfig.streamVadAbsoluteSpeechFloorDb(),
            adaptiveRiseSpeedMultiplier: 1.0,
            adaptiveSilenceDeltaDb: SharedConfig.streamVadAdaptiveSilenceDeltaDb(),
            ceilingMarginDb: SharedConfig.streamVadCeilingMarginDb(),
            adaptiveStaleFloorSeconds: SharedConfig.streamVadStaleFloorSeconds(),
            adaptiveFallTauSeconds: SharedConfig.streamVadFallTauSeconds(),
            adaptiveDynamicsEnabled: SharedConfig.streamVadDynamicsEnabled(),
            adaptiveDynamicsSpreadDb: SharedConfig.streamVadDynamicsSpreadDb(),
            adaptiveFlatSpreadDb: SharedConfig.streamVadFlatSpreadDb(),
            loudRegimeEnabled: SharedConfig.streamVadLoudRegimeEnabled(),
            loudRegimeEnterDb: SharedConfig.streamVadLoudFloorRegimeEnterDb(),
            loudRegimeExitDb: SharedConfig.streamVadLoudFloorRegimeExitDb(),
            loudRegimeEnterMs: SharedConfig.streamVadLoudRegimeEnterMs(),
            loudRegimeExitMs: SharedConfig.streamVadLoudRegimeExitMs(),
            loudStrongDeltaDb: SharedConfig.streamVadLoudStrongDeltaDb(),
            loudContinuationDeltaDb: SharedConfig.streamVadLoudContinuationDeltaDb(),
            loudSilenceDeltaDb: SharedConfig.streamVadLoudSilenceDeltaDb(),
            loudRiseDbPerSec: SharedConfig.streamVadLoudRiseDbPerSec(),
            loudDynamicsSpreadDb: SharedConfig.streamVadLoudDynamicsSpreadDb(),
            whisperHighBandRatioDb: SharedConfig.streamVadWhisperHighBandRatioDb()
        )
        self.vadGateConfig = vadGateConfig
        vad = VADContext(
            gateConfig: vadGateConfig,
            silenceThresholdSamples: silenceSamples,
            minSpeechSamples: minSpeechSamples,
            minChunkSamples: minChunkSamples,
            maxNoiseSamples: maxNoiseSamples,
            endpointMachineEnabled: SharedConfig.streamEndpointMachineEnabled(),
            loudFlatSpreadDb: SharedConfig.streamVadLoudFlatSpreadDb(),
            loudFlatTerminateSeconds: SharedConfig.streamVadLoudFlatTerminateSeconds(),
            loudFlatTerminateEnabled: SharedConfig.streamVadLoudFlatTerminateEnabled(),
            analysisHpfEnabled: SharedConfig.streamVadAnalysisHpfEnabled(),
            analysisHpfCutoffHz: SharedConfig.Defaults.streamVadHpfCutoffHzDefault
        )
    }

    // MARK: - Start

    /// Begins streaming audio capture.
    ///
    /// - Parameter onChunk: Called on vadQueue for each detected speech
    ///   segment. The first argument is a monotonically increasing chunk ID
    ///   (starting at 0); the second is float32 PCM samples at 16 kHz mono.
    /// - Parameter onChunkSplitterState: Called on vadQueue after each processed audio
    ///   frame with the current detector and endpoint state.
    /// - Parameter telemetry: Optional per-frame chunk splitter telemetry sink. Telemetry
    ///   callbacks run on vadQueue and are disabled when this is `nil`.
    /// - Throws: `AudioRecorder.AudioRecorderError.permissionDenied` or `.permissionNotRequested`
    ///   if mic access is unavailable; `AudioRecorder.AudioRecorderError.invalidSessionConfiguration`
    ///   if session setup fails; `StreamingRecorderError.engineStartFailed` if
    ///   the audio engine cannot start.
    func start(fileURL: URL? = nil, onChunk: @escaping ChunkHandler, onChunkSplitterState: ((ChunkSplitterFrameState) -> Void)? = nil, telemetry: VADTelemetrySink? = nil) async throws {
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

        var startCompleted = false
        defer {
            if !startCompleted {
                teardownEngine()
                self.onChunk = nil
                self.onChunkSplitterState = nil
                isRecording = false
                AudioSession.deactivate()
            }
        }

        self.onChunk = onChunk
        self.onChunkSplitterState = onChunkSplitterState
        self.telemetryFlushable = telemetry as? VADTelemetryFlushable
        vad.setTelemetrySink(telemetry)

        // 3. Build the 16 kHz mono target format (converter output)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            FileLogger.shared.logDurable(.error, .audio, "CRASH-PROOF: Could not create 16kHz mono float32 audio format")
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
            FileLogger.shared.logDurable(.error, .audio, "CRASH-PROOF: Audio input unavailable (no microphone route)")
            throw StreamingRecorderError.engineStartFailed(
                NSError(domain: "StreamingAudioRecorder", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio input unavailable (no microphone route)"])
            )
        }
        guard nativeFormat.channelCount >= 1 else {
            FileLogger.shared.logDurable(.error, .audio, "CRASH-PROOF: Audio input has no channels")
            throw StreamingRecorderError.nativeFormatUnavailable(
                "Input node has \(nativeFormat.channelCount) channels"
            )
        }

        // Capture references for the closure (no actor self capture).
        let handler = onChunk
        let stateHandler = onChunkSplitterState
        let vad = self.vad
        let vadQueue = self.vadQueue
        let telemetryFlushable = self.telemetryFlushable
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
                    telemetryFlushable: telemetryFlushable,
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
            throw StreamingRecorderError.engineStartFailed(error)
        }

        vadQueue.sync {
            telemetryFlushable?.flush()
        }

        isRecording = true
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { _ in
            vad.resetAfterRouteChange()
        }

        var startedPayload: [String: Any] = [
            "rms": vadGateConfig.staticRms,
            "mode": vadGateConfig.mode.rawValue,
            "silenceMs": SharedConfig.chunkSplitterSilenceMs(),
            "minSpeechMs": SharedConfig.streamVadMinSpeechMs(),
            "minChunkMs": SharedConfig.streamVadMinChunkMs(),
            "maxNoiseSec": SharedConfig.streamVadMaxNoiseSec(),
            "analysisHpf": SharedConfig.streamVadAnalysisHpfEnabled(),
            "hpfCutoffHz": SharedConfig.Defaults.streamVadHpfCutoffHzDefault
        ]
        switch vadGateConfig.mode {
        case .staticMode:
            break
        case .adaptive:
            startedPayload["deltaDb"] = vadGateConfig.adaptiveDeltaDb
        }
        FileLogger.shared.info(.audio, "Started", payload: startedPayload)
        startCompleted = true
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
        stateHandler: ((ChunkSplitterFrameState) -> Void)?,
        telemetryFlushable: VADTelemetryFlushable?,
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
        telemetryFlushable?.flushIfNeeded()

        if let stateHandler = stateHandler {
            let emissionSummary = vad.takePendingEmissionSummary()
            stateHandler(vad.frameState(emissionSummary: emissionSummary))
        }

        // Emit chunk if ready (handler runs synchronously on vadQueue)
        if let emission = emission {
            FileLogger.shared.debug(.audio, "Chunk splitter: emission",
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
        let stateHandler = self.onChunkSplitterState
        let stoppedFlag = self.stoppedFlag
        let accounting = self.accounting
        let telemetryFlushable = self.telemetryFlushable
        let emission: VADEmission? = await withCheckedContinuation { continuation in
            vadQueue.async {
                stoppedFlag.set(true)
                let result = vad.flush()
                vad.endTelemetrySession()
                telemetryFlushable?.flush()
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

        vad.setTelemetrySink(nil)
        self.telemetryFlushable = nil
        onChunk = nil
        onChunkSplitterState = nil

        FileLogger.shared.info(.audio, "Stopped")
    }
}
