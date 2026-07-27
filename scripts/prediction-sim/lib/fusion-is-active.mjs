// Pure-logic JS port of PredictionEngine.fusionIsActive(previousWord:).
// Kept in sync per AGENTS.md -> Test policy.

/**
 * True when KenLM fusion would actually run: a previous word exists to give
 * context AND the trigram provider is loaded.
 *
 * @param {object} opts
 * @param {string|null|undefined} opts.previousWord - The word before the current word.
 * @param {boolean} opts.trigramReady - Whether the trigram/KenLM provider is loaded and ready.
 * @returns {boolean}
 */
export function fusionIsActive({ previousWord, trigramReady }) {
  if (!previousWord || previousWord.length === 0) return false;
  return trigramReady === true;
}
