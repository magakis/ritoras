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

}
