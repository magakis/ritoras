import SwiftUI

struct VADSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var tester = AudioLevelTesterViewModel()
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
        formWithProfileHandlers
    }

    private var formWithProfileHandlers: some View {
        formWithEndpointTimingHandlers
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

    private var formWithEndpointTimingHandlers: some View {
        formWithFloorDynamicsSpreadHandler
            .onChange(of: settings.streamVadOnsetMs) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadEndEvidenceMs) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadResumeMs) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadAmbiguousRescueMs) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadPreRollMs) { _, _ in
                rebuildTesterGate()
            }
    }

    private var formWithFloorDynamicsSpreadHandler: some View {
        formWithFloorDynamicsHandlers
            .onChange(of: settings.streamVadDynamicsSpreadDb) { _, _ in
                rebuildTesterGate()
            }
    }

    private var formWithFloorDynamicsHandlers: some View {
        formWithCoreHandlers
            .onChange(of: settings.streamVadAdaptationSpeed) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadAdaptiveSilenceDeltaDb) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadStaleFloorSeconds) { _, _ in
                rebuildTesterGate()
            }
            .onChange(of: settings.streamVadFallTauSeconds) { _, _ in
                rebuildTesterGate()
            }
    }

    private var formWithCoreHandlers: some View {
        formContent
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
    }

    private var formContent: some View {
        Form {
            testerSection
            controlsSection
            resetSection
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
            meterBar
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
            Text("Measuring… (\(Int(tester.calibrationElapsedMs.rounded())) / \(settings.streamVadCalibrationMs) ms)")
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
            modeSection
            advancedModeSection
            endpointTimingSection
            floorDynamicsSection
            signalPathSection
        }
    }

    private var advancedModeSection: some View {
        Section {
            modeSpecificRows
            minSpeechDurationRow
            minChunkDurationRow
        } footer: {
            advancedModeFooter
        }
    }

    @ViewBuilder
    private var modeSpecificRows: some View {
        switch settings.streamVadMode {
        case .staticMode:
            speechRmsRow
        case .calibrated:
            calibrationMsRow
            calibratedOffsetRow
        case .adaptive:
            adaptiveDeltaRow
        }
    }

    private var advancedModeFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changing the Normal sensitivity profile resets the Advanced Sensitivity Δ.")
            Text("Changes apply live to this tester and on the next recording.")
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
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb(),
            adaptiveRiseSpeedMultiplier: settings.streamVadAdaptationSpeed,
            adaptiveSilenceDeltaDb: settings.streamVadAdaptiveSilenceDeltaDb,
            adaptiveStaleFloorSeconds: settings.streamVadStaleFloorSeconds,
            adaptiveFallTauSeconds: settings.streamVadFallTauSeconds,
            adaptiveDynamicsEnabled: SharedConfig.streamVadDynamicsEnabled(),
            adaptiveDynamicsSpreadDb: settings.streamVadDynamicsSpreadDb
        ))
    }

    private var endpointTimingSection: some View {
        Section {
            endpointTimingRows
        } header: {
            Text("Endpoint timing")
        } footer: {
            endpointTimingFooter
        }
    }

    @ViewBuilder
    private var endpointTimingRows: some View {
        silenceDurationRow
        onsetConfirmationRow
        endEvidenceRow
        resumeGraceRow
        ambiguousRescueRow
        preRollRow
    }

    private var endpointTimingFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Endpoint timing applies to every mode; floor dynamics only to adaptive.")
            Button("Reset to Defaults", role: .destructive) {
                settings.resetVadEndpointTimingDefaults()
            }
        }
    }

    @ViewBuilder
    private var floorDynamicsSection: some View {
        if settings.streamVadMode == .adaptive {
            Section {
                floorDynamicsRows
            } header: {
                Text("Floor dynamics")
            } footer: {
                floorDynamicsFooter
            }
        }
    }

    @ViewBuilder
    private var floorDynamicsRows: some View {
        adaptationSpeedRow
        dynamicsSpreadRow
        adaptiveSilenceDeltaRow
        staleFloorRow
        fallTauRow
    }

    private var floorDynamicsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Floor dynamics control how adaptive mode follows changing room noise. 0.5× matches the previous steady feel.")
            Text("If detection misbehaves, turn off Dynamics to restore simple loudness-based detection.")
            Button("Reset to Defaults", role: .destructive) {
                settings.resetVadFloorDynamicsDefaults()
            }
        }
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

    private var onsetConfirmationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Onset Confirmation")
                Spacer()
                Text("\(settings.streamVadOnsetMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadOnsetMs) },
                    set: { settings.streamVadOnsetMs = Int($0) }
                ),
                in: 30...500,
                step: 10
            )
            Text("Loud audio must hold this long to start an utterance")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var endEvidenceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("End Evidence")
                Spacer()
                Text("\(settings.streamVadEndEvidenceMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadEndEvidenceMs) },
                    set: { settings.streamVadEndEvidenceMs = Int($0) }
                ),
                in: 50...500,
                step: 10
            )
            Text("Quiet must hold this long before the end timer arms")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var resumeGraceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Resume Grace")
                Spacer()
                Text("\(settings.streamVadResumeMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadResumeMs) },
                    set: { settings.streamVadResumeMs = Int($0) }
                ),
                in: 50...500,
                step: 10
            )
            Text("Speech must persist this long to cancel a pending end")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var ambiguousRescueRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ambiguous Rescue")
                Spacer()
                Text("\(settings.streamVadAmbiguousRescueMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadAmbiguousRescueMs) },
                    set: { settings.streamVadAmbiguousRescueMs = Int($0) }
                ),
                in: 100...1000,
                step: 10
            )
            Text("In-between audio this long pulls back a pending end")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var preRollRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pre-roll")
                Spacer()
                Text("\(settings.streamVadPreRollMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.streamVadPreRollMs) },
                    set: { settings.streamVadPreRollMs = Int($0) }
                ),
                in: 100...1000,
                step: 10
            )
            Text("Audio kept before each utterance — keep at or above 250 ms to capture the first word whole")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var adaptationSpeedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Adaptation Speed")
                Spacer()
                Text("\(settings.streamVadAdaptationSpeed, specifier: "%.1f")×")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadAdaptationSpeed, in: 0.5...4.0, step: 0.5)
            Text("How fast the floor follows the room getting louder")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var dynamicsSpreadRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dynamics Spread")
                Spacer()
                Text("\(settings.streamVadDynamicsSpreadDb, specifier: "%.1f") dB")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadDynamicsSpreadDb, in: 6...24, step: 0.5)
            Text("How much rise-and-fall counts as speech. Steady noise stays ambient.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var adaptiveSilenceDeltaRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Silence Δ")
                Spacer()
                Text("\(settings.streamVadAdaptiveSilenceDeltaDb, specifier: "%.1f") dB")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadAdaptiveSilenceDeltaDb, in: 1...5, step: 0.5)
            Text("How far above the floor still counts as quiet")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var staleFloorRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stale Window")
                Spacer()
                Text("\(settings.streamVadStaleFloorSeconds, specifier: "%.1f") s")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadStaleFloorSeconds, in: 0.5...5.0, step: 0.1)
            Text("Idle time without quiet before the floor snaps to the room")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var fallTauRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fall Speed")
                Spacer()
                Text("\(settings.streamVadFallTauSeconds, specifier: "%.1f") s")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.streamVadFallTauSeconds, in: 0.2...2.0, step: 0.1)
            Text("How fast the floor drops when the room quiets")
                .font(.caption)
                .foregroundColor(.secondary)
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
