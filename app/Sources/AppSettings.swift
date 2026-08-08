import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var servers: [String] = []
    @Published var timeoutSeconds: TimeInterval = 30.0
    @Published var autoCapitalizationEnabled: Bool = true
    @Published var autocorrectOnSpaceEnabled: Bool = true
    @Published var dictationMode: SharedConfig.DictationMode = .batch
    @Published var audioFormat: SharedConfig.AudioFormat = .aac
    @Published var verboseLogging: Bool = SharedConfig.Defaults.verboseLoggingDefault
    @Published var hapticsEnabled: Bool = SharedConfig.Defaults.hapticsEnabledDefault
    @Published var appGroupOverride: String = SharedConfig.Defaults.appGroupOverrideDefault

    @Published var streamVadSpeechRms: Float = SharedConfig.Defaults.streamVadSpeechRmsDefault
    @Published var streamVadSilenceMs: Int = SharedConfig.Defaults.streamVadSilenceMsDefault
    @Published var streamVadMinSpeechMs: Int = SharedConfig.Defaults.streamVadMinSpeechMsDefault
    @Published var streamMaxChunkSeconds: TimeInterval = SharedConfig.Defaults.streamMaxChunkSecondsDefault
    @Published var streamVadHysteresisRatio: Float = SharedConfig.Defaults.streamVadHysteresisRatioDefault
    @Published var streamVadPreRollMs: Int = SharedConfig.Defaults.streamVadPreRollMsDefault
    @Published var streamVadMinSilenceAtMaxSpeechMs: Int = SharedConfig.Defaults.streamVadMinSilenceAtMaxSpeechMsDefault
    @Published var streamVadPostRollMs: Int = SharedConfig.Defaults.streamVadPostRollMsDefault

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)

        let config = SharedConfig.load()
        servers = config.servers
        timeoutSeconds = config.timeoutSeconds
        autoCapitalizationEnabled = SharedConfig.autoCapitalizationEnabled()
        autocorrectOnSpaceEnabled = SharedConfig.autocorrectOnSpaceEnabled()
        dictationMode = SharedConfig.dictationMode()
        audioFormat = SharedConfig.audioFormat()
        verboseLogging = SharedConfig.verboseLoggingEnabled()
        hapticsEnabled = SharedConfig.hapticsEnabled()
        appGroupOverride = SharedConfig.appGroupOverride()
        streamVadSpeechRms = SharedConfig.streamVadSpeechRms()
        streamVadSilenceMs = SharedConfig.streamVadSilenceMs()
        streamVadMinSpeechMs = SharedConfig.streamVadMinSpeechMs()
        streamMaxChunkSeconds = SharedConfig.streamMaxChunkSeconds()
        streamVadHysteresisRatio = SharedConfig.streamVadHysteresisRatio()
        streamVadPreRollMs = SharedConfig.streamVadPreRollMs()
        streamVadMinSilenceAtMaxSpeechMs = SharedConfig.streamVadMinSilenceAtMaxSpeechMs()
        streamVadPostRollMs = SharedConfig.streamVadPostRollMs()

        $servers.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving servers",
                                   payload: ["count": newValue.count])
            self?.saveServers(newValue)
        }.store(in: &cancellables)
        $timeoutSeconds.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving timeoutSeconds",
                                   payload: ["value": newValue])
            self?.saveTimeoutSeconds(newValue)
        }.store(in: &cancellables)
        $autoCapitalizationEnabled.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving autoCapitalizationEnabled",
                                   payload: ["value": newValue])
            self?.saveAutoCapitalizationEnabled(newValue)
        }.store(in: &cancellables)
        $autocorrectOnSpaceEnabled.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving autocorrectOnSpaceEnabled",
                                   payload: ["value": newValue])
            self?.saveAutocorrectOnSpaceEnabled(newValue)
        }.store(in: &cancellables)
        $dictationMode.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving dictationMode",
                                   payload: ["value": newValue.rawValue])
            self?.saveDictationMode(newValue)
        }.store(in: &cancellables)
        $audioFormat.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving audioFormat",
                                   payload: ["value": newValue.rawValue])
            self?.saveAudioFormat(newValue)
        }.store(in: &cancellables)
        $verboseLogging.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving verboseLogging",
                                   payload: ["value": newValue])
            self?.saveVerboseLogging(newValue)
        }.store(in: &cancellables)
        $hapticsEnabled.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving hapticsEnabled",
                                   payload: ["value": newValue])
            self?.saveHapticsEnabled(newValue)
        }.store(in: &cancellables)
        $appGroupOverride.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving appGroupOverride",
                                   payload: ["value": newValue])
            self?.saveAppGroupOverride(newValue)
        }.store(in: &cancellables)
        $streamVadSpeechRms.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadSpeechRms",
                                   payload: ["value": newValue])
            self?.saveStreamVadSpeechRms(newValue)
        }.store(in: &cancellables)
        $streamVadSilenceMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadSilenceMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadSilenceMs(newValue)
        }.store(in: &cancellables)
        $streamVadMinSpeechMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMinSpeechMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadMinSpeechMs(newValue)
        }.store(in: &cancellables)
        $streamMaxChunkSeconds.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamMaxChunkSeconds",
                                   payload: ["value": newValue])
            self?.saveStreamMaxChunkSeconds(newValue)
        }.store(in: &cancellables)
        $streamVadHysteresisRatio.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadHysteresisRatio",
                                   payload: ["value": newValue])
            self?.saveStreamVadHysteresisRatio(newValue)
        }.store(in: &cancellables)
        $streamVadPreRollMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadPreRollMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadPreRollMs(newValue)
        }.store(in: &cancellables)
        $streamVadMinSilenceAtMaxSpeechMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMinSilenceAtMaxSpeechMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadMinSilenceAtMaxSpeechMs(newValue)
        }.store(in: &cancellables)
        $streamVadPostRollMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadPostRollMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadPostRollMs(newValue)
        }.store(in: &cancellables)
    }

    /// Synchronous write to App Group — backs the explicit Save button.
    func save() {
        saveToAppGroup()
    }

    private func saveToAppGroup() {
        if let data = try? JSONEncoder().encode(servers) {
            appGroupDefaults?.set(data, forKey: "servers")
        }
        appGroupDefaults?.set(timeoutSeconds, forKey: "timeoutSeconds")
        appGroupDefaults?.set(autoCapitalizationEnabled, forKey: SharedConfig.Defaults.autoCapitalizationEnabledKey)
        appGroupDefaults?.set(autocorrectOnSpaceEnabled, forKey: SharedConfig.Defaults.autocorrectOnSpaceEnabledKey)
        appGroupDefaults?.set(dictationMode.rawValue, forKey: SharedConfig.Defaults.dictationModeKey)
        appGroupDefaults?.set(audioFormat.rawValue, forKey: SharedConfig.Defaults.audioFormatKey)
        appGroupDefaults?.set(verboseLogging, forKey: SharedConfig.Defaults.verboseLoggingKey)
        appGroupDefaults?.set(hapticsEnabled, forKey: SharedConfig.Defaults.hapticsEnabledKey)
        // Persist the override to the ORIGINAL suite so AppGroupResolver (which
        // reads that suite during first resolve) can see it even when the resolved
        // identifier differs (SideStore fallback state).
        UserDefaults(suiteName: SharedConfig.Defaults.originalAppGroupId)?
            .set(appGroupOverride, forKey: SharedConfig.Defaults.appGroupOverrideKey)
        appGroupDefaults?.set(streamVadSpeechRms, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        appGroupDefaults?.set(streamVadSilenceMs, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.set(streamVadMinSpeechMs, forKey: SharedConfig.Defaults.streamVadMinSpeechMsKey)
        appGroupDefaults?.set(streamMaxChunkSeconds, forKey: SharedConfig.Defaults.streamMaxChunkSecondsKey)
        appGroupDefaults?.set(streamVadHysteresisRatio, forKey: SharedConfig.Defaults.streamVadHysteresisRatioKey)
        appGroupDefaults?.set(streamVadPreRollMs, forKey: SharedConfig.Defaults.streamVadPreRollMsKey)
        appGroupDefaults?.set(streamVadMinSilenceAtMaxSpeechMs, forKey: SharedConfig.Defaults.streamVadMinSilenceAtMaxSpeechMsKey)
        appGroupDefaults?.set(streamVadPostRollMs, forKey: SharedConfig.Defaults.streamVadPostRollMsKey)
        postSettingsChanged()
    }

    private func saveServers(_ servers: [String]) {
        if let data = try? JSONEncoder().encode(servers) {
            appGroupDefaults?.set(data, forKey: "servers")
        }
        postSettingsChanged()
    }

    private func saveTimeoutSeconds(_ seconds: TimeInterval) {
        appGroupDefaults?.set(seconds, forKey: "timeoutSeconds")
        postSettingsChanged()
    }

    private func saveAutoCapitalizationEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.autoCapitalizationEnabledKey)
        postSettingsChanged()
    }

    private func saveAutocorrectOnSpaceEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.autocorrectOnSpaceEnabledKey)
        postSettingsChanged()
    }

    private func saveDictationMode(_ mode: SharedConfig.DictationMode) {
        appGroupDefaults?.set(mode.rawValue, forKey: SharedConfig.Defaults.dictationModeKey)
        postSettingsChanged()
    }

    private func saveAudioFormat(_ format: SharedConfig.AudioFormat) {
        appGroupDefaults?.set(format.rawValue, forKey: SharedConfig.Defaults.audioFormatKey)
        postSettingsChanged()
    }

    private func saveVerboseLogging(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.verboseLoggingKey)
        postSettingsChanged()
    }

    private func saveHapticsEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.hapticsEnabledKey)
        postSettingsChanged()
    }

    private func saveAppGroupOverride(_ value: String) {
        UserDefaults(suiteName: SharedConfig.Defaults.originalAppGroupId)?
            .set(value, forKey: SharedConfig.Defaults.appGroupOverrideKey)
        postSettingsChanged()
    }

    private func saveStreamVadSpeechRms(_ value: Float) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        postSettingsChanged()
    }

    private func saveStreamVadSilenceMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        postSettingsChanged()
    }

    private func saveStreamVadMinSpeechMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadMinSpeechMsKey)
        postSettingsChanged()
    }

    private func saveStreamMaxChunkSeconds(_ value: TimeInterval) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamMaxChunkSecondsKey)
        postSettingsChanged()
    }

    private func saveStreamVadHysteresisRatio(_ value: Float) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadHysteresisRatioKey)
        postSettingsChanged()
    }

    private func saveStreamVadPreRollMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadPreRollMsKey)
        postSettingsChanged()
    }

    private func saveStreamVadMinSilenceAtMaxSpeechMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadMinSilenceAtMaxSpeechMsKey)
        postSettingsChanged()
    }

    private func saveStreamVadPostRollMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadPostRollMsKey)
        postSettingsChanged()
    }

    private func postSettingsChanged() {
        DarwinNotifier.post(SharedConfig.Defaults.darwinSettingsChangedNotificationName)
    }

    func resetToDefaults() {
        servers = [SharedConfig.Defaults.baseUrl]
        timeoutSeconds = SharedConfig.Defaults.timeoutSeconds
        autoCapitalizationEnabled = SharedConfig.Defaults.autoCapitalizationEnabledDefault
        autocorrectOnSpaceEnabled = SharedConfig.Defaults.autocorrectOnSpaceEnabledDefault
        dictationMode = .batch
        audioFormat = .aac
        verboseLogging = SharedConfig.Defaults.verboseLoggingDefault
        hapticsEnabled = SharedConfig.Defaults.hapticsEnabledDefault
        resetVadToDefaults()
    }

    func resetVadToDefaults() {
        streamVadSpeechRms = SharedConfig.Defaults.streamVadSpeechRmsDefault
        streamVadSilenceMs = SharedConfig.Defaults.streamVadSilenceMsDefault
        streamVadMinSpeechMs = SharedConfig.Defaults.streamVadMinSpeechMsDefault
        streamMaxChunkSeconds = SharedConfig.Defaults.streamMaxChunkSecondsDefault
        streamVadHysteresisRatio = SharedConfig.Defaults.streamVadHysteresisRatioDefault
        streamVadPreRollMs = SharedConfig.Defaults.streamVadPreRollMsDefault
        streamVadMinSilenceAtMaxSpeechMs = SharedConfig.Defaults.streamVadMinSilenceAtMaxSpeechMsDefault
        streamVadPostRollMs = SharedConfig.Defaults.streamVadPostRollMsDefault
    }
}
