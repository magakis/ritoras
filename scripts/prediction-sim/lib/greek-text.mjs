// Pure-logic JS port of keyboard/Sources/GreekText.swift.
// Kept in sync per AGENTS.md -> Test policy.

const MEDIAL_SIGMA = '\u{03C3}'; // σ
const FINAL_SIGMA = '\u{03C2}'; // ς

const LETTER_RE = /^\p{L}$/u;

/**
 * Convert a single trailing σ (U+03C3) to the word-final form ς (U+03C2).
 * No-op for words shorter than two characters, words ending in any other
 * character, and words already ending in ς (idempotent). Uppercase Σ is left
 * untouched. All characters involved are BMP, so UTF-16 indexing is exact for
 * the inputs this keyboard produces.
 */
export function finalSigma(word) {
  if (word.length < 2) return word;
  if (word[word.length - 1] !== MEDIAL_SIGMA) return word;
  return word.slice(0, -1) + FINAL_SIGMA;
}

/**
 * True when the character immediately before the cursor is a word-final ς
 * preceded by a letter — the shape the keyboard's auto-conversion produces.
 * The controller additionally gates on its own tracking of an auto-inserted ς;
 * this function only validates the text shape.
 */
export function shouldRevertSigma(text) {
  if (text.length < 2) return false;
  if (text[text.length - 1] !== FINAL_SIGMA) return false;
  return LETTER_RE.test(text[text.length - 2]);
}
