import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var baseUrl: String {
        didSet { saveToAppGroup() }
    }
    @Published var model: String {
        didSet { saveToAppGroup() }
    }
    @Published var apiKey: String {
        didSet { saveToAppGroup() }
    }
    @Published var timeoutSeconds: TimeInterval {
        didSet { saveToAppGroup() }
    }
    @Published var language: String {
        didSet { saveToAppGroup() }
    }

    private var appGroupDefaults: UserDefaults?

    private init() {
        let config = SharedConfig.load()
        baseUrl = config.baseUrl
        model = config.model
        apiKey = config.apiKey
        timeoutSeconds = config.timeoutSeconds
        language = config.language
        appGroupDefaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
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
