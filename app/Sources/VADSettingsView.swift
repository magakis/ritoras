import SwiftUI
import UIKit

struct VADSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var tester = AudioLevelTesterViewModel()
    @State private var isCopyingDigest = false
    @State private var digestCopied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        formWithTesterRebuildHandlers
        .navigationTitle("Streaming VAD")
        .onDisappear {
            stopTester()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
    }

    private var formWithTesterRebuildHandlers: some View {
        formContent
            .onChange(of: settings.streamVadSensitivityProfile) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadAdaptationSpeed) { _, _ in
                rebuildTesterGate()
            }
    }

    private var formContent: some View {
        Form {
            testerSection
            controlsSection
        }
    }

    private func stopTester() {
        Task {
            await tester.stop()
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background {
            stopTester()
        }
        if phase == .active {
            Task {
                await tester.recheckPermission()
            }
        }
    }

    // MARK: - Tester Section

    private let meterFullScale: Float = 0.15

    private var testerSection: some View {
        Section {
            Toggle("Test Microphone", isOn: Binding(
                get: { tester.isMonitoring },
                set: { newValue in
                    Task {
                        if newValue { await tester.start() }
                        else { await tester.stop() }
                    }
                }
            ))

            if tester.permissionDenied {
                permissionDeniedRow
            } else {
                meterRow
            }
        } footer: {
            Text("Use the live meter to check microphone levels and tune VAD sensitivity. Green means an utterance is in progress; brief noise bumps stay red.")
        }
    }

    private var permissionDeniedRow: some View {
        HStack {
            Text("Microphone access denied. Enable it in Settings → Ritoras.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Open Settings") {
                tester.openSystemSettings()
            }
            .buttonStyle(.bordered)
        }
    }

    private var meterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            meterBar
            analysisLevelReadings
            levelReadings
            thresholdReadings
            fallbackStatus
            monitoringPrompt
        }
    }

    private var meterBar: some View {
        GeometryReader { geo in
            meterBarContent(width: geo.size.width)
        }
        .frame(height: 20)
    }

    private func meterBarContent(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5))
            currentLevelBar(width: width)
            floorMarker(width: width)
            thresholdMarker(width: width)
            peakMarker(width: width)
            calibrationOverlay
        }
    }

    private func currentLevelBar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tester.isSpeech ? Color.green : Color.red)
            .frame(width: CGFloat(min(tester.currentRms / meterFullScale, 1.0)) * width)
    }

    @ViewBuilder
    private func floorMarker(width: CGFloat) -> some View {
        if let floorDb = tester.floorDb {
            Rectangle()
                .fill(Color.gray)
                .frame(width: 1)
                .offset(x: meterOffset(db: floorDb, width: width))
        }
    }

    @ViewBuilder
    private func thresholdMarker(width: CGFloat) -> some View {
        if !tester.calibrating {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2)
                .offset(x: meterOffset(db: tester.thresholdDb, width: width))
        }
    }

    private func peakMarker(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue)
            .frame(width: 2)
            .offset(x: CGFloat(min(tester.peakRms / meterFullScale, 1.0)) * width)
    }

    @ViewBuilder
    private var calibrationOverlay: some View {
        if tester.calibrating {
            Text("Measuring… (\(Int(tester.calibrationElapsedMs.rounded())) / \(SharedConfig.streamVadCalibrationMs()) ms)")
                .font(.caption2)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func meterOffset(db: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(AudioMath.rmsFromDb(Float(db)) / meterFullScale, 1.0)) * width
    }

    private var levelReadings: some View {
        HStack {
            Text("now \(String(format: "%.4f", tester.currentRms))")
            Spacer()
            Text("peak \(String(format: "%.4f", tester.peakRms))")
            Spacer()
            Text(String(format: "onset %.1f dB", tester.thresholdDb))
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var analysisLevelReadings: some View {
        if let analysisDb = tester.currentAnalysisDb {
            HStack {
                Text(String(format: "raw %.1f dB", AudioMath.dbFromRms(tester.currentRms)))
                Spacer()
                Text(String(format: "analysis %.1f dB", analysisDb))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var thresholdReadings: some View {
        HStack {
            Text(String(format: "continue %.1f dB", tester.continuationThresholdDb))
            Spacer()
            Text(String(format: "silence %.1f dB", tester.silenceThresholdDb))
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var fallbackStatus: some View {
        if tester.usedFallback {
            Text("adaptive fallback")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var monitoringPrompt: some View {
        if tester.isMonitoring && tester.currentRms < 0.001 {
            Text("Speak into the microphone to see levels.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Controls Section

    @ViewBuilder
    private var controlsSection: some View {
        normalSection
        advancedDisclosure
    }

    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced") {
            Section {
                adaptationSpeedRow
            } header: {
                Text("Noise floor")
            } footer: {
                Text("How quickly the noise floor adapts to your room. 1.0× is balanced.")
            }
            diagnosticsSection
        }
    }

    private var normalSection: some View {
        Section {
            Picker("Sensitivity", selection: $settings.streamVadSensitivityProfile) {
                Text("Automatic").tag(VADSensitivityProfile.automatic)
                Text("Quiet Voice").tag(VADSensitivityProfile.quietVoice)
                Text("Noisy Environment").tag(VADSensitivityProfile.noisyEnvironment)
            }
        } header: {
            Text("Normal")
        } footer: {
            Text("Sensitivity adjusts voice detection for your environment.")
        }
    }

    private func rebuildTesterGate() {
        tester.rebuildGate(using: VADGateConfig(
            mode: SharedConfig.streamVadMode(),
            staticRms: SharedConfig.streamVadSpeechRms(),
            calibrationMs: SharedConfig.streamVadCalibrationMs(),
            calibratedOffsetDb: SharedConfig.streamVadCalibratedOffsetDb(),
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb(),
            adaptiveRiseSpeedMultiplier: settings.streamVadAdaptationSpeed,
            adaptiveSilenceDeltaDb: SharedConfig.streamVadAdaptiveSilenceDeltaDb(),
            adaptiveStaleFloorSeconds: SharedConfig.streamVadStaleFloorSeconds(),
            adaptiveFallTauSeconds: SharedConfig.streamVadFallTauSeconds(),
            adaptiveDynamicsEnabled: SharedConfig.streamVadDynamicsEnabled(),
            adaptiveDynamicsSpreadDb: SharedConfig.streamVadDynamicsSpreadDb(),
            adaptiveFlatSpreadDb: SharedConfig.streamVadFlatSpreadDb()
        ))
    }

    private var diagnosticsSection: some View {
        let telemetryURLs = RecordingStore.shared.streamTelemetryURLs()

        return Section {
            Toggle("VAD Telemetry", isOn: $settings.streamVadTelemetryEnabled)
            Text("Records per-frame VAD decisions to a file next to the session audio, for offline replay and tuning.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("\(telemetryURLs.count) of 20 telemetry recordings retained")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                copyDigest(files: telemetryURLs)
            } label: {
                if isCopyingDigest {
                    Label("Building Digest…", systemImage: "doc.on.doc")
                } else {
                    Label(digestCopied ? "Copied ✓" : "Copy Digest — Last 20 Recordings", systemImage: "doc.on.doc")
                }
            }
            .disabled(!settings.streamVadTelemetryEnabled || telemetryURLs.isEmpty || isCopyingDigest)

            if !settings.streamVadTelemetryEnabled {
                Text("Enable VAD Telemetry to copy a digest.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if telemetryURLs.isEmpty {
                Text("No telemetry recordings to summarize yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let url = RecordingStore.shared.newestStreamTelemetryURL() {
                ShareLink(item: url) {
                    Label("Share Latest Telemetry", systemImage: "square.and.arrow.up")
                }
            } else {
                Text("No telemetry file yet")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Changes take effect next session. The telemetry ring retains up to 20 recordings.")
        }
    }

    @MainActor
    private func copyDigest(files: [URL]) {
        isCopyingDigest = true
        digestCopied = false
        let globalSettings = globalVADSettings()
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                VADTelemetryDigest.buildText(
                    files: files,
                    globalSettings: globalSettings,
                    budget: VADTelemetryDigest.defaultBudget
                )
            }.value
            UIPasteboard.general.string = text
            isCopyingDigest = false
            digestCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                digestCopied = false
            }
        }
    }

    private func globalVADSettings() -> [(String, String)] {
        // This list intentionally mirrors the sessionStart config keys.
        [
            ("telemetryEnabled", SharedConfig.streamVadTelemetryEnabled() ? "ON" : "OFF"),
            ("mode", SharedConfig.streamVadMode().rawValue),
            ("sensitivity", SharedConfig.streamVadSensitivityProfile().rawValue),
            ("pause", SharedConfig.streamVadPauseProfile().rawValue),
            ("staticRms", "\(SharedConfig.streamVadSpeechRms())"),
            ("calibration", "\(SharedConfig.streamVadCalibrationMs())ms"),
            ("calibratedOffset", "\(SharedConfig.streamVadCalibratedOffsetDb())dB"),
            ("endpointSilence", "\(SharedConfig.streamVadSilenceMs())ms"),
            ("onset", "\(SharedConfig.streamVadOnsetMs())ms"),
            ("endEvidence", "\(SharedConfig.streamVadEndEvidenceMs())ms"),
            ("resume", "\(SharedConfig.streamVadResumeMs())ms"),
            ("rescue", "\(SharedConfig.streamVadAmbiguousRescueMs())ms"),
            ("preRoll", "\(SharedConfig.streamVadPreRollMs())ms"),
            ("minSpeech", "\(SharedConfig.streamVadMinSpeechMs())ms"),
            ("minChunk", "\(SharedConfig.streamVadMinChunkMs())ms"),
            ("adaptationSpeed", "\(SharedConfig.streamVadAdaptationSpeed())"),
            ("dynamicSpread", "\(SharedConfig.streamVadDynamicsSpreadDb())dB"),
            ("flatSpread", "\(SharedConfig.streamVadFlatSpreadDb())dB"),
            ("adaptiveDelta", "\(SharedConfig.streamVadAdaptiveDeltaDb())dB"),
            ("continuationDelta", "\(SharedConfig.streamVadAdaptiveContinuationDeltaDb())dB"),
            ("adaptiveSilenceDelta", "\(SharedConfig.streamVadAdaptiveSilenceDeltaDb())dB"),
            ("staleFloor", "\(SharedConfig.streamVadStaleFloorSeconds())s"),
            ("fallTau", "\(SharedConfig.streamVadFallTauSeconds())s"),
            ("dynamicsEnabled", SharedConfig.streamVadDynamicsEnabled() ? "true" : "false"),
            ("endpointMachineEnabled", SharedConfig.streamEndpointMachineEnabled() ? "true" : "false"),
            ("maxNoise", "\(SharedConfig.streamVadMaxNoiseSec())s"),
            ("analysisHpfEnabled", SharedConfig.streamVadAnalysisHpfEnabled() ? "true" : "false"),
            ("analysisHpfCutoff", "\(SharedConfig.Defaults.streamVadHpfCutoffHzDefault)Hz"),
            ("measurementMode", SharedConfig.audioMeasurementModeEnabled() ? "ON" : "OFF")
        ]
    }

    private var adaptationSpeedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Floor Adaptation Speed")
                Spacer()
                Text("\(settings.streamVadAdaptationSpeed, specifier: "%.1f")×")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadAdaptationSpeed, in: 0.5...4.0, step: 0.5)
        }
    }
}
