// Pure-logic JS port of shared/TextNormalization.swift. Kept in sync per AGENTS.md → Test policy.

export const CANONICAL_APOSTROPHE = '\u{2019}';

const APOSTROPHE_VARIANTS = new Set(['\u{0027}', '\u{2018}', '\u{2019}']);

/** True iff `ch` is one of the three apostrophe variants. */
export function isApostropheVariant(ch) {
  return APOSTROPHE_VARIANTS.has(ch);
}

/** Returns the input with every apostrophe variant replaced by canonical U+2019. Idempotent. */
export function canonicalize(s) {
  let out = '';
  for (const ch of s) {
    out += APOSTROPHE_VARIANTS.has(ch) ? CANONICAL_APOSTROPHE : ch;
  }
  return out;
}

/** Quote/bracket characters treated as word boundaries at the leading/trailing edge. */
export const BOUNDARY_QUOTES = new Set([
  '"',
  '\u{201C}', '\u{201D}',
  '\u{2018}', '\u{2019}',
  '«', '»',
  '「', '」', '『', '』',
  '„',
]);
