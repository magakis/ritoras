import SwiftUI
import AVFoundation
@main
struct RitorasApp: App {
    @StateObject private var settings = AppSettings.shared
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @StateObject private var dictationViewModel = DictationViewModel()
    @State private var dictationRequest: DictationRequest?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FileLogger.shared.info(.app, "Container app launched", payload: ["version": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"])
        // Log the resolved app-group identifier via FileLogger (post-resolution, safe to use FileLogger now).
        FileLogger.shared.info(.app, "AppGroupResolver outcome", payload: [
            "resolvedIdentifier": SharedConfig.Defaults.appGroupId,
            "bundleId": Bundle.main.bundleIdentifier ?? "?"
        ])
        MetricKitSubscriber.shared.start()
        FileLogger.shared.info(.app, "MetricKit subscriber started")
    }

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
                FileLogger.shared.info(.app, "Received URL", payload: ["url": url.absoluteString])

                guard url.scheme == SharedConfig.Defaults.urlScheme,
                      url.host == SharedConfig.Defaults.dictateURLPath else {
                    FileLogger.shared.debug(.app, "URL doesn't match ritoras://dictate — ignoring",
                                              payload: ["url": url.absoluteString])
                    return
                }

                if let id = parseId(from: url) {
                    FileLogger.shared.info(.app, "Parsed dictation ID",
                                           payload: ["id": id.uuidString, "url": url.absoluteString])
                    dictationRequest = DictationRequest(id: id)
                    dictationViewModel.startLocalhostServer()
                } else {
                    FileLogger.shared.warn(.app, "Failed to parse ID from URL",
                                           payload: ["url": url.absoluteString])
                    // Don't present DictationView with random UUID
                }
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    break
                case .background, .inactive:
                    break
                @unknown default:
                    break
                }
            }
            .fullScreenCover(item: $dictationRequest) { request in
                DictationView(requestId: request.id)
                    .environmentObject(dictationViewModel)
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
