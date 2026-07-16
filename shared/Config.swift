import Foundation

struct SharedConfig {
    struct Defaults {
        static let baseUrl = "http://100.107.181.45:5000"
        static let timeoutSeconds: TimeInterval = 30.0
        static let appGroupId = "group.com.ritoras.app"
        static let urlScheme = "ritoras"
        static let dictateURLPath = "dictate"
        static let darwinNotificationName = "com.ritoras.dictationCompleted"
        static let dictationPayloadKey = "dictation.payload"
        static let dictationTimeoutSeconds: TimeInterval = 30
        static let backspaceInitialRepeatDelay: TimeInterval = 0.5
        static let backspaceCharRepeatInterval: TimeInterval = 0.1
        static let backspaceCharsBeforeWordMode: Int = 22
        static let backspaceWordRepeatInterval: TimeInterval = 0.35
        static let backspaceWordCharInterval: TimeInterval = 0.015   // 15ms per char while spreading a word's deletes
        static var dictateURL: URL { URL(string: "\(urlScheme)://\(dictateURLPath)")! }
    }

    let servers: [String]
    let timeoutSeconds: TimeInterval

    static func load() -> SharedConfig {
        if let suiteDefaults = UserDefaults(suiteName: Defaults.appGroupId) {
            let servers: [String]
            if let data = suiteDefaults.data(forKey: "servers"),
               let decoded = try? JSONDecoder().decode([String].self, from: data)
            {
                servers = decoded
            } else {
                servers = [Defaults.baseUrl]
            }

            return SharedConfig(
                servers: servers,
                timeoutSeconds: suiteDefaults.object(forKey: "timeoutSeconds") as? TimeInterval ?? Defaults.timeoutSeconds
            )
        }
        return SharedConfig(
            servers: [Defaults.baseUrl],
            timeoutSeconds: Defaults.timeoutSeconds
        )
    }
}
