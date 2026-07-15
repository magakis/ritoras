import Foundation

struct SharedConfig {
    struct Defaults {
        static let baseUrl = "http://100.107.181.45:5000"
        static let timeoutSeconds: TimeInterval = 30.0
        static let appGroupId = "group.com.ritoras.app"
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
