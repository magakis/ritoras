import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showOnboarding = false
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            serverSection
            modelSection
            authSection
            timeoutSection
            languageSection
            micPermissionSection
            infoSection
        }
        .navigationTitle("Ritoras Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Reset") {
                    showResetConfirmation = true
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showOnboarding = true }) {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .alert("Reset to Defaults", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
            }
        } message: {
            Text("This will reset all settings to their default values.")
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onboardingCompleted: .constant(true))
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Server URL", text: $settings.baseUrl)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Text("Use HTTPS via Tailscale (*.ts.net) to avoid ATS issues. Plain HTTP over 100.x Tailscale IP requires NSAllowsArbitraryLoads.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Whisper Server")
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Model", text: $settings.model)
                    .textInputAutocapitalization(.never)
                Text("e.g. whisper-1, base, large-v3 — depends on your server.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Model")
        }
    }

    // MARK: - Auth Section

    private var authSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                SecureField("API Key", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                Text("Leave empty if your server doesn't require authentication.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Authentication")
        }
    }

    // MARK: - Timeout Section

    private var timeoutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Stepper(
                    "Timeout: \(Int(settings.timeoutSeconds))s",
                    value: $settings.timeoutSeconds,
                    in: 5...60,
                    step: 1
                )
            }
        } header: {
            Text("Network")
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Language", text: $settings.language)
                    .textInputAutocapitalization(.never)
                Text("ISO 639-1 code (e.g. en, fr, es). Leave empty for auto-detect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Language")
        }
    }

    // MARK: - Microphone Permission Section

    private var micPermissionSection: some View {
        Section {
            HStack {
                Text("Microphone")
                Spacer()
                let granted = AVAudioSession.sharedInstance().recordPermission == .granted
                Text(granted ? "Granted" : "Not granted")
                    .foregroundColor(granted ? .green : .red)
            }
            if AVAudioSession.sharedInstance().recordPermission != .granted {
                Button("Grant Microphone Access") {
                    AVAudioSession.sharedInstance().requestRecordPermission { _ in }
                }
            }
        } header: {
            Text("Permissions")
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        Section {
            HStack {
                Text("App Group ID")
                Spacer()
                Text(SharedConfig.Defaults.appGroupId)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Button("Show Onboarding Again") {
                showOnboarding = true
            }
        } header: {
            Text("About")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppSettings.shared)
    }
}
