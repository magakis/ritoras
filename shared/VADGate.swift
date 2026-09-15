import Foundation
import os

// These VAD types are intentionally top-level rather than nested in SharedConfig.
// Keeping the pure-logic gate self-contained mirrors scripts/prediction-sim/lib/vad-gate.mjs.

enum VADMode: String, CaseIterable {
    case staticMode = "static"
    case calibrated = "calibrated"
    case adaptive = "adaptive"
}

struct VADGateConfig {
    let mode: VADMode
    let staticRms: Float
    let calibrationMs: Int
    let calibratedOffsetDb: Double
    let adaptiveDeltaDb: Double
    let adaptiveHysteresisEnabled: Bool
}

struct VADGateOutput {
    let isSpeech: Bool
    let thresholdDb: Double
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
    private static let hysteresisBumpDb = 3.0
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
    private var inSpeech = false
    private var floorDb: Double?
    private var thresholdDb: Double
    private var usedFallback = false
    private var pendingRetroactiveSpeechMs = 0.0
    private var pendingTrailingSilenceMs: Double?
    private var unfairLock = os_unfair_lock()
    private var lastOutput: VADGateOutput

    init(config: VADGateConfig) {
        self.config = config
        self.behaviorMode = config.mode
        self.adaptiveSeedComplete = config.mode != .adaptive
        self.thresholdDb = Double(AudioMath.dbFromRms(config.staticRms))
        self.lastOutput = VADGateOutput(
            isSpeech: false,
            thresholdDb: Double(AudioMath.dbFromRms(config.staticRms)),
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
        let isSpeech = frameDb >= thresholdDb
        return emit(
            isSpeech: isSpeech,
            thresholdDb: thresholdDb,
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
            isSpeech: false,
            thresholdDb: calibrationThresholdDb(),
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
            inSpeech = false
            behaviorMode = .adaptive
            usedFallback = true
        }
        calibrationFinished = true
    }

    private func processCalibrated(frameDb: Double) -> VADGateOutput {
        let isSpeech = frameDb >= thresholdDb
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            isSpeech: isSpeech,
            thresholdDb: thresholdDb,
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
        let continueDb = config.adaptiveHysteresisEnabled
            ? startDb + Self.hysteresisBumpDb
            : startDb
        let decisionThreshold = inSpeech ? continueDb : startDb
        let isSpeech = frameDb >= decisionThreshold
        inSpeech = isSpeech

        if !isSpeech {
            updateFloor(frameDb: frameDb, frameDuration: frameDuration)
        }

        let outputFloor = floorDb
        let outputThreshold: Double
        if let outputFloor {
            let outputStartDb = outputFloor + config.adaptiveDeltaDb
            outputThreshold = inSpeech && config.adaptiveHysteresisEnabled
                ? outputStartDb + Self.hysteresisBumpDb
                : outputStartDb
        } else {
            outputThreshold = decisionThreshold
        }
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            isSpeech: isSpeech,
            thresholdDb: outputThreshold,
            floorDb: outputFloor,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs
        )
    }

    private func processAdaptiveSeed(frameDb: Double) -> VADGateOutput {
        adaptiveSeedDbs.append(frameDb)
        let runningMinimum = adaptiveSeedDbs.min() ?? frameDb
        let runningFloor = clampFloor(runningMinimum)
        // Before the sixth frame, decisions use the raw running minimum. The
        // exposed floor is clamped, and the sixth frame makes that clamped
        // value the steady-state floor.
        let startDb = runningMinimum + config.adaptiveDeltaDb
        let continueDb = config.adaptiveHysteresisEnabled
            ? startDb + Self.hysteresisBumpDb
            : startDb
        let decisionThreshold = inSpeech ? continueDb : startDb
        let isSpeech = frameDb >= decisionThreshold
        inSpeech = isSpeech
        floorDb = runningFloor

        if adaptiveSeedDbs.count >= Self.adaptiveSeedFrames {
            adaptiveSeedComplete = true
            adaptiveSeedDbs.removeAll(keepingCapacity: true)
        }

        let outputThreshold = inSpeech && config.adaptiveHysteresisEnabled
            ? runningFloor + config.adaptiveDeltaDb + Self.hysteresisBumpDb
            : runningFloor + config.adaptiveDeltaDb
        let (retroactiveSpeechMs, trailingSilenceMs) = takeRetroactiveCredit()
        return emit(
            isSpeech: isSpeech,
            thresholdDb: outputThreshold,
            floorDb: runningFloor,
            calibrating: false,
            retroactiveSpeechMs: retroactiveSpeechMs,
            trailingSilenceMs: trailingSilenceMs
        )
    }

    private func updateFloor(frameDb: Double, frameDuration: Double) {
        guard var floor = floorDb else { return }
        let tau = frameDb < floor ? Self.tauFall : Self.tauRise
        let alpha = 1.0 - exp(-frameDuration / tau)
        floor += alpha * (frameDb - floor)
        floorDb = clampFloor(floor)
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
        isSpeech: Bool,
        thresholdDb: Double,
        floorDb: Double?,
        calibrating: Bool,
        retroactiveSpeechMs: Double,
        trailingSilenceMs: Double?
    ) -> VADGateOutput {
        let output = VADGateOutput(
            isSpeech: isSpeech,
            thresholdDb: thresholdDb,
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
