import Foundation

struct DictationPayload: Codable, Equatable {
    enum Status: String, Codable {
        case recording
        case transcribing
        case completed
        case error
        case cancelled
    }

    let id: UUID
    var status: Status
    var text: String?
    var errorMessage: String?
    let timestamp: Date

    /// Path to the payload file inside the shared App Group container.
    ///
    /// We write the payload to this FILE in addition to UserDefaults because
    /// `UserDefaults(suiteName:)` is **not reliably consistent across processes**
    /// — the keyboard extension frequently reads a stale value written by the
    /// containing app (cfprefsd caches per process and lags). File I/O through
    /// the shared container, by contrast, is immediately visible to both
    /// processes, so the keyboard always sees the latest status.
    private static var sharedFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConfig.Defaults.appGroupId
        ) else { return nil }
        return container.appendingPathComponent("dictation-payload.json")
    }

    /// Reads the latest payload, preferring the shared-container file (instantly
    /// consistent) and falling back to App Group UserDefaults.
    static func current() -> DictationPayload? {
        // 1. File (authoritative — no cross-process caching lag).
        if let url = sharedFileURL,
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(DictationPayload.self, from: data) {
            return payload
        }
        // 2. UserDefaults (force-refresh before reading).
        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) else {
            return nil
        }
        defaults.synchronize()
        guard let data = defaults.data(forKey: SharedConfig.Defaults.dictationPayloadKey) else {
            return nil
        }
        return try? JSONDecoder().decode(DictationPayload.self, from: data)
    }

    /// Writes the payload to BOTH the shared-container file (instantly visible to
    /// the keyboard) and the App Group UserDefaults (legacy compatibility).
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }

        // File (authoritative cross-process channel).
        if let url = DictationPayload.sharedFileURL {
            try? data.write(to: url, options: .atomic)
        }

        // UserDefaults (belt-and-suspenders).
        if let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) {
            defaults.set(data, forKey: SharedConfig.Defaults.dictationPayloadKey)
            defaults.synchronize()
        }
    }

    /// Removes the payload from both stores.
    static func clear() {
        if let url = sharedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) {
            defaults.removeObject(forKey: SharedConfig.Defaults.dictationPayloadKey)
            defaults.synchronize()
        }
    }
}
