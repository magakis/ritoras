import SwiftUI
import Combine
import UIKit

/// Floating badge that sits on top of the settings sheet while a dictation is
/// in progress (wired up in Phase 2). Shows live elapsed time and the current
/// dictation phase, can be dragged to a persisted position, and dismisses the
/// sheet it is overlaid on when tapped.
struct ActiveRecordingBadge: View {
    @EnvironmentObject private var viewModel: DictationViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("recordingBadgeOffsetX") private var storedOffsetX: Double = 0
    @AppStorage("recordingBadgeOffsetY") private var storedOffsetY: Double = 0

    @GestureState private var dragOffset: CGSize = .zero
    @State private var tick = 0
    @State private var isPulsing = false

    /// 1 Hz tick that re-renders the elapsed label. Subscribed via onReceive,
    /// which auto-cancels when the badge disappears.
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            FileLogger.shared.info(.app, "ActiveRecordingBadge tapped — returning to recording",
                                   payload: ["phase": String(describing: viewModel.phase)])
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(.systemRed))
                    .frame(width: 8, height: 8)
                    .opacity(isPulsing ? 0.35 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)

                Image(systemName: phaseSymbolName)
                    .font(.caption)
                    .foregroundColor(.primary)

                if viewModel.recordingStartTime != nil {
                    Text(elapsedString)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Gesture choice: plain .gesture() on the Button itself. A tap produces
        // zero translation, so the DragGesture never recognizes (default
        // minimumDistance ~10pt) and the Button action fires; a real drag
        // recognizes and takes over. This keeps tap and drag both working
        // without .highPriorityGesture or an inner/outer wrapper split.
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    storedOffsetX = clampOffset(storedOffsetX + Double(value.translation.width))
                    storedOffsetY = clampOffset(storedOffsetY + Double(value.translation.height))
                }
        )
        .offset(x: CGFloat(storedOffsetX) + dragOffset.width,
                y: CGFloat(storedOffsetY) + dragOffset.height)
        // Animate only the drop-settle (stored offsets change on drag end), not
        // the live drag — dragOffset changes are not tracked by any animation.
        .animation(.easeInOut, value: storedOffsetX)
        .animation(.easeInOut, value: storedOffsetY)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        .onReceive(tickTimer) { _ in
            tick += 1
        }
        .onAppear {
            isPulsing = true
        }
    }

    private var phaseSymbolName: String {
        switch viewModel.phase {
        case .recording:
            return "waveform"
        case .transcribing:
            return "ellipsis"
        case .done:
            return "checkmark"
        case .error:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark"
        }
    }

    private var elapsedString: String {
        guard let start = viewModel.recordingStartTime else { return "00:00" }
        let elapsed = Date().timeIntervalSince(start)
        return String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
    }

    /// Clamps a stored offset so the badge cannot be dragged fully off-screen.
    /// Heuristic: the badge is small (~150pt wide), so ±160 keeps it visible.
    private func clampOffset(_ value: Double) -> Double {
        min(max(value, -160), 160)
    }
}
