// Pure-logic JS port of SymSpellProvider.applyCapitalizationTemplate(from:to:).
// Kept in sync per AGENTS.md -> Test policy.

/**
 * Applies the capitalization pattern from `input` to `suggestion`.
 *
 * Heuristic (covers ~95% of real cases):
 * - If suggestion already contains an uppercase letter beyond position 0,
 *   it is likely a proper noun (e.g. "USA", "iPhone") → return as-is.
 * - If `input` first char is uppercase and the rest is lowercase/whitespace →
 *   "sentence case" → uppercase the first letter of suggestion.
 * - If `input` is all uppercase and length > 1 →
 *   "all caps" → uppercase the entire suggestion.
 * - Otherwise → "lowercase / mixed" → return suggestion as-is.
 *
 * @param {string} input - The typed word (capitalization template).
 * @param {string} suggestion - The lowercase suggestion to apply template to.
 * @returns {string}
 */
export function applyCapitalizationTemplate(input, suggestion) {
  // Preserve suggestions that are already capitalized (proper nouns / acronyms).
  const suggestionAfterFirst = suggestion.slice(1);
  if ([...suggestionAfterFirst].some(ch => ch !== ch.toLowerCase())) {
    return suggestion;
  }

  if (input.length === 0) return suggestion;

  const firstChar = input[0];
  const rest = input.slice(1);

  // Sentence case: first char uppercase, rest is lowercase or whitespace.
  if (firstChar !== firstChar.toLowerCase() && [...rest].every(ch =>
    (ch !== ch.toUpperCase() && ch === ch.toLowerCase()) || /\s/u.test(ch)
  )) {
    if (suggestion.length === 0) return suggestion;
    return suggestion[0].toUpperCase() + suggestion.slice(1);
  }

  // All caps: input length > 1 and every char is uppercase.
  if (input.length > 1 && [...input].every(ch => ch !== ch.toLowerCase())) {
    return suggestion.toUpperCase();
  }

  // English orthography: the standalone pronoun "i" is always capitalized ("I").
  // Applies only when the result begins with a lowercase "i" immediately
  // followed by an apostrophe (i'd, i'll, i'm) — never arbitrary leading "i"
  // ("information").
  if (suggestion[0] === 'i' && (suggestion[1] === "'" || suggestion[1] === '\u{2019}')) {
    return 'I' + suggestion.slice(1);
  }

  // Lowercase / mixed: leave suggestion as-is.
  return suggestion;
}
