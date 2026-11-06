import SwiftUI
import UIKit

struct DictationView: View {
    @EnvironmentObject var viewModel: DictationViewModel
    @Environment(\.dismiss) private var dismiss
    let requestId: UUID

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showHistory = false
    @State private var showChunkReview = false
    @State private var showSettings = false
    @State private var shouldFollowLiveTranscript = true
    @State private var isDraggingLiveTranscript = false
    @State private var isLiveTranscriptNearBottom = true
    @State private var pendingLiveTranscriptFollowScroll = false
    @State private var liveTranscriptRevision = 0

    private let liveTranscriptBottomAnchor = "live-transcript-bottom"

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                if viewModel.phase != .recording {
                    Spacer()
                }

                switch viewModel.phase {
                case .connecting:
                    connectingContent
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

                if viewModel.phase != .recording {
                    Spacer()
                }
            }
            .padding()
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .sheet(isPresented: $showChunkReview) {
            ChunkReviewView(records: viewModel.chunkReviews)
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
                if viewModel.phase == .connecting || viewModel.phase == .recording || viewModel.phase == .transcribing {
                    // Show the badge only while a dictation is actively in flight
                    // (connecting, recording or transcribing). Done/error/cancelled
                    // phases have no ongoing recording to return to, so the badge
                    // is hidden.
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
            case .recording where viewModel.activeID != nil, .connecting where viewModel.activeID != nil:
                Task { await viewModel.cancel() }
            case .done, .error, .cancelled:
                viewModel.clearChunkReviews()
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

    private var connectingContent: some View {
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

            Text("Starting…")
                .font(.title2)
                .fontWeight(.medium)

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
    }

    private var recordingContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(viewModel.activeModeLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.tertiary, in: Capsule())
            }

            if let state = viewModel.chunkSplitterState {
                SilenceProgressIndicator(
                    state: state,
                    chunkDispatchCount: viewModel.chunkDispatchCount
                )
            }

            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundColor(Color(.systemRed))

            Text("Recording...")
                .font(.title2)
                .fontWeight(.medium)

            Text(timeString(from: elapsed))
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())

            liveTranscriptView

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
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startTimer()
        }
    }

    private var liveTranscriptView: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(viewModel.livePartial)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        Color.clear
                            .frame(height: 1)
                            .id(liveTranscriptBottomAnchor)
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: LiveTranscriptContentMetricsPreferenceKey.self,
                                value: LiveTranscriptContentMetrics(
                                    minY: content.frame(in: .named("live-transcript-scroll")).minY,
                                    height: content.size.height,
                                    revision: liveTranscriptRevision
                                )
                            )
                        }
                    }
                }
                .coordinateSpace(name: "live-transcript-scroll")
                .onPreferenceChange(LiveTranscriptContentMetricsPreferenceKey.self) { metrics in
                    guard metrics.revision == liveTranscriptRevision else { return }

                    let distanceFromBottom = metrics.height + metrics.minY - viewport.size.height
                    isLiveTranscriptNearBottom = distanceFromBottom <= 40

                    // Layout and programmatic scroll changes should not disable bottom-following.
                    if isDraggingLiveTranscript {
                        shouldFollowLiveTranscript = isLiveTranscriptNearBottom
                    }

                    if pendingLiveTranscriptFollowScroll && shouldFollowLiveTranscript {
                        scrollProxy.scrollTo(liveTranscriptBottomAnchor, anchor: .bottom)
                        pendingLiveTranscriptFollowScroll = false
                    }
                }
                .onChange(of: viewModel.livePartial, initial: true) { _, _ in
                    pendingLiveTranscriptFollowScroll = true
                    liveTranscriptRevision += 1
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            isDraggingLiveTranscript = true
                            shouldFollowLiveTranscript = isLiveTranscriptNearBottom
                        }
                        .onEnded { _ in
                            shouldFollowLiveTranscript = isLiveTranscriptNearBottom
                            isDraggingLiveTranscript = false
                        }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            if let fallbackNotice = viewModel.fallbackNotice {
                Text(fallbackNotice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Done State

    private func doneContent(text: String) -> some View {
        VStack(spacing: 24) {
            TranscriptionResultView(
                text: text,
                recoveredViaFallback: viewModel.currentResultUsedSavedAudioFallback
            ) {
                dismiss()
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .foregroundColor(.secondary)
                Text("Swipe back to return to your keyboard")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button("History") {
                    showHistory = true
                }
                .buttonStyle(.bordered)

                if !viewModel.chunkReviews.isEmpty {
                    Button {
                        showChunkReview = true
                    } label: {
                        Label("Review Chunks", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered)
                }
            }
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

private struct LiveTranscriptContentMetrics: Equatable {
    let minY: CGFloat
    let height: CGFloat
    let revision: Int
}

private struct LiveTranscriptContentMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = LiveTranscriptContentMetrics(minY: 0, height: 0, revision: 0)

    static func reduce(
        value: inout LiveTranscriptContentMetrics,
        nextValue: () -> LiveTranscriptContentMetrics
    ) {
        value = nextValue()
    }
}
