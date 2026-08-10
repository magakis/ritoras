import Foundation

/// Pure offset arithmetic for replacing a typed word with a correction at a
/// cursor-relative location. No UIKit import.
///
/// The plan is expressed as `textDocumentProxy` operations applied in order:
///   1. `adjustTextPosition(byCharacterOffset: backMove)` — move the cursor
///      back to the end of the typed word.
///   2. `deleteBackward()` × `deleteCount` — remove the typed word.
///   3. `insertText(insert)` — place the correction.
///   4. `adjustTextPosition(byCharacterOffset: forwardMove)` — return the
///      cursor to its original relative spot.
enum RetroactiveApplyPlan {

    /// A cursor-relative replacement plan.
    struct Plan {
        /// Negative offset: move the cursor back to the end of the typed word.
        let backMove: Int
        /// Number of characters to delete (always `typedWord.count`).
        let deleteCount: Int
        /// The correction text to insert.
        let insert: String
        /// Positive offset: move the cursor forward again after inserting.
        let forwardMove: Int
    }

    /// Builds a plan for replacing `typedWord` with `correction` when the typed
    /// word's body ends `offsetFromCursorEnd` characters before the cursor.
    ///
    /// INVARIANT: `forwardMove == offsetFromCursorEnd` REGARDLESS of any length
    /// difference between `typedWord` and `correction`. The delete + insert
    /// happens entirely between the cursor's back-move target and the cursor's
    /// original position, so the cursor's RELATIVE distance from the corrected
    /// word's end is preserved — the cursor ends up at the same relative spot
    /// whether the correction is shorter, longer, or the same length as the
    /// typed word. (In absolute terms the cursor shifts by the length delta,
    /// which is exactly what keeps it aligned with the corrected word.)
    static func plan(typedWord: String, correction: String, offsetFromCursorEnd: Int) -> Plan {
        Plan(
            backMove: -offsetFromCursorEnd,
            deleteCount: typedWord.count,
            insert: correction,
            forwardMove: offsetFromCursorEnd
        )
    }
}
