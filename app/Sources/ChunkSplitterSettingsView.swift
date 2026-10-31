import SwiftUI
import UIKit

struct ChunkSplitterSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var tester = AudioLevelTesterViewModel()
    @State private var isCopyingDigest = false
    @State private var digestCopied = false
    @State private var isBuildingTelemetryZip = false
    @State private var telemetryZipURL: URL?
    @State private var telemetryZipError: String?
    @State private var isShowingResetConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        formWithTesterRebuildHandlers
        .navigationTitle("Streaming")
        .onDisappear {
            stopTester()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
    }

    private var formWithTesterRebuildHandlers: some View {
        formContent
        .onChange(of: settings.chunkSplitterMode) { _, _ in
                rebuildTesterGate()
            }
        .onChange(of: settings.chunkSplitterSpeechRms) { _, _ in
                rebuildTesterGate()
            }
        .onChange(of: settings.chunkSplitterAbsoluteSpeechFloorDb) { _, _ in
                rebuildTesterGate()
            }
    }

    private var formContent: some View {
        Form {
            aacSection
            testerSection
            controlsSection
            resetSection
        }
        .alert("Reset Streaming Settings?", isPresented: $isShowingResetConfirmation) {
            Button("Reset to Defaults", role: .destructive) {
                settings.resetStreamingSettingsToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Streaming and chunk splitter settings will be restored to their defaults.")
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

    // MARK: - Audio Format Section

    private var aacSection: some View {
        Section {
            Toggle("AAC Streaming", isOn: $settings.streamAacEnabled)

            Picker("Source Rate", selection: $settings.streamAacSourceSampleRate) {
                Text("16 kHz").tag(16_000)
                Text("48 kHz").tag(48_000)
            }
            .pickerStyle(.segmented)
            .disabled(!settings.streamAacEnabled)
        } header: {
            Text("Audio Format")
        } footer: {
            Text(
                "AAC chunks are negotiated with the server before audio is sent. "
                    + "Unsupported servers continue with Float32 PCM. "
                    + "Changes take effect next session."
            )
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
            if settings.chunkSplitterVADSource == .silero {
                Text("The meter shows DSP level classification for reference; Silero CoreML decisions use speech probability instead.")
            } else {
                Text("Use the live meter to check microphone levels and tune the chunk splitter's voice sensitivity. Green means an utterance is in progress; brief noise bumps stay red.")
            }
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

    private func thresholdMarker(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.orange)
            .frame(width: 2)
            .offset(x: meterOffset(db: tester.thresholdDb, width: width))
    }

    private func peakMarker(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.blue)
            .frame(width: 2)
            .offset(x: CGFloat(min(tester.peakRms / meterFullScale, 1.0)) * width)
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
        modeSection
        advancedDisclosure
    }

    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced") {
            diagnosticsSection
        }
    }

    private var normalSection: some View {
        Section {
            if settings.chunkSplitterVADSource == .dsp {
                absoluteSpeechFloorRow
            }
            silenceDurationRow
        } header: {
            Text("Basics")
        } footer: {
            if settings.chunkSplitterVADSource == .silero {
                Text("Silence duration controls how long the endpoint waits before closing an utterance. 700 ms is the default; 450 ms is the minimum.")
            } else {
                Text("Sensitivity adjusts voice detection for your environment. Silence duration controls how long the chunk splitter waits in silence before closing the utterance. 700 ms is the default; 450 ms is the minimum.")
            }
        }
    }

    private var silenceDurationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Silence Duration")
                Spacer()
                Text("\(settings.chunkSplitterSilenceMs) ms")
                    .foregroundColor(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.chunkSplitterSilenceMs) },
                    set: { settings.chunkSplitterSilenceMs = Int($0) }
                ),
                in: 450...5000,
                step: 50
            )
        }
    }

    private var absoluteSpeechFloorRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Minimum speech level")
                Spacer()
                Text(String(format: "%.0f dB", settings.chunkSplitterAbsoluteSpeechFloorDb))
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.chunkSplitterAbsoluteSpeechFloorDb, in: -80...(-30), step: 1)
            Text("Sets the quietest level that can count as speech. Lower values can hear whisper-quiet speech in quiet rooms, but may pick up faint background noise. Values above the room's noise floor have no effect. Try −65 dB for whisper testing.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset Streaming Settings to Defaults", role: .destructive) {
                isShowingResetConfirmation = true
            }
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Evidence source", selection: $settings.chunkSplitterVADSource) {
                ForEach(VADSource.allCases, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }

            if settings.chunkSplitterVADSource == .dsp {
                Picker("Detection", selection: $settings.chunkSplitterMode) {
                    ForEach(VADMode.allCases, id: \.self) { mode in
                        switch mode {
                        case .staticMode:
                            Text("Static").tag(mode)
                        case .adaptive:
                            Text("Adaptive").tag(mode)
                        }
                    }
                }
                .pickerStyle(.segmented)

                if settings.chunkSplitterMode == .staticMode {
                    speechRmsRow
                }
            } else {
                sileroSettingsRows
            }
        } header: {
            Text("Mode")
        } footer: {
            modeHelpText
        }
    }

    @ViewBuilder
    private var modeHelpText: some View {
        if settings.chunkSplitterVADSource == .silero {
            Text(
                "Silero CoreML analyzes 576-sample windows at 16 kHz. "
                    + "Probability thresholds classify strong speech, continuation, or silence; "
                    + "the DSP level gate is bypassed. Changes take effect next session."
            )
        } else {
            switch settings.chunkSplitterMode {
            case .staticMode:
                Text("One fixed level bar. Retune it when your environment changes.")
            case .adaptive:
                Text("Seeds the noise floor from the quietest tenth of the first second, then tracks it continuously. Δ is how far above the floor speech must be — lower it for whispering (try 6–8). Best hands-off choice across environments.")
            }
        }
    }

    private var sileroSettingsRows: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Start threshold")
                    Spacer()
                    Text(String(format: "%.2f", settings.sileroStartThreshold))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.sileroStartThreshold, in: 0.10...0.90, step: 0.01)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Stop threshold")
                    Spacer()
                    Text(String(format: "%.2f", min(settings.sileroStopThreshold, settings.sileroStartThreshold)))
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { min(settings.sileroStopThreshold, settings.sileroStartThreshold) },
                        set: { settings.sileroStopThreshold = $0 }
                    ),
                    in: 0.10...settings.sileroStartThreshold,
                    step: 0.01
                )
            }

            Stepper(
                "Smoothing: \(settings.sileroSmoothingSteps) model steps",
                value: $settings.sileroSmoothingSteps,
                in: 1...15
            )
        }
    }

    private var speechRmsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speech RMS Threshold")
                Spacer()
                TextField("0.025", value: $settings.chunkSplitterSpeechRms, format: .number.precision(.fractionLength(3...4)))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 84)
            }
            Text("lower = more sensitive")
                .font(.caption)
                .foregroundColor(.secondary)
            Slider(value: $settings.chunkSplitterSpeechRms, in: 0.005...0.10, step: 0.001)
        }
    }

    private func rebuildTesterGate() {
        tester.rebuildGate(using: VADGateConfig(
            mode: SharedConfig.streamVadMode(),
            staticRms: SharedConfig.streamVadSpeechRms(),
            adaptiveDeltaDb: SharedConfig.streamVadAdaptiveDeltaDb(),
            adaptiveContinuationDeltaDb: SharedConfig.streamVadAdaptiveContinuationDeltaDb(),
            adaptiveAbsoluteSpeechFloorDb: settings.chunkSplitterAbsoluteSpeechFloorDb,
            adaptiveRiseSpeedMultiplier: 1.0,
            adaptiveSilenceDeltaDb: SharedConfig.streamVadAdaptiveSilenceDeltaDb(),
            ceilingMarginDb: SharedConfig.streamVadCeilingMarginDb(),
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
            Toggle("Chunk Splitter Telemetry", isOn: $settings.chunkSplitterTelemetryEnabled)
            Text("Records per-frame chunk-splitting decisions to a file next to the session audio, for offline replay and tuning.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Full Recording Upload", isOn: $settings.fullRecordingUploadEnabled)
            Text("Uploads the complete session recording before chunk splitting for diagnostics after each streamed transcription.")
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
            .disabled(!settings.chunkSplitterTelemetryEnabled || telemetryURLs.isEmpty || isCopyingDigest)

            if !settings.chunkSplitterTelemetryEnabled {
                Text("Enable Chunk Splitter Telemetry to copy a digest.")
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

            if !telemetryURLs.isEmpty {
                Button {
                    Task { await buildAndShareTelemetryZip(from: telemetryURLs) }
                } label: {
                    if isBuildingTelemetryZip {
                        Label("Building Zip…", systemImage: "square.and.arrow.up")
                    } else {
                        Label("Share Full Telemetry — Last 20 Recordings", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isBuildingTelemetryZip || telemetryURLs.isEmpty)

                if let telemetryZipError {
                    Text(telemetryZipError)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Changes take effect next session. The telemetry ring retains up to 20 recordings.")
        }
        .sheet(isPresented: Binding(
            get: { telemetryZipURL != nil },
            set: { isPresented in
                if !isPresented { cleanupTelemetryZip() }
            }
        )) {
            if let url = telemetryZipURL {
                ActivityShareSheet(items: [url])
            }
        }
    }

    @MainActor
    private func buildAndShareTelemetryZip(from files: [URL]) async {
        guard !isBuildingTelemetryZip else { return }
        isBuildingTelemetryZip = true
        telemetryZipError = nil

        do {
            let zipURL = try await Task.detached(priority: .userInitiated) {
                try Self.buildTelemetryZip(from: files)
            }.value
            telemetryZipURL = zipURL
        } catch {
            FileLogger.shared.log(.warn, .app, "telemetry zip build failed")
            telemetryZipError = "Couldn't build the zip — try again."
        }

        isBuildingTelemetryZip = false
    }

    private static func buildTelemetryZip(from files: [URL]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let stagedDirectory = temporaryDirectory.appendingPathComponent("ritoras-chunk-splitter-telemetry-\(stamp)", isDirectory: true)
        let zipURL = temporaryDirectory.appendingPathComponent("ritoras-chunk-splitter-telemetry-\(stamp).zip")
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagedDirectory) }

        for file in files {
            do {
                try fileManager.copyItem(at: file, to: stagedDirectory.appendingPathComponent(file.lastPathComponent))
            } catch {
                FileLogger.shared.log(.warn, .app, "telemetry file skipped")
            }
        }

        var coordinationError: NSError?
        var zipError: Error?
        NSFileCoordinator().coordinate(readingItemAt: stagedDirectory, options: .forUploading, error: &coordinationError) { zippedURL in
            do {
                try? fileManager.removeItem(at: zipURL)
                try fileManager.copyItem(at: zippedURL, to: zipURL)
            } catch {
                zipError = error
            }
        }

        if let zipError { throw zipError }
        if let coordinationError { throw coordinationError }
        return zipURL
    }

    @MainActor
    private func cleanupTelemetryZip() {
        if let telemetryZipURL {
            try? FileManager.default.removeItem(at: telemetryZipURL)
        }
        telemetryZipURL = nil
    }

    @MainActor
    private func copyDigest(files: [URL]) {
        isCopyingDigest = true
        digestCopied = false
        let globalSettings = globalChunkSplitterSettings()
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                ChunkSplitterTelemetryDigest.buildText(
                    files: files,
                    globalSettings: globalSettings,
                    budget: ChunkSplitterTelemetryDigest.defaultBudget
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

    private func globalChunkSplitterSettings() -> [(String, String)] {
        // This list intentionally mirrors the sessionStart config keys.
        let sileroConfiguration = SharedConfig.sileroEvidenceConfiguration()
        return [
            ("telemetryEnabled", SharedConfig.chunkSplitterTelemetryEnabled() ? "ON" : "OFF"),
            ("vadSource", SharedConfig.vadSource().rawValue),
            ("sileroStartThreshold", "\(sileroConfiguration.startThreshold)"),
            ("sileroStopThreshold", "\(sileroConfiguration.stopThreshold)"),
            ("sileroSmoothingSteps", "\(sileroConfiguration.smoothingSteps)"),
            ("mode", SharedConfig.streamVadMode().rawValue),
            ("pause", SharedConfig.chunkSplitterPauseProfile().rawValue),
            ("staticRms", "\(SharedConfig.streamVadSpeechRms())"),
            ("endpointSilence", "\(SharedConfig.chunkSplitterSilenceMs())ms"),
            ("onset", "\(SharedConfig.streamVadOnsetMs())ms"),
            ("endEvidence", "\(SharedConfig.streamVadEndEvidenceMs())ms"),
            ("resume", "\(SharedConfig.streamVadResumeMs())ms"),
            ("rescue", "\(SharedConfig.streamVadAmbiguousRescueMs())ms"),
            ("minSpeech", "\(SharedConfig.streamVadMinSpeechMs())ms"),
            ("minChunk", "\(SharedConfig.streamVadMinChunkMs())ms"),
            ("adaptationSpeed", "1.0"),
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
}
