import Foundation

/// The supported styling options for per-request LLM cleanup.
enum LLMCleanupStyling: String, CaseIterable, Sendable {
    case serverDefault = "serverDefault"
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal

    /// User-facing label for cleanup settings.
    var displayName: String {
        switch self {
        case .serverDefault: return "Server default"
        case .casual: return "Casual"
        case .semiCasual: return "Semi-casual"
        case .semiFormal: return "Semi-formal"
        case .formal: return "Formal"
        }
    }
}

/// The supported structure options for per-request LLM cleanup.
enum LLMCleanupStructure: String, CaseIterable, Sendable {
    case serverDefault = "serverDefault"
    case prose
    case lists

    /// User-facing label for cleanup settings.
    var displayName: String {
        switch self {
        case .serverDefault: return "Server default"
        case .prose: return "Prose"
        case .lists: return "Lists"
        }
    }
}

/// The supported context options for per-request LLM cleanup.
enum LLMCleanupContext: String, CaseIterable, Sendable {
    case serverDefault = "serverDefault"
    case general
    case email

    /// User-facing label for cleanup settings.
    var displayName: String {
        switch self {
        case .serverDefault: return "Server default"
        case .general: return "General"
        case .email: return "Email"
        }
    }
}

/// Immutable cleanup preferences shared by settings and dictation request builders.
struct LLMCleanupPreferences: Sendable {
    let styling: LLMCleanupStyling
    let structure: LLMCleanupStructure
    let context: LLMCleanupContext

    /// Calls `body` only for explicitly selected values; server defaults are omitted.
    func forEachWireField(_ body: (String, String) -> Void) {
        if styling != .serverDefault {
            body("cleanup_styling", styling.rawValue)
        }
        if structure != .serverDefault {
            body("cleanup_structure", structure.rawValue)
        }
        if context != .serverDefault {
            body("cleanup_context", context.rawValue)
        }
    }
}
