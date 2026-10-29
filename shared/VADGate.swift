import Foundation
import os

// These VAD types are intentionally top-level rather than nested in SharedConfig.
// Keeping the pure-logic gate self-contained mirrors scripts/prediction-sim/lib/vad-gate.mjs.

enum VADMode: String, CaseIterable {
    case staticMode = "static"
    case adaptive = "adaptive"
}

enum VADEvidence: String {
    case strong
    case continuing
    case ambiguous
    case silence
}

struct VADGateConfig {
    let mode: VADMode
    let staticRms: Float
    let adaptiveDeltaDb: Double
    let adaptiveContinuationDeltaDb: Double
    let adaptiveAbsoluteSpeechFloorDb: Double
    let adaptiveRiseSpeedMultiplier: Double
    let adaptiveSilenceDeltaDb: Double
    let ceilingMarginDb: Double
    let adaptiveStaleFloorSeconds: Double
    let adaptiveFallTauSeconds: Double
    let adaptiveDynamicsEnabled: Bool
    let adaptiveDynamicsSpreadDb: Double
    let adaptiveFlatSpreadDb: Double
    let loudRegimeEnabled: Bool
    let loudRegimeEnterDb: Double
    let loudRegimeExitDb: Double
    let loudRegimeEnterMs: Int
    let loudRegimeExitMs: Int
    let loudStrongDeltaDb: Double
    let loudContinuationDeltaDb: Double
    let loudSilenceDeltaDb: Double
    let loudRiseDbPerSec: Double
    let loudDynamicsSpreadDb: Double
    let primingMaximumSeconds: Double
    let primingQuietSeedSeconds: Double
    let whisperHighBandRatioDb: Double

    init(
        mode: VADMode,
        staticRms: Float,
        adaptiveDeltaDb: Double,
        adaptiveContinuationDeltaDb: Double,
        adaptiveAbsoluteSpeechFloorDb: Double,
        adaptiveRiseSpeedMultiplier: Double,
        adaptiveSilenceDeltaDb: Double,
        ceilingMarginDb: Double = SharedConfig.Defaults.streamVadCeilingMarginDbDefault,
        adaptiveStaleFloorSeconds: Double,
        adaptiveFallTauSeconds: Double,
        adaptiveDynamicsEnabled: Bool,
        adaptiveDynamicsSpreadDb: Double,
        adaptiveFlatSpreadDb: Double,
        loudRegimeEnabled: Bool = true,
        loudRegimeEnterDb: Double = -35.0,
        loudRegimeExitDb: Double = -38.0,
        loudRegimeEnterMs: Int = 300,
        loudRegimeExitMs: Int = 1_000,
        loudStrongDeltaDb: Double = 7.0,
        loudContinuationDeltaDb: Double = 3.0,
        loudSilenceDeltaDb: Double = 2.0,
        loudRiseDbPerSec: Double = 12.0,
        loudDynamicsSpreadDb: Double = 9.0,
        primingMaximumSeconds: Double = 0.45,
        primingQuietSeedSeconds: Double = 0.10,
        whisperHighBandRatioDb: Double = SharedConfig.Defaults
            .streamVadWhisperHighBandRatioDbDefault
    ) {
        self.mode = mode
        self.staticRms = staticRms
        self.adaptiveDeltaDb = adaptiveDeltaDb
        self.adaptiveContinuationDeltaDb = adaptiveContinuationDeltaDb
        self.adaptiveAbsoluteSpeechFloorDb = adaptiveAbsoluteSpeechFloorDb
        self.adaptiveRiseSpeedMultiplier = adaptiveRiseSpeedMultiplier
        self.adaptiveSilenceDeltaDb = adaptiveSilenceDeltaDb
        self.ceilingMarginDb = ceilingMarginDb
        self.adaptiveStaleFloorSeconds = adaptiveStaleFloorSeconds
        self.adaptiveFallTauSeconds = adaptiveFallTauSeconds
        self.adaptiveDynamicsEnabled = adaptiveDynamicsEnabled
        self.adaptiveDynamicsSpreadDb = adaptiveDynamicsSpreadDb
        self.adaptiveFlatSpreadDb = adaptiveFlatSpreadDb
        self.loudRegimeEnabled = loudRegimeEnabled
        self.loudRegimeEnterDb = loudRegimeEnterDb
        self.loudRegimeExitDb = loudRegimeExitDb
        self.loudRegimeEnterMs = loudRegimeEnterMs
        self.loudRegimeExitMs = loudRegimeExitMs
        self.loudStrongDeltaDb = loudStrongDeltaDb
        self.loudContinuationDeltaDb = loudContinuationDeltaDb
        self.loudSilenceDeltaDb = loudSilenceDeltaDb
        self.loudRiseDbPerSec = loudRiseDbPerSec
        self.loudDynamicsSpreadDb = loudDynamicsSpreadDb
        self.primingMaximumSeconds = primingMaximumSeconds
        self.primingQuietSeedSeconds = primingQuietSeedSeconds
        self.whisperHighBandRatioDb = whisperHighBandRatioDb
    }
}

struct VADGateOutput {
    let isSpeech: Bool
    let evidence: VADEvidence
    let speechShaped: Bool
    let thresholdDb: Double
    let continuationThresholdDb: Double
    let silenceThresholdDb: Double
    let floorDb: Double?
    let floorConverged: Bool
    let dynamicsSpreadDb: Double?
    let shortSpreadDb: Double?
    let highBandRatioDb: Double?
    let isLoudRegime: Bool
    let didReanchor: Bool
    let didCompletePriming: Bool
    let primingDurationSeconds: Double
    let primingEndedAtCap: Bool
}

final class VADThresholdGate: @unchecked Sendable {
    // Fixed algorithm constants. They are intentionally not user-facing settings.
    static let adaptiveEndPendingWindDispersionDb = 6.0
    // Telemetry puts normal/quiet dictation floors around -35…-55 dB and genuinely
    // loud ambient floors around -24…-34 dB. Real speech crests 10–20 dB above
    // its p10 and can pass the strict loud rule while bounded noise wobble cannot.
    static let loudFloorRegimeDb = -35.0
    static let adaptiveImplausibleSpeechSeconds = 8.0
    private static let staticContinuationOffsetDb = 4.0
    private static let staticSilenceOffsetDb = 6.0
    private static let elevatedRiseDbPerSecond = 12.0
    private static let speechCeilingQualificationMarginDb = 2.0
    private static let adaptiveColdStartSpeechShapeMarginDb = 2.0
    // Bound the utterance-end correction and keep the residual breath bump from undoing it.
    private static let utteranceEndFloorReseedMaximumDropDb = 4.0
    private static let utteranceEndFloorRiseHoldSeconds = 1.2
    private static let adaptiveColdStartGraceSeconds = 0.4
    private static let adaptiveColdStartDispersionWindowSeconds = 0.4
    // Keep shape evidence local so a completed speech tail cannot hold quiet open.
    private static let speechShapeWindowSeconds = 0.1
    private static let whisperContextSeconds =
        SharedConfig.Defaults.streamVadWhisperContextMsDefault / 1_000.0
    private static let adaptiveRollingWindowDuration = 3.0
    private static let adaptiveRollingWindowCapacity = 256
    private static let floorMinDb = -80.0
    private static let floorMaxDb = -20.0
    private static let adaptiveRollingPercentile = 0.1
    private static let adaptiveFloorMovementEpsilonDb = 1e-6
    private static let timeBoundaryEpsilon = 1e-9

    private let config: VADGateConfig
    var loudRegimeEnabled: Bool { config.loudRegimeEnabled }
    let effectiveAdaptiveDeltaDb: Double
    private let effectiveAdaptiveContinuationDeltaDb: Double
    let effectiveAbsoluteSpeechFloorDb: Double
    let effectiveCeilingMarginDb: Double
    private let effectiveSilenceDeltaDb: Double
    private let effectiveRiseSpeedMultiplier: Double
    private let effectiveStaleFloorSeconds: Double
    private let effectiveFallTauSeconds: Double
    let effectiveDynamicsSpreadDb: Double
    let effectiveFlatSpreadDb: Double
    private let effectiveWhisperHighBandRatioDb: Double
    private let effectiveLoudStrongDeltaDb: Double
    private let effectiveLoudContinuationDeltaDb: Double
    private let effectiveLoudSilenceDeltaDb: Double
    private var behaviorMode: VADMode
    private var adaptiveRefinementElapsed = 0.0
    private var adaptivePrimingElapsed = 0.0
    private var adaptivePrimingQuietElapsed = 0.0
    private var adaptivePrimed = false
    private var adaptiveRefinementComplete: Bool
    private var coldStartSpeechShapedNow = false
    private var coldStartConverged = false
    private var floorDb: Double?
    private var thresholdDb: Double
    private var pendingReanchorEvent = false
    private var hasLoggedReanchorRefusal = false
    private var hasRefusedReanchorSinceLastAcceptance = false
    private var elapsedSinceSilenceEvidence = 0.0
    private var adaptiveRollingDbs: [Double] = []
    private var adaptiveRollingDurations: [Double] = []
    private var adaptiveRollingFloorEligible: [Bool] = []
    private var adaptiveRollingWriteIndex = 0
    private var adaptiveRollingCount = 0
    private var adaptiveRollingElapsed = 0.0
    private var adaptiveRollingPercentileCache: Double?
    private var adaptiveSignalPercentileCache: Double?
    private var adaptiveSignalFallbackActive = false
    private var implausibleSpeechFallbackActive = false
    private var implausibleFallbackSuspendsSpeechCeiling = false
    private var floorRiseAppliedThisFrameDb = 0.0
    private var floorMovementAppliedThisFrame = false
    private var floorRiseSuppressionRemainingSeconds = 0.0
    private var lastKnownMachineIsIdle = true
    private var speechCeilingDb: Double?
    private var utteranceSpeechLevelDb: Double?
    private var isLoudRegime = false
    private var loudRegimeEnterElapsed = 0.0
    private var loudRegimeExitElapsed = 0.0
    private var frameHighBandRatioDb: Double?
    private var frameWithinUtteranceContext = false
    private var whisperSpeechContextRemainingSeconds = 0.0
    private var whisperModulationObserved = false
    private var unfairLock = os_unfair_lock()
    private var lastOutput: VADGateOutput

    init(config: VADGateConfig) {
        let clamp: (Double, Double, Double) -> Double = { value, lower, upper in
            min(max(value, lower), upper)
        }
        let effectiveAdaptiveDeltaDb = clamp(config.adaptiveDeltaDb, 3.0, 24.0)
        let effectiveAdaptiveContinuationDeltaDb = clamp(
            config.adaptiveContinuationDeltaDb,
            2.0,
            effectiveAdaptiveDeltaDb - 1.0
        )
        let effectiveAbsoluteSpeechFloorDb = clamp(config.adaptiveAbsoluteSpeechFloorDb, -80.0, -30.0)
        let effectiveCeilingMarginDb = clamp(config.ceilingMarginDb, 0.0, 24.0)
        let effectiveSilenceDeltaDb = clamp(
            config.adaptiveSilenceDeltaDb,
            1.0,
            min(5.0, effectiveAdaptiveContinuationDeltaDb - 1.0)
        )
        let effectiveRiseSpeedMultiplier = clamp(config.adaptiveRiseSpeedMultiplier, 0.5, 4.0)
        let effectiveStaleFloorSeconds = clamp(config.adaptiveStaleFloorSeconds, 0.5, 10.0)
            / effectiveRiseSpeedMultiplier
        let effectiveFallTauSeconds = clamp(config.adaptiveFallTauSeconds, 0.2, 2.0)
        let effectiveDynamicsSpreadDb = clamp(config.adaptiveDynamicsSpreadDb, 6.0, 24.0)
        let effectiveFlatSpreadDb = clamp(config.adaptiveFlatSpreadDb, 3.0, 8.0)
        let effectiveWhisperHighBandRatioDb = clamp(config.whisperHighBandRatioDb, -30.0, 0.0)
        let effectiveLoudStrongDeltaDb = min(
            effectiveAdaptiveDeltaDb,
            clamp(config.loudStrongDeltaDb, 3.0, 24.0)
        )
        let effectiveLoudContinuationDeltaDb = min(
            min(
                effectiveAdaptiveContinuationDeltaDb,
                clamp(config.loudContinuationDeltaDb, 2.0, effectiveAdaptiveDeltaDb - 1.0)
            ),
            effectiveLoudStrongDeltaDb - 1.0
        )
        let effectiveLoudSilenceDeltaDb = min(
            effectiveSilenceDeltaDb,
            clamp(config.loudSilenceDeltaDb, 1.0, min(5.0, effectiveLoudContinuationDeltaDb - 1.0))
        )
        let initialFloorDb: Double? = config.mode == .adaptive ? Self.floorMinDb : nil
        let initialThresholdDb = config.mode == .adaptive
            ? max(Self.floorMinDb + effectiveAdaptiveDeltaDb, effectiveAbsoluteSpeechFloorDb)
            : Double(AudioMath.dbFromRms(config.staticRms))
        self.config = config
        self.effectiveAdaptiveDeltaDb = effectiveAdaptiveDeltaDb
        self.effectiveAdaptiveContinuationDeltaDb = effectiveAdaptiveContinuationDeltaDb
        self.effectiveAbsoluteSpeechFloorDb = effectiveAbsoluteSpeechFloorDb
        self.effectiveCeilingMarginDb = effectiveCeilingMarginDb
        self.effectiveSilenceDeltaDb = effectiveSilenceDeltaDb
        self.effectiveRiseSpeedMultiplier = effectiveRiseSpeedMultiplier
        self.effectiveStaleFloorSeconds = effectiveStaleFloorSeconds
        self.effectiveFallTauSeconds = effectiveFallTauSeconds
        self.effectiveDynamicsSpreadDb = effectiveDynamicsSpreadDb
        self.effectiveFlatSpreadDb = effectiveFlatSpreadDb
        self.effectiveWhisperHighBandRatioDb = effectiveWhisperHighBandRatioDb
        self.effectiveLoudStrongDeltaDb = effectiveLoudStrongDeltaDb
        self.effectiveLoudContinuationDeltaDb = effectiveLoudContinuationDeltaDb
        self.effectiveLoudSilenceDeltaDb = effectiveLoudSilenceDeltaDb
        self.behaviorMode = config.mode
        self.adaptiveRefinementComplete = config.mode != .adaptive
        self.floorDb = initialFloorDb
        self.thresholdDb = initialThresholdDb
        self.adaptiveRollingPercentileCache = nil
        self.lastOutput = VADGateOutput(
            isSpeech: false,
            evidence: .silence,
            speechShaped: false,
            thresholdDb: initialThresholdDb,
            continuationThresholdDb: config.mode == .adaptive
                ? max(Self.floorMinDb + effectiveAdaptiveContinuationDeltaDb, effectiveAbsoluteSpeechFloorDb)
                : initialThresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: config.mode == .adaptive
                ? Self.floorMinDb + effectiveSilenceDeltaDb
                : initialThresholdDb - Self.staticSilenceOffsetDb,
            floorDb: initialFloorDb,
            floorConverged: false,
            dynamicsSpreadDb: nil,
            shortSpreadDb: nil,
            highBandRatioDb: nil,
            isLoudRegime: false,
            didReanchor: false,
            didCompletePriming: false,
            primingDurationSeconds: 0,
            primingEndedAtCap: false
        )
        adaptiveRollingDbs = Array(repeating: 0, count: Self.adaptiveRollingWindowCapacity)
        adaptiveRollingDurations = Array(repeating: 0, count: Self.adaptiveRollingWindowCapacity)
        adaptiveRollingFloorEligible = Array(repeating: false, count: Self.adaptiveRollingWindowCapacity)
    }

    func process(
        frameDb: Double,
        frameDuration: Double,
        highBandRatioDb: Double? = nil,
        withinUtteranceContext: Bool = false
    ) -> VADGateOutput {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        floorRiseAppliedThisFrameDb = 0
        floorMovementAppliedThisFrame = false
        frameHighBandRatioDb = highBandRatioDb.flatMap { $0.isFinite ? $0 : nil }
        frameWithinUtteranceContext = withinUtteranceContext
        whisperModulationObserved = false
        let output: VADGateOutput
        switch behaviorMode {
        case .staticMode:
            output = processStatic(frameDb: frameDb, frameDuration: frameDuration)
        case .adaptive:
            output = processAdaptive(frameDb: frameDb, frameDuration: frameDuration)
        }
        whisperSpeechContextRemainingSeconds = whisperModulationObserved
            ? Self.whisperContextSeconds
            : max(0, whisperSpeechContextRemainingSeconds - max(0, frameDuration))
        return output
    }

    var snapshot: VADGateOutput {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return lastOutput
    }

    var secondsSinceSilenceEvidence: Double {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return elapsedSinceSilenceEvidence
    }

    /// Returns the normalized parameters used by the gate, without exposing
    /// mutable threshold state.
    var effectiveParameters: [String: Any] {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return [
            "mode": behaviorMode.rawValue,
            "strongDeltaDb": effectiveAdaptiveDeltaDb,
            "continuationDeltaDb": effectiveAdaptiveContinuationDeltaDb,
            "absoluteSpeechFloorDb": effectiveAbsoluteSpeechFloorDb,
            "silenceDeltaDb": effectiveSilenceDeltaDb,
            "dynamicsSpreadDb": effectiveDynamicsSpreadDb,
            "flatSpreadDb": effectiveFlatSpreadDb,
            "whisperHighBandRatioDb": effectiveWhisperHighBandRatioDb,
            "dynamicsEnabled": config.adaptiveDynamicsEnabled,
            "loudRegimeEnabled": config.loudRegimeEnabled,
            "loudRegimeEnterDb": config.loudRegimeEnterDb,
            "loudRegimeExitDb": config.loudRegimeExitDb,
            "loudRegimeEnterMs": config.loudRegimeEnterMs,
            "loudRegimeExitMs": config.loudRegimeExitMs,
            "loudStrongDeltaDb": effectiveLoudStrongDeltaDb,
            "loudContinuationDeltaDb": effectiveLoudContinuationDeltaDb,
            "loudSilenceDeltaDb": effectiveLoudSilenceDeltaDb,
            "loudRiseDbPerSec": config.loudRiseDbPerSec,
            "loudDynamicsSpreadDb": config.loudDynamicsSpreadDb,
            "staleFloorSeconds": effectiveStaleFloorSeconds,
            "staleFloorSecondsRaw": config.adaptiveStaleFloorSeconds,
            "fallTauSeconds": effectiveFallTauSeconds,
            "riseMultiplier": effectiveRiseSpeedMultiplier,
            "riseSpeedMultiplier": effectiveRiseSpeedMultiplier
        ]
    }

    func takePendingReanchorEvent() -> Bool {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        let event = pendingReanchorEvent
        pendingReanchorEvent = false
        return event
    }

    func noteUtteranceEnded(quietestStrongDb: Double?, trailingSilenceDb: Double? = nil) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        guard behaviorMode == .adaptive else { return }
        // Headroom guard: trust an utterance's quietest strong frame as a speech
        // ceiling only when it clears the floor by delta + margin — the relation
        // the finalize path used to check retroactively. An utterance whose strong
        // evidence hugs the floor is ambient-shaped; adopting it would pin the
        // floor below ambient and wedge the endpointer in speechActive.
        if let quietestStrongDb,
           let floorDb,
           quietestStrongDb >= floorDb + effectiveAdaptiveDeltaDb + Self.speechCeilingQualificationMarginDb {
            speechCeilingDb = min(speechCeilingDb ?? quietestStrongDb, quietestStrongDb)
        }
        // Rejected or nil: keep the previous ceiling (idle decay still releases it).
        if let trailingSilenceDb, trailingSilenceDb.isFinite, let floorDb {
            if speechCeilingDb == nil {
                let lowestAllowedFloor = max(
                    Self.floorMinDb,
                    floorDb - Self.utteranceEndFloorReseedMaximumDropDb
                )
                let reseededFloor = min(
                    floorDb,
                    max(lowestAllowedFloor, clampFloor(trailingSilenceDb))
                )
                if reseededFloor < floorDb {
                    self.floorDb = reseededFloor
                    floorRiseSuppressionRemainingSeconds = Self.utteranceEndFloorRiseHoldSeconds
                } else {
                    floorRiseSuppressionRemainingSeconds = 0
                }
            } else {
                // Preserve headroom: a deeper floor could promote ambient evidence to strong.
                floorRiseSuppressionRemainingSeconds = 0
            }
        } else {
            floorRiseSuppressionRemainingSeconds = 0
        }
        utteranceSpeechLevelDb = nil
        implausibleSpeechFallbackActive = false
        implausibleFallbackSuspendsSpeechCeiling = false
        resetAdaptiveRollingWindow()
    }

    private func processStatic(frameDb: Double, frameDuration: Double) -> VADGateOutput {
        // Static evidence and floor behavior stay level-only; rolling history is
        // used only as a quiet-shape witness.
        appendAdaptiveRollingFrame(db: frameDb, duration: frameDuration)
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: thresholdDb,
            continuationThresholdDb: thresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: thresholdDb - Self.staticSilenceOffsetDb
        )
        return emit(
            evidence: levels.evidence,
            isSpeech: levels.evidence == .strong,
            speechShaped: levels.speechShaped,
            thresholdDb: thresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: nil
        )
    }

    private func processAdaptive(frameDb: Double, frameDuration: Double) -> VADGateOutput {
        var didReanchor = false
        var didCompletePriming = false
        var primingEndedAtCap = false
        appendAdaptiveRollingFrame(db: frameDb, duration: frameDuration)
        let signalPercentile = adaptiveSignalPercentile()
        adaptiveSignalPercentileCache = signalPercentile
        let windowMax = adaptiveRollingMaxDb(coverSeconds: Self.adaptiveColdStartDispersionWindowSeconds)
        let dispersionDb = (windowMax ?? frameDb) - (signalPercentile ?? frameDb)
        let shortSpreadDb: Double?
        if config.adaptiveDynamicsEnabled {
            let windowMin = adaptiveRollingMinDb(coverSeconds: Self.adaptiveColdStartDispersionWindowSeconds)
            shortSpreadDb = (windowMax ?? frameDb) - (windowMin ?? frameDb)
        } else {
            shortSpreadDb = nil
        }
        let adjacentStepDb = adaptiveRollingAdjacentStepDb()
        if !adaptiveRefinementComplete {
            return processAdaptiveRefinement(
                frameDb: frameDb,
                frameDuration: frameDuration,
                signalPercentile: signalPercentile,
                dispersionDb: dispersionDb,
                shortSpreadDb: shortSpreadDb
            )
        }

        guard let currentFloor = floorDb else {
            floorDb = Self.floorMinDb
            adaptiveRefinementComplete = false
            adaptiveRefinementElapsed = 0
            coldStartSpeechShapedNow = false
            coldStartConverged = false
            return processAdaptiveRefinement(
                frameDb: frameDb,
                frameDuration: frameDuration,
                signalPercentile: signalPercentile,
                dispersionDb: dispersionDb,
                shortSpreadDb: shortSpreadDb
            )
        }

        let thresholds = adaptiveThresholds(floor: currentFloor)
        var levels = classify(
            frameDb: frameDb,
            strongThresholdDb: thresholds.strong,
            continuationThresholdDb: thresholds.continuation,
            silenceThresholdDb: thresholds.silence,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb,
            adjacentStepDb: adjacentStepDb
        )
        if levels.evidence == .silence, frameDuration > 0 {
            markLatestAdaptiveRollingFrameAsFloorEligible()
        }
        adaptiveRollingPercentileCache = adaptiveRollingPercentile()
        if levels.evidence == .silence {
            elapsedSinceSilenceEvidence = 0
            implausibleSpeechFallbackActive = false
            implausibleFallbackSuspendsSpeechCeiling = false
        } else {
            elapsedSinceSilenceEvidence += max(0, frameDuration)
            let elapsedSinceSilenceEvidenceWithEpsilon = elapsedSinceSilenceEvidence
                + Self.timeBoundaryEpsilon
            let viaIdle = lastKnownMachineIsIdle
                && elapsedSinceSilenceEvidenceWithEpsilon >= effectiveStaleFloorSeconds
            let flatSignal = dispersionDb < effectiveFlatSpreadDb
                && (shortSpreadDb.map { $0 < effectiveFlatSpreadDb } ?? true)
            let viaStuckRun = !lastKnownMachineIsIdle
                && elapsedSinceSilenceEvidenceWithEpsilon >= Self.adaptiveImplausibleSpeechSeconds
                && flatSignal
            let wasImplausibleSpeechFallbackActive = implausibleSpeechFallbackActive
            if wasImplausibleSpeechFallbackActive && !viaStuckRun {
                elapsedSinceSilenceEvidence = 0
            }
            implausibleSpeechFallbackActive = viaStuckRun
            if !viaStuckRun {
                implausibleFallbackSuspendsSpeechCeiling = false
            }
            let floorAtInitClamp = currentFloor <= Self.floorMinDb + Self.adaptiveFloorMovementEpsilonDb
            if floorAtInitClamp || viaIdle || (viaStuckRun && !wasImplausibleSpeechFallbackActive),
               let target = adaptiveRollingPercentileCache ?? adaptiveSignalPercentileCache {
                let usesSignalFallback = adaptiveRollingPercentileCache == nil
                let elapsedBeforeReset = elapsedSinceSilenceEvidence
                let maximumReanchorFloor = Self.floorMaxDb - effectiveAdaptiveDeltaDb
                let refusesImplausibleFallbackTarget = viaStuckRun
                    && usesSignalFallback
                    && target > maximumReanchorFloor
                if refusesImplausibleFallbackTarget {
                    if !wasImplausibleSpeechFallbackActive {
                        elapsedSinceSilenceEvidence = 0
                        implausibleSpeechFallbackActive = false
                        implausibleFallbackSuspendsSpeechCeiling = false
                    }
                    hasRefusedReanchorSinceLastAcceptance = true
                    if !hasLoggedReanchorRefusal {
                        hasLoggedReanchorRefusal = true
                        FileLogger.shared.warn(.audio, "VAD: re-anchor refused")
                    }
                } else {
                    if !viaStuckRun { elapsedSinceSilenceEvidence = 0 }
                    let fallbackSpeechIsPlausible = utteranceSpeechLevelDb.map {
                        target >= $0 - effectiveDynamicsSpreadDb
                    } ?? false
                    implausibleFallbackSuspendsSpeechCeiling = viaStuckRun
                        && usesSignalFallback
                        && !fallbackSpeechIsPlausible
                    if implausibleFallbackSuspendsSpeechCeiling {
                        self.speechCeilingDb = nil
                        utteranceSpeechLevelDb = nil
                    }
                    let reanchoredFloor: Double
                    if implausibleFallbackSuspendsSpeechCeiling {
                        reanchoredFloor = clampFloor(target)
                    } else if let speechCeilingDb {
                        reanchoredFloor = clampFloor(min(
                            target,
                            speechCeilingDb - effectiveCeilingMarginDb
                        ))
                    } else {
                        reanchoredFloor = clampFloor(target)
                    }
                    if reanchoredFloor <= maximumReanchorFloor {
                        updateFloor(
                            targetDb: reanchoredFloor,
                            frameDuration: frameDuration,
                            maximumRiseDbPerSecond: maximumFloorRiseDbPerSecond,
                            enforceSpeechCeiling: !implausibleFallbackSuspendsSpeechCeiling
                        )
                        let appliedFloor = floorDb ?? currentFloor
                        let floorMoved = abs(appliedFloor - currentFloor)
                            > Self.adaptiveFloorMovementEpsilonDb
                        if viaStuckRun && floorMoved {
                            FileLogger.shared.warn(
                                .audio,
                                "VAD: stuck floor re-anchored after implausible speech run",
                                payload: ["floorDb": appliedFloor, "runSeconds": elapsedBeforeReset]
                            )
                        }
                        if floorMoved && !hasRefusedReanchorSinceLastAcceptance {
                            pendingReanchorEvent = true
                            didReanchor = true
                        }
                        adaptiveSignalFallbackActive = adaptiveSignalFallbackActive || usesSignalFallback
                        hasRefusedReanchorSinceLastAcceptance = false
                        let thresholds = adaptiveThresholds(floor: appliedFloor)
                        levels = classify(
                            frameDb: frameDb,
                            strongThresholdDb: thresholds.strong,
                            continuationThresholdDb: thresholds.continuation,
                            silenceThresholdDb: thresholds.silence,
                            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
                            shortSpreadDb: shortSpreadDb,
                            adjacentStepDb: adjacentStepDb
                        )
                        if levels.evidence == .silence, frameDuration > 0 {
                            elapsedSinceSilenceEvidence = 0
                            implausibleSpeechFallbackActive = false
                            implausibleFallbackSuspendsSpeechCeiling = false
                            markLatestAdaptiveRollingFrameAsFloorEligible()
                            adaptiveRollingPercentileCache = adaptiveRollingPercentile()
                        }
                    } else {
                        hasRefusedReanchorSinceLastAcceptance = true
                        if !hasLoggedReanchorRefusal {
                            hasLoggedReanchorRefusal = true
                            FileLogger.shared.warn(.audio, "VAD: re-anchor refused")
                        }
                    }
                }
            }
        }
        let evidence = dynamicsGatedEvidence(levels.evidence, dispersionDb: dispersionDb)
        (didCompletePriming, primingEndedAtCap) = updatePriming(
            frameDb: frameDb,
            strongThresholdDb: levels.strongThresholdDb,
            frameDuration: frameDuration
        )
        return emit(
            evidence: evidence,
            isSpeech: evidence == .strong || evidence == .continuing,
            speechShaped: levels.speechShaped,
            thresholdDb: levels.strongThresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: floorDb,
            floorConverged: coldStartConverged,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb,
            didReanchor: didReanchor,
            didCompletePriming: didCompletePriming,
            primingDurationSeconds: adaptivePrimingElapsed,
            primingEndedAtCap: primingEndedAtCap
        )
    }

    private func processAdaptiveRefinement(
        frameDb: Double,
        frameDuration: Double,
        signalPercentile: Double?,
        dispersionDb: Double,
        shortSpreadDb: Double?
    ) -> VADGateOutput {
        adaptiveRefinementElapsed += max(0, frameDuration)
        if floorDb == nil {
            floorDb = Self.floorMinDb
        }

        let initialThresholds = adaptiveThresholds(floor: floorDb ?? Self.floorMinDb)
        let initialLevels = classify(
            frameDb: frameDb,
            strongThresholdDb: initialThresholds.strong,
            continuationThresholdDb: initialThresholds.continuation,
            silenceThresholdDb: initialThresholds.silence,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb,
            adjacentStepDb: adaptiveRollingAdjacentStepDb()
        )
        if initialLevels.evidence == .silence, frameDuration > 0 {
            markLatestAdaptiveRollingFrameAsFloorEligible()
        }
        let rollingFloorPercentile = adaptiveRollingPercentile()
        adaptiveRollingPercentileCache = rollingFloorPercentile
        let seedTarget = rollingFloorPercentile ?? signalPercentile

        let shapedThresholdDb = config.adaptiveDynamicsEnabled
            ? effectiveDynamicsSpreadDb
            : effectiveAdaptiveDeltaDb + Self.adaptiveColdStartSpeechShapeMarginDb
        coldStartSpeechShapedNow = dispersionDb >= shapedThresholdDb

        if adaptiveRefinementElapsed >= Self.adaptiveColdStartGraceSeconds,
           let seedTarget {
            updateFloor(
                targetDb: seedTarget,
                frameDuration: frameDuration,
                maximumRiseDbPerSecond: maximumFloorRiseDbPerSecond
            )
            adaptiveSignalFallbackActive = adaptiveSignalFallbackActive
                || rollingFloorPercentile == nil
            if !coldStartConverged {
                coldStartConverged = true
                FileLogger.shared.info(
                    .audio,
                    "VAD: cold-start floor converged",
                    payload: ["floorDb": floorDb ?? NSNull()]
                )
            }
        }
        adaptiveRefinementComplete = coldStartConverged

        let currentFloor = floorDb ?? Self.floorMinDb
        let thresholds = adaptiveThresholds(floor: currentFloor)
        let adjacentStepDb = adaptiveRollingAdjacentStepDb()
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: thresholds.strong,
            continuationThresholdDb: thresholds.continuation,
            silenceThresholdDb: thresholds.silence,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb,
            adjacentStepDb: adjacentStepDb
        )
        if levels.evidence == .silence, frameDuration > 0 {
            markLatestAdaptiveRollingFrameAsFloorEligible()
            adaptiveRollingPercentileCache = adaptiveRollingPercentile()
        }
        let evidence = dynamicsGatedEvidence(
            levels.evidence,
            dispersionDb: shortSpreadDb ?? dispersionDb
        )
        let isSpeech = evidence == .strong || evidence == .continuing
        let (didCompletePriming, primingEndedAtCap) = updatePriming(
            frameDb: frameDb,
            strongThresholdDb: levels.strongThresholdDb,
            frameDuration: frameDuration
        )
        return emit(
            evidence: evidence,
            isSpeech: isSpeech,
            speechShaped: levels.speechShaped,
            thresholdDb: levels.strongThresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: currentFloor,
            floorConverged: coldStartConverged,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb,
            didCompletePriming: didCompletePriming,
            primingDurationSeconds: adaptivePrimingElapsed,
            primingEndedAtCap: primingEndedAtCap
        )
    }

    private func updatePriming(
        frameDb: Double,
        strongThresholdDb: Double,
        frameDuration: Double
    ) -> (didComplete: Bool, endedAtCap: Bool) {
        guard behaviorMode == .adaptive, !adaptivePrimed else { return (false, false) }
        let duration = max(0, frameDuration)
        adaptivePrimingElapsed = min(config.primingMaximumSeconds, adaptivePrimingElapsed + duration)
        if coldStartConverged && frameDb < strongThresholdDb {
            adaptivePrimingQuietElapsed += duration
        } else {
            adaptivePrimingQuietElapsed = 0
        }
        let endedAtCap = adaptivePrimingElapsed + Self.timeBoundaryEpsilon >= config.primingMaximumSeconds
        guard adaptivePrimingQuietElapsed >= config.primingQuietSeedSeconds || endedAtCap else {
            return (false, false)
        }
        adaptivePrimed = true
        return (true, endedAtCap && adaptivePrimingQuietElapsed < config.primingQuietSeedSeconds)
    }

    private func dynamicsGatedEvidence(_ evidence: VADEvidence, dispersionDb: Double) -> VADEvidence {
        let dynamicsSpreadDb = isLoudRegime
            ? max(0, config.loudDynamicsSpreadDb)
            : effectiveDynamicsSpreadDb
        guard config.adaptiveDynamicsEnabled,
              evidence == .strong,
              dynamicsSpreadDb > 0,
              dispersionDb < dynamicsSpreadDb else {
            return evidence
        }
        return .continuing
    }

    private func updateLoudRegime(duration: Double, machineIsIdle: Bool) {
        guard config.loudRegimeEnabled, let floorDb else { return }
        if floorDb >= config.loudRegimeEnterDb {
            loudRegimeEnterElapsed += max(0, duration)
            loudRegimeExitElapsed = 0
            if loudRegimeEnterElapsed * 1_000.0 >= Double(config.loudRegimeEnterMs) {
                isLoudRegime = true
            }
        } else if floorDb <= config.loudRegimeExitDb {
            loudRegimeEnterElapsed = 0
            if machineIsIdle {
                loudRegimeExitElapsed += max(0, duration)
                if loudRegimeExitElapsed * 1_000.0 >= Double(config.loudRegimeExitMs) {
                    isLoudRegime = false
                }
            } else {
                loudRegimeExitElapsed = 0
            }
        } else {
            loudRegimeEnterElapsed = 0
            loudRegimeExitElapsed = 0
        }
    }

    /// Updates the adaptive floor using current VAD evidence and silence-only
    /// percentile samples; a starved window never substitutes non-silence data.
    func updateFloorTracking(
        frameDb: Double,
        duration: Double,
        machineIsIdle: Bool = true,
        machineIsEnding: Bool = false
    ) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        let floorMovementAlreadyApplied = floorMovementAppliedThisFrame
        floorMovementAppliedThisFrame = false
        let wasMachineIsIdle = lastKnownMachineIsIdle
        lastKnownMachineIsIdle = machineIsIdle
        updateLoudRegime(duration: duration, machineIsIdle: machineIsIdle)
        guard behaviorMode == .adaptive else { return }
        let hasSpeechLikeEvidence = lastOutput.evidence == .strong || lastOutput.evidence == .continuing
        let tracksUtteranceSpeechLevel = frameWithinUtteranceContext
            && hasSpeechLikeEvidence
            && !implausibleSpeechFallbackActive
        if !tracksUtteranceSpeechLevel, (machineIsIdle || wasMachineIsIdle) {
            utteranceSpeechLevelDb = nil
        }
        let priorSpeechLevelDb = utteranceSpeechLevelDb
        let speechLevelIsPlausible = priorSpeechLevelDb.map {
            frameDb >= $0 - effectiveDynamicsSpreadDb
        } ?? true
        if tracksUtteranceSpeechLevel && speechLevelIsPlausible {
            if wasMachineIsIdle { utteranceSpeechLevelDb = nil }
            // Reject abrupt lower-level bursts; keep the quietest plausible speech sample as the ceiling.
            let speechLevel = min(utteranceSpeechLevelDb ?? frameDb, frameDb)
            utteranceSpeechLevelDb = speechLevel
            speechCeilingDb = min(speechCeilingDb ?? speechLevel, speechLevel)
        }
        guard floorDb != nil else { return }
        guard adaptiveRefinementComplete else { return }
        // Let residual post-finalize noise decay before it can lift the new quiet floor.
        let suppressReseededFloorRise = machineIsIdle && floorRiseSuppressionRemainingSeconds > 0
        if suppressReseededFloorRise {
            floorRiseSuppressionRemainingSeconds = max(
                0,
                floorRiseSuppressionRemainingSeconds - max(0, duration)
            )
        }
        var riseCap: Double
        if suppressReseededFloorRise {
            riseCap = 0
        } else {
            switch lastOutput.evidence {
            case .strong:
                riseCap = 0
            case .continuing:
                riseCap = machineIsIdle
                    ? (isLoudRegime ? config.loudRiseDbPerSec : Self.elevatedRiseDbPerSecond)
                        * effectiveRiseSpeedMultiplier
                    : 0
            case .ambiguous, .silence:
                riseCap = machineIsIdle
                    ? (isLoudRegime ? config.loudRiseDbPerSec : Self.elevatedRiseDbPerSecond)
                        * effectiveRiseSpeedMultiplier
                    : 0
            }
        }
        if machineIsIdle, !tracksUtteranceSpeechLevel, let speechCeilingDb {
            let decayedCeilingDb = speechCeilingDb
                + Self.elevatedRiseDbPerSecond * effectiveRiseSpeedMultiplier * max(0, duration)
            let clampBound = decayedCeilingDb - effectiveCeilingMarginDb
            self.speechCeilingDb = clampBound > Self.floorMaxDb
                ? nil
                : decayedCeilingDb
        }
        if !implausibleFallbackSuspendsSpeechCeiling, enforceSpeechCeiling() {
            refreshAdaptiveOutput()
        }
        if floorMovementAlreadyApplied { return }
        if implausibleSpeechFallbackActive,
           !machineIsEnding,
           let fallbackTarget = adaptiveRollingPercentileCache ?? adaptiveSignalPercentileCache {
            let maximumFallbackTarget = Self.floorMaxDb - effectiveAdaptiveDeltaDb
            guard fallbackTarget <= maximumFallbackTarget else {
                hasRefusedReanchorSinceLastAcceptance = true
                return
            }
            updateFloor(
                targetDb: fallbackTarget,
                frameDuration: duration,
                maximumRiseDbPerSecond: maximumFloorRiseDbPerSecond,
                enforceSpeechCeiling: !implausibleFallbackSuspendsSpeechCeiling
            )
            hasRefusedReanchorSinceLastAcceptance = false
            refreshAdaptiveOutput()
            return
        }
        if machineIsEnding,
           !suppressReseededFloorRise,
           let shortSpreadDb = lastOutput.shortSpreadDb,
           let dynamicsSpreadDb = lastOutput.dynamicsSpreadDb,
           shortSpreadDb < effectiveFlatSpreadDb,
            dynamicsSpreadDb < Self.adaptiveEndPendingWindDispersionDb,
            lastOutput.evidence != .strong,
            let target = adaptiveRollingPercentileCache {
            updateFloor(
                targetDb: target,
                frameDuration: duration,
                maximumRiseDbPerSecond: maximumFloorRiseDbPerSecond
            )
            refreshAdaptiveOutput()
            return
        }
        if riseCap == 0,
           let floorDb,
           adaptiveRollingPercentileAtLeast(floorDb) {
            return
        }
        let target = adaptiveRollingPercentileCache
            ?? (adaptiveSignalFallbackActive && machineIsIdle && !machineIsEnding
                ? adaptiveSignalPercentileCache
                : nil)
        guard let target else { return }
        riseCap = min(riseCap, maximumFloorRiseDbPerSecond)
        updateFloor(targetDb: target, frameDuration: duration, maximumRiseDbPerSecond: riseCap)
        refreshAdaptiveOutput()
    }

    /// Resets adaptive tracking after an audio-route change.
    func resetFloorAfterRouteChange() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        isLoudRegime = false
        loudRegimeEnterElapsed = 0
        loudRegimeExitElapsed = 0
        whisperSpeechContextRemainingSeconds = 0
        switch config.mode {
        case .adaptive:
            behaviorMode = .adaptive
            adaptiveRefinementElapsed = 0
            adaptiveRefinementComplete = false
            adaptivePrimingElapsed = 0
            adaptivePrimingQuietElapsed = 0
            adaptivePrimed = false
            coldStartSpeechShapedNow = false
            coldStartConverged = false
            floorDb = Self.floorMinDb
        case .staticMode:
            return
        }
        let resetAdaptiveThresholds = adaptiveThresholds(floor: Self.floorMinDb)
        thresholdDb = resetAdaptiveThresholds.strong
        elapsedSinceSilenceEvidence = 0
        pendingReanchorEvent = false
        hasRefusedReanchorSinceLastAcceptance = false
        speechCeilingDb = nil
        utteranceSpeechLevelDb = nil
        adaptiveSignalFallbackActive = false
        implausibleSpeechFallbackActive = false
        implausibleFallbackSuspendsSpeechCeiling = false
        floorRiseAppliedThisFrameDb = 0
        floorMovementAppliedThisFrame = false
        floorRiseSuppressionRemainingSeconds = 0
        resetAdaptiveRollingWindow()
        lastOutput = VADGateOutput(
            isSpeech: false,
            evidence: .silence,
            speechShaped: false,
            thresholdDb: thresholdDb,
            continuationThresholdDb: resetAdaptiveThresholds.continuation,
            silenceThresholdDb: resetAdaptiveThresholds.silence,
            floorDb: floorDb,
            floorConverged: false,
            dynamicsSpreadDb: nil,
            shortSpreadDb: nil,
            highBandRatioDb: nil,
            isLoudRegime: false,
            didReanchor: false,
            didCompletePriming: false,
            primingDurationSeconds: 0,
            primingEndedAtCap: false
        )
    }

    private func updateFloor(
        targetDb: Double,
        frameDuration: Double,
        maximumRiseDbPerSecond: Double,
        enforceSpeechCeiling: Bool = true
    ) {
        guard var floor = floorDb else { return }
        let previousFloor = floor
        if targetDb > floor {
            let maximumRiseDb = max(0, maximumRiseDbPerSecond) * max(0, frameDuration)
            let availableRiseDb = max(0, maximumRiseDb - floorRiseAppliedThisFrameDb)
            let appliedRiseDb = min(targetDb - floor, availableRiseDb)
            floor += appliedRiseDb
            floorRiseAppliedThisFrameDb += appliedRiseDb
        } else {
            let alpha = 1.0 - exp(-frameDuration / effectiveFallTauSeconds)
            floor += alpha * (targetDb - floor)
        }
        if enforceSpeechCeiling, let speechCeilingDb {
            floor = min(floor, speechCeilingDb - effectiveCeilingMarginDb)
        }
        let updatedFloor = clampFloor(floor)
        if abs(updatedFloor - previousFloor) > Self.adaptiveFloorMovementEpsilonDb {
            floorMovementAppliedThisFrame = true
        }
        floorDb = updatedFloor
    }

    private var maximumFloorRiseDbPerSecond: Double {
        Self.elevatedRiseDbPerSecond * effectiveRiseSpeedMultiplier
    }

    private func enforceSpeechCeiling() -> Bool {
        guard let floorDb, let speechCeilingDb else { return false }
        let ceilingBoundDb = speechCeilingDb - effectiveCeilingMarginDb
        guard floorDb > ceilingBoundDb else { return false }
        self.floorDb = clampFloor(ceilingBoundDb)
        floorMovementAppliedThisFrame = true
        return true
    }

    private func appendAdaptiveRollingFrame(db: Double, duration: Double) {
        guard duration > 0 else { return }
        if adaptiveRollingCount == Self.adaptiveRollingWindowCapacity {
            let oldestIndex = (adaptiveRollingWriteIndex - adaptiveRollingCount + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            adaptiveRollingElapsed -= adaptiveRollingDurations[oldestIndex]
        } else {
            adaptiveRollingCount += 1
        }

        adaptiveRollingDbs[adaptiveRollingWriteIndex] = db
        adaptiveRollingDurations[adaptiveRollingWriteIndex] = duration
        adaptiveRollingFloorEligible[adaptiveRollingWriteIndex] = false
        adaptiveRollingWriteIndex = (adaptiveRollingWriteIndex + 1) % Self.adaptiveRollingWindowCapacity
        adaptiveRollingElapsed += duration

        while adaptiveRollingCount > 0,
              adaptiveRollingElapsed > Self.adaptiveRollingWindowDuration {
            let oldestIndex = (adaptiveRollingWriteIndex - adaptiveRollingCount + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            adaptiveRollingElapsed -= adaptiveRollingDurations[oldestIndex]
            adaptiveRollingCount -= 1
        }
    }

    private func markLatestAdaptiveRollingFrameAsFloorEligible() {
        guard adaptiveRollingCount > 0 else { return }
        let latestIndex = (adaptiveRollingWriteIndex - 1 + Self.adaptiveRollingWindowCapacity)
            % Self.adaptiveRollingWindowCapacity
        adaptiveRollingFloorEligible[latestIndex] = true
    }

    private func resetAdaptiveRollingWindow() {
        adaptiveRollingWriteIndex = 0
        adaptiveRollingCount = 0
        adaptiveRollingElapsed = 0
        adaptiveRollingPercentileCache = nil
        adaptiveSignalPercentileCache = nil
    }

    private func adaptiveSignalPercentile() -> Double? {
        guard adaptiveRollingCount > 0 else { return nil }
        var values: [Double] = []
        values.reserveCapacity(adaptiveRollingCount)
        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - adaptiveRollingCount + offset + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            values.append(adaptiveRollingDbs[index])
        }
        return percentile(values, percentile: Self.adaptiveRollingPercentile)
    }

    private func adaptiveRollingPercentile() -> Double? {
        guard adaptiveRollingCount > 0 else { return nil }
        var values: [Double] = []
        values.reserveCapacity(adaptiveRollingCount)
        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - adaptiveRollingCount + offset
                + Self.adaptiveRollingWindowCapacity) % Self.adaptiveRollingWindowCapacity
            if adaptiveRollingFloorEligible[index] {
                values.append(adaptiveRollingDbs[index])
            }
        }
        guard !values.isEmpty else { return nil }
        return percentile(values, percentile: Self.adaptiveRollingPercentile)
    }

    private func adaptiveRollingMaxDb(coverSeconds: Double) -> Double? {
        guard adaptiveRollingCount > 0 else { return nil }
        var maximum = -Double.infinity
        var coveredSeconds = 0.0
        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - 1 - offset + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            maximum = max(maximum, adaptiveRollingDbs[index])
            coveredSeconds += adaptiveRollingDurations[index]
            if coveredSeconds > coverSeconds { break }
        }
        return maximum
    }

    private func adaptiveRollingMinDb(coverSeconds: Double) -> Double? {
        guard adaptiveRollingCount > 0 else { return nil }
        var minimum = Double.infinity
        var coveredSeconds = 0.0
        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - 1 - offset + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            minimum = min(minimum, adaptiveRollingDbs[index])
            coveredSeconds += adaptiveRollingDurations[index]
            if coveredSeconds > coverSeconds { break }
        }
        return minimum
    }

    private func adaptiveRollingAdjacentStepDb() -> Double? {
        guard adaptiveRollingCount > 1 else { return nil }
        // A past transient must not veto a locally flat speech run after the edge.
        let currentIndex = (adaptiveRollingWriteIndex - 1 + Self.adaptiveRollingWindowCapacity)
            % Self.adaptiveRollingWindowCapacity
        let previousIndex = (adaptiveRollingWriteIndex - 2 + Self.adaptiveRollingWindowCapacity)
            % Self.adaptiveRollingWindowCapacity
        return abs(adaptiveRollingDbs[currentIndex] - adaptiveRollingDbs[previousIndex])
    }

    private func adaptiveQuietShapeSpreads(
        below silenceThresholdDb: Double
    ) -> (dynamics: Double?, short: Double?, adjacentStep: Double?) {
        guard adaptiveRollingCount > 0 else { return (nil, nil, nil) }
        var quietValues: [Double] = []
        var adjacentStepDb: Double?
        var newerFrameDb: Double?
        var coveredSeconds = 0.0
        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - 1 - offset + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            let frameDb = adaptiveRollingDbs[index]
            guard frameDb < silenceThresholdDb else { break }
            if let newerFrameDb {
                let stepDb = abs(newerFrameDb - frameDb)
                if adjacentStepDb == nil {
                    adjacentStepDb = stepDb
                }
                // Do not let modulation before an abrupt transition keep settled quiet speech-shaped.
                if stepDb >= Self.adaptiveEndPendingWindDispersionDb { break }
            }
            quietValues.append(frameDb)
            newerFrameDb = frameDb
            coveredSeconds += adaptiveRollingDurations[index]
            if coveredSeconds > Self.speechShapeWindowSeconds { break }
        }
        guard let maximum = quietValues.max(), let minimum = quietValues.min() else {
            return (nil, nil, nil)
        }
        return (
            dynamics: maximum - percentile(quietValues, percentile: Self.adaptiveRollingPercentile),
            short: maximum - minimum,
            adjacentStep: adjacentStepDb
        )
    }

    private func adaptiveRollingPercentileAtLeast(_ floorDb: Double) -> Bool {
        var eligibleCount = 0
        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - adaptiveRollingCount + offset
                + Self.adaptiveRollingWindowCapacity) % Self.adaptiveRollingWindowCapacity
            if adaptiveRollingFloorEligible[index] { eligibleCount += 1 }
        }
        guard eligibleCount > 0 else { return false }

        let position = Self.adaptiveRollingPercentile * Double(eligibleCount - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, eligibleCount - 1)
        var belowCount = 0
        var maximumBelow = -Double.infinity
        var minimumAtOrAbove = Double.infinity

        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - adaptiveRollingCount + offset + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
            guard adaptiveRollingFloorEligible[index] else { continue }
            let value = adaptiveRollingDbs[index]
            if value < floorDb {
                belowCount += 1
                maximumBelow = max(maximumBelow, value)
            } else {
                minimumAtOrAbove = min(minimumAtOrAbove, value)
            }
        }

        if belowCount <= lowerIndex {
            return true
        }
        if belowCount > upperIndex {
            return false
        }
        guard upperIndex > lowerIndex else { return false }
        let fraction = position - Double(lowerIndex)
        return maximumBelow + fraction * (minimumAtOrAbove - maximumBelow) >= floorDb
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        let sortedValues = values.sorted()
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = percentile * Double(sortedValues.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = min(lowerIndex + 1, sortedValues.count - 1)
        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex] + fraction * (sortedValues[upperIndex] - sortedValues[lowerIndex])
    }

    private func refreshAdaptiveOutput() {
        guard let floorDb else { return }
        let thresholds = adaptiveThresholds(floor: floorDb)
        lastOutput = VADGateOutput(
            isSpeech: lastOutput.isSpeech,
            evidence: lastOutput.evidence,
            speechShaped: lastOutput.speechShaped,
            thresholdDb: thresholds.strong,
            continuationThresholdDb: thresholds.continuation,
            silenceThresholdDb: thresholds.silence,
            floorDb: floorDb,
            floorConverged: coldStartConverged,
            dynamicsSpreadDb: lastOutput.dynamicsSpreadDb,
            shortSpreadDb: lastOutput.shortSpreadDb,
            highBandRatioDb: lastOutput.highBandRatioDb,
            isLoudRegime: isLoudRegime,
            didReanchor: false,
            didCompletePriming: false,
            primingDurationSeconds: adaptivePrimingElapsed,
            primingEndedAtCap: false
        )
    }

    private func adaptiveThresholds(
        floor: Double
    ) -> (strong: Double, continuation: Double, silence: Double) {
        if isLoudRegime {
            let strongThresholdDb = max(
                floor + effectiveLoudStrongDeltaDb,
                effectiveAbsoluteSpeechFloorDb
            )
            let continuationThresholdDb = min(
                max(floor + effectiveLoudContinuationDeltaDb, effectiveAbsoluteSpeechFloorDb),
                strongThresholdDb - 1.0
            )
            return (
                strong: strongThresholdDb,
                continuation: continuationThresholdDb,
                silence: min(
                    min(floor + effectiveLoudSilenceDeltaDb, 5.0),
                    continuationThresholdDb - 1.0
                )
            )
        }
        return (
            strong: max(floor + effectiveAdaptiveDeltaDb, effectiveAbsoluteSpeechFloorDb),
            continuation: max(floor + effectiveAdaptiveContinuationDeltaDb, effectiveAbsoluteSpeechFloorDb),
            silence: floor + effectiveSilenceDeltaDb
        )
    }

    private func classify(
        frameDb: Double,
        strongThresholdDb: Double,
        continuationThresholdDb: Double,
        silenceThresholdDb: Double,
        dynamicsSpreadDb: Double? = nil,
        shortSpreadDb: Double? = nil,
        adjacentStepDb: Double? = nil
    ) -> (
        evidence: VADEvidence,
        strongThresholdDb: Double,
        continuationThresholdDb: Double,
        silenceThresholdDb: Double,
        speechShaped: Bool
    ) {
        let evidence: VADEvidence
        let speechShaped: Bool
        whisperModulationObserved = false
        if frameDb >= strongThresholdDb {
            evidence = .strong
            speechShaped = Self.isSpeechShaped(
                dynamicsSpreadDb: dynamicsSpreadDb,
                shortSpreadDb: shortSpreadDb,
                flatSpreadDb: effectiveFlatSpreadDb,
                adjacentStepDb: adjacentStepDb,
                allowWindBoundaryStep: true
            )
        } else if frameDb >= continuationThresholdDb {
            evidence = .continuing
            speechShaped = Self.isSpeechShaped(
                dynamicsSpreadDb: dynamicsSpreadDb,
                shortSpreadDb: shortSpreadDb,
                flatSpreadDb: effectiveFlatSpreadDb,
                adjacentStepDb: adjacentStepDb,
                allowWindBoundaryStep: true
            )
        } else if frameDb < silenceThresholdDb {
            let quietShapeSpreads = adaptiveQuietShapeSpreads(below: silenceThresholdDb)
            let temporalShape = Self.isSpeechShaped(
                dynamicsSpreadDb: quietShapeSpreads.dynamics,
                shortSpreadDb: quietShapeSpreads.short,
                flatSpreadDb: effectiveFlatSpreadDb,
                adjacentStepDb: quietShapeSpreads.adjacentStep
            )
            let highBandWhisper = frameHighBandRatioDb.map {
                $0 >= effectiveWhisperHighBandRatioDb
            } ?? false
            let modulatedWhisper = highBandWhisper
                && (quietShapeSpreads.short ?? 0)
                    >= SharedConfig.Defaults.streamVadWhisperModulationSpreadDbDefault
                && (quietShapeSpreads.adjacentStep ?? .infinity)
                    < Self.adaptiveEndPendingWindDispersionDb
            whisperModulationObserved = modulatedWhisper
            // Carry a syllabic HF witness briefly across valleys, not across steady hiss.
            let recentWhisperContext = highBandWhisper
                && frameWithinUtteranceContext
                && whisperSpeechContextRemainingSeconds > 0
            speechShaped = temporalShape || modulatedWhisper || recentWhisperContext
            evidence = .silence
        } else {
            evidence = .ambiguous
            speechShaped = Self.isSpeechShaped(
                dynamicsSpreadDb: dynamicsSpreadDb,
                shortSpreadDb: shortSpreadDb,
                flatSpreadDb: effectiveFlatSpreadDb,
                adjacentStepDb: adjacentStepDb,
                allowWindBoundaryStep: true
            )
        }
        return (evidence, strongThresholdDb, continuationThresholdDb, silenceThresholdDb, speechShaped)
    }

    // Require modulation without the abrupt jumps that characterize gusts.
    static func isSpeechShaped(
        dynamicsSpreadDb: Double?,
        shortSpreadDb: Double?,
        flatSpreadDb: Double,
        adjacentStepDb: Double?,
        allowWindBoundaryStep: Bool = false
    ) -> Bool {
        guard let dynamicsSpreadDb, let shortSpreadDb, let adjacentStepDb else { return false }
        // Quiet frames keep the strict wind boundary; other evidence accepts exactly 6 dB.
        let stepIsWithinSpeechBoundary = allowWindBoundaryStep
            ? adjacentStepDb <= Self.adaptiveEndPendingWindDispersionDb
            : adjacentStepDb < Self.adaptiveEndPendingWindDispersionDb
        guard stepIsWithinSpeechBoundary else { return false }
        return dynamicsSpreadDb >= Self.adaptiveEndPendingWindDispersionDb || shortSpreadDb >= flatSpreadDb
    }

    private func clampFloor(_ floor: Double) -> Double {
        min(max(floor, Self.floorMinDb), Self.floorMaxDb)
    }

    private func emit(
        evidence: VADEvidence,
        isSpeech: Bool,
        speechShaped: Bool = false,
        thresholdDb: Double,
        continuationThresholdDb: Double,
        silenceThresholdDb: Double,
        floorDb: Double?,
        floorConverged: Bool = false,
        dynamicsSpreadDb: Double? = nil,
        shortSpreadDb: Double? = nil,
        isLoudRegime: Bool? = nil,
        didReanchor: Bool = false,
        didCompletePriming: Bool = false,
        primingDurationSeconds: Double = 0,
        primingEndedAtCap: Bool = false
    ) -> VADGateOutput {
        let output = VADGateOutput(
            isSpeech: isSpeech,
            evidence: evidence,
            speechShaped: speechShaped,
            thresholdDb: thresholdDb,
            continuationThresholdDb: continuationThresholdDb,
            silenceThresholdDb: silenceThresholdDb,
            floorDb: floorDb,
            floorConverged: floorConverged,
            dynamicsSpreadDb: dynamicsSpreadDb,
            shortSpreadDb: shortSpreadDb,
            highBandRatioDb: frameHighBandRatioDb,
            isLoudRegime: isLoudRegime ?? self.isLoudRegime,
            didReanchor: didReanchor,
            didCompletePriming: didCompletePriming,
            primingDurationSeconds: primingDurationSeconds,
            primingEndedAtCap: primingEndedAtCap
        )
        lastOutput = output
        return output
    }
}
