import SwiftUI

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
}
