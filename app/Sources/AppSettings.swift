import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var servers: [String] = []
    @Published var timeoutSeconds: TimeInterval = SharedConfig.Defaults.timeoutSeconds
    @Published var whisperApiKey: String = ""
    @Published var autoCapitalizationEnabled: Bool = true
    @Published var autocorrectOnSpaceEnabled: Bool = true
    @Published var dictationMode: SharedConfig.DictationMode = .batch
    @Published var verboseLogging: Bool = SharedConfig.Defaults.verboseLoggingDefault
    @Published var hapticsEnabled: Bool = SharedConfig.Defaults.hapticsEnabledDefault
    @Published var keyboardLanguage: KeyboardLanguage = SharedConfig.Defaults.keyboardLanguageDefault

    @Published var streamVadMode: VADMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .staticMode
    @Published var streamVadSensitivityProfile: VADSensitivityProfile = SharedConfig.Defaults.streamVadSensitivityProfileDefault
    @Published var streamVadPauseProfile: VADPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
    @Published var streamVadSilenceMs: Int = SharedConfig.Defaults.streamVadSilenceMsDefault
    @Published var streamVadAdaptationSpeed: Double = SharedConfig.Defaults.streamVadAdaptationSpeedDefault
    @Published var streamVadSpeechRms: Float = SharedConfig.Defaults.streamVadSpeechRmsDefault
    @Published var streamVadTelemetryEnabled: Bool = SharedConfig.Defaults.streamVadTelemetryEnabledDefault

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()
    private var streamVadSilenceOverridePresent = false
    private var updatingDerivedVadValue = false

    private init() {
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
        migrateRetiredVadKeys()

        let config = SharedConfig.load()
        servers = config.servers
        timeoutSeconds = config.timeoutSeconds
        whisperApiKey = config.apiKey
        autoCapitalizationEnabled = SharedConfig.autoCapitalizationEnabled()
        autocorrectOnSpaceEnabled = SharedConfig.autocorrectOnSpaceEnabled()
        dictationMode = SharedConfig.dictationMode()
        verboseLogging = SharedConfig.verboseLoggingEnabled()
        hapticsEnabled = SharedConfig.hapticsEnabled()
        keyboardLanguage = SharedConfig.keyboardLanguage()
        streamVadMode = SharedConfig.streamVadMode()
        streamVadSensitivityProfile = SharedConfig.streamVadSensitivityProfile()
        streamVadPauseProfile = SharedConfig.streamVadPauseProfile()
        streamVadSilenceMs = SharedConfig.streamVadSilenceMs()
        streamVadSilenceOverridePresent = SharedConfig.streamVadSilenceMsOverridePresent()
        streamVadAdaptationSpeed = SharedConfig.streamVadAdaptationSpeed()
        streamVadSpeechRms = SharedConfig.streamVadSpeechRms()
        streamVadTelemetryEnabled = SharedConfig.streamVadTelemetryEnabled()

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
        $whisperApiKey.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving whisperApiKey",
                                   payload: ["length": newValue.count])
            self?.saveWhisperApiKey(newValue)
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
        $keyboardLanguage.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving keyboardLanguage",
                                   payload: ["value": newValue.rawValue])
            self?.saveKeyboardLanguage(newValue)
        }.store(in: &cancellables)
        $streamVadMode.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMode",
                                   payload: ["value": newValue.rawValue])
            self?.saveStreamVadMode(newValue)
        }.store(in: &cancellables)
        $streamVadSensitivityProfile.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadSensitivityProfile",
                                   payload: ["value": newValue.rawValue])
            self?.saveStreamVadSensitivityProfile(newValue)
        }.store(in: &cancellables)
        $streamVadPauseProfile.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadPauseProfile",
                                   payload: ["value": newValue.rawValue])
            guard let self else { return }
            self.streamVadSilenceOverridePresent = false
            self.appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
            self.appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
            self.saveStreamVadPauseProfile(newValue)
            self.updatingDerivedVadValue = true
            self.streamVadSilenceMs = VADProfileResolver.pauseDurationMs(for: newValue)
            self.updatingDerivedVadValue = false
        }.store(in: &cancellables)
        $streamVadSilenceMs.dropFirst().sink { [weak self] newValue in
            guard let self, !self.updatingDerivedVadValue else { return }
            FileLogger.shared.info(.settings, "saving streamVadSilenceMs",
                                   payload: ["value": newValue])
            self.streamVadSilenceOverridePresent = true
            self.saveStreamVadSilenceMs(newValue)
        }.store(in: &cancellables)
        $streamVadAdaptationSpeed.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadAdaptationSpeed",
                                   payload: ["value": newValue])
            self?.saveStreamVadAdaptationSpeed(newValue)
        }.store(in: &cancellables)
        $streamVadSpeechRms.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadSpeechRms",
                                   payload: ["value": newValue])
            self?.saveStreamVadSpeechRms(newValue)
        }.store(in: &cancellables)
        $streamVadTelemetryEnabled.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadTelemetryEnabled",
                                   payload: ["value": newValue])
            self?.saveStreamVadTelemetryEnabled(newValue)
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
        appGroupDefaults?.set(whisperApiKey, forKey: SharedConfig.Defaults.whisperApiKeyKey)
        appGroupDefaults?.set(autoCapitalizationEnabled, forKey: SharedConfig.Defaults.autoCapitalizationEnabledKey)
        appGroupDefaults?.set(autocorrectOnSpaceEnabled, forKey: SharedConfig.Defaults.autocorrectOnSpaceEnabledKey)
        appGroupDefaults?.set(dictationMode.rawValue, forKey: SharedConfig.Defaults.dictationModeKey)
        appGroupDefaults?.set(verboseLogging, forKey: SharedConfig.Defaults.verboseLoggingKey)
        appGroupDefaults?.set(hapticsEnabled, forKey: SharedConfig.Defaults.hapticsEnabledKey)
        appGroupDefaults?.set(keyboardLanguage.rawValue, forKey: SharedConfig.Defaults.keyboardLanguageKey)
        appGroupDefaults?.set(streamVadMode.rawValue, forKey: SharedConfig.Defaults.streamVadModeKey)
        appGroupDefaults?.set(streamVadSensitivityProfile.rawValue, forKey: SharedConfig.Defaults.streamVadSensitivityProfileKey)
        appGroupDefaults?.set(streamVadPauseProfile.rawValue, forKey: SharedConfig.Defaults.streamVadPauseProfileKey)
        if streamVadSilenceOverridePresent {
            appGroupDefaults?.set(streamVadSilenceMs, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
            appGroupDefaults?.set(true, forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        }
        appGroupDefaults?.set(streamVadAdaptationSpeed, forKey: SharedConfig.Defaults.streamVadAdaptationSpeedKey)
        appGroupDefaults?.set(streamVadSpeechRms, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        appGroupDefaults?.set(streamVadTelemetryEnabled, forKey: SharedConfig.Defaults.streamVadTelemetryEnabledKey)
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

    private func saveWhisperApiKey(_ key: String) {
        appGroupDefaults?.set(key, forKey: SharedConfig.Defaults.whisperApiKeyKey)
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

    private func saveVerboseLogging(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.verboseLoggingKey)
        postSettingsChanged()
    }

    private func saveHapticsEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.hapticsEnabledKey)
        postSettingsChanged()
    }

    private func saveKeyboardLanguage(_ language: KeyboardLanguage) {
        appGroupDefaults?.set(language.rawValue, forKey: SharedConfig.Defaults.keyboardLanguageKey)
        postSettingsChanged()
    }

    private func saveStreamVadMode(_ mode: VADMode) {
        appGroupDefaults?.set(mode.rawValue, forKey: SharedConfig.Defaults.streamVadModeKey)
        postSettingsChanged()
    }

    private func saveStreamVadSensitivityProfile(_ profile: VADSensitivityProfile) {
        appGroupDefaults?.set(profile.rawValue, forKey: SharedConfig.Defaults.streamVadSensitivityProfileKey)
        postSettingsChanged()
    }

    private func saveStreamVadPauseProfile(_ profile: VADPauseProfile) {
        appGroupDefaults?.set(profile.rawValue, forKey: SharedConfig.Defaults.streamVadPauseProfileKey)
        postSettingsChanged()
    }

    private func saveStreamVadSilenceMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.set(true, forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        postSettingsChanged()
    }

    private func saveStreamVadAdaptationSpeed(_ value: Double) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadAdaptationSpeedKey)
        postSettingsChanged()
    }

    private func saveStreamVadSpeechRms(_ value: Float) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        postSettingsChanged()
    }

    private func saveStreamVadTelemetryEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.streamVadTelemetryEnabledKey)
        postSettingsChanged()
    }

    private func postSettingsChanged() {
        DarwinNotifier.post(SharedConfig.Defaults.darwinSettingsChangedNotificationName)
    }

    private func migrateRetiredVadKeys() {
        let retiredKeys = [
            SharedConfig.Defaults.streamVadCalibrationMsKey,
            SharedConfig.Defaults.streamVadCalibratedOffsetDbKey,
            SharedConfig.Defaults.streamVadAdaptiveDeltaDbKey,
            SharedConfig.Defaults.streamVadAdaptiveDeltaDbOverrideKey,
            SharedConfig.Defaults.streamVadOnsetMsKey,
            SharedConfig.Defaults.streamVadEndEvidenceMsKey,
            SharedConfig.Defaults.streamVadResumeMsKey,
            SharedConfig.Defaults.streamVadAmbiguousRescueMsKey,
            SharedConfig.Defaults.streamVadPreRollMsKey,
            SharedConfig.Defaults.streamVadMinSpeechMsKey,
            SharedConfig.Defaults.streamVadMinChunkMsKey,
            SharedConfig.Defaults.streamVadAdaptiveSilenceDeltaDbKey,
            SharedConfig.Defaults.streamVadStaleFloorSecondsKey,
            SharedConfig.Defaults.streamVadFallTauSecondsKey,
            SharedConfig.Defaults.streamVadDynamicsSpreadDbKey,
            SharedConfig.Defaults.streamVadFlatSpreadDbKey,
            SharedConfig.Defaults.audioMeasurementModeEnabledKey
        ]
        retiredKeys.forEach { appGroupDefaults?.removeObject(forKey: $0) }
        FileLogger.shared.info(.settings, "removed retired VAD settings",
                               payload: ["count": retiredKeys.count])
    }

    func resetToDefaults() {
        servers = [SharedConfig.Defaults.baseUrl]
        timeoutSeconds = SharedConfig.Defaults.timeoutSeconds
        whisperApiKey = ""
        autoCapitalizationEnabled = SharedConfig.Defaults.autoCapitalizationEnabledDefault
        autocorrectOnSpaceEnabled = SharedConfig.Defaults.autocorrectOnSpaceEnabledDefault
        dictationMode = .batch
        verboseLogging = SharedConfig.Defaults.verboseLoggingDefault
        hapticsEnabled = SharedConfig.Defaults.hapticsEnabledDefault
        keyboardLanguage = SharedConfig.Defaults.keyboardLanguageDefault
        streamVadMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .staticMode
        streamVadPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
        streamVadSilenceOverridePresent = false
        updatingDerivedVadValue = true
        streamVadSilenceMs = SharedConfig.Defaults.streamVadSilenceMsDefault
        updatingDerivedVadValue = false
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        streamVadSpeechRms = SharedConfig.Defaults.streamVadSpeechRmsDefault
    }

    func resetVadSettingsToDefaults() {
        streamVadSilenceOverridePresent = false
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        streamVadSensitivityProfile = SharedConfig.Defaults.streamVadSensitivityProfileDefault
        streamVadPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
        streamVadMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .staticMode
        streamVadAdaptationSpeed = SharedConfig.Defaults.streamVadAdaptationSpeedDefault
        streamVadSpeechRms = SharedConfig.Defaults.streamVadSpeechRmsDefault
        streamVadTelemetryEnabled = SharedConfig.Defaults.streamVadTelemetryEnabledDefault
        updatingDerivedVadValue = true
        streamVadSilenceMs = SharedConfig.Defaults.streamVadSilenceMsDefault
        updatingDerivedVadValue = false
        postSettingsChanged()
    }
}
