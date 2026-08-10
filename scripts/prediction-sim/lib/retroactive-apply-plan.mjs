// Pure-logic JS port of keyboard/Sources/Prediction/Autocorrect/RetroactiveApplyPlan.swift.
// Kept in sync per AGENTS.md -> Test policy.

/**
 * Builds a cursor-relative plan for replacing a typed word with a correction.
 *
 * Mirrors RetroactiveApplyPlan.plan(typedWord:correction:offsetFromCursorEnd:)
 * in Swift. Expressed as textDocumentProxy operations applied in order:
 *   1. adjustTextPosition(byCharacterOffset: backMove)  — move the cursor back
 *      to the end of the typed word.
 *   2. deleteBackward() × deleteCount                    — remove the typed word.
 *   3. insertText(insert)                                — place the correction.
 *   4. adjustTextPosition(byCharacterOffset: forwardMove) — return the cursor
 *      to its original relative spot.
 *
 * INVARIANT: forwardMove === offsetFromCursorEnd REGARDLESS of any length
 * difference between typedWord and correction — the delete + insert happens
 * entirely between the cursor's back-move target and the cursor's original
 * position, so the cursor's RELATIVE distance from the corrected word's end is
 * preserved.
 *
 * @param {string} typedWord - The word the user actually typed.
 * @param {string} correction - The correction text to insert.
 * @param {number} offsetFromCursorEnd - Char distance from the cursor to the
 *   typed word's body end.
 * @returns {{backMove: number, deleteCount: number, insert: string, forwardMove: number}}
 */
export function plan(typedWord, correction, offsetFromCursorEnd) {
  return {
    backMove: -offsetFromCursorEnd,
    deleteCount: typedWord.length,
    insert: correction,
    forwardMove: offsetFromCursorEnd,
  };
}
