import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var servers: [String] = []
    @Published var timeoutSeconds: TimeInterval = 30.0
    @Published var autoCapitalizationEnabled: Bool = true
    @Published var dictationMode: SharedConfig.DictationMode = .batch

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)

        let config = SharedConfig.load()
        servers = config.servers
        timeoutSeconds = config.timeoutSeconds
        autoCapitalizationEnabled = SharedConfig.autoCapitalizationEnabled()
        dictationMode = SharedConfig.dictationMode()

        $servers.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $timeoutSeconds.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $autoCapitalizationEnabled.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $dictationMode.dropFirst().sink { [weak self] newValue in
            #if DEBUG
            print("[AppSettings] dictationMode changed to \(newValue.rawValue)")
            #endif
            self?.saveToAppGroup()
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
        appGroupDefaults?.set(dictationMode.rawValue, forKey: SharedConfig.Defaults.dictationModeKey)
    }

    func resetToDefaults() {
        servers = [SharedConfig.Defaults.baseUrl]
        timeoutSeconds = SharedConfig.Defaults.timeoutSeconds
        autoCapitalizationEnabled = SharedConfig.Defaults.autoCapitalizationEnabledDefault
        dictationMode = .batch
    }
}
