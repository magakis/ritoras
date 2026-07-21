import SwiftUI
import UIKit

struct DictationView: View {
    @EnvironmentObject var viewModel: DictationViewModel
    @Environment(\.dismiss) private var dismiss
    let requestId: UUID

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showHistory = false

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
                }

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .task {
            await viewModel.start(id: requestId)
        }
        .onDisappear {
            timer?.invalidate()
            switch viewModel.phase {
            case .recording:
                Task { await viewModel.cancel() }
            default:
                // During transcribing the background task keeps the app alive
                // until transcription completes — do not cancel mid-flight.
                break
            }
        }
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)

            Text("Done!")
                .font(.largeTitle)
                .fontWeight(.bold)

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxHeight: 250)

            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .foregroundColor(.secondary)
                Text("Swipe back to return to your keyboard")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button("History") {
                    showHistory = true
                }
                .buttonStyle(.bordered)
            }

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
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
                        Task { await viewModel.retry(jobId: requestId) }
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
