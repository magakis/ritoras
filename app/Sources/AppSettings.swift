import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var baseUrl: String = ""
    @Published var model: String = ""
    @Published var apiKey: String = ""
    @Published var timeoutSeconds: TimeInterval = 30.0
    @Published var language: String = ""

    private var appGroupDefaults: UserDefaults?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Initialize appGroupDefaults BEFORE setting properties to avoid nil in didSet
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)

        // Now load config and set properties
        let config = SharedConfig.load()
        baseUrl = config.baseUrl
        model = config.model
        apiKey = config.apiKey
        timeoutSeconds = config.timeoutSeconds
        language = config.language

        // Set up Combine subscriptions to save when any property changes
        $baseUrl.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $model.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $apiKey.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $timeoutSeconds.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
        $language.dropFirst().sink { [weak self] _ in self?.saveToAppGroup() }.store(in: &cancellables)
    }

    private func saveToAppGroup() {
        appGroupDefaults?.set(baseUrl, forKey: "baseUrl")
        appGroupDefaults?.set(model, forKey: "model")
        appGroupDefaults?.set(apiKey, forKey: "apiKey")
        appGroupDefaults?.set(timeoutSeconds, forKey: "timeoutSeconds")
        appGroupDefaults?.set(language, forKey: "language")
    }

    func resetToDefaults() {
        baseUrl = SharedConfig.Defaults.baseUrl
        model = SharedConfig.Defaults.model
        apiKey = SharedConfig.Defaults.apiKey
        timeoutSeconds = SharedConfig.Defaults.timeoutSeconds
        language = SharedConfig.Defaults.language
    }
}
