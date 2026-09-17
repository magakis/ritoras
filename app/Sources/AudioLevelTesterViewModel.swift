import Foundation
import AVFoundation
import UIKit

@MainActor
final class AudioLevelTesterViewModel: ObservableObject {
    @Published private(set) var currentRms: Float = 0
    @Published private(set) var peakRms: Float = 0
    @Published private(set) var thresholdDb: Double = Double(AudioMath.dbFromRms(SharedConfig.streamVadSpeechRms()))
    @Published private(set) var continuationThresholdDb: Double = Double(AudioMath.dbFromRms(SharedConfig.streamVadSpeechRms())) - 4.0
    @Published private(set) var silenceThresholdDb: Double = Double(AudioMath.dbFromRms(SharedConfig.streamVadSpeechRms())) - 6.0
    @Published private(set) var floorDb: Double?
    @Published private(set) var calibrating = false
    @Published private(set) var isSpeech = false
    @Published private(set) var usedFallback = false
    @Published private(set) var calibrationElapsedMs: Double = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var permissionDenied = false

    private let monitor = AudioLevelMonitor()
    private var gate: VADThresholdGate?
    private var endpoint: StreamingEndpoint?
    private var endpointMachineEnabled = true
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
                    guard let self,
                          self.sessionToken == token,
                          let gate = self.gate,
                          let endpoint = self.endpoint else { return }
                    let frameDb = Double(AudioMath.dbFromRms(smoothed))
                    let output = gate.process(frameDb: frameDb, frameDuration: frameDuration)
                    let previousState = endpoint.state
                    if self.endpointMachineEnabled {
                        let durationSamples = max(0, Int((frameDuration * 16000.0).rounded()))
                        let evidence = StreamingEndpointEvidence(rawValue: output.evidence.rawValue) ?? .silence
                        _ = endpoint.process(evidence: evidence, durationSamples: durationSamples)
                        gate.updateFloorIfIdle(
                            frameDb: frameDb,
                            duration: frameDuration,
                            machineIsIdle: previousState == .idle && endpoint.state == .idle,
                            utteranceOpened: previousState != .speechActive && endpoint.state == .speechActive
                        )
                    } else {
                        gate.updateFloorIfIdle(
                            frameDb: frameDb,
                            duration: frameDuration,
                            machineIsIdle: !output.isSpeech
                        )
                    }
                    let effectiveOutput = gate.snapshot
                    self.currentRms = smoothed
                    self.peakRms = peak
                    self.thresholdDb = effectiveOutput.thresholdDb
                    self.continuationThresholdDb = effectiveOutput.continuationThresholdDb
                    self.silenceThresholdDb = effectiveOutput.silenceThresholdDb
                    self.floorDb = effectiveOutput.floorDb
                    self.calibrating = effectiveOutput.calibrating
                    self.isSpeech = self.endpointMachineEnabled
                        ? endpoint.state == .speechActive || endpoint.state == .endPending
                        : effectiveOutput.isSpeech
                    self.usedFallback = effectiveOutput.usedFallback
                    if effectiveOutput.calibrating {
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
                continuationThresholdDb = output.continuationThresholdDb
                silenceThresholdDb = output.silenceThresholdDb
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
        continuationThresholdDb = 0
        silenceThresholdDb = 0
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
        rebuildGate(using: VADGateConfig(
            mode: SharedConfig.streamVadMode(),
            staticRms: SharedConfig.streamVadSpeechRms(),
            calibrationMs: SharedConfig.streamVadCalibrationMs(),
            calibratedOffsetDb: SharedConfig.streamVadCalibratedOffsetDb(),
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb()
        ))
    }

    func rebuildGate(using config: VADGateConfig) {
        gate = VADThresholdGate(config: config)
        endpoint = StreamingEndpoint(configuration: StreamingEndpointConfiguration(
            endpointSilenceSamples: Int(Double(SharedConfig.streamVadSilenceMs()) * 16.0),
            preRollSamples: Int(Double(SharedConfig.Defaults.streamVadPreRollMsDefault) * 16.0)
        ))
        endpointMachineEnabled = SharedConfig.streamEndpointMachineEnabled()

        let output = gate?.snapshot
        thresholdDb = output?.thresholdDb ?? Double(AudioMath.dbFromRms(config.staticRms))
        continuationThresholdDb = output?.continuationThresholdDb ?? 0
        silenceThresholdDb = output?.silenceThresholdDb ?? 0
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
