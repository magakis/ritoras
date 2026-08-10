// Pure-logic JS port of keyboard/Sources/Prediction/Autocorrect/RecentWordsExtractor.swift.
// Kept in sync per AGENTS.md -> Test policy.

import { canonicalize } from './text-normalization.mjs';

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
 *
 * Local copy mirroring the private helper in RecentWordsExtractor.swift, which
 * itself mirrors CurrentWordExtractor.swift — the Swift helpers are private per
 * file, so the ports carry the same per-file copy.
 */
function stripTrailingPunctuation(word) {
  if (word === null || word === undefined || word === '') return null;
  let result = word;
  while (result.length > 0 && isPunctuation(result[result.length - 1])) {
    result = result.slice(0, -1);
  }
  return result === '' ? null : result;
}

function isWhitespace(ch) {
  return /\s/.test(ch);
}

/**
 * Extracts recently committed words walking backwards from the cursor.
 *
 * Mirrors RecentWordsExtractor.extract(from:maxCount:) in Swift.
 *
 * @param {string|null|undefined} context - The full string before the cursor.
 * @param {number} maxCount - Maximum number of committed words to return (default 4).
 * @returns {Array<{word: string, lookupWord: string, offsetFromCursorEnd: number}>}
 *   Most recent word first. `offsetFromCursorEnd` is the char distance from the
 *   cursor to the END of the word's body (after trailing punctuation).
 */
export function extract(context, maxCount = 4) {
  if (context === null || context === undefined || context === '') return [];
  if (!(maxCount > 0)) return [];

  const endsWithWhitespace = /\s$/.test(context);

  const results = [];
  let index = context.length;

  // Skip trailing whitespace so `index` lands just after the last token.
  while (index > 0 && isWhitespace(context[index - 1])) {
    index--;
  }

  // If the cursor is mid-word, skip the in-progress token and the whitespace
  // before it, so `index` points just after the last committed word.
  if (!endsWithWhitespace) {
    while (index > 0) {
      const previous = context[index - 1];
      if (isWhitespace(previous)) {
        index--;
        break;
      }
      index--;
    }
  }

  // Collect committed words walking backwards, up to maxCount.
  while (results.length < maxCount && index > 0) {
    // Find the start of the token ending at `index`.
    let tokenStart = index;
    while (tokenStart > 0 && !isWhitespace(context[tokenStart - 1])) {
      tokenStart--;
    }

    const word = context.slice(tokenStart, index);
    const stripped = stripTrailingPunctuation(word) ?? word;
    const lookupWord = canonicalize(stripped);

    // The word's body (after trailing punctuation) ends `strippedCount`
    // characters before the token's display end. The apply plan deletes exactly
    // the body, so the offset must point at the body end.
    const strippedCount = word.length - stripped.length;
    const bodyEnd = index - strippedCount;

    results.push({
      word,
      lookupWord,
      offsetFromCursorEnd: context.length - bodyEnd,
    });

    // Advance to the previous token: hop over the current token's start
    // position, then over any whitespace separating it from the next token.
    index = tokenStart;
    while (index > 0 && isWhitespace(context[index - 1])) {
      index--;
    }
  }

  return results;
}
