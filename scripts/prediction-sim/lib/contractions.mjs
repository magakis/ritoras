// Pure-logic JS port of keyboard/Sources/Prediction/Contractions.swift.
// Kept in sync per AGENTS.md -> Test policy.

const APOSTROPHE = '\u{2019}';

/**
 * Maps canonicalized-lowercase apostrophe-less input → lowercase contraction.
 * Case is re-applied by the caller via `applyCapitalizationTemplate`.
 *
 * Conservative inclusion policy: only keys that, when the user types them, are
 * almost certainly intended as contractions rather than standalone words.
 * Ambiguous keys like `well` (→ `we'll`), `were` (→ `we're`), `its` (→ `it's`),
 * `cant` (→ `can't`), `cause` (→ `'cause`), `bout` (→ `'bout`) are deliberately
 * EXCLUDED to avoid false-positive autocorrects on correctly-typed words.
 */
export const CONTRACTIONS = new Map([
  // Negative contractions
  ['dont', `don${APOSTROPHE}t`],
  ['wont', `won${APOSTROPHE}t`],
  ['couldnt', `couldn${APOSTROPHE}t`],
  ['wouldnt', `wouldn${APOSTROPHE}t`],
  ['shouldnt', `shouldn${APOSTROPHE}t`],
  ['isnt', `isn${APOSTROPHE}t`],
  ['wasnt', `wasn${APOSTROPHE}t`],
  ['arent', `aren${APOSTROPHE}t`],
  ['didnt', `didn${APOSTROPHE}t`],
  ['doesnt', `doesn${APOSTROPHE}t`],
  ['havent', `haven${APOSTROPHE}t`],
  ['hadnt', `hadn${APOSTROPHE}t`],
  ['hasnt', `hasn${APOSTROPHE}t`],
  ['werent', `weren${APOSTROPHE}t`],
  ['neednt', `needn${APOSTROPHE}t`],
  ['oughtnt', `oughtn${APOSTROPHE}t`],

  // Pronoun + verb contractions
  ['youre', `you${APOSTROPHE}re`],
  ['youve', `you${APOSTROPHE}ve`],
  ['youll', `you${APOSTROPHE}ll`],
  ['youd', `you${APOSTROPHE}d`],
  ['theyre', `they${APOSTROPHE}re`],
  ['theyve', `they${APOSTROPHE}ve`],
  ['theyll', `they${APOSTROPHE}ll`],
  ['theyd', `they${APOSTROPHE}d`],
  ['thats', `that${APOSTROPHE}s`],
  ['whats', `what${APOSTROPHE}s`],
  ['heres', `here${APOSTROPHE}s`],
  ['theres', `there${APOSTROPHE}s`],
  ['whos', `who${APOSTROPHE}s`],
  ['hes', `he${APOSTROPHE}s`],
  ['shes', `she${APOSTROPHE}s`],
  ['maam', `ma${APOSTROPHE}am`],
  ['yall', `y${APOSTROPHE}all`],
  ['tis', `${APOSTROPHE}tis`],
  ['twas', `${APOSTROPHE}twas`],
]);

/**
 * Returns the canonical contraction for the given canonicalized-lowercase
 * apostrophe-less input, or null if no mapping exists.
 * @param {string} word
 * @returns {string|null}
 */
export function expansion(word) {
  return CONTRACTIONS.get(word) ?? null;
}
