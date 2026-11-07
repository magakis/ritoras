import Foundation

/// The fixed language-intelligence slots exposed by the server-v2 `/slots` catalog.
enum ServerSlotName: String, CaseIterable, Codable, Sendable {
    case asr
    case spelling
    case vocabulary
    case prediction
    case grammar
}

/// Availability of the keyboard-consumed service slots; grammar is intentionally excluded.
struct KeyboardServicesSlotAvailability: Codable, Equatable, Sendable {
    let spelling: Bool
    let vocabulary: Bool
    let prediction: Bool

    /// Availability used when a server has no successfully decoded `/slots` response.
    static let unavailable = KeyboardServicesSlotAvailability(
        spelling: false,
        vocabulary: false,
        prediction: false
    )
}

/// A single entry returned in the server-v2 `/slots` catalog.
struct ServerSlotCatalogEntry: Codable, Equatable, Sendable {
    let name: String
    let enabled: Bool
    let status: String
    let occupant: String?
    let profile: String?
    let engine: String?
}

/// Decoded `/slots` response. Unknown JSON fields, including ASR `legacy_surface`, are ignored.
struct ServerSlotCatalog: Codable, Equatable, Sendable {
    let slots: [ServerSlotCatalogEntry]

    /// Returns the first catalog entry matching a known slot name.
    func slot(named name: ServerSlotName) -> ServerSlotCatalogEntry? {
        slots.first(where: { $0.name == name.rawValue })
    }

    /// Reports only ready, enabled spelling, vocabulary, and prediction services.
    var keyboardServicesAvailability: KeyboardServicesSlotAvailability {
        KeyboardServicesSlotAvailability(
            spelling: isReady(.spelling),
            vocabulary: isReady(.vocabulary),
            prediction: isReady(.prediction)
        )
    }

    private func isReady(_ name: ServerSlotName) -> Bool {
        guard let slot = slot(named: name) else { return false }
        return slot.enabled && slot.status == "ready"
    }
}

/// Classification of a configured server for keyboard services; dictation remains `/status`-based.
enum ServerCapabilityClassification: Equatable, Sendable {
    case dictationOnly
    case keyboardServices
}

/// Classifies a `/slots` result using the spelling slot as the keyboard-services gate.
/// Only an authenticated HTTP 200 with enabled, ready spelling is keyboard-capable.
func classifyKeyboardServicesCapability(
    statusCode: Int?,
    catalog: ServerSlotCatalog?
) -> ServerCapabilityClassification {
    guard statusCode == 200,
          let catalog,
          let spelling = catalog.slot(named: .spelling),
          spelling.enabled,
          spelling.status == "ready" else {
        return .dictationOnly
    }
    return .keyboardServices
}
