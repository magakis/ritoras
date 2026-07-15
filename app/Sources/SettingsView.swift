import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showOnboarding = false
    @State private var showResetConfirmation = false
    @State private var testStatuses: [Int: TestStatus] = [:]

    enum TestStatus: Equatable {
        case untested
        case testing
        case success
        case failure(String)

        var iconName: String {
            switch self {
            case .untested: return "antenna.radiowaves.left.and.right"
            case .testing: return "ellipsis.circle"
            case .success: return "checkmark.circle.fill"
            case .failure: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .untested: return .accentColor
            case .testing: return .secondary
            case .success: return .green
            case .failure: return .red
            }
        }
    }

    var body: some View {
        Form {
            serverSection
            timeoutSection
            infoSection
        }
        .navigationTitle("Ritoras Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showOnboarding = true }) {
                    Image(systemName: "questionmark.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Reset") {
                    showResetConfirmation = true
                }
            }
        }
        .alert("Reset to Defaults", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                testStatuses = [:]
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
            ForEach(settings.servers.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Button {
                        settings.servers.remove(at: index)
                        testStatuses = [:]
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)

                    TextField("Server URL", text: $settings.servers[index])
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.body)

                    Button {
                        testServer(at: index)
                    } label: {
                        Image(systemName: testStatuses[index, default: .untested].iconName)
                            .foregroundColor(testStatuses[index, default: .untested].color)
                    }
                    .buttonStyle(.borderless)
                    .disabled(testStatuses[index] == .testing)
                }
            }
            .onDelete { offsets in
                settings.servers.remove(atOffsets: offsets)
                testStatuses = [:]
            }

            Button("Add Server") {
                settings.servers.append("")
            }
        } header: {
            Text("Whisper Servers")
        } footer: {
            Text("Servers are tried in the order shown. If one fails, the next is attempted automatically.")
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

    // MARK: - Helpers

    private func testServer(at index: Int) {
        guard index < settings.servers.count else { return }
        let server = settings.servers[index]
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testStatuses[index] = .failure("URL is empty")
            return
        }

        testStatuses[index] = .testing

        Task {
            let healthy = await WhisperClient.checkHealth(
                serverURL: server,
                timeout: settings.timeoutSeconds
            )
            await MainActor.run {
                guard index < settings.servers.count else {
                    testStatuses = [:]
                    return
                }
                testStatuses[index] = healthy
                    ? .success
                    : .failure("Server unreachable. Check the URL and your connection.")
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppSettings.shared)
    }
}
