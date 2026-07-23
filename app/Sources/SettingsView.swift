import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showOnboarding = false
    @State private var isEditingServers = false
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
            dictationSection
            keyboardSection
            historySection
            diagnosticsSection
            infoSection
        }
        .navigationTitle("Ritoras Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showOnboarding = true }) {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onboardingCompleted: .constant(true))
        }
    }

    // MARK: - Server Section
    // Order is semantically meaningful — drives failover priority in WhisperClient.transcribe and probe priority in selectFirstHealthyServer.

    private var serverSection: some View {
        Section {
            ForEach(settings.servers.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    if isEditingServers {
                        Button {
                            settings.servers.remove(at: index)
                            testStatuses = [:]
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }

                    if isEditingServers {
                        TextField("Server URL", text: $settings.servers[index])
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .font(.body)
                    } else {
                        Text(settings.servers[index])
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !isEditingServers {
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
            }
            .onMove { offsets, destination in
                settings.servers.move(fromOffsets: offsets, toOffset: destination)
                testStatuses = [:]
            }

            if isEditingServers {
                Button("Add Server") {
                    settings.servers.append("")
                }
            }
        } header: {
            HStack {
                Text("Whisper Servers")
                Spacer()
                Button(isEditingServers ? "Done" : "Edit") {
                    withAnimation {
                        if isEditingServers {
                            settings.servers.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            testStatuses = [:]
                        }
                        isEditingServers.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.blue)
            }
        } footer: {
            Text("Servers are tried in the order shown. Drag the grip on the right to reorder at any time. Tap Edit to add, change, or delete a server. Tap a server's test icon to check whether it's reachable.")
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Dictation Section

    private var dictationSection: some View {
        Section {
            Picker("Mode", selection: $settings.dictationMode) {
                Text("Batch (full recording)").tag(SharedConfig.DictationMode.batch)
                Text("Stream (live)").tag(SharedConfig.DictationMode.stream)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Dictation")
        } footer: {
            Text("Batch records the whole clip then transcribes (most reliable). Stream transcribes live as you pause — faster feedback, needs a stable connection.")
        }
    }

    // MARK: - Keyboard Section

    private var keyboardSection: some View {
        Section {
            Toggle("Auto-Capitalization", isOn: $settings.autoCapitalizationEnabled)
            Toggle("Auto-Correction", isOn: $settings.autocorrectOnSpaceEnabled)
            Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
        } header: {
            Text("Keyboard")
        } footer: {
            Text("iOS's built-in Keyboard Feedback setting does not apply to custom keyboards. This toggle provides independent control.")
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        Section {
            NavigationLink("Transcription History") {
                HistoryView()
            }
            NavigationLink("Failed Transcriptions") {
                RecoveryView()
            }
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section {
            Toggle("Verbose Logging", isOn: $settings.verboseLogging)
            NavigationLink("Debug Log") {
                DebugLogView()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Verbose Logging writes additional debug-level entries to the log. Off by default.")
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
            HStack {
                Text("Version")
                Spacer()
                Text(appVersionDisplay)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("About")
        }
    }

    // MARK: - Helpers

    private var appVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(version) (\(build))"
    }

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
                timeout: 3.0
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
