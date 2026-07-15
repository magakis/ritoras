import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showOnboarding = false
    @State private var showResetConfirmation = false
    @State private var pastedLogs = ""
    @State private var testStatuses: [Int: TestStatus] = [:]
    @State private var showSavedToast = false

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
            debugSection
            infoSection
        }
        .navigationTitle("Ritoras Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showOnboarding = true }) {
                    Image(systemName: "questionmark.circle")
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Save") {
                    settings.save()
                    showSavedToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showSavedToast = false
                    }
                }
                Button("Reset") {
                    showResetConfirmation = true
                }
                EditButton()
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
        .overlay {
            if showSavedToast {
                Text("Saved ✓")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    .allowsHitTesting(false)
            }
        }
        .onReceive(settings.$servers) { _ in
            // Clear stale test statuses when servers array changes
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        Section {
            ForEach(settings.servers.indices, id: \.self) { index in
                HStack(spacing: 8) {
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
            .onMove { source, destination in
                settings.servers.move(fromOffsets: source, toOffset: destination)
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

    // MARK: - Debug Logs Section

    private var debugSection: some View {
        Section {
            Text("If the keyboard shows errors, long-press the keyboard to copy logs, then paste them here:")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $pastedLogs)
                .frame(height: 150)
                .font(.system(size: 11, design: .monospaced))
        } header: {
            Text("Debug Logs")
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
