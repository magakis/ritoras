// Pure-logic JS port of keyboard/Sources/Prediction/AmbiguousContractions.swift.
// Kept in sync per AGENTS.md -> Test policy.

const APOSTROPHE = '\u{2019}';

/**
 * Maps canonicalized-lowercase apostrophe-less input → correctly-cased
 * contraction. Unlike CONTRACTIONS (deterministic fast-path), every key here
 * is a real standalone dictionary word with its own meaning ("its" =
 * possessive, "cant" = hypocritical talk, "id" = identification), so the
 * contraction form is only auto-applied when KenLM clearly favors it.
 */
export const AMBIGUOUS_CONTRACTIONS = new Map([
  ['its', `it${APOSTROPHE}s`],
  ['cant', `can${APOSTROPHE}t`],
  ['id', `I${APOSTROPHE}d`],
  ['well', `we${APOSTROPHE}ll`],
  ['were', `we${APOSTROPHE}re`],
  ['shell', `she${APOSTROPHE}ll`],
  ['ill', `I${APOSTROPHE}ll`],
  ['wed', `we${APOSTROPHE}d`],
  ['lets', `let${APOSTROPHE}s`],
  // NOTE: "hell" (→ he'll) deliberately omitted — low value by decision.
]);

/**
 * Returns the contraction candidate for the given canonicalized-lowercase
 * apostrophe-less input, or null if no mapping exists.
 * @param {string} word
 * @returns {string|null}
 */
export function expansion(word) {
  return AMBIGUOUS_CONTRACTIONS.get(word) ?? null;
}
