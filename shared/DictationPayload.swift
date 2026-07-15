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
    
    // Read from App Group UserDefaults
    static func current() -> DictationPayload? {
        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId),
              let data = defaults.data(forKey: SharedConfig.Defaults.dictationPayloadKey) else {
            return nil
        }
        return try? JSONDecoder().decode(DictationPayload.self, from: data)
    }
    
    // Write to App Group UserDefaults
    func save() {
        guard let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId) else { return }
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: SharedConfig.Defaults.dictationPayloadKey)
        }
    }
}
