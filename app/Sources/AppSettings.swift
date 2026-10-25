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
    @Published var audioMeasurementModeEnabled: Bool = SharedConfig.Defaults.audioMeasurementModeEnabledDefault
    @Published var audioCaptureAttenuationEnabled: Bool = SharedConfig.Defaults.audioCaptureAttenuationEnabledDefault

    @Published var chunkSplitterMode: VADMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .adaptive
    @Published var chunkSplitterPauseProfile: ChunkSplitterPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
    @Published var chunkSplitterSilenceMs: Int = SharedConfig.Defaults.streamVadSilenceMsDefault
    @Published var chunkSplitterSpeechRms: Float = SharedConfig.Defaults.streamVadSpeechRmsDefault
    @Published var chunkSplitterAbsoluteSpeechFloorDb: Double = SharedConfig.Defaults.streamVadAbsoluteSpeechFloorDbDefault
    @Published var chunkSplitterTelemetryEnabled: Bool = SharedConfig.Defaults.streamVadTelemetryEnabledDefault
    @Published var fullRecordingUploadEnabled: Bool = SharedConfig.Defaults.fullRecordingUploadEnabledDefault

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()
    private var chunkSplitterSilenceOverridePresent = false
    private var updatingDerivedChunkSplitterValue = false

    private init() {
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
        migrateRetiredChunkSplitterKeys()

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
        audioMeasurementModeEnabled = SharedConfig.audioMeasurementModeEnabled()
        audioCaptureAttenuationEnabled = SharedConfig.audioCaptureAttenuationEnabled()
        chunkSplitterMode = SharedConfig.streamVadMode()
        chunkSplitterPauseProfile = SharedConfig.chunkSplitterPauseProfile()
        chunkSplitterSilenceMs = SharedConfig.chunkSplitterSilenceMs()
        chunkSplitterSilenceOverridePresent = SharedConfig.chunkSplitterSilenceMsOverridePresent()
        chunkSplitterSpeechRms = SharedConfig.streamVadSpeechRms()
        chunkSplitterAbsoluteSpeechFloorDb = SharedConfig.streamVadAbsoluteSpeechFloorDb()
        chunkSplitterTelemetryEnabled = SharedConfig.chunkSplitterTelemetryEnabled()
        fullRecordingUploadEnabled = SharedConfig.fullRecordingUploadEnabled()

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
        $audioMeasurementModeEnabled.dropFirst().sink { [weak self] value in
            self?.saveAudioMeasurementModeEnabled(value)
        }.store(in: &cancellables)
        $audioCaptureAttenuationEnabled.dropFirst().sink { [weak self] value in
            self?.saveAudioCaptureAttenuationEnabled(value)
        }.store(in: &cancellables)
        $chunkSplitterMode.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving chunk splitter mode",
                                   payload: ["value": newValue.rawValue])
            self?.saveChunkSplitterMode(newValue)
        }.store(in: &cancellables)
        $chunkSplitterPauseProfile.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving chunk splitter pause profile",
                                   payload: ["value": newValue.rawValue])
            guard let self else { return }
            self.chunkSplitterSilenceOverridePresent = false
            self.appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
            self.appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
            self.saveChunkSplitterPauseProfile(newValue)
            self.updatingDerivedChunkSplitterValue = true
            self.chunkSplitterSilenceMs = ChunkSplitterProfileResolver.pauseDurationMs(for: newValue)
            self.updatingDerivedChunkSplitterValue = false
        }.store(in: &cancellables)
        $chunkSplitterSilenceMs.dropFirst().sink { [weak self] newValue in
            guard let self, !self.updatingDerivedChunkSplitterValue else { return }
            FileLogger.shared.info(.settings, "saving chunk splitter silence duration",
                                   payload: ["value": newValue])
            self.chunkSplitterSilenceOverridePresent = true
            self.saveChunkSplitterSilenceMs(newValue)
        }.store(in: &cancellables)
        $chunkSplitterSpeechRms.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving chunk splitter speech threshold",
                                   payload: ["value": newValue])
            self?.saveChunkSplitterSpeechRms(newValue)
        }.store(in: &cancellables)
        $chunkSplitterAbsoluteSpeechFloorDb.dropFirst().sink { [weak self] newValue in
            self?.saveChunkSplitterAbsoluteSpeechFloorDb(newValue)
        }.store(in: &cancellables)
        $chunkSplitterTelemetryEnabled.dropFirst().sink { [weak self] newValue in
            FileLogger.shared.info(.settings, "saving chunk splitter telemetry enabled",
                                   payload: ["value": newValue])
            self?.saveChunkSplitterTelemetryEnabled(newValue)
        }.store(in: &cancellables)
        $fullRecordingUploadEnabled.dropFirst().sink { [weak self] newValue in
            self?.saveFullRecordingUploadEnabled(newValue)
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
        saveAudioMeasurementModeEnabled(audioMeasurementModeEnabled)
        saveAudioCaptureAttenuationEnabled(audioCaptureAttenuationEnabled)
        appGroupDefaults?.set(chunkSplitterMode.rawValue, forKey: SharedConfig.Defaults.streamVadModeKey)
        appGroupDefaults?.set(chunkSplitterPauseProfile.rawValue, forKey: SharedConfig.Defaults.streamVadPauseProfileKey)
        if chunkSplitterSilenceOverridePresent {
            appGroupDefaults?.set(chunkSplitterSilenceMs, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
            appGroupDefaults?.set(true, forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        }
        appGroupDefaults?.set(chunkSplitterSpeechRms, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        saveChunkSplitterAbsoluteSpeechFloorDb(chunkSplitterAbsoluteSpeechFloorDb)
        appGroupDefaults?.set(chunkSplitterTelemetryEnabled, forKey: SharedConfig.Defaults.streamVadTelemetryEnabledKey)
        saveFullRecordingUploadEnabled(fullRecordingUploadEnabled)
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

    private func saveAudioMeasurementModeEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.audioMeasurementModeEnabledKey)
        postSettingsChanged()
    }

    private func saveAudioCaptureAttenuationEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.audioCaptureAttenuationEnabledKey)
        postSettingsChanged()
    }

    private func saveChunkSplitterMode(_ mode: VADMode) {
        appGroupDefaults?.set(mode.rawValue, forKey: SharedConfig.Defaults.streamVadModeKey)
        postSettingsChanged()
    }

    private func saveChunkSplitterPauseProfile(_ profile: ChunkSplitterPauseProfile) {
        appGroupDefaults?.set(profile.rawValue, forKey: SharedConfig.Defaults.streamVadPauseProfileKey)
        postSettingsChanged()
    }

    private func saveChunkSplitterSilenceMs(_ value: Int) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.set(true, forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        postSettingsChanged()
    }

    private func saveChunkSplitterSpeechRms(_ value: Float) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadSpeechRmsKey)
        postSettingsChanged()
    }

    private func saveChunkSplitterAbsoluteSpeechFloorDb(_ value: Double) {
        appGroupDefaults?.set(value, forKey: SharedConfig.Defaults.streamVadAbsoluteSpeechFloorDbKey)
        postSettingsChanged()
    }

    private func saveChunkSplitterTelemetryEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.streamVadTelemetryEnabledKey)
        postSettingsChanged()
    }

    private func saveFullRecordingUploadEnabled(_ enabled: Bool) {
        appGroupDefaults?.set(enabled, forKey: SharedConfig.Defaults.fullRecordingUploadEnabledKey)
        postSettingsChanged()
    }

    private func postSettingsChanged() {
        DarwinNotifier.post(SharedConfig.Defaults.darwinSettingsChangedNotificationName)
    }

    private func migrateRetiredChunkSplitterKeys() {
        // Keep the old key names here after removing their SharedConfig constants.
        let retiredKeys = [
            "streamVadCalibrationMs",
            "streamVadCalibratedOffsetDb",
            SharedConfig.Defaults.streamVadAdaptiveDeltaDbKey,
            SharedConfig.Defaults.streamVadAdaptiveDeltaDbOverrideKey,
            SharedConfig.Defaults.streamVadOnsetMsKey,
            SharedConfig.Defaults.streamVadEndEvidenceMsKey,
            SharedConfig.Defaults.streamVadResumeMsKey,
            SharedConfig.Defaults.streamVadAmbiguousRescueMsKey,
            "streamVadPreRollMs",
            "streamVadLoudPreRollMs",
            "streamVadLoudLatchMs",
            "streamVadLoudLatchAmbiguousEnabled",
            "streamVadLoudLatchWitnessDb",
            SharedConfig.Defaults.streamVadMinSpeechMsKey,
            SharedConfig.Defaults.streamVadMinChunkMsKey,
            SharedConfig.Defaults.streamVadAdaptiveSilenceDeltaDbKey,
            SharedConfig.Defaults.streamVadStaleFloorSecondsKey,
            SharedConfig.Defaults.streamVadFallTauSecondsKey,
            SharedConfig.Defaults.streamVadDynamicsSpreadDbKey,
            SharedConfig.Defaults.streamVadFlatSpreadDbKey,
            "streamVadAdaptationSpeed",
        ]
        retiredKeys.forEach { appGroupDefaults?.removeObject(forKey: $0) }
        FileLogger.shared.info(.settings, "removed retired chunk splitter settings",
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
        audioMeasurementModeEnabled = SharedConfig.Defaults.audioMeasurementModeEnabledDefault
        audioCaptureAttenuationEnabled = SharedConfig.Defaults.audioCaptureAttenuationEnabledDefault
        chunkSplitterMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .adaptive
        chunkSplitterPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
        chunkSplitterSilenceOverridePresent = false
        updatingDerivedChunkSplitterValue = true
        chunkSplitterSilenceMs = SharedConfig.Defaults.streamVadSilenceMsDefault
        updatingDerivedChunkSplitterValue = false
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        chunkSplitterSpeechRms = SharedConfig.Defaults.streamVadSpeechRmsDefault
    }

    func resetChunkSplitterSettingsToDefaults() {
        chunkSplitterSilenceOverridePresent = false
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsKey)
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadSilenceMsOverrideKey)
        chunkSplitterPauseProfile = SharedConfig.Defaults.streamVadPauseProfileDefault
        chunkSplitterMode = VADMode(rawValue: SharedConfig.Defaults.streamVadModeDefault) ?? .adaptive
        chunkSplitterSpeechRms = SharedConfig.Defaults.streamVadSpeechRmsDefault
        appGroupDefaults?.removeObject(forKey: SharedConfig.Defaults.streamVadAbsoluteSpeechFloorDbKey)
        chunkSplitterTelemetryEnabled = SharedConfig.Defaults.streamVadTelemetryEnabledDefault
        fullRecordingUploadEnabled = SharedConfig.Defaults.fullRecordingUploadEnabledDefault
        updatingDerivedChunkSplitterValue = true
        chunkSplitterSilenceMs = SharedConfig.Defaults.streamVadSilenceMsDefault
        updatingDerivedChunkSplitterValue = false
        postSettingsChanged()
    }
}
