import Foundation

struct KeyboardServerSuggestionSettings {
    let enabled: Bool
    let spellingEnabled: Bool
    let vocabularyEnabled: Bool
    let predictionEnabled: Bool
    let strictRemoteOnlyEnabled: Bool

    func capabilityEnabled(_ endpoint: KeyboardServicesSuggestionEndpoint) -> Bool {
        switch endpoint {
        case .spelling: return spellingEnabled
        case .vocabulary: return vocabularyEnabled
        case .prediction: return predictionEnabled
        }
    }
}

/// In-memory cache for keyboard settings that are read on frequent keyboard paths.
/// Refreshed by a Darwin notification from the container app when settings change,
/// eliminating per-keystroke UserDefaults IPC.
///
/// Thread-safe via NSLock — read from the main thread (keystroke path) and the
/// Darwin delivery thread (refresh path).
final class KeyboardSettingsCache {
    private static let strictRemoteOnlyLock = NSLock()
    private static var _strictRemoteOnlyEnabled = SharedConfig.Defaults.serverSuggestionsStrictRemoteEnabledDefault

    /// Latest cached value read by KeyboardView's display-only policy.
    static var strictRemoteOnlyEnabled: Bool {
        strictRemoteOnlyLock.lock()
        defer { strictRemoteOnlyLock.unlock() }
        return _strictRemoteOnlyEnabled
    }

    private let lock = NSLock()
    private var _autoCapitalization: Bool
    private var _autocorrectOnSpace: Bool
    private var _haptics: Bool
    private var _language: KeyboardLanguage
    private var _serverSuggestionSettings: KeyboardServerSuggestionSettings

    var autoCapitalization: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _autoCapitalization
    }

    var autocorrectOnSpace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _autocorrectOnSpace
    }

    var haptics: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _haptics
    }

    var language: KeyboardLanguage {
        lock.lock()
        defer { lock.unlock() }
        return _language
    }

    var serverSuggestionSettings: KeyboardServerSuggestionSettings {
        lock.lock()
        defer { lock.unlock() }
        return _serverSuggestionSettings
    }

    init() {
        _autoCapitalization = SharedConfig.autoCapitalizationEnabled()
        _autocorrectOnSpace = SharedConfig.autocorrectOnSpaceEnabled()
        _haptics = SharedConfig.hapticsEnabled()
        _language = SharedConfig.keyboardLanguage()
        _serverSuggestionSettings = Self.loadServerSuggestionSettings()
        Self.cacheStrictRemoteOnlySetting(_serverSuggestionSettings.strictRemoteOnlyEnabled)
    }

    /// Reads the settings from the App Group, then publishes one cache snapshot.
    func refresh() {
        let autoCap = SharedConfig.autoCapitalizationEnabled()
        let autoCorr = SharedConfig.autocorrectOnSpaceEnabled()
        let hapticsVal = SharedConfig.hapticsEnabled()
        let languageVal = SharedConfig.keyboardLanguage()
        let serverSuggestionSettings = Self.loadServerSuggestionSettings()
        lock.lock()
        _autoCapitalization = autoCap
        _autocorrectOnSpace = autoCorr
        _haptics = hapticsVal
        _language = languageVal
        _serverSuggestionSettings = serverSuggestionSettings
        lock.unlock()
        Self.cacheStrictRemoteOnlySetting(serverSuggestionSettings.strictRemoteOnlyEnabled)
    }

    private static func loadServerSuggestionSettings() -> KeyboardServerSuggestionSettings {
        KeyboardServerSuggestionSettings(
            enabled: SharedConfig.serverSuggestionsEnabled(),
            spellingEnabled: SharedConfig.serverSpellingSuggestionsEnabled(),
            vocabularyEnabled: SharedConfig.serverVocabularySuggestionsEnabled(),
            predictionEnabled: SharedConfig.serverPredictionSuggestionsEnabled(),
            strictRemoteOnlyEnabled: SharedConfig.serverSuggestionsStrictRemoteEnabled()
        )
    }

    private static func cacheStrictRemoteOnlySetting(_ enabled: Bool) {
        strictRemoteOnlyLock.lock()
        _strictRemoteOnlyEnabled = enabled
        strictRemoteOnlyLock.unlock()
    }
}
