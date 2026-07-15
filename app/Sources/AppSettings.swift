import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var servers: [String] = []
    @Published var timeoutSeconds: TimeInterval = 30.0

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)

        let config = SharedConfig.load()
        servers = config.servers
        timeoutSeconds = config.timeoutSeconds

        $servers.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $timeoutSeconds.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
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
    }

    func resetToDefaults() {
        servers = [SharedConfig.Defaults.baseUrl]
        timeoutSeconds = SharedConfig.Defaults.timeoutSeconds
    }
}
