// Pure-logic JS port of keyboard/Sources/Prediction/CurrentWordExtractor.swift.
// Kept in sync per AGENTS.md -> Test policy.

import { canonicalize, BOUNDARY_QUOTES, isApostropheVariant } from './text-normalization.mjs';

// Unicode property check for "is punctuation".
// Matches Swift's Character.isPunctuation for the characters we care about
// (quotes, apostrophes, brackets, commas, periods, etc.).
const PUNCTUATION_RE = /[\p{P}]/u;

function isPunctuation(ch) {
  return PUNCTUATION_RE.test(ch);
}

/**
 * Strip ALL trailing punctuation (apostrophes included) from a finished word.
 * Returns null if the input is null/empty or becomes empty after stripping.
 */
function stripTrailingPunctuation(word) {
  if (word === null || word === undefined || word === '') return null;
  let result = word;
  while (result.length > 0 && isPunctuation(result[result.length - 1])) {
    result = result.slice(0, -1);
  }
  return result === '' ? null : result;
}

/**
 * Strip trailing punctuation from a word, but preserve apostrophe variants
 * (contractions like don't, names like O'Brien, possessives).
 */
function stripTrailingNonApostrophePunctuation(word) {
  let result = word;
  while (result.length > 0) {
    const last = result[result.length - 1];
    if (isApostropheVariant(last)) break;
    if (!isPunctuation(last)) break;
    result = result.slice(0, -1);
  }
  return result;
}

/**
 * Strip leading boundary-quote punctuation from an in-progress token.
 * Apostrophes at the leading edge are also stripped (they cannot be word-internal
 * without a preceding letter).
 */
function stripLeadingPunctuation(word) {
  let result = word;
  while (result.length > 0 && BOUNDARY_QUOTES.has(result[0])) {
    result = result.slice(1);
  }
  return result;
}

/**
 * Extracts the current word context from the document text before the cursor.
 *
 * Mirrors CurrentWordExtractor.extract(from:) in Swift.
 *
 * @param {string|null|undefined} context - The full string before the cursor.
 * @returns {{ currentWord: string, lookupWord: string, previousWord: string|null, previousWord2: string|null, isAtWordBoundary: boolean }}
 */
export function extract(context) {
  if (context === null || context === undefined || context === '') {
    return {
      currentWord: '',
      lookupWord: '',
      previousWord: null,
      previousWord2: null,
      isAtWordBoundary: true,
    };
  }

  // Check if cursor is at a word boundary (last char is whitespace).
  const isAtWordBoundary = /\s$/.test(context);

  // Split into non-empty tokens (do NOT trim the input first).
  const tokens = context.split(/\s+/).filter(Boolean);

  if (isAtWordBoundary) {
    // Cursor is after whitespace -> ready for next-word prediction.
    const currentWord = '';
    const lookupWord = '';
    const previousWord = stripTrailingPunctuation(tokens[tokens.length - 1]);
    const previousWord2 = tokens.length >= 2
      ? stripTrailingPunctuation(tokens[tokens.length - 2])
      : null;
    return {
      currentWord,
      lookupWord,
      previousWord,
      previousWord2,
      isAtWordBoundary: true,
    };
  } else {
    // Cursor is mid-word -> completions of the current word.
    const currentWord = tokens[tokens.length - 1] ?? '';
    const stripped = stripLeadingPunctuation(currentWord);
    const stripped2 = stripTrailingNonApostrophePunctuation(stripped);
    const lookupWord = canonicalize(stripped2);

    const previousWord = tokens.length >= 2
      ? stripTrailingPunctuation(tokens[tokens.length - 2])
      : null;
    const previousWord2 = tokens.length >= 3
      ? stripTrailingPunctuation(tokens[tokens.length - 3])
      : null;

    return {
      currentWord,
      lookupWord,
      previousWord,
      previousWord2,
      isAtWordBoundary: false,
    };
  }
}
