import Foundation

/// Snapshot of the typed word and trigger character captured on the main
/// thread at dispatch time. Used by the application guard to verify context
/// still matches when the async result completes.
struct AutocorrectAsyncSnapshot: Sendable {
    let typedWord: String
    let triggerChar: String
}

/// Pure predicate: validates at completion time that an async autocorrect
/// result is still applicable to the current document state.
///
/// All three checks must pass for the correction to be applied:
/// 1. The input target is still `.hostApp` (not `.emojiSearch`).
/// 2. The current word origin is still `.typing` — the user did not tap a
///    suggestion or have another autocorrect applied in the meantime.
/// 3. The live document context still ends with `typedWord + triggerChar`,
///    proving the cursor is still immediately after the same word + trigger
///    and no intervening keystrokes, cursor moves, or deletions occurred.
enum AutocorrectApplicationGuard {
    static func shouldApply(
        snapshot: AutocorrectAsyncSnapshot,
        liveContext: String,
        isHostApp: Bool,
        wordOrigin: WordOrigin
    ) -> Bool {
        guard isHostApp else { return false }
        guard wordOrigin == .typing else { return false }
        guard liveContext.hasSuffix(snapshot.typedWord + snapshot.triggerChar) else { return false }
        return true
    }
}
