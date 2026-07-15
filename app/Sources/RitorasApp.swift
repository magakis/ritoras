import SwiftUI
import AVFoundation

@main
struct RitorasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var dictationRequest: DictationRequest?

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    NavigationStack {
                        SettingsView()
                    }
                } else {
                    OnboardingView(onboardingCompleted: $onboardingCompleted)
                }
            }
            .environmentObject(settings)
            .task {
                // Request microphone permission from the container app.
                // The keyboard extension CANNOT show this dialog without being dismissed.
                if AVAudioSession.sharedInstance().recordPermission == .undetermined {
                    AVAudioSession.sharedInstance().requestRecordPermission { _ in }
                }
            }
            .onOpenURL { url in
                print("📡 [RitorasApp] Received URL: \(url.absoluteString)")

                guard url.scheme == SharedConfig.Defaults.urlScheme,
                      url.host == SharedConfig.Defaults.dictateURLPath else {
                    print("📡 [RitorasApp] URL doesn't match ritoras://dictate — ignoring")
                    return
                }

                if let id = parseId(from: url) {
                    print("📡 [RitorasApp] Parsed dictation ID: \(id)")
                    dictationRequest = DictationRequest(id: id)
                } else {
                    print("📡 [RitorasApp] Failed to parse ID from URL: \(url)")
                    // Don't present DictationView with random UUID
                }
            }
            .fullScreenCover(item: $dictationRequest) { request in
                DictationView(requestId: request.id)
            }
        }
    }

    /// Parses a UUID from the `id` query parameter in the incoming URL.
    /// Supports both `ritoras://dictate` (returns nil) and
    /// `ritoras://dictate?id=<UUID>` (returns the parsed UUID).
    private func parseId(from url: URL) -> UUID? {
        // Try URLComponents first
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
           let uuid = UUID(uuidString: idString) {
            return uuid
        }
        // Manual fallback: parse query string directly
        guard let query = url.query else { return nil }
        for param in query.split(separator: "&") {
            let parts = param.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "id" {
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                if let uuid = UUID(uuidString: value) {
                    return uuid
                }
            }
        }
        return nil
    }
}

/// Identifiable wrapper for a dictation request UUID, used to present
/// DictationView as a `.fullScreenCover(item:)`.
struct DictationRequest: Identifiable {
    let id: UUID
}

/// Handles background URLSession delivery: when iOS relaunches the app to
/// deliver a completed background transcription upload, we store the completion
/// handler and reconnect the session so the delegate callbacks fire (and the
/// completion handler is invoked once all events are processed).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundTranscriptionService.identifier else { return }
        BackgroundTranscriptionService.shared.backgroundCompletionHandler = completionHandler
        BackgroundTranscriptionService.shared.reconnect()
    }
}
