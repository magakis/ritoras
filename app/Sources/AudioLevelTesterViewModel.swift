import Foundation
import AVFoundation
import UIKit

@MainActor
final class AudioLevelTesterViewModel: ObservableObject {
    @Published private(set) var currentRms: Float = 0
    @Published private(set) var peakRms: Float = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var permissionDenied = false

    private let monitor = AudioLevelMonitor()
    private var sessionToken = 0

    func start() async {
        guard !isMonitoring else { return }

        // Check microphone permission
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            break
        case .denied:
            permissionDenied = true
            return
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.shared.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            if !granted {
                permissionDenied = true
                return
            }
        @unknown default:
            permissionDenied = true
            return
        }

        // Reset levels for a fresh monitoring session
        currentRms = 0
        peakRms = 0

        // Capture supersession token before the await — if stop() runs
        // during monitor.start(...), the token will diverge and we skip
        // writing stale state.
        sessionToken &+= 1
        let token = sessionToken

        do {
            try await monitor.start { [weak self] smoothed, peak in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionToken == token else { return }
                    self.currentRms = smoothed
                    self.peakRms = peak
                }
            }
            // Re-check: if stop() ran during the await, token is stale
            guard sessionToken == token else { return }
            isMonitoring = true
        } catch {
            guard sessionToken == token else { return }
            FileLogger.shared.warn(.audio, "AudioLevelTester start failed",
                                  payload: ["error": "\(error)"])
            isMonitoring = false
        }
    }

    func stop() async {
        // Invalidate any in-flight start() suspended across await
        sessionToken &+= 1

        await monitor.stop()

        isMonitoring = false
        currentRms = 0
        peakRms = 0
    }

    func recheckPermission() async {
        if AVAudioApplication.shared.recordPermission == .granted {
            permissionDenied = false
        }
    }

    func openSystemSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }
}
