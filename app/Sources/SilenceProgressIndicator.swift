import SwiftUI

struct SilenceProgressIndicator: View {
    let state: ChunkSplitterFrameState
    let chunkDispatchCount: Int
    @State private var displayedEndpointState: String

    init(state: ChunkSplitterFrameState, chunkDispatchCount: Int) {
        self.state = state
        self.chunkDispatchCount = chunkDispatchCount
        _displayedEndpointState = State(initialValue: state.endpointState)
    }

    private var silenceProgress: Double {
        guard state.endpointState != "idle",
              state.silenceTargetMs > 0,
              state.silenceTargetMs > state.endEvidenceMs else {
            return 0
        }

        let progressRangeMs = state.silenceTargetMs - state.endEvidenceMs
        let silenceSinceEndPendingMs = state.accumulatedSilenceMs - state.endEvidenceMs
        return min(max(silenceSinceEndPendingMs / progressRangeMs, 0), 1)
    }

    private var stateLabel: String {
        switch displayedEndpointState {
        case "idle":
            return "Listening"
        case "onsetPending":
            return "Detecting speech"
        case "speechActive":
            return "Recording speech"
        case "endPending":
            return "Finalizing…"
        default:
            return "Listening"
        }
    }

    private var stateTextColor: Color {
        if displayedEndpointState == "idle" {
            return .secondary
        }
        if displayedEndpointState == "endPending" {
            return .orange
        }
        return .primary
    }

    private var stateDotColor: Color {
        switch displayedEndpointState {
        case "speechActive":
            return .green
        case "endPending":
            return .orange
        default:
            return .secondary
        }
    }

    private var fillColor: Color {
        switch state.endpointState {
        case "idle":
            return .clear
        case "endPending":
            return .orange
        default:
            return .orange.opacity(0.35)
        }
    }

    private var labelTaskID: String {
        "\(state.endpointState)|\(state.lastEmissionReason ?? "")"
    }

    private var evidenceColor: Color {
        state.evidence == "silence" ? .red : .green
    }

    private var dispatchCaption: String? {
        guard let reason = state.lastEmissionReason else { return nil }

        switch reason {
        case "endpoint":
            return "sent · endpoint"
        case "flush":
            return "sent · stop"
        default:
            return "sent · \(reason)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            progressBar

            HStack(spacing: 6) {
                Circle()
                    .fill(stateDotColor)
                    .frame(width: 6, height: 6)

                Text(stateLabel)
                    .font(.caption2)
                    .foregroundColor(stateTextColor)

                Spacer(minLength: 4)

                if let dispatchCaption = dispatchCaption {
                    Text(dispatchCaption)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.lastEmissionReason)

            levelReadout
        }
        .task(id: labelTaskID) { @MainActor in
            let nextEndpointState = state.endpointState
            guard nextEndpointState != "idle", state.lastEmissionReason == nil else {
                displayedEndpointState = nextEndpointState
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            displayedEndpointState = nextEndpointState
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray5))

            RoundedRectangle(cornerRadius: 6)
                .fill(fillColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(x: silenceProgress, y: 1, anchor: .leading)
                .animation(
                    state.endpointState == "endPending"
                        ? .linear(duration: 0.08)
                        : nil,
                    value: silenceProgress
                )

            if state.lastEmissionReason != nil {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.7))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.25), value: state.lastEmissionReason)
        .phaseAnimator([0.0, 1.0, 0.0], trigger: chunkDispatchCount) { content, phase in
            content
                .overlay {
                    Capsule()
                        .fill(Color.primary.opacity(phase * 0.7))
                }
                .clipShape(Capsule())
        }
    }

    private var levelReadout: some View {
        HStack(spacing: 8) {
            Text(String(format: "now %.1f dB", state.frameDb))
                .foregroundColor(evidenceColor)

            Spacer(minLength: 0)

            Text(String(format: "onset %.1f", state.thresholdDb))
            Text(String(format: "continue %.1f", state.continuationThresholdDb))
            Text(String(format: "silence %.1f", state.silenceThresholdDb))
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var accessibilityLabel: String {
        "Silence progress, \(stateLabel.lowercased())"
    }

    private var accessibilityValue: String {
        var value = String(format: "%.0f percent", silenceProgress * 100)
        if let reason = dispatchCaption {
            value += ". \(reason)"
        }
        return value
    }
}
