import Foundation

// MARK: - Codable Snapshots

/// Wire-compatible snapshot of the current dictation phase.
/// The `phase` field uses string values ("idle", "recording", "transcribing",
/// "done", "error") so callers on any platform can decode it without sharing
/// the `DictationPhase` enum definition.
struct DictationStateSnapshot: Codable {
    let phase: String
    let activeID: String?
    let startedAt: Date?
}

/// Wire-compatible snapshot of a terminal dictation result.
/// Mirrors the `DictationPayload` JSON shape (`{id, status, text, errorMessage, timestamp}`)
/// for consistency. Both keyboard and future clients decode the same schema.
struct DictationResultSnapshot: Codable {
    let id: String
    let status: String
    let text: String?
    let errorMessage: String?
    let timestamp: Date
}
