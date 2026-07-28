import SwiftUI

struct VADSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            controlsSection
            resetSection
        }
        .navigationTitle("Streaming VAD")
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
