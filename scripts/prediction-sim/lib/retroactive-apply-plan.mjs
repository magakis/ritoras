// Pure-logic JS port of keyboard/Sources/Prediction/Autocorrect/RetroactiveApplyPlan.swift.
// Kept in sync per AGENTS.md -> Test policy.

import { extract } from './recent-words-extractor.mjs';

/**
 * Builds a cursor-relative plan for replacing a typed word with a correction.
 *
 * Mirrors RetroactiveApplyPlan.plan(typedWord:correction:offsetFromCursorEnd:contextAnchor:)
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
 * @param {string} [contextAnchor=''] - Context captured with the committed word.
 * @returns {{backMove: number, deleteCount: number, insert: string, forwardMove: number, expectedText: string, contextAnchor: string}}
 */
export function plan(typedWord, correction, offsetFromCursorEnd, contextAnchor = '') {
  return {
    backMove: -offsetFromCursorEnd,
    deleteCount: typedWord.length,
    insert: correction,
    forwardMove: offsetFromCursorEnd,
    expectedText: typedWord,
    contextAnchor,
  };
}

/**
 * Resolves the committed word against current live text. `null` means the
 * caller must abort without moving the cursor or mutating the document.
 */
export function revalidatedPlan(p, liveContext) {
  if (!p.contextAnchor || !p.expectedText) return null;
  const anchorStart = liveContext.indexOf(p.contextAnchor);
  if (anchorStart < 0 || liveContext.indexOf(p.contextAnchor, anchorStart + 1) >= 0) {
    return null;
  }

  const anchoredWord = extract(`${p.contextAnchor} `, 1)[0];
  if (!anchoredWord || !hasExactBytes(anchoredWord.wordBody, p.expectedText)) return null;

  const anchorEnd = anchorStart + p.contextAnchor.length;
  const anchorOffset = anchoredWord.offsetFromCursorEnd - 1;
  if (anchorOffset < 0) return null;
  const offsetFromCursorEnd = liveContext.length - anchorEnd + anchorOffset;
  const end = liveContext.length - offsetFromCursorEnd;
  const start = end - p.expectedText.length;
  if (start < 0 || !hasExactBytes(liveContext.slice(start, end), p.expectedText)) return null;

  return {
    ...p,
    backMove: -offsetFromCursorEnd,
    deleteCount: p.expectedText.length,
    forwardMove: offsetFromCursorEnd,
  };
}

/** Applies only after live-range resolution and byte verification succeed. */
export function applyVerified(doc, cursor, p) {
  const livePlan = revalidatedPlan(p, doc.slice(0, cursor));
  if (!livePlan) return { doc, cursor, applied: false };

  let nextCursor = cursor + livePlan.backMove;
  const nextDoc = doc.slice(0, nextCursor - livePlan.deleteCount)
    + doc.slice(nextCursor);
  nextCursor -= livePlan.deleteCount;
  const insertedDoc = nextDoc.slice(0, nextCursor)
    + livePlan.insert
    + nextDoc.slice(nextCursor);
  nextCursor += livePlan.insert.length + livePlan.forwardMove;
  return { doc: insertedDoc, cursor: nextCursor, applied: true };
}

function hasExactBytes(actual, expected) {
  return Buffer.from(actual, 'utf8').equals(Buffer.from(expected, 'utf8'));
}
