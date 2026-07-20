import UIKit

/// Owns the keyboard's long-lived haptic generators. Total memory < 1 KB.
/// Generators are instance properties so `prepare()` actually primes the
/// Taptic Engine across taps; recreating per-tap defeats `prepare()`.
final class HapticsManager {
    static let shared = HapticsManager()

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    private(set) var isEnabled: Bool = SharedConfig.hapticsEnabled()

    private init() {}

#if DEBUG
    private(set) var impactCallCount = 0
    private(set) var selectionCallCount = 0
    private(set) var notificationCallCount = 0
    private(set) var prepareCallCount = 0

    func _testResetCounters() {
        impactCallCount = 0
        selectionCallCount = 0
        notificationCallCount = 0
        prepareCallCount = 0
    }

    func _testSetEnabled(_ enabled: Bool) { isEnabled = enabled }
#endif

    func reloadEnabledFromAppGroup() {
        isEnabled = SharedConfig.hapticsEnabled()
    }

    // MARK: - Key-press entry points

    /// Letters, numbers, symbols, space, return, single-tap backspace.
    func tapImpact() {
        guard isEnabled else { return }
        impactLight.impactOccurred()
        #if DEBUG
        impactCallCount += 1
        #endif
    }

    /// Prime the impact generator on touch-down (Apple's documented latency pattern).
    func prepareImpact() {
        guard isEnabled else { return }
        impactLight.prepare()
        #if DEBUG
        prepareCallCount += 1
        #endif
    }

    /// Shift tap, shift-lock toggle, mode toggles (123/ABC/#+=), emoji keyboard open.
    func tapSelection() {
        guard isEnabled else { return }
        selection.selectionChanged()
        #if DEBUG
        selectionCallCount += 1
        #endif
    }

    /// Reserved for future use (e.g., mic tap ack).
    func tapSuccessNotification() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
        #if DEBUG
        notificationCallCount += 1
        #endif
    }
}
