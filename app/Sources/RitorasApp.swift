import SwiftUI
import AVFoundation

@main
struct RitorasApp: App {
    @StateObject private var settings = AppSettings.shared
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    var body: some Scene {
        WindowGroup {
            if onboardingCompleted {
                NavigationStack {
                    SettingsView()
                }
                .environmentObject(settings)
            } else {
                OnboardingView(onboardingCompleted: $onboardingCompleted)
                    .environmentObject(settings)
            }
        }
    }
    .task {
        // Request microphone permission from the container app.
        // The keyboard extension CANNOT show this dialog without being dismissed.
        // By granting here, the keyboard can record without any dialog.
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }
}
