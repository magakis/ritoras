import SwiftUI
import AVFoundation

@main
struct RitorasApp: App {
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
                guard url.scheme == SharedConfig.Defaults.urlScheme,
                      url.host == SharedConfig.Defaults.dictateURLPath else { return }
                let id = parseId(from: url) ?? UUID()
                dictationRequest = DictationRequest(id: id)
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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }
        guard let idString = queryItems.first(where: { $0.name == "id" })?.value else { return nil }
        return UUID(uuidString: idString)
    }
}

/// Identifiable wrapper for a dictation request UUID, used to present
/// DictationView as a `.fullScreenCover(item:)`.
struct DictationRequest: Identifiable {
    let id: UUID
}
