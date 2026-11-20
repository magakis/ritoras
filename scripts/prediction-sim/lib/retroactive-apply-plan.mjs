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

/** Verifies the expected deletion window and its exact preceding context. */
export function matchesApplyTarget(p, liveContextAtCaret) {
  if (typeof liveContextAtCaret !== 'string' || liveContextAtCaret === '') return false;
  if (p.deleteCount <= 0 || p.deleteCount !== p.expectedText.length) return false;

  const precedingAnchor = precedingContextAnchor(p);
  if (precedingAnchor === null || precedingAnchor === '') return false;

  const windowStart = liveContextAtCaret.length - p.deleteCount;
  if (windowStart < 0
      || !hasExactBytes(liveContextAtCaret.slice(windowStart), p.expectedText)) {
    return false;
  }

  const textBeforeWindow = liveContextAtCaret.slice(0, windowStart);
  return textBeforeWindow.length >= precedingAnchor.length
    && hasExactBytes(textBeforeWindow.slice(-precedingAnchor.length), precedingAnchor);
}

/** Returns the captured context immediately before the committed word body. */
function precedingContextAnchor(p) {
  if (!p.contextAnchor || !p.expectedText) return null;

  const anchoredWord = extract(`${p.contextAnchor} `, 1)[0];
  if (!anchoredWord || !hasExactBytes(anchoredWord.wordBody, p.expectedText)) return null;

  const wordEndOffset = anchoredWord.offsetFromCursorEnd - 1;
  const wordEnd = p.contextAnchor.length - wordEndOffset;
  const wordStart = wordEnd - p.expectedText.length;
  if (wordEndOffset < 0
      || wordStart < 0
      || wordEnd < wordStart
      || !hasExactBytes(p.contextAnchor.slice(wordStart, wordEnd), p.expectedText)) {
    return null;
  }

  return p.contextAnchor.slice(0, wordStart);
}

/** Simulates one deferred apply, consuming the pending correction on every outcome. */
export function applyVerified(
  doc,
  cursor,
  p,
  { cursorAdjustmentSucceeds = true, contextReadable = true } = {}
) {
  const livePlan = revalidatedPlan(p, doc.slice(0, cursor));
  if (!livePlan) return { doc, cursor, applied: false, pendingCorrection: null };

  let nextCursor = cursorAdjustmentSucceeds
    ? cursor + livePlan.backMove
    : cursor;
  const liveContextAtCaret = contextReadable ? doc.slice(0, nextCursor) : null;
  if (!matchesApplyTarget(livePlan, liveContextAtCaret)) {
    return { doc, cursor: nextCursor, applied: false, pendingCorrection: null };
  }

  const nextDoc = doc.slice(0, nextCursor - livePlan.deleteCount)
    + doc.slice(nextCursor);
  nextCursor -= livePlan.deleteCount;
  const insertedDoc = nextDoc.slice(0, nextCursor)
    + livePlan.insert
    + nextDoc.slice(nextCursor);
  nextCursor += livePlan.insert.length + livePlan.forwardMove;
  return {
    doc: insertedDoc,
    cursor: nextCursor,
    applied: true,
    pendingCorrection: null,
  };
}

function hasExactBytes(actual, expected) {
  return Buffer.from(actual, 'utf8').equals(Buffer.from(expected, 'utf8'));
}
