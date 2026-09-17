import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var servers: [String] = []
    @Published var timeoutSeconds: TimeInterval = 30.0
    @Published var autoCapitalizationEnabled: Bool = true
    @Published var autocorrectOnSpaceEnabled: Bool = true
    @Published var dictationMode: SharedConfig.DictationMode = .batch
    @Published var verboseLogging: Bool = SharedConfig.Defaults.verboseLoggingDefault
    @Published var hapticsEnabled: Bool = SharedConfig.Defaults.hapticsEnabledDefault
    @Published var keyboardLanguage: KeyboardLanguage = SharedConfig.Defaults.keyboardLanguageDefault

    @Published var streamVadSensitivityProfile: VADSensitivityProfile = SharedConfig.Defaults.streamVadSensitivityProfileDefault
    @Published var streamVadPauseProfile: VADPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
    @Published var streamVadMode: VADMode = .staticMode
    @Published var streamVadCalibrationMs: Int = SharedConfig.Defaults.streamVadCalibrationMsDefault
    @Published var streamVadCalibratedOffsetDb: Double = SharedConfig.Defaults.streamVadCalibratedOffsetDbDefault
    @Published var streamVadAdaptiveDeltaDb: Double = SharedConfig.Defaults.streamVadAdaptiveDeltaDbDefault
    @Published var streamVadSpeechRms: Float = SharedConfig.Defaults.streamVadSpeechRmsDefault
    @Published var streamVadSilenceMs: Int = SharedConfig.Defaults.streamVadSilenceMsDefault
    @Published var streamVadMinSpeechMs: Int = SharedConfig.Defaults.streamVadMinSpeechMsDefault
    @Published var streamVadMinChunkMs: Int = SharedConfig.Defaults.streamVadMinChunkMsDefault
    @Published var streamVadMaxNoiseSec: Double = SharedConfig.Defaults.streamVadMaxNoiseSecDefault
    @Published var audioMeasurementModeEnabled: Bool = SharedConfig.Defaults.audioMeasurementModeEnabledDefault

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()
    private var streamVadAdaptiveDeltaOverridePresent = false
    private var updatingDerivedVadValue = false

    private init() {
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)

        let config = SharedConfig.load()
        servers = config.servers
        timeoutSeconds = config.timeoutSeconds
        autoCapitalizationEnabled = SharedConfig.autoCapitalizationEnabled()
        autocorrectOnSpaceEnabled = SharedConfig.autocorrectOnSpaceEnabled()
        dictationMode = SharedConfig.dictationMode()
        verboseLogging = SharedConfig.verboseLoggingEnabled()
        hapticsEnabled = SharedConfig.hapticsEnabled()
        keyboardLanguage = SharedConfig.keyboardLanguage()
        streamVadSensitivityProfile = SharedConfig.streamVadSensitivityProfile()
        streamVadPauseProfile = SharedConfig.streamVadPauseProfile()
        streamVadMode = SharedConfig.streamVadMode()
        streamVadCalibrationMs = SharedConfig.streamVadCalibrationMs()
        streamVadCalibratedOffsetDb = SharedConfig.streamVadCalibratedOffsetDb()
        streamVadAdaptiveDeltaDb = SharedConfig.streamVadAdaptiveDeltaDb()
        streamVadSpeechRms = SharedConfig.streamVadSpeechRms()
        streamVadSilenceMs = SharedConfig.streamVadSilenceMs()
        streamVadMinSpeechMs = SharedConfig.streamVadMinSpeechMs()
        streamVadMinChunkMs = SharedConfig.streamVadMinChunkMs()
        streamVadMaxNoiseSec = SharedConfig.streamVadMaxNoiseSec()
        audioMeasurementModeEnabled = SharedConfig.audioMeasurementModeEnabled()
        streamVadAdaptiveDeltaOverridePresent = SharedConfig.streamVadAdaptiveDeltaDbOverridePresent()

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
        $streamVadSensitivityProfile.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadSensitivityProfile",
                                   payload: ["value": newValue.rawValue])
            self?.saveStreamVadSensitivityProfile(newValue)
            guard let self, !self.streamVadAdaptiveDeltaOverridePresent else { return }
            self.updatingDerivedVadValue = true
            self.streamVadAdaptiveDeltaDb = SharedConfig.streamVadAdaptiveDeltaDb()
            self.updatingDerivedVadValue = false
        }.store(in: &cancellables)
        $streamVadPauseProfile.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadPauseProfile",
                                   payload: ["value": newValue.rawValue])
            self?.saveStreamVadPauseProfile(newValue)
            guard let self else { return }
            self.updatingDerivedVadValue = true
            self.streamVadSilenceMs = SharedConfig.streamVadSilenceMs()
            self.updatingDerivedVadValue = false
        }.store(in: &cancellables)
        $streamVadMode.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMode",
                                   payload: ["value": newValue.rawValue])
            self?.saveStreamVadMode(newValue)
        }.store(in: &cancellables)
        $streamVadCalibrationMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadCalibrationMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadCalibrationMs(newValue)
        }.store(in: &cancellables)
        $streamVadCalibratedOffsetDb.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadCalibratedOffsetDb",
                                   payload: ["value": newValue])
            self?.saveStreamVadCalibratedOffsetDb(newValue)
        }.store(in: &cancellables)
        $streamVadAdaptiveDeltaDb.dropFirst().sink { [weak self] newValue in
            guard let self, !self.updatingDerivedVadValue else { return }
            FileLogger.shared.info(.settings, "saving streamVadAdaptiveDeltaDb",
                                   payload: ["value": newValue])
            self.streamVadAdaptiveDeltaOverridePresent = true
            self.saveStreamVadAdaptiveDeltaDb(newValue)
        }.store(in: &cancellables)
        $streamVadSpeechRms.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadSpeechRms",
                                   payload: ["value": newValue])
            self?.saveStreamVadSpeechRms(newValue)
        }.store(in: &cancellables)
        $streamVadSilenceMs.dropFirst().sink { [weak self] newValue in
            guard let self, !self.updatingDerivedVadValue else { return }
            FileLogger.shared.info(.settings, "saving streamVadSilenceMs",
                                   payload: ["value": newValue])
            self.saveStreamVadSilenceMs(newValue)
            if newValue != VADProfileResolver.oldSilenceDefaultMs {
                let profile = VADProfileResolver.pauseProfile(forLegacySilenceMs: newValue)
                if self.streamVadPauseProfile != profile {
                    self.streamVadPauseProfile = profile
                }
            }
            self.updatingDerivedVadValue = true
            self.streamVadSilenceMs = SharedConfig.streamVadSilenceMs()
            self.updatingDerivedVadValue = false
        }.store(in: &cancellables)
        $streamVadMinSpeechMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMinSpeechMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadMinSpeechMs(newValue)
        }.store(in: &cancellables)
        $streamVadMinChunkMs.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMinChunkMs",
                                   payload: ["value": newValue])
            self?.saveStreamVadMinChunkMs(newValue)
        }.store(in: &cancellables)
        $streamVadMaxNoiseSec.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving streamVadMaxNoiseSec",
                                   payload: ["value": newValue])
            self?.saveStreamVadMaxNoiseSec(newValue)
        }.store(in: &cancellables)
        $audioMeasurementModeEnabled.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving audioMeasurementModeEnabled",
                                   payload: ["value": newValue])
            self?.saveAudioMeasurementModeEnabled(newValue)
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
        appGroupDefaults?.set(verboseLogging, forKey: SharedConfig.Defaults.verboseLoggingKey)
        appGroupDefaults?.set(hapticsEnabled, forKey: SharedConfig.Defaults.hapticsEnabledKey)
        appGroupDefaults?.set(keyboardLanguage.rawValue, forKey: SharedConfig.Defaults.keyboardLanguageKey)
        appGroupDefaults?.set(streamVadSensitivityProfile.rawValue, forKey: SharedConfig.Defaults.streamVadSensitivityProfileKey)
        appGroupDefaults?.set(streamVadPauseProfile.rawValue, forKey: SharedConfig.Defaults.streamVadPauseProfileKey)
        appGroupDefaults?.set(streamVadMode.rawValue, forKey: SharedConfig.Defaults.streamVadModeKey)
        appGroupDefaults?.set(streamVadCalibrationMs, forKey: SharedConfig.Defaults.streamVadCalibrationMsKey)
        appGroupDefaults?.set(streamVadCalibratedOffsetDb, forKey: SharedConfig.Defaults.streamVadCalibratedOffsetDbKey)
        if streamVadAdaptiveDeltaOverridePresent {
            appGroupDefaults?.set(streamVadAdaptiveDeltaDb, forKey: SharedConfig.Defaults.streamVadAdaptiveDeltaDbKey)
            appGroupDefaults?.set(true, forKey: SharedConfig.Defaults.streamVadAdaptiveDeltaDbOverrideKey)
        }
        appGroupDefaults?.set(streamVadSpeechRms, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        appGroupDefaults?.set(streamVadSilenceMs, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.set(streamVadMinSpeechMs, forKey: SharedConfig.Defaults.streamVadMinSpeechMsKey)
        appGroupDefaults?.set(streamVadMinChunkMs, forKey: SharedConfig.Defaults.streamVadMinChunkMsKey)
        appGroupDefaults?.set(streamVadMaxNoiseSec, forKey: SharedConfig.Defaults.streamVadMaxNoiseSecKey)
        appGroupDefaults?.set(audioMeasurementModeEnabled, forKey: SharedConfig.Defaults.audioMeasurementModeEnabledKey)
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

    private func saveStreamVadSensitivityProfile(_ profile: VADSensitivityProfile) {
        appGroupDefaults?.set(profile.rawValue, forKey: SharedConfig.Defaults.streamVadSensitivityProfileKey)
        postSettingsChanged()
    }

    private func saveStreamVadPauseProfile(_ profile: VADPauseProfile) {
        appGroupDefaults?.set(profile.rawValue, forKey: SharedConfig.Defaults.streamVadPauseProfileKey)
        postSettingsChanged()
    }

    private func saveStreamVadMode(_ mode: VADMode) {
        appGroupDefaults?.set(mode.rawValue, forKey: SharedConfig.Defaults.streamVadModeKey)
        postSettingsChanged()
    }

    private func saveStreamVadCalibrationMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadCalibrationMsKey)
        postSettingsChanged()
    }

    private func saveStreamVadCalibratedOffsetDb(_ value: Double) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadCalibratedOffsetDbKey)
        postSettingsChanged()
    }

    private func saveStreamVadAdaptiveDeltaDb(_ value: Double) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadAdaptiveDeltaDbKey)
        appGroupDefaults?.set(true, forKey: SharedConfig.Defaults.streamVadAdaptiveDeltaDbOverrideKey)
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

    private func saveStreamVadMinChunkMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadMinChunkMsKey)
        postSettingsChanged()
    }

    private func saveStreamVadMaxNoiseSec(_ value: Double) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadMaxNoiseSecKey)
        postSettingsChanged()
    }

    private func saveAudioMeasurementModeEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.audioMeasurementModeEnabledKey)
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
        verboseLogging = SharedConfig.Defaults.verboseLoggingDefault
        hapticsEnabled = SharedConfig.Defaults.hapticsEnabledDefault
        keyboardLanguage = SharedConfig.Defaults.keyboardLanguageDefault
        audioMeasurementModeEnabled = SharedConfig.Defaults.audioMeasurementModeEnabledDefault
        resetVadToDefaults()
    }

    func resetVadToDefaults() {
        streamVadAdaptiveDeltaOverridePresent = false
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadAdaptiveDeltaDbKey)
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadAdaptiveDeltaDbOverrideKey)
        streamVadSensitivityProfile = SharedConfig.Defaults.streamVadSensitivityProfileDefault
        streamVadPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
        streamVadMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .staticMode
        streamVadCalibrationMs = SharedConfig.Defaults.streamVadCalibrationMsDefault
        streamVadCalibratedOffsetDb = SharedConfig.Defaults.streamVadCalibratedOffsetDbDefault
        updatingDerivedVadValue = true
        streamVadAdaptiveDeltaDb = SharedConfig.Defaults.streamVadAdaptiveDeltaDbDefault
        updatingDerivedVadValue = false
        streamVadSpeechRms = SharedConfig.Defaults.streamVadSpeechRmsDefault
        streamVadSilenceMs = SharedConfig.Defaults.streamVadSilenceMsDefault
        streamVadMinSpeechMs = SharedConfig.Defaults.streamVadMinSpeechMsDefault
        streamVadMinChunkMs = SharedConfig.Defaults.streamVadMinChunkMsDefault
        streamVadMaxNoiseSec = SharedConfig.Defaults.streamVadMaxNoiseSecDefault
    }
}
