import SwiftUI
import UIKit

struct DictationView: View {
    @EnvironmentObject var viewModel: DictationViewModel
    @Environment(\.dismiss) private var dismiss
    let requestId: UUID

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showHistory = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                switch viewModel.phase {
                case .recording:
                    recordingContent
                case .transcribing:
                    transcribingContent
                case .done(let text):
                    doneContent(text: text)
                case .error(let message):
                    errorContent(message: message)
                case .cancelled:
                    cancelledContent
                }

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .overlay(alignment: .topTrailing) {
            settingsGearButton
                .padding(.top, 8)
                .padding(.trailing, 16)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            // A sheet presents its content in a fresh environment context — it
            // does not inherit @EnvironmentObject from the presenting view, so
            // re-inject both objects the sheet content reads: SettingsView (and
            // its NavigationLink destinations like RecoveryView) need AppSettings
            // and DictationViewModel, and the ActiveRecordingBadge overlay needs
            // DictationViewModel.
            .environmentObject(AppSettings.shared)
            .environmentObject(viewModel)
            .overlay(alignment: .topTrailing) {
                if viewModel.phase == .recording || viewModel.phase == .transcribing {
                    // Show the badge only while a dictation is actively in flight
                    // (recording or transcribing). Done/error/cancelled phases have
                    // no ongoing recording to return to, so the badge is hidden.
                    ActiveRecordingBadge()
                        .padding(.top, 60)    // clear the dynamic island / status bar
                        .padding(.trailing, 16)
                }
            }
        }
        .task {
            await viewModel.start(id: requestId)
        }
        .onDisappear {
            timer?.invalidate()
            switch viewModel.phase {
            case .recording where viewModel.activeID != nil:
                Task { await viewModel.cancel() }
            default:
                // During transcribing the background task keeps the app alive
                // until transcription completes — do not cancel mid-flight.
                break
            }
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .cancelled = newPhase {
                dismiss()
            }
        }
        .onChange(of: showSettings) { _, isPresented in
            if isPresented {
                FileLogger.shared.info(.app, "Settings sheet opened during dictation",
                                       payload: ["phase": String(describing: viewModel.phase)])
            } else {
                FileLogger.shared.info(.app, "Settings sheet closed during dictation",
                                       payload: ["phase": String(describing: viewModel.phase)])
            }
        }
    }

    // MARK: - Settings

    private var settingsGearButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.title3)
                .foregroundColor(.primary)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Settings")
    }

    // MARK: - Recording State

    private var recordingContent: some View {
        VStack(spacing: 24) {
            Text(viewModel.activeModeLabel)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.tertiary, in: Capsule())

            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundColor(Color(.systemRed))

            Text("Recording...")
                .font(.title2)
                .fontWeight(.medium)

            Text(timeString(from: elapsed))
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())

            if !viewModel.livePartial.isEmpty {
                Text(viewModel.livePartial)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                timer?.invalidate()
                Task { await viewModel.stop() }
            }) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(Color(.systemRed))
            }
            .buttonStyle(.plain)
            .frame(width: 100, height: 100)
            .minimumScaleFactor(0.5)

            Text("Tap to stop recording")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Cancel") {
                Task {
                    await viewModel.cancel()
                    dismiss()
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.top, 8)
        }
        .onAppear {
            startTimer()
        }
    }

    // MARK: - Transcribing State

    private var transcribingContent: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2.0)

            Text("Transcribing...")
                .font(.title2)
                .fontWeight(.medium)

            Text("Processing your recording")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Done State

    private func doneContent(text: String) -> some View {
        VStack(spacing: 24) {
            TranscriptionResultView(text: text) {
                dismiss()
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .foregroundColor(.secondary)
                Text("Swipe back to return to your keyboard")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button("History") {
                showHistory = true
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Error State

    private func errorContent(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Something went wrong")
                .font(.title2)
                .fontWeight(.medium)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if hasSavedAudio {
                VStack(spacing: 12) {
                    Button("Retry Transcription") {
                        Task { await viewModel.retryAsLiveDictation(jobId: requestId) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Dismiss") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Start New Recording") {
                        Task { await viewModel.start(id: requestId) }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 16) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Try Again") {
                        Task { await viewModel.start(id: requestId) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Cancelled State

    private var cancelledContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Cancelled")
                .font(.title2)
                .fontWeight(.medium)
        }
    }

    /// Whether a failed-job record with saved audio exists for the current
    /// request ID. When true, the error screen offers "Retry Transcription"
    /// instead of the generic "Try Again".
    private var hasSavedAudio: Bool {
        FailedJobStore.shared.list().contains(where: { $0.jobId == requestId })
    }

    // MARK: - Timer

    private func startTimer() {
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func timeString(from interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
