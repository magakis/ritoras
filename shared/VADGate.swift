import Foundation
import os

// These VAD types are intentionally top-level rather than nested in SharedConfig.
// Keeping the pure-logic gate self-contained mirrors scripts/prediction-sim/lib/vad-gate.mjs.

enum VADMode: String, CaseIterable {
    case staticMode = "static"
    case calibrated = "calibrated"
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
    let calibrationMs: Int
    let calibratedOffsetDb: Double
    let adaptiveDeltaDb: Double
    let adaptiveContinuationDeltaDb: Double
    let adaptiveRiseSpeedMultiplier: Double
    let adaptiveSilenceDeltaDb: Double
    let adaptiveStaleFloorSeconds: Double
    let adaptiveFallTauSeconds: Double
    let adaptiveDynamicsEnabled: Bool
    let adaptiveDynamicsSpreadDb: Double
    let adaptiveFlatSpreadDb: Double
}

struct VADGateOutput {
    let isSpeech: Bool
    let evidence: VADEvidence
    let thresholdDb: Double
    let continuationThresholdDb: Double
    let silenceThresholdDb: Double
    let floorDb: Double?
    let calibrating: Bool
    let usedFallback: Bool
    let retroactiveSpeechMs: Double
    let trailingSilenceMs: Double?
    let dynamicsSpreadDb: Double?
    let shortSpreadDb: Double?
}

final class VADThresholdGate: @unchecked Sendable {
    private struct CalibrationFrame {
        let db: Double
        let duration: Double
    }

    // Fixed algorithm constants. They are intentionally not user-facing settings.
    static let adaptiveEndPendingWindDispersionDb = 6.0
    private static let staticContinuationOffsetDb = 4.0
    private static let staticSilenceOffsetDb = 6.0
    private static let elevatedRiseDbPerSecond = 12.0
    private static let speechCeilingMarginDb = 2.0
    private static let adaptiveMinRefinementDuration = 1.0
    private static let adaptiveColdStartGraceSeconds = 0.4
    private static let adaptiveColdStartDispersionWindowSeconds = 0.4
    private static let adaptiveRollingWindowDuration = 3.0
    private static let adaptiveRollingWindowCapacity = 256
    private static let floorMinDb = -80.0
    private static let floorMaxDb = -20.0
    private static let calibrationQuartile = 0.25
    private static let quietBandDb = 6.0
    private static let adaptiveRollingPercentile = 0.1
    private static let adaptiveFloorMovementEpsilonDb = 1e-6
    private static let calibrationCompletionEpsilon = 1e-9

    private let config: VADGateConfig
    private let effectiveAdaptiveDeltaDb: Double
    private let effectiveAdaptiveContinuationDeltaDb: Double
    private let effectiveSilenceDeltaDb: Double
    private let effectiveRiseSpeedMultiplier: Double
    private let effectiveStaleFloorSeconds: Double
    private let effectiveFallTauSeconds: Double
    private let effectiveDynamicsSpreadDb: Double
    private let effectiveFlatSpreadDb: Double
    private var behaviorMode: VADMode
    private var calibrationFinished = false
    private var calibrationElapsed = 0.0
    private var calibrationFrames: [CalibrationFrame] = []
    private var adaptiveRefinementElapsed = 0.0
    private var adaptiveRefinementComplete: Bool
    private var coldStartSpeechShapedNow = false
    private var coldStartConverged = false
    private var floorDb: Double?
    private var thresholdDb: Double
    private var usedFallback = false
    private var pendingRetroactiveSpeechMs = 0.0
    private var pendingTrailingSilenceMs: Double?
    private var pendingReanchorEvent = false
    private var hasLoggedReanchorRefusal = false
    private var hasRefusedReanchorSinceLastAcceptance = false
    private var elapsedSinceSilenceEvidence = 0.0
    private var adaptiveRollingDbs: [Double] = []
    private var adaptiveRollingDurations: [Double] = []
    private var adaptiveRollingWriteIndex = 0
    private var adaptiveRollingCount = 0
    private var adaptiveRollingElapsed = 0.0
    private var adaptiveRollingPercentileCache: Double?
    private var lastKnownMachineIsIdle = true
    private var speechCeilingDb: Double?
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
        let initialFloorDb: Double? = config.mode == .adaptive ? Self.floorMinDb : nil
        let initialThresholdDb = config.mode == .adaptive
            ? Self.floorMinDb + effectiveAdaptiveDeltaDb
            : Double(AudioMath.dbFromRms(config.staticRms))
        self.config = config
        self.effectiveAdaptiveDeltaDb = effectiveAdaptiveDeltaDb
        self.effectiveAdaptiveContinuationDeltaDb = effectiveAdaptiveContinuationDeltaDb
        self.effectiveSilenceDeltaDb = effectiveSilenceDeltaDb
        self.effectiveRiseSpeedMultiplier = effectiveRiseSpeedMultiplier
        self.effectiveStaleFloorSeconds = effectiveStaleFloorSeconds
        self.effectiveFallTauSeconds = effectiveFallTauSeconds
        self.effectiveDynamicsSpreadDb = effectiveDynamicsSpreadDb
        self.effectiveFlatSpreadDb = effectiveFlatSpreadDb
        self.behaviorMode = config.mode
        self.adaptiveRefinementComplete = config.mode != .adaptive
        self.floorDb = initialFloorDb
        self.thresholdDb = initialThresholdDb
        self.adaptiveRollingPercentileCache = nil
        self.lastOutput = VADGateOutput(
            isSpeech: false,
            evidence: .silence,
            thresholdDb: initialThresholdDb,
            continuationThresholdDb: config.mode == .adaptive
                ? Self.floorMinDb + effectiveAdaptiveContinuationDeltaDb
                : initialThresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: config.mode == .adaptive
                ? Self.floorMinDb + effectiveSilenceDeltaDb
                : initialThresholdDb - Self.staticSilenceOffsetDb,
            floorDb: initialFloorDb,
            calibrating: config.mode == .calibrated,
            usedFallback: false,
            retroactiveSpeechMs: 0,
            trailingSilenceMs: nil,
            dynamicsSpreadDb: nil,
            shortSpreadDb: nil
        )
        calibrationFrames.reserveCapacity(36)
        adaptiveRollingDbs = Array(repeating: 0, count: Self.adaptiveRollingWindowCapacity)
        adaptiveRollingDurations = Array(repeating: 0, count: Self.adaptiveRollingWindowCapacity)
    }

    func process(frameDb: Double, frameDuration: Double) -> VADGateOutput {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }

        switch behaviorMode {
        case .staticMode:
            return processStatic(frameDb: frameDb)
        case .calibrated:
            if !calibrationFinished {
                return processCalibration(frameDb: frameDb, frameDuration: frameDuration)
            }
            return processCalibrated(frameDb: frameDb)
        case .adaptive:
            return processAdaptive(frameDb: frameDb, frameDuration: frameDuration)
        }
    }

    var snapshot: VADGateOutput {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return lastOutput
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
            "silenceDeltaDb": effectiveSilenceDeltaDb,
            "dynamicsSpreadDb": effectiveDynamicsSpreadDb,
            "flatSpreadDb": effectiveFlatSpreadDb,
            "dynamicsEnabled": config.adaptiveDynamicsEnabled,
            "staleFloorSeconds": effectiveStaleFloorSeconds,
            "fallTauSeconds": effectiveFallTauSeconds,
            "riseMultiplier": effectiveRiseSpeedMultiplier
        ]
    }

    func takePendingReanchorEvent() -> Bool {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        let event = pendingReanchorEvent
        pendingReanchorEvent = false
        return event
    }

    func noteUtteranceEnded(quietestStrongDb: Double?) {
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
           quietestStrongDb >= floorDb + effectiveAdaptiveDeltaDb + Self.speechCeilingMarginDb {
            speechCeilingDb = quietestStrongDb
        }
        // Rejected or nil: keep the previous ceiling (idle decay still releases it).
        resetAdaptiveRollingWindow()
    }

    private func processStatic(frameDb: Double) -> VADGateOutput {
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: thresholdDb,
            continuationThresholdDb: thresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: thresholdDb - Self.staticSilenceOffsetDb
        )
        return emit(
            evidence: levels.evidence,
            isSpeech: levels.evidence == .strong,
            thresholdDb: thresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: nil,
            calibrating: false,
            retroactiveSpeechMs: 0,
            trailingSilenceMs: nil
        )
    }

    private func processCalibration(frameDb: Double, frameDuration: Double) -> VADGateOutput {
        calibrationFrames.append(CalibrationFrame(db: frameDb, duration: frameDuration))
        calibrationElapsed += frameDuration
        // Tolerate the representation error from summing frame durations such
        // as ten 0.1-second frames without changing the elapsed-time boundary.
        if calibrationElapsed + Self.calibrationCompletionEpsilon >= Double(config.calibrationMs) / 1000.0 {
            finishCalibration()
        }

        // Every frame in the window is held as non-speech. The threshold is only
        // reported for diagnostics; the calibrated floor remains nil until the
        // window has ended. The running Q1 gives a stable interim value after the
        // first frame, while the existing threshold is the empty-window fallback.
        return emit(
            evidence: .silence,
            isSpeech: false,
            thresholdDb: calibrationThresholdDb(),
            continuationThresholdDb: calibrationThresholdDb() - Self.staticContinuationOffsetDb,
            silenceThresholdDb: calibrationThresholdDb() - Self.staticSilenceOffsetDb,
            floorDb: nil,
            calibrating: true,
            retroactiveSpeechMs: 0,
            trailingSilenceMs: nil
        )
    }

    private func finishCalibration() {
        let q1 = calibrationQ1()
        let referenceThreshold = q1 + config.calibratedOffsetDb
        var quietCount = 0
        for frame in calibrationFrames where frame.db <= q1 + Self.quietBandDb {
            quietCount += 1
        }

        var retroactiveSpeechSeconds = 0.0
        for frame in calibrationFrames where frame.db >= referenceThreshold {
            retroactiveSpeechSeconds += frame.duration
        }

        var trailingSilenceSeconds = 0.0
        for frame in calibrationFrames.reversed() {
            guard frame.db < referenceThreshold else { break }
            trailingSilenceSeconds += frame.duration
        }
        pendingRetroactiveSpeechMs = retroactiveSpeechSeconds * 1000.0
        pendingTrailingSilenceMs = trailingSilenceSeconds * 1000.0

        let minimumQuietFrames = max(3, calibrationFrames.count / 3)
        if quietCount >= minimumQuietFrames {
            thresholdDb = referenceThreshold
            floorDb = nil
            behaviorMode = .calibrated
        } else {
            // A contaminated window starts Adaptive from its measured Q1 rather
            // than collecting a second seed window, so calibration cannot gate
            // away speech that occurred during the first window.
            let seededFloor = clampFloor(q1)
            floorDb = seededFloor
            thresholdDb = seededFloor + effectiveAdaptiveDeltaDb
            adaptiveRefinementElapsed = 0
            adaptiveRefinementComplete = true
            behaviorMode = .adaptive
            usedFallback = true
        }
        calibrationFinished = true
    }

    private func processCalibrated(frameDb: Double) -> VADGateOutput {
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: thresholdDb,
            continuationThresholdDb: thresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: thresholdDb - Self.staticSilenceOffsetDb
        )
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            evidence: levels.evidence,
            isSpeech: levels.evidence == .strong,
            thresholdDb: thresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: nil,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs
        )
    }

    private func processAdaptive(frameDb: Double, frameDuration: Double) -> VADGateOutput {
        appendAdaptiveRollingFrame(db: frameDb, duration: frameDuration)
        let rollingPercentile = adaptiveRollingPercentile()
        let windowMax = adaptiveRollingMaxDb(coverSeconds: Self.adaptiveColdStartDispersionWindowSeconds)
        let dispersionDb = (windowMax ?? frameDb) - (rollingPercentile ?? frameDb)
        let shortSpreadDb: Double?
        if config.adaptiveDynamicsEnabled {
            let windowMin = adaptiveRollingMinDb(coverSeconds: Self.adaptiveColdStartDispersionWindowSeconds)
            shortSpreadDb = (windowMax ?? frameDb) - (windowMin ?? frameDb)
        } else {
            shortSpreadDb = nil
        }
        adaptiveRollingPercentileCache = rollingPercentile
        if !adaptiveRefinementComplete {
            return processAdaptiveRefinement(
                frameDb: frameDb,
                frameDuration: frameDuration,
                rollingPercentile: rollingPercentile,
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
                rollingPercentile: rollingPercentile,
                dispersionDb: dispersionDb,
                shortSpreadDb: shortSpreadDb
            )
        }

        let startDb = currentFloor + effectiveAdaptiveDeltaDb
        var levels = classify(
            frameDb: frameDb,
            strongThresholdDb: startDb,
            continuationThresholdDb: currentFloor + effectiveAdaptiveContinuationDeltaDb,
            silenceThresholdDb: currentFloor + effectiveSilenceDeltaDb
        )
        if levels.evidence == .silence {
            elapsedSinceSilenceEvidence = 0
        } else {
            elapsedSinceSilenceEvidence += max(0, frameDuration)
            if elapsedSinceSilenceEvidence + Self.calibrationCompletionEpsilon >= effectiveStaleFloorSeconds,
               lastKnownMachineIsIdle,
               let target = rollingPercentile {
                elapsedSinceSilenceEvidence = 0
                let reanchoredFloor: Double
                if let speechCeilingDb {
                    reanchoredFloor = clampFloor(min(
                        target,
                        speechCeilingDb - effectiveAdaptiveDeltaDb - Self.speechCeilingMarginDb
                    ))
                } else {
                    reanchoredFloor = clampFloor(target)
                }
                let maximumReanchorFloor = Self.floorMaxDb - effectiveAdaptiveDeltaDb
                if reanchoredFloor <= maximumReanchorFloor {
                    let floorMoved = abs(reanchoredFloor - currentFloor) > Self.adaptiveFloorMovementEpsilonDb
                    floorDb = reanchoredFloor
                    if floorMoved && !hasRefusedReanchorSinceLastAcceptance {
                        pendingReanchorEvent = true
                    }
                    hasRefusedReanchorSinceLastAcceptance = false
                    levels = classify(
                        frameDb: frameDb,
                        strongThresholdDb: reanchoredFloor + effectiveAdaptiveDeltaDb,
                        continuationThresholdDb: reanchoredFloor + effectiveAdaptiveContinuationDeltaDb,
                        silenceThresholdDb: reanchoredFloor + effectiveSilenceDeltaDb
                    )
                } else {
                    hasRefusedReanchorSinceLastAcceptance = true
                    if !hasLoggedReanchorRefusal {
                        hasLoggedReanchorRefusal = true
                        FileLogger.shared.warn(.audio, "VAD: re-anchor refused")
                    }
                }
            }
        }
        let evidence = dynamicsGatedEvidence(levels.evidence, dispersionDb: dispersionDb)
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            evidence: evidence,
            isSpeech: evidence == .strong || evidence == .continuing,
            thresholdDb: levels.strongThresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: floorDb,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb
        )
    }

    private func processAdaptiveRefinement(
        frameDb: Double,
        frameDuration: Double,
        rollingPercentile: Double?,
        dispersionDb: Double,
        shortSpreadDb: Double?
    ) -> VADGateOutput {
        adaptiveRefinementElapsed += max(0, frameDuration)
        if floorDb == nil {
            floorDb = Self.floorMinDb
        }

        let shapedThresholdDb = config.adaptiveDynamicsEnabled
            ? effectiveDynamicsSpreadDb
            : effectiveAdaptiveDeltaDb + Self.speechCeilingMarginDb
        coldStartSpeechShapedNow = dispersionDb >= shapedThresholdDb

        if !coldStartSpeechShapedNow,
           adaptiveRefinementElapsed >= Self.adaptiveColdStartGraceSeconds,
           let rollingPercentile {
            floorDb = clampFloor(rollingPercentile)
            if !coldStartConverged {
                coldStartConverged = true
                FileLogger.shared.info(
                    .audio,
                    "VAD: cold-start floor converged",
                    payload: ["floorDb": floorDb ?? NSNull()]
                )
            }
        } else if !coldStartConverged {
            if let floorDb {
                self.floorDb = min(floorDb, clampFloor(frameDb))
            } else {
                floorDb = Self.floorMinDb
            }
        }
        // Cold-start refinement is capped at twice the minimum duration so it cannot
        // defer convergence without bound. This protects the idle case; sustained
        // dispersive ambient that onsets during refinement can still complete while
        // unconverged and pin the -80 dB floor, a documented limitation.
        if coldStartConverged
            || adaptiveRefinementElapsed + Self.calibrationCompletionEpsilon
                >= 2 * Self.adaptiveMinRefinementDuration {
            adaptiveRefinementComplete = true
        }

        let currentFloor = floorDb ?? Self.floorMinDb
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: currentFloor + effectiveAdaptiveDeltaDb,
            continuationThresholdDb: currentFloor + effectiveAdaptiveContinuationDeltaDb,
            silenceThresholdDb: currentFloor + effectiveSilenceDeltaDb
        )
        let evidence = dynamicsGatedEvidence(levels.evidence, dispersionDb: dispersionDb)
        let isSpeech = evidence == .strong || evidence == .continuing
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            evidence: evidence,
            isSpeech: isSpeech,
            thresholdDb: levels.strongThresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: currentFloor,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs,
            dynamicsSpreadDb: config.adaptiveDynamicsEnabled ? dispersionDb : nil,
            shortSpreadDb: shortSpreadDb
        )
    }

    private func dynamicsGatedEvidence(_ evidence: VADEvidence, dispersionDb: Double) -> VADEvidence {
        guard config.adaptiveDynamicsEnabled,
              evidence == .strong,
              dispersionDb < effectiveDynamicsSpreadDb else {
            return evidence
        }
        return .continuing
    }

    /// Updates the adaptive floor using the current VAD evidence. The rolling
    /// percentile remains populated by every processed frame, so a poisoned
    /// floor cannot prevent ambient audio from becoming adaptation evidence.
    func updateFloorTracking(
        frameDb: Double,
        duration: Double,
        machineIsIdle: Bool = true,
        machineIsEnding: Bool = false
    ) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        lastKnownMachineIsIdle = machineIsIdle
        guard behaviorMode == .adaptive else { return }
        guard floorDb != nil else { return }
        guard adaptiveRefinementComplete else { return }
        let riseCap: Double
        switch lastOutput.evidence {
        case .strong:
            riseCap = 0
        case .continuing:
            riseCap = machineIsIdle
                ? Self.elevatedRiseDbPerSecond * effectiveRiseSpeedMultiplier
                : 0
        case .ambiguous, .silence:
            riseCap = machineIsIdle
                ? Self.elevatedRiseDbPerSecond * effectiveRiseSpeedMultiplier
                : 0
        }
        if machineIsIdle, let speechCeilingDb {
            let decayedCeilingDb = speechCeilingDb
                + Self.elevatedRiseDbPerSecond * effectiveRiseSpeedMultiplier * max(0, duration)
            let clampBound = decayedCeilingDb - effectiveAdaptiveDeltaDb - Self.speechCeilingMarginDb
            self.speechCeilingDb = clampBound > Self.floorMaxDb - effectiveAdaptiveDeltaDb
                ? nil
                : decayedCeilingDb
        }
        if machineIsEnding,
           let shortSpreadDb = lastOutput.shortSpreadDb,
           let dynamicsSpreadDb = lastOutput.dynamicsSpreadDb,
           shortSpreadDb < effectiveFlatSpreadDb,
           dynamicsSpreadDb < Self.adaptiveEndPendingWindDispersionDb,
           lastOutput.evidence != .strong,
           let floorDb {
            let target = max(adaptiveRollingPercentileCache ?? frameDb, frameDb)
            let risenFloor = max(
                floorDb,
                min(
                    target,
                    floorDb + Self.elevatedRiseDbPerSecond * effectiveRiseSpeedMultiplier * duration
                )
            )
            self.floorDb = clampFloor(risenFloor)
            refreshAdaptiveOutput()
            return
        }
        if riseCap == 0,
           let floorDb,
           adaptiveRollingPercentileAtLeast(floorDb) {
            return
        }
        guard let target = adaptiveRollingPercentileCache else { return }
        updateFloor(targetDb: target, frameDuration: duration, maximumRiseDbPerSecond: riseCap)
        refreshAdaptiveOutput()
    }

    /// Resets adaptive tracking or calibration after an audio-route change.
    func recalibrateFloor() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        switch config.mode {
        case .adaptive:
            behaviorMode = .adaptive
            adaptiveRefinementElapsed = 0
            adaptiveRefinementComplete = false
            coldStartSpeechShapedNow = false
            coldStartConverged = false
            floorDb = Self.floorMinDb
        case .calibrated:
            behaviorMode = .calibrated
            calibrationFinished = false
            calibrationElapsed = 0
            calibrationFrames.removeAll(keepingCapacity: true)
            pendingRetroactiveSpeechMs = 0
            pendingTrailingSilenceMs = nil
            floorDb = nil
            adaptiveRefinementElapsed = 0
            adaptiveRefinementComplete = false
        case .staticMode:
            return
        }
        thresholdDb = config.mode == .adaptive
            ? Self.floorMinDb + effectiveAdaptiveDeltaDb
            : Double(AudioMath.dbFromRms(config.staticRms))
        elapsedSinceSilenceEvidence = 0
        pendingReanchorEvent = false
        hasRefusedReanchorSinceLastAcceptance = false
        speechCeilingDb = nil
        resetAdaptiveRollingWindow()
        usedFallback = false
        lastOutput = VADGateOutput(
            isSpeech: false,
            evidence: .silence,
            thresholdDb: thresholdDb,
            continuationThresholdDb: config.mode == .adaptive
                ? Self.floorMinDb + effectiveAdaptiveContinuationDeltaDb
                : thresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: config.mode == .adaptive
                ? Self.floorMinDb + effectiveSilenceDeltaDb
                : thresholdDb - Self.staticSilenceOffsetDb,
            floorDb: floorDb,
            calibrating: config.mode == .calibrated,
            usedFallback: false,
            retroactiveSpeechMs: 0,
            trailingSilenceMs: nil,
            dynamicsSpreadDb: nil,
            shortSpreadDb: nil
        )
    }

    private func updateFloor(
        targetDb: Double,
        frameDuration: Double,
        maximumRiseDbPerSecond: Double
    ) {
        guard var floor = floorDb else { return }
        if targetDb > floor {
            floor = min(targetDb, floor + maximumRiseDbPerSecond * frameDuration)
        } else {
            let alpha = 1.0 - exp(-frameDuration / effectiveFallTauSeconds)
            floor += alpha * (targetDb - floor)
        }
        if let speechCeilingDb {
            floor = min(floor, speechCeilingDb - effectiveAdaptiveDeltaDb - Self.speechCeilingMarginDb)
        }
        floorDb = clampFloor(floor)
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

    private func resetAdaptiveRollingWindow() {
        adaptiveRollingWriteIndex = 0
        adaptiveRollingCount = 0
        adaptiveRollingElapsed = 0
        adaptiveRollingPercentileCache = nil
    }

    private func adaptiveRollingPercentile() -> Double? {
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

    private func adaptiveRollingPercentileAtLeast(_ floorDb: Double) -> Bool {
        guard adaptiveRollingCount > 0 else { return false }

        let position = Self.adaptiveRollingPercentile * Double(adaptiveRollingCount - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, adaptiveRollingCount - 1)
        var belowCount = 0
        var maximumBelow = -Double.infinity
        var minimumAtOrAbove = Double.infinity

        for offset in 0..<adaptiveRollingCount {
            let index = (adaptiveRollingWriteIndex - adaptiveRollingCount + offset + Self.adaptiveRollingWindowCapacity)
                % Self.adaptiveRollingWindowCapacity
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
        lastOutput = VADGateOutput(
            isSpeech: lastOutput.isSpeech,
            evidence: lastOutput.evidence,
            thresholdDb: floorDb + effectiveAdaptiveDeltaDb,
            continuationThresholdDb: floorDb + effectiveAdaptiveContinuationDeltaDb,
            silenceThresholdDb: floorDb + effectiveSilenceDeltaDb,
            floorDb: floorDb,
            calibrating: lastOutput.calibrating,
            usedFallback: usedFallback,
            retroactiveSpeechMs: lastOutput.retroactiveSpeechMs,
            trailingSilenceMs: lastOutput.trailingSilenceMs,
            dynamicsSpreadDb: lastOutput.dynamicsSpreadDb,
            shortSpreadDb: lastOutput.shortSpreadDb
        )
    }

    private func classify(
        frameDb: Double,
        strongThresholdDb: Double,
        continuationThresholdDb: Double,
        silenceThresholdDb: Double
    ) -> (evidence: VADEvidence, strongThresholdDb: Double, continuationThresholdDb: Double, silenceThresholdDb: Double) {
        let evidence: VADEvidence
        if frameDb >= strongThresholdDb {
            evidence = .strong
        } else if frameDb >= continuationThresholdDb {
            evidence = .continuing
        } else if frameDb < silenceThresholdDb {
            evidence = .silence
        } else {
            evidence = .ambiguous
        }
        return (evidence, strongThresholdDb, continuationThresholdDb, silenceThresholdDb)
    }

    private func calibrationQ1() -> Double {
        var sortedDbs: [Double] = []
        sortedDbs.reserveCapacity(calibrationFrames.count)
        for frame in calibrationFrames {
            sortedDbs.append(frame.db)
        }
        sortedDbs.sort()
        let index = Int(Self.calibrationQuartile * Double(sortedDbs.count - 1))
        return sortedDbs[index]
    }

    private func calibrationThresholdDb() -> Double {
        guard !calibrationFrames.isEmpty else {
            return thresholdDb
        }
        return calibrationQ1() + config.calibratedOffsetDb
    }

    private func clampFloor(_ floor: Double) -> Double {
        min(max(floor, Self.floorMinDb), Self.floorMaxDb)
    }

    private func takeRetroactiveCredit() -> (Double, Double?) {
        let credit = (pendingRetroactiveSpeechMs, pendingTrailingSilenceMs)
        pendingRetroactiveSpeechMs = 0
        pendingTrailingSilenceMs = nil
        return credit
    }

    private func emit(
        evidence: VADEvidence,
        isSpeech: Bool,
        thresholdDb: Double,
        continuationThresholdDb: Double,
        silenceThresholdDb: Double,
        floorDb: Double?,
        calibrating: Bool,
        retroactiveSpeechMs: Double,
        trailingSilenceMs: Double?,
        dynamicsSpreadDb: Double? = nil,
        shortSpreadDb: Double? = nil
    ) -> VADGateOutput {
        let output = VADGateOutput(
            isSpeech: isSpeech,
            evidence: evidence,
            thresholdDb: thresholdDb,
            continuationThresholdDb: continuationThresholdDb,
            silenceThresholdDb: silenceThresholdDb,
            floorDb: floorDb,
            calibrating: calibrating,
            usedFallback: usedFallback,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs,
            dynamicsSpreadDb: dynamicsSpreadDb,
            shortSpreadDb: shortSpreadDb
        )
        lastOutput = output
        return output
    }
}
