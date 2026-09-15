import Foundation

/// Tracks whether a deferred dictation flush has been checked for a document.
/// A nil identity never suppresses an attempt because the host can attach the
/// identity asynchronously after the keyboard appears.
struct DeferredFlushGate {
    private(set) var lastCheckedDocId: UUID?
    private(set) var hasChecked = false

    /// Returns false only when the last recorded identity matches a non-nil
    /// current identity. Nil identities always allow another attempt.
    func shouldAttempt(currentDocId: UUID?) -> Bool {
        guard let currentDocId else { return true }
        return !hasChecked || lastCheckedDocId != currentDocId
    }

    /// Records the identity observed for the latest deferred flush check.
    mutating func record(currentDocId: UUID?) {
        hasChecked = true
        lastCheckedDocId = currentDocId
    }

    /// Clears the recorded deferred flush check.
    mutating func reset() {
        hasChecked = false
        lastCheckedDocId = nil
    }
}
