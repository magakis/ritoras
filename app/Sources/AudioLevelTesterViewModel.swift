import Foundation
import AVFoundation
import UIKit

@MainActor
final class AudioLevelTesterViewModel: ObservableObject {
    @Published private(set) var currentRms: Float = 0
    @Published private(set) var peakRms: Float = 0
    @Published private(set) var thresholdDb: Double = Double(AudioMath.dbFromRms(SharedConfig.streamVadSpeechRms()))
    @Published private(set) var floorDb: Double?
    @Published private(set) var calibrating = false
    @Published private(set) var isSpeech = false
    @Published private(set) var usedFallback = false
    @Published private(set) var calibrationElapsedMs: Double = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var permissionDenied = false

    private let monitor = AudioLevelMonitor()
    private var gate: VADThresholdGate?
    private var sessionToken = 0

    func start() async {
        guard !isMonitoring else { return }

        // Check microphone permission
        let permission = AVAudioSession.sharedInstance().recordPermission
        switch permission {
        case .granted:
            break
        case .denied:
            permissionDenied = true
            return
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            if !granted {
                permissionDenied = true
                return
            }
        @unknown default:
            permissionDenied = true
            return
        }

        // Reset levels for a fresh monitoring session
        currentRms = 0
        peakRms = 0
        rebuildGate()

        // Capture supersession token before the await — if stop() runs
        // during monitor.start(...), the token will diverge and we skip
        // writing stale state.
        sessionToken &+= 1
        let token = sessionToken

        do {
            try await monitor.start { [weak self] smoothed, peak, frameDuration in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionToken == token, let gate = self.gate else { return }
                    let frameDb = Double(AudioMath.dbFromRms(smoothed))
                    let output = gate.process(frameDb: frameDb, frameDuration: frameDuration)
                    self.currentRms = smoothed
                    self.peakRms = peak
                    self.thresholdDb = output.thresholdDb
                    self.floorDb = output.floorDb
                    self.calibrating = output.calibrating
                    self.isSpeech = output.isSpeech
                    self.usedFallback = output.usedFallback
                    if output.calibrating {
                        let calibrationMs = Double(SharedConfig.streamVadCalibrationMs())
                        self.calibrationElapsedMs = min(
                            self.calibrationElapsedMs + frameDuration * 1000.0,
                            calibrationMs
                        )
                    } else {
                        self.calibrationElapsedMs = 0
                    }
                }
            }
            // Re-check: if stop() ran during the await, token is stale
            guard sessionToken == token else { return }
            isMonitoring = true
            if let output = gate?.snapshot {
                thresholdDb = output.thresholdDb
                floorDb = output.floorDb
                calibrating = output.calibrating
                usedFallback = output.usedFallback
            }
        } catch {
            guard sessionToken == token else { return }
            FileLogger.shared.warn(.audio, "AudioLevelTester start failed",
                                  payload: ["error": "\(error)"])
            isMonitoring = false
        }
    }

    func stop() async {
        // Invalidate any in-flight start() suspended across await
        sessionToken &+= 1

        await monitor.stop()

        isMonitoring = false
        currentRms = 0
        peakRms = 0
        thresholdDb = Double(AudioMath.dbFromRms(SharedConfig.streamVadSpeechRms()))
        floorDb = nil
        calibrating = false
        isSpeech = false
        usedFallback = false
        calibrationElapsedMs = 0
    }

    func recheckPermission() async {
        if AVAudioSession.sharedInstance().recordPermission == .granted {
            permissionDenied = false
        }
    }

    func rebuildGate() {
        gate = VADThresholdGate(config: VADGateConfig(
            mode: SharedConfig.streamVadMode(),
            staticRms: SharedConfig.streamVadSpeechRms(),
            calibrationMs: SharedConfig.streamVadCalibrationMs(),
            calibratedOffsetDb: SharedConfig.streamVadCalibratedOffsetDb(),
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveHysteresisEnabled: SharedConfig.streamVadAdaptiveHysteresisEnabled()
        ))

        let output = gate?.snapshot
        thresholdDb = output?.thresholdDb ?? Double(AudioMath.dbFromRms(SharedConfig.streamVadSpeechRms()))
        floorDb = output?.floorDb
        calibrating = isMonitoring && (output?.calibrating ?? false)
        isSpeech = false
        usedFallback = false
        calibrationElapsedMs = 0
    }

    func openSystemSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}
