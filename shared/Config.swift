import Foundation

struct SharedConfig {
    struct Defaults {
        static let baseUrl = "http://100.107.181.45:5000"
        static let model = ""
        static let apiKey = ""
        static let timeoutSeconds: TimeInterval = 30.0
        static let language = ""
        static let appGroupId = "group.com.ritoras.app"
    }

    let baseUrl: String
    let model: String
    let apiKey: String
    let timeoutSeconds: TimeInterval
    let language: String

    static func load() -> SharedConfig {
        if let suiteDefaults = UserDefaults(suiteName: Defaults.appGroupId) {
            return SharedConfig(
                baseUrl: suiteDefaults.string(forKey: "baseUrl") ?? Defaults.baseUrl,
                model: suiteDefaults.string(forKey: "model") ?? Defaults.model,
                apiKey: suiteDefaults.string(forKey: "apiKey") ?? Defaults.apiKey,
                timeoutSeconds: suiteDefaults.object(forKey: "timeoutSeconds") as? TimeInterval ?? Defaults.timeoutSeconds,
                language: suiteDefaults.string(forKey: "language") ?? Defaults.language
            )
        }
        return SharedConfig(
            baseUrl: Defaults.baseUrl,
            model: Defaults.model,
            apiKey: Defaults.apiKey,
            timeoutSeconds: Defaults.timeoutSeconds,
            language: Defaults.language
        )
    }
}
