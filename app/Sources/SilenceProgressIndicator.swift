import SwiftUI

struct SilenceProgressIndicator: View {
    let state: StreamingVADFrameState
    let chunkDispatchCount: Int

    private var silenceProgress: Double {
        guard !state.calibrating,
              state.endpointState == "endPending",
              state.evidence == "silence",
              state.silenceTargetMs > 0 else {
            return 0
        }

        return min(max(state.accumulatedSilenceMs / state.silenceTargetMs, 0), 1)
    }

    private var stateLabel: String {
        if state.calibrating {
            return "Measuring…"
        }

        switch state.endpointState {
        case "idle":
            return "Listening"
        case "onsetPending":
            return "Detecting speech"
        case "speechActive":
            return "Recording speech"
        case "endPending":
            return "Waiting for endpoint"
        default:
            return "Listening"
        }
    }

    private var stateTextColor: Color {
        if state.calibrating || state.endpointState == "idle" {
            return .secondary
        }
        if state.endpointState == "endPending" {
            return .orange
        }
        return .primary
    }

    private var stateDotColor: Color {
        switch state.endpointState {
        case "speechActive":
            return .green
        case "endPending":
            return .orange
        default:
            return .secondary
        }
    }

    private var fillColor: Color {
        state.endpointState == "endPending" ? .orange : .secondary.opacity(0.3)
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
                    state.endpointState == "endPending" && state.evidence == "silence"
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
