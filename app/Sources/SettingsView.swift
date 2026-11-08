import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var isEditingServers = false
    @State private var isEditingAPIKey = false
    @State private var apiKeyDraft: String = ""
    @FocusState private var apiKeyFieldFocused: Bool
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
            apiKeySection
            dictationSection
            cleanupSection
            audioSection
            keyboardSection
            serverSuggestionsSection
            dictionarySection
            historySection
            diagnosticsSection
            infoSection
        }
        .navigationTitle("Ritoras Settings")
        .onAppear {
            settings.refreshLLMCleanupPreferences()
            settings.refreshServerCapabilityBadges()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                settings.refreshLLMCleanupPreferences()
                settings.refreshServerCapabilityBadges()
            }
        }
    }

    // MARK: - Server Section
    // Order is semantically meaningful — drives failover priority in WhisperClient.transcribe and probe priority in selectFirstHealthyServer.

    private var serverSection: some View {
        Section {
            ForEach(settings.servers.indices, id: \.self) { index in
                HStack(alignment: .center, spacing: 8) {
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

                    VStack(alignment: .leading, spacing: 6) {
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

                        serverCapabilityBadges(for: settings.servers[index])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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

    // MARK: - API Key Section

    private var apiKeySection: some View {
        Section {
            if isEditingAPIKey {
                TextField("API Key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($apiKeyFieldFocused)
                    .onSubmit(commitAPIKey)
            } else {
                Button {
                    apiKeyDraft = settings.whisperApiKey
                    isEditingAPIKey = true
                    apiKeyFieldFocused = true
                } label: {
                    Text(settings.whisperApiKey.isEmpty ? "Tap to set" : settings.whisperApiKey)
                        .font(.body)
                        .foregroundColor(settings.whisperApiKey.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Sent as a Bearer token with every Whisper request. Request the key from the developer — leave empty if your servers don't require auth.")
        }
        .onChange(of: apiKeyFieldFocused) { focused in
            if !focused && isEditingAPIKey {
                commitAPIKey()
            }
        }
    }

    private func commitAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != settings.whisperApiKey {
            settings.whisperApiKey = trimmed
        }
        isEditingAPIKey = false
        apiKeyFieldFocused = false
    }

    // MARK: - Dictation Section

    private var dictationSection: some View {
        Section {
            Picker("Mode", selection: $settings.dictationMode) {
                Text("Batch (full recording)").tag(SharedConfig.DictationMode.batch)
                Text("Stream (live)").tag(SharedConfig.DictationMode.stream)
                Text("Unified stream · experimental").tag(SharedConfig.DictationMode.unifiedStream)
            }
            .pickerStyle(.segmented)

            if settings.dictationMode == .stream {
                NavigationLink("Streaming") {
                    ChunkSplitterSettingsView()
                }
            } else if settings.dictationMode == .unifiedStream {
                TextField("Unified server base URL", text: $settings.unifiedStreamServerBaseURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)

                if settings.unifiedStreamServerBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    Label(
                        "Set the unified server URL before using this mode.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text(
                "Batch records the whole clip then transcribes (most reliable). "
                    + "Stream transcribes live as you pause — faster feedback, "
                    + "needs a stable connection. Streaming settings only affect Stream mode."
            )
        }
    }

    // MARK: - LLM Cleanup Section

    private var cleanupSection: some View {
        Section {
            Picker("Styling", selection: $settings.llmCleanupStyling) {
                ForEach(LLMCleanupStyling.allCases, id: \.self) { styling in
                    Text(styling.displayName).tag(styling)
                }
            }
            Picker("Structure", selection: $settings.llmCleanupStructure) {
                ForEach(LLMCleanupStructure.allCases, id: \.self) { structure in
                    Text(structure.displayName).tag(structure)
                }
            }
            Picker("Context", selection: $settings.llmCleanupContext) {
                ForEach(LLMCleanupContext.allCases, id: \.self) { context in
                    Text(context.displayName).tag(context)
                }
            }
        } header: {
            Text("LLM Cleanup")
        } footer: {
            Text("Server default leaves each cleanup choice to the server.")
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        Section {
            Toggle("Measurement Mode", isOn: $settings.audioMeasurementModeEnabled)
            Toggle("Capture Attenuation (Experimental)", isOn: $settings.audioCaptureAttenuationEnabled)
        } header: {
            Text("Audio")
        } footer: {
            Text("Measurement Mode minimizes iOS microphone processing and automatic gain control for cleaner Standard-mode capture. Experimental attenuation requests a 16 kHz hardware capture path, which may reduce input level; it takes effect when the audio session next activates.")
        }
    }

    // MARK: - Keyboard Section

    private var keyboardSection: some View {
        Section {
            Picker("Keyboard language", selection: $settings.keyboardLanguage) {
                ForEach(KeyboardLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Toggle("Auto-Capitalization", isOn: $settings.autoCapitalizationEnabled)
            Toggle("Auto-Correction", isOn: $settings.autocorrectOnSpaceEnabled)
            Toggle("Haptic Feedback", isOn: $settings.hapticsEnabled)
        } header: {
            Text("Keyboard")
        } footer: {
            Text("iOS's built-in Keyboard Feedback setting does not apply to custom keyboards. This toggle provides independent control.")
        }
    }

    // MARK: - Server-Assisted Suggestions Section

    private var serverSuggestionsSection: some View {
        Section {
            Toggle("Enable", isOn: $settings.serverSuggestionsEnabled)
            Toggle("Spelling", isOn: $settings.serverSpellingSuggestionsEnabled)
                .disabled(!settings.serverSuggestionsEnabled)
            Toggle("Vocabulary", isOn: $settings.serverVocabularySuggestionsEnabled)
                .disabled(!settings.serverSuggestionsEnabled)
            Toggle("Prediction", isOn: $settings.serverPredictionSuggestionsEnabled)
                .disabled(!settings.serverSuggestionsEnabled)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Strict remote-only (debug)", isOn: $settings.serverSuggestionsStrictRemoteEnabled)
                Text("The suggestion bar shows only server results; an empty bar means the server returned nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.serverSuggestionsEnabled)
        } header: {
            Text("Server-assisted suggestions · Experimental")
        } footer: {
            Text("When enabled, selected spelling, vocabulary, or prediction requests are sent to the pinned server. Local prediction and autocorrection remain on-device.")
        }
    }

    // MARK: - Dictionary Section

    private var dictionarySection: some View {
        Section {
            NavigationLink("Personal Dictionary") {
                DictionaryView()
            }
        } header: {
            Text("Personal Dictionary")
        } footer: {
            Text("Words you keep from autocorrect. They won't be flagged as typos or auto-corrected while you type. Changes take effect the next time the keyboard is opened.")
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
            NavigationLink("Raw Log File") {
                RawLogFileView()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Captures developer-level diagnostics in the debug log. Off by default.")
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

    private func serverCapabilityBadges(for server: String) -> some View {
        let badges = settings.capabilityBadges(for: server)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                capabilityBadge(
                    title: "Dictation",
                    value: badges.dictation.displayValue,
                    color: color(for: badges.dictation)
                )
                capabilityBadge(
                    title: "Spelling",
                    value: badges.spelling.displayValue,
                    color: color(for: badges.spelling)
                )
            }
            HStack(spacing: 5) {
                capabilityBadge(
                    title: "Vocabulary",
                    value: badges.vocabulary.displayValue,
                    color: color(for: badges.vocabulary)
                )
                capabilityBadge(
                    title: "Prediction",
                    value: badges.prediction.displayValue,
                    color: color(for: badges.prediction)
                )
            }
            slotsCatalogTimestamp(for: badges)
        }
    }

    private func capabilityBadge(title: String, value: String, color: Color) -> some View {
        Text("\(title) · \(value)")
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func color(for state: ServerCapabilityBadges.SlotState) -> Color {
        switch state {
        case .available: return .green
        case .unavailable: return .secondary
        case .unknown: return .secondary
        case .undetected: return .orange
        }
    }

    private func color(for state: ServerCapabilityBadges.DictationState) -> Color {
        switch state {
        case .warm: return .green
        case .cold: return .orange
        case .unknown: return .secondary
        }
    }

    @ViewBuilder
    private func slotsCatalogTimestamp(for badges: ServerCapabilityBadges) -> some View {
        if let timestamp = badges.slotsCatalogTimestamp {
            Text("Capabilities last detected \(timestamp, style: .relative)")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else if let timestamp = badges.slotsLastProbeTimestamp {
            Text("Slots last checked \(timestamp, style: .relative)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
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
