// Pure-logic JS port of keyboard/Sources/Prediction/WordListLoader.swift.
// Kept in sync per AGENTS.md -> Test policy.

import { loadDictionary } from './load-dictionary.mjs';
import { canonicalize } from './text-normalization.mjs';

/**
 * Loads the bundled frequency dictionary with each word canonicalized
 * (apostrophe variants -> U+2019), matching the Swift WordListLoader behavior.
 *
 * @param {string} [dictPath] - Path to the frequency dictionary file.
 * @returns {Array<{word: string, count: number}>}
 */
export function loadCanonicalDictionary(dictPath) {
  return loadDictionary(dictPath).map(({ word, count }) => ({
    word: canonicalize(word),
    count,
  }));
}
