import Foundation

/// In-memory cache for four keyboard settings that are read on every keystroke.
/// Refreshed by a Darwin notification from the container app when settings change,
/// eliminating per-keystroke UserDefaults IPC.
///
/// Thread-safe via NSLock — read from the main thread (keystroke path) and the
/// Darwin delivery thread (refresh path).
final class KeyboardSettingsCache {
    private let lock = NSLock()
    private var _autoCapitalization: Bool
    private var _autocorrectOnSpace: Bool
    private var _haptics: Bool
    private var _language: KeyboardLanguage

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

    init() {
        _autoCapitalization = SharedConfig.autoCapitalizationEnabled()
        _autocorrectOnSpace = SharedConfig.autocorrectOnSpaceEnabled()
        _haptics = SharedConfig.hapticsEnabled()
        _language = SharedConfig.keyboardLanguage()
    }

    /// Reads all four settings from the App Group under a single lock acquire.
    func refresh() {
        let autoCap = SharedConfig.autoCapitalizationEnabled()
        let autoCorr = SharedConfig.autocorrectOnSpaceEnabled()
        let hapticsVal = SharedConfig.hapticsEnabled()
        let languageVal = SharedConfig.keyboardLanguage()
        lock.lock()
        _autoCapitalization = autoCap
        _autocorrectOnSpace = autoCorr
        _haptics = hapticsVal
        _language = languageVal
        lock.unlock()
    }
}
