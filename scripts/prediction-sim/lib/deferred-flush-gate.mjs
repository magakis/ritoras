// Pure-logic JS port of keyboard/Sources/DeferredFlushGate.swift.
// Kept in sync per AGENTS.md -> Test policy.

/**
 * Tracks whether a deferred dictation flush has been checked for a document.
 * Ids are strings (or null), matching the UUID-or-nil values used by Swift.
 * A null identity never suppresses an attempt because the host can attach the
 * identity asynchronously after the keyboard appears.
 */
export class DeferredFlushGate {
  constructor() {
    this.lastCheckedDocId = null;
    this.hasChecked = false;
  }

  /**
   * Returns false only when the last recorded identity matches a non-null
   * current identity. Null identities always allow another attempt.
   * @param {string|null} currentDocId - Current document identity, or null.
   * @returns {boolean}
   */
  shouldAttempt(currentDocId) {
    if (currentDocId === null) return true;
    return !this.hasChecked || this.lastCheckedDocId !== currentDocId;
  }

  /**
   * Records the identity observed for the latest deferred flush check.
   * @param {string|null} currentDocId - Observed document identity, or null.
   */
  record(currentDocId) {
    this.hasChecked = true;
    this.lastCheckedDocId = currentDocId;
  }

  /** Clears the recorded deferred flush check. */
  reset() {
    this.hasChecked = false;
    this.lastCheckedDocId = null;
  }
}
