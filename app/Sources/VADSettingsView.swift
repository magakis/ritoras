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
            Text("Speak normally, then set the threshold above the noise floor and below your speech.")
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
                        .fill(tester.currentRms < settings.streamVadSpeechRms ? Color.green : Color.red)
                        .frame(width: CGFloat(min(tester.currentRms / meterFullScale, 1.0)) * width)

                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2)
                        .offset(x: CGFloat(settings.streamVadSpeechRms / meterFullScale) * width)

                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 2)
                        .offset(x: CGFloat(min(tester.peakRms / meterFullScale, 1.0)) * width)
                }
            }
            .frame(height: 20)

            HStack {
                Text("now \(String(format: "%.4f", tester.currentRms))")
                Spacer()
                Text("peak \(String(format: "%.4f", tester.peakRms))")
                Spacer()
                Text("threshold \(String(format: "%.4f", settings.streamVadSpeechRms))")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if tester.isMonitoring && tester.currentRms < 0.001 {
                Text("Speak into the microphone to see levels.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        Section {
            silenceDurationRow
            speechRmsRow
            minSpeechDurationRow
            maxChunkDurationRow
        } footer: {
            Text("Changes apply on the next recording.")
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
                in: 500...5000,
                step: 100
            )
        }
    }

    private var speechRmsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speech RMS Threshold")
                Spacer()
                Text(String(format: "%.3f", settings.streamVadSpeechRms))
                    .foregroundColor(.secondary)
            }
            Text("lower = more sensitive")
                .font(.caption)
                .foregroundColor(.secondary)
            Slider(value: $settings.streamVadSpeechRms, in: 0.005...0.10, step: 0.005)
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

    private var maxChunkDurationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Max Chunk Duration")
                Spacer()
                Text(String(format: "%.1f s", settings.streamMaxChunkSeconds))
                    .foregroundColor(.secondary)
            }
            Text("longer = fewer, larger chunks")
                .font(.caption)
                .foregroundColor(.secondary)
            Slider(value: $settings.streamMaxChunkSeconds, in: 2...15, step: 0.5)
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
