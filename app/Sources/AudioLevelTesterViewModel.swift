import Foundation
import AVFoundation
import UIKit

@MainActor
final class AudioLevelTesterViewModel: ObservableObject {
    @Published private(set) var currentRms: Float = 0
    @Published private(set) var currentAnalysisDb: Double? = nil
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
    private var effectiveFlatSpreadDb = SharedConfig.Defaults.streamVadFlatSpreadDbDefault
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
        currentAnalysisDb = nil
        peakRms = 0
        rebuildGate()

        // Capture supersession token before the await — if stop() runs
        // during monitor.start(...), the token will diverge and we skip
        // writing stale state.
        sessionToken &+= 1
        let token = sessionToken

        do {
            try await monitor.start { [weak self] smoothed, peak, frameDuration, analysisRms in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.sessionToken == token,
                          let gate = self.gate,
                          let endpoint = self.endpoint else { return }
                    let frameDb = Double(AudioMath.dbFromRms(smoothed))
                    let output = gate.process(frameDb: frameDb, frameDuration: frameDuration)
                    let analysisDb = analysisRms.map { Double(AudioMath.dbFromRms($0)) }
                    let previousState = endpoint.state
                    if self.endpointMachineEnabled {
                        let durationSamples = max(0, Int((frameDuration * 16000.0).rounded()))
                        let evidence = StreamingEndpointEvidence(rawValue: output.evidence.rawValue) ?? .silence
                        var endpointEvidence = evidence
                        if previousState == .endPending,
                           let shortSpreadDb = output.shortSpreadDb,
                           let dynamicsSpreadDb = output.dynamicsSpreadDb,
                           shortSpreadDb < self.effectiveFlatSpreadDb,
                           dynamicsSpreadDb < VADThresholdGate.adaptiveEndPendingWindDispersionDb,
                           endpointEvidence == .continuing || endpointEvidence == .ambiguous {
                            endpointEvidence = .silence
                        }
                        _ = endpoint.process(evidence: endpointEvidence, durationSamples: durationSamples)
                        gate.updateFloorTracking(
                            frameDb: frameDb,
                            duration: frameDuration,
                            machineIsIdle: previousState == .idle && endpoint.state == .idle,
                            machineIsEnding: previousState == .endPending || endpoint.state == .endPending
                        )
                    } else {
                        gate.updateFloorTracking(
                            frameDb: frameDb,
                            duration: frameDuration,
                            machineIsIdle: !output.isSpeech
                        )
                    }
                    let effectiveOutput = gate.snapshot
                    self.currentRms = smoothed
                    self.currentAnalysisDb = analysisDb
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
        currentAnalysisDb = nil
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
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb(),
            adaptiveAbsoluteSpeechFloorDb: SharedConfig.streamVadAbsoluteSpeechFloorDb(),
            adaptiveRiseSpeedMultiplier: SharedConfig.streamVadAdaptationSpeed(),
            adaptiveSilenceDeltaDb: SharedConfig.streamVadAdaptiveSilenceDeltaDb(),
            adaptiveStaleFloorSeconds: SharedConfig.streamVadStaleFloorSeconds(),
            adaptiveFallTauSeconds: SharedConfig.streamVadFallTauSeconds(),
            adaptiveDynamicsEnabled: SharedConfig.streamVadDynamicsEnabled(),
            adaptiveDynamicsSpreadDb: SharedConfig.streamVadDynamicsSpreadDb(),
            adaptiveFlatSpreadDb: SharedConfig.streamVadFlatSpreadDb()
        ))
    }

    func rebuildGate(using config: VADGateConfig) {
        let newGate = VADThresholdGate(config: config)
        gate = newGate
        effectiveFlatSpreadDb = (newGate.effectiveParameters["flatSpreadDb"] as? Double)
            ?? SharedConfig.Defaults.streamVadFlatSpreadDbDefault
        endpoint = StreamingEndpoint(configuration: StreamingEndpointConfiguration(
            onsetSamples: Int(Double(SharedConfig.streamVadOnsetMs()) * 16.0),
            endEvidenceSamples: Int(Double(SharedConfig.streamVadEndEvidenceMs()) * 16.0),
            endpointSilenceSamples: Int(Double(SharedConfig.streamVadSilenceMs()) * 16.0),
            resumeSamples: Int(Double(SharedConfig.streamVadResumeMs()) * 16.0),
            ambiguousRescueSamples: Int(Double(SharedConfig.streamVadAmbiguousRescueMs()) * 16.0),
            preRollSamples: Int(Double(SharedConfig.streamVadPreRollMs()) * 16.0)
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
