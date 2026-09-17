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
}

final class VADThresholdGate: @unchecked Sendable {
    private struct CalibrationFrame {
        let db: Double
        let duration: Double
    }

    // Fixed algorithm constants. They are intentionally not user-facing settings.
    private static let tauFall = 0.5
    private static let tauRise = 7.0
    private static let silenceDeltaDb = 3.0
    private static let staticContinuationOffsetDb = 4.0
    private static let staticSilenceOffsetDb = 6.0
    private static let maximumRiseDbPerSecond = 1.5
    private static let stableSilenceForAdaptation = 0.3
    private static let floorMinDb = -80.0
    private static let floorMaxDb = -20.0
    private static let calibrationQuartile = 0.25
    private static let quietBandDb = 6.0
    private static let adaptiveSeedFrames = 6
    private static let calibrationCompletionEpsilon = 1e-9

    private let config: VADGateConfig
    private var behaviorMode: VADMode
    private var calibrationFinished = false
    private var calibrationElapsed = 0.0
    private var calibrationFrames: [CalibrationFrame] = []
    private var adaptiveSeedDbs: [Double] = []
    private var adaptiveSeedComplete: Bool
    private var adaptiveSeedLocked = false
    private var floorDb: Double?
    private var thresholdDb: Double
    private var usedFallback = false
    private var pendingRetroactiveSpeechMs = 0.0
    private var pendingTrailingSilenceMs: Double?
    private var idleSilenceElapsed = 0.0
    private var requiresStableSilence = false
    private var unfairLock = os_unfair_lock()
    private var lastOutput: VADGateOutput

    init(config: VADGateConfig) {
        self.config = config
        self.behaviorMode = config.mode
        self.adaptiveSeedComplete = config.mode != .adaptive
        self.thresholdDb = Double(AudioMath.dbFromRms(config.staticRms))
        self.lastOutput = VADGateOutput(
            isSpeech: false,
            evidence: .silence,
            thresholdDb: Double(AudioMath.dbFromRms(config.staticRms)),
            continuationThresholdDb: Double(AudioMath.dbFromRms(config.staticRms)) - Self.staticContinuationOffsetDb,
            silenceThresholdDb: Double(AudioMath.dbFromRms(config.staticRms)) - Self.staticSilenceOffsetDb,
            floorDb: nil,
            calibrating: config.mode == .calibrated,
            usedFallback: false,
            retroactiveSpeechMs: 0,
            trailingSilenceMs: nil
        )
        calibrationFrames.reserveCapacity(36)
        adaptiveSeedDbs.reserveCapacity(Self.adaptiveSeedFrames)
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
        // first frame, while the running minimum is the empty-window fallback.
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
            thresholdDb = seededFloor + config.adaptiveDeltaDb
            adaptiveSeedDbs.removeAll(keepingCapacity: true)
            adaptiveSeedComplete = true
            adaptiveSeedLocked = false
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
        if !adaptiveSeedComplete {
            return processAdaptiveSeed(frameDb: frameDb)
        }

        guard let currentFloor = floorDb else {
            // This is only reachable before the first adaptive seed frame. Keep
            // the interim behavior identical to the running-min seed path.
            adaptiveSeedComplete = false
            return processAdaptiveSeed(frameDb: frameDb)
        }

        let startDb = currentFloor + config.adaptiveDeltaDb
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: startDb,
            continuationThresholdDb: currentFloor + config.adaptiveContinuationDeltaDb,
            silenceThresholdDb: currentFloor + Self.silenceDeltaDb
        )
        noteEvidence(levels.evidence)
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            evidence: levels.evidence,
            isSpeech: levels.evidence == .strong || levels.evidence == .continuing,
            thresholdDb: levels.strongThresholdDb,
            continuationThresholdDb: levels.continuationThresholdDb,
            silenceThresholdDb: levels.silenceThresholdDb,
            floorDb: floorDb,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs
        )
    }

    private func processAdaptiveSeed(frameDb: Double) -> VADGateOutput {
        adaptiveSeedDbs.append(frameDb)
        let runningMinimum = adaptiveSeedDbs.min() ?? frameDb
        let runningFloor = clampFloor(runningMinimum)
        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: runningMinimum + config.adaptiveDeltaDb,
            continuationThresholdDb: runningMinimum + config.adaptiveContinuationDeltaDb,
            silenceThresholdDb: runningMinimum + Self.silenceDeltaDb
        )
        // Seed only while the window still looks idle. Once strong or
        // continuing evidence appears, speech cannot move the floor.
        if !adaptiveSeedLocked {
            floorDb = runningFloor
        }
        noteEvidence(levels.evidence)
        if levels.evidence == .strong || levels.evidence == .continuing {
            adaptiveSeedLocked = true
        }

        if adaptiveSeedDbs.count >= Self.adaptiveSeedFrames {
            adaptiveSeedComplete = true
            adaptiveSeedDbs.removeAll(keepingCapacity: true)
        }

        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            evidence: levels.evidence,
            isSpeech: levels.evidence == .strong || levels.evidence == .continuing,
            thresholdDb: (floorDb ?? runningFloor) + config.adaptiveDeltaDb,
            continuationThresholdDb: (floorDb ?? runningFloor) + config.adaptiveContinuationDeltaDb,
            silenceThresholdDb: (floorDb ?? runningFloor) + Self.silenceDeltaDb,
            floorDb: floorDb ?? runningFloor,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs
        )
    }

    /// Updates the adaptive floor only after the endpoint machine has reported
    /// confident idle. The caller supplies that state explicitly so speech and
    /// end-pending audio can never contaminate the floor.
    func updateFloorIfIdle(frameDb: Double, duration: Double) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        guard behaviorMode == .adaptive, let floor = floorDb else { return }

        let levels = classify(
            frameDb: frameDb,
            strongThresholdDb: floor + config.adaptiveDeltaDb,
            continuationThresholdDb: floor + config.adaptiveContinuationDeltaDb,
            silenceThresholdDb: floor + Self.silenceDeltaDb
        )
        guard levels.evidence == .silence else {
            idleSilenceElapsed = 0
            return
        }

        idleSilenceElapsed += duration
        if requiresStableSilence && idleSilenceElapsed + Self.calibrationCompletionEpsilon < Self.stableSilenceForAdaptation {
            return
        }
        updateFloor(frameDb: frameDb, frameDuration: duration)
        refreshAdaptiveOutput()
    }

    /// Resets adaptive tracking or calibration after an audio-route change.
    func recalibrateFloor() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        switch config.mode {
        case .adaptive:
            behaviorMode = .adaptive
            adaptiveSeedDbs.removeAll(keepingCapacity: true)
            adaptiveSeedComplete = false
            adaptiveSeedLocked = false
            floorDb = nil
        case .calibrated:
            behaviorMode = .calibrated
            calibrationFinished = false
            calibrationElapsed = 0
            calibrationFrames.removeAll(keepingCapacity: true)
            pendingRetroactiveSpeechMs = 0
            pendingTrailingSilenceMs = nil
            floorDb = nil
            adaptiveSeedDbs.removeAll(keepingCapacity: true)
            adaptiveSeedComplete = false
            adaptiveSeedLocked = false
        case .staticMode:
            return
        }
        thresholdDb = Double(AudioMath.dbFromRms(config.staticRms))
        idleSilenceElapsed = 0
        requiresStableSilence = false
        usedFallback = false
        lastOutput = VADGateOutput(
            isSpeech: false,
            evidence: .silence,
            thresholdDb: thresholdDb,
            continuationThresholdDb: thresholdDb - Self.staticContinuationOffsetDb,
            silenceThresholdDb: thresholdDb - Self.staticSilenceOffsetDb,
            floorDb: nil,
            calibrating: config.mode == .calibrated,
            usedFallback: false,
            retroactiveSpeechMs: 0,
            trailingSilenceMs: nil
        )
    }

    private func updateFloor(frameDb: Double, frameDuration: Double) {
        guard var floor = floorDb else { return }
        let tau = frameDb < floor ? Self.tauFall : Self.tauRise
        let alpha = 1.0 - exp(-frameDuration / tau)
        let proposed = floor + alpha * (frameDb - floor)
        if proposed > floor {
            floor = min(proposed, floor + Self.maximumRiseDbPerSecond * frameDuration)
        } else {
            floor = proposed
        }
        floorDb = clampFloor(floor)
    }

    private func noteEvidence(_ evidence: VADEvidence) {
        if evidence == .strong || evidence == .continuing {
            requiresStableSilence = true
            idleSilenceElapsed = 0
        }
    }

    private func refreshAdaptiveOutput() {
        guard let floorDb else { return }
        lastOutput = VADGateOutput(
            isSpeech: lastOutput.isSpeech,
            evidence: lastOutput.evidence,
            thresholdDb: floorDb + config.adaptiveDeltaDb,
            continuationThresholdDb: floorDb + config.adaptiveContinuationDeltaDb,
            silenceThresholdDb: floorDb + Self.silenceDeltaDb,
            floorDb: floorDb,
            calibrating: lastOutput.calibrating,
            usedFallback: usedFallback,
            retroactiveSpeechMs: lastOutput.retroactiveSpeechMs,
            trailingSilenceMs: lastOutput.trailingSilenceMs
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
        trailingSilenceMs: Double?
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
            trailingSilenceMs: trailingSilenceMs
        )
        lastOutput = output
        return output
    }
}
