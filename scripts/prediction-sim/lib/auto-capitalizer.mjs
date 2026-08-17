// Pure-logic JS port of keyboard/Sources/AutoCapitalization/AutoCapitalizer.swift.
// Kept in sync per AGENTS.md -> Test policy.

/** Bounded lookback (chars) — matches AutoCapitalizer.lookbackLimit (200). */
export const LOOKBACK_LIMIT = 200;

/** Closing quotes/brackets transparent when they trail terminal punctuation. */
const CLOSING_PUNCTUATION = new Set([
  '"', "'", ')', ']', '}', '」', '』', '„', '\u{201D}', // right double quotation mark
]);

/** Opening quotes/brackets transparent at a sentence-start position. */
const OPENING_PUNCTUATION = new Set([
  '"', "'", '(', '[', '{', '«', '„', '\u{201C}', // left double quotation mark
]);

/** Mid-sentence punctuation that must never trigger capitalisation. */
const MID_SENTENCE_PUNCTUATION = new Set([
  ',', ':', ';', '-', '\u{2013}', // en dash
  '\u{2014}', // em dash
  '\u{2026}', // horizontal ellipsis
]);

/**
 * Canonical English abbreviation list (every entry lowercase, includes the
 * trailing period) — mirrors AbbreviationSet.english. Only consulted for
 * `language === 'english'`; Greek has no abbreviation table.
 */
const ABBREVIATIONS = new Set([
  // Titles
  'mr.', 'mrs.', 'ms.', 'miss.', 'dr.', 'prof.', 'sr.', 'jr.', 'st.',
  'rev.', 'hon.', 'capt.', 'lt.', 'sgt.', 'pres.', 'rep.', 'sen.',
  'gov.', 'esq.',
  // Academic
  'ph.d.', 'b.a.', 'm.a.', 'm.s.', 'b.s.', 'm.d.',
  // Business
  'inc.', 'ltd.', 'co.', 'corp.', 'llc',
  // Latin
  'vs.', 'etc.', 'e.g.', 'i.e.', 'cf.', 'ca.', 'approx.',
  // Time
  'a.m.', 'p.m.',
  // Geo
  'u.s.', 'u.k.', 'u.a.e.',
  // Months
  'jan.', 'feb.', 'mar.', 'apr.', 'jun.', 'jul.', 'aug.', 'sep.',
  'sept.', 'oct.', 'nov.', 'dec.',
  // Weekdays
  'mon.', 'tue.', 'tues.', 'wed.', 'thu.', 'thur.', 'fri.', 'sat.',
  'sun.',
]);

/**
 * Returns `true` when the next character typed at the cursor position should
 * be automatically capitalised, based solely on the text before the cursor.
 *
 * Mirrors `AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor:language:)`.
 *
 * @param {string} contextBeforeCursor - The full text before the cursor.
 * @param {string} [language='english'] - Active keyboard language
 *   ('english'|'greek'). Greek differs: `;` (U+003B) is the Greek question
 *   mark and therefore sentence-ending terminal punctuation, and the English
 *   AbbreviationSet is skipped (no Greek abbreviation table).
 * @returns {boolean} `true` to capitalise, `false` to leave as-is.
 */
export function shouldCapitalizeNext(contextBeforeCursor, language = 'english') {
  const suffix = contextBeforeCursor.slice(-LOOKBACK_LIMIT);

  // 1. Start of field.
  if (suffix.length === 0 || [...suffix].every(ch => /\s/u.test(ch))) {
    return true;
  }

  // 2. Peel off trailing whitespace and closing quotes/brackets.
  let effective = trimTrailingWhitespace(suffix);
  effective = stripTrailingClosingPunctuation(effective);
  effective = trimTrailingWhitespace(effective);

  // 3. Strip leading opening quotes/brackets (symmetric trailing-closing
  //    counterpart) — opening punctuation is transparent at sentence start.
  effective = stripLeadingOpeningPunctuation(effective);
  effective = trimLeadingWhitespace(effective);

  // 4. After stripping, nothing left → sentence start.
  if (effective.length === 0) {
    return true;
  }

  // 5. Examine the last non-whitespace character.
  const lastChar = effective[effective.length - 1];

  // 6. Terminal punctuation that may end a sentence. Greek treats `;` as its
  //    question mark, so it is terminal there; English keeps it mid-sentence
  //    (step 7).
  if (lastChar === '.' || lastChar === '!' || lastChar === '?'
      || (language === 'greek' && lastChar === ';')) {
    return isTrueSentenceEnd(lastChar, effective, language);
  }

  // 7. Mid-sentence punctuation — never capitalise.
  if (MID_SENTENCE_PUNCTUATION.has(lastChar)) {
    return false;
  }

  // 8. Default: mid-word or mid-sentence → don't capitalise.
  return false;
}

/**
 * Determines whether the terminal punctuation at the end of `text` represents
 * a true sentence end, or is part of an abbreviation, initial, or numeric
 * expression. Mirrors `AutoCapitalizer.isTrueSentenceEnd(_:in:language:)`.
 *
 * @param {string} char - The trailing punctuation character.
 * @param {string} text - The effective (stripped) context.
 * @param {string} language - 'english' | 'greek'.
 * @returns {boolean}
 */
function isTrueSentenceEnd(char, text, language) {
  // Exclamation and question marks are always sentence-ending. Greek uses ";"
  // (U+003B) for its question mark, so it is always sentence-ending there too.
  if (char === '!' || char === '?') return true;
  if (language === 'greek' && char === ';') return true;

  if (char !== '.') return false;

  // Last whitespace-delimited token (the word that ends with this period).
  const lastToken = extractLastToken(text);

  // a) Known abbreviation → not a sentence end. English-only: the
  //    AbbreviationSet is an English list; Greek has no abbreviation table.
  if (language === 'english' && ABBREVIATIONS.has(lastToken.toLowerCase())) {
    return false;
  }

  const withoutPeriod = lastToken.slice(0, -1);

  // b) Single-letter initial (e.g. "A.", "J.").
  if (withoutPeriod.length === 1 && isLetter(withoutPeriod[0])) {
    return false;
  }

  // c) Multi-initial pattern (e.g. "J.K.", "U.S.A.").
  if (withoutPeriod.length > 1) {
    const segments = withoutPeriod.split('.');
    if (segments.length > 1 && segments.every(seg => seg.length === 1 && isLetter(seg[0]))) {
      return false;
    }
  }

  // d) Decimal guard: character immediately before the period is a digit.
  if (text.length > 1 && isNumber(text[text.length - 2])) {
    return false;
  }

  // Verified true sentence end.
  return true;
}

/** Returns the last whitespace-delimited token (word) in `text`. */
function extractLastToken(text) {
  let lastSpace = -1;
  for (let i = 0; i < text.length; i++) {
    if (/\s/u.test(text[i])) lastSpace = i;
  }
  return lastSpace >= 0 ? text.slice(lastSpace + 1) : text;
}

/** Strips trailing closing quotes/brackets from `text` iteratively. */
function stripTrailingClosingPunctuation(text) {
  let result = text;
  while (result.length > 0 && CLOSING_PUNCTUATION.has(result[result.length - 1])) {
    result = result.slice(0, -1);
  }
  return result;
}

/** Strips leading opening quotes/brackets from `text` iteratively. */
function stripLeadingOpeningPunctuation(text) {
  let result = text;
  while (result.length > 0 && OPENING_PUNCTUATION.has(result[0])) {
    result = result.slice(1);
  }
  return result;
}

/** Swift `isWhitespace` equivalent for a single code unit. */
function isWhitespace(ch) {
  return /\s/u.test(ch);
}

function trimTrailingWhitespace(text) {
  let end = text.length;
  while (end > 0 && isWhitespace(text[end - 1])) end--;
  return text.slice(0, end);
}

function trimLeadingWhitespace(text) {
  let start = 0;
  while (start < text.length && isWhitespace(text[start])) start++;
  return text.slice(start);
}

/** Swift `Character.isLetter` equivalent (any Unicode letter). */
function isLetter(ch) {
  return /\p{L}/u.test(ch);
}

/** Swift `Character.isNumber` equivalent (any Unicode number). */
function isNumber(ch) {
  return /\p{N}/u.test(ch);
}
