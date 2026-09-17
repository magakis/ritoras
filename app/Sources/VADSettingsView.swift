import SwiftUI

struct VADSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var tester = AudioLevelTesterViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            testerSection
            controlsSection
            resetSection
        }
        .navigationTitle("Streaming VAD")
        .onDisappear {
            Task {
                await tester.stop()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                Task {
                    await tester.stop()
                }
            }
            if phase == .active {
                Task {
                    await tester.recheckPermission()
                }
            }
        }
        .onChange(of: settings.streamVadMode) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.streamVadCalibrationMs) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.streamVadCalibratedOffsetDb) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.streamVadAdaptiveDeltaDb) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.streamVadSensitivityProfile) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.streamVadPauseProfile) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.streamVadSpeechRms) { _, _ in
            rebuildTesterGate()
        }
        .onChange(of: settings.audioMeasurementModeEnabled) { _, _ in
            rebuildTesterGate()
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
            Text("Use the live meter to check microphone levels and tune the selected VAD mode. Green means an utterance is in progress; brief noise bumps stay red.")
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
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(tester.isSpeech ? Color.green : Color.red)
                        .frame(width: CGFloat(min(tester.currentRms / meterFullScale, 1.0)) * width)

                    if let floorDb = tester.floorDb {
                        Rectangle()
                            .fill(Color.gray)
                            .frame(width: 1)
                            .offset(x: CGFloat(min(
                                AudioMath.rmsFromDb(Float(floorDb)) / meterFullScale,
                                1.0
                            )) * width)
                    }

                    if !tester.calibrating {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2)
                            .offset(x: CGFloat(min(
                                AudioMath.rmsFromDb(Float(tester.thresholdDb)) / meterFullScale,
                                1.0
                            )) * width)
                    }

                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 2)
                        .offset(x: CGFloat(min(tester.peakRms / meterFullScale, 1.0)) * width)

                    if tester.calibrating {
                        Text("Measuring… (\(Int(tester.calibrationElapsedMs.rounded())) / \(settings.streamVadCalibrationMs) ms)")
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(height: 20)

            HStack {
                Text("now \(String(format: "%.4f", tester.currentRms))")
                Spacer()
                Text("peak \(String(format: "%.4f", tester.peakRms))")
                Spacer()
                Text(String(format: "onset %.1f dB", tester.thresholdDb))
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack {
                Text(String(format: "continue %.1f dB", tester.continuationThresholdDb))
                Spacer()
                Text(String(format: "silence %.1f dB", tester.silenceThresholdDb))
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if tester.usedFallback {
                Text("adaptive fallback")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if tester.isMonitoring && tester.currentRms < 0.001 {
                Text("Speak into the microphone to see levels.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Controls Section

    @ViewBuilder
    private var controlsSection: some View {
        normalSection

        DisclosureGroup("Advanced") {
            modeSection

            Section {
                silenceDurationRow
                switch settings.streamVadMode {
                case .staticMode:
                    speechRmsRow
                case .calibrated:
                    calibrationMsRow
                    calibratedOffsetRow
                case .adaptive:
                    adaptiveDeltaRow
                }
                minSpeechDurationRow
                minChunkDurationRow
                maxNoiseRow
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Silence duration is a legacy control; changing it selects the nearest pause profile.")
                    Text("Changes apply live to this tester and on the next recording.")
                }
            }

            signalPathSection
        }
    }

    private var normalSection: some View {
        Section {
            Picker("Sensitivity", selection: $settings.streamVadSensitivityProfile) {
                Text("Automatic").tag(VADSensitivityProfile.automatic)
                Text("Quiet Voice").tag(VADSensitivityProfile.quietVoice)
                Text("Noisy Environment").tag(VADSensitivityProfile.noisyEnvironment)
            }

            Picker("Pause", selection: $settings.streamVadPauseProfile) {
                Text("Fast").tag(VADPauseProfile.fast)
                Text("Balanced").tag(VADPauseProfile.balanced)
                Text("Long").tag(VADPauseProfile.long)
            }
        } header: {
            Text("Normal")
        } footer: {
            Text("Sensitivity adjusts voice detection for your environment. Pause closes after 450 ms, 700 ms, or 1100 ms of silence.")
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Detection", selection: $settings.streamVadMode) {
                ForEach(VADMode.allCases, id: \.self) { mode in
                    switch mode {
                    case .staticMode:
                        Text("Static").tag(mode)
                    case .calibrated:
                        Text("Calibrated").tag(mode)
                    case .adaptive:
                        Text("Adaptive").tag(mode)
                    }
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Mode")
        } footer: {
            modeHelpText
        }
    }

    private var modeHelpText: some View {
        switch settings.streamVadMode {
        case .staticMode:
            Text("One fixed level bar. Retune it when your environment changes.")
        case .calibrated:
            Text("Start talking whenever you like — the measurement ignores speech and needs no quiet period. It reads the quiet quarter of the first moments of each dictation. Raise Δ if chunks fire on noise; if you talk through the whole window it switches to adaptive tracking automatically.")
        case .adaptive:
            Text("Seeds the noise floor from the quietest tenth of the first second, then tracks it continuously. Δ is how far above the floor speech must be — lower it for whispering (try 6–8). Best hands-off choice across environments.")
        }
    }

    private func rebuildTesterGate() {
        tester.rebuildGate(using: VADGateConfig(
            mode: settings.streamVadMode,
            staticRms: settings.streamVadSpeechRms,
            calibrationMs: settings.streamVadCalibrationMs,
            calibratedOffsetDb: settings.streamVadCalibratedOffsetDb,
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb()
        ))
    }

    private var signalPathSection: some View {
        Section {
            Toggle("Measurement Mode", isOn: $settings.audioMeasurementModeEnabled)
        } header: {
            Text("Signal Path")
        } footer: {
            Text("Off by default. Strips iOS audio processing (AGC); this can sound worse in wind or crowds and changes the absolute level scale.")
        }
    }

    private var silenceDurationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Silence Duration")
                Spacer()
                Text("\(settings.streamVadSilenceMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadSilenceMs) },
                    set: { settings.streamVadSilenceMs = Int($0) }
                ),
                in: 450...5000,
                step: 100
            )
        }
    }

    private var speechRmsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speech RMS Threshold")
                Spacer()
                TextField("0.025", value: $settings.streamVadSpeechRms, format: .number.precision(.fractionLength(3...4)))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
            }
            Text("lower = more sensitive")
                .font(.caption)
                .foregroundColor(.secondary)
            Slider(value: $settings.streamVadSpeechRms, in: 0.005...0.10, step: 0.001)
        }
    }

    private var calibrationMsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Calibration Window")
                Spacer()
                Text("\(settings.streamVadCalibrationMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadCalibrationMs) },
                    set: { settings.streamVadCalibrationMs = Int($0) }
                ),
                in: 500...3000,
                step: 100
            )
        }
    }

    private var calibratedOffsetRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sensitivity Δ")
                Spacer()
                Text("\(settings.streamVadCalibratedOffsetDb, specifier: "%.0f") dB")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadCalibratedOffsetDb, in: 3...20, step: 1)
        }
    }

    private var adaptiveDeltaRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sensitivity Δ")
                Spacer()
                Text("\(settings.streamVadAdaptiveDeltaDb, specifier: "%.0f") dB")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadAdaptiveDeltaDb, in: 3...24, step: 1)
        }
    }

    private var minSpeechDurationRow: some View {
        Stepper(value: $settings.streamVadMinSpeechMs, in: 100...1000, step: 50) {
            HStack {
                Text("Min Speech Duration")
                Spacer()
                Text("\(settings.streamVadMinSpeechMs) ms")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var minChunkDurationRow: some View {
        Stepper(value: $settings.streamVadMinChunkMs, in: 100...2000, step: 50) {
            HStack {
                Text("Min Chunk Duration")
                Spacer()
                Text("\(settings.streamVadMinChunkMs) ms")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var maxNoiseRow: some View {
        Stepper(value: $settings.streamVadMaxNoiseSec, in: 2...15, step: 1) {
            HStack {
                Text("Max Noise Duration")
                Spacer()
                Text("\(settings.streamVadMaxNoiseSec, specifier: "%.0f") s")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        Section {
            Button("Reset VAD to Defaults", role: .destructive) {
                settings.resetVadToDefaults()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
