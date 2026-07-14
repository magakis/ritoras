import SwiftUI
import AVFoundation

@main
struct RitorasApp: App {
    @StateObject private var settings = AppSettings.shared
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

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
        }
    }
}
