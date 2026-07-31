// Pure-logic JS port of keyboard/Sources/Prediction/SymSpell/SymSpellProvider.swift.
// Kept in sync per AGENTS.md -> Test policy.

import { score as qwertyScore } from './qwerty-geometry.mjs';
import { expansion } from './contractions.mjs';
import { expansion as ambiguousExpansion } from './ambiguous-contractions.mjs';
import { applyCapitalizationTemplate } from './apply-capitalization-template.mjs';

/**
 * Default parameter values matching SharedConfig.Defaults:
 *   qwertyDistanceBeta        = 1.5
 *   qwertyDoublingDiscount    = 0.5
 *   qwertyTranspositionDiscount = 0.7
 */
export const DEFAULTS = {
  beta: 1.5,
  doublingDiscount: 0.5,
  transpositionDiscount: 0.7,
};

/**
 * Adapts SymSpell to the scored-suggestion pipeline.
 *
 * In the Swift, the provider handles:
 *   - Verbatim candidate (always at score 1.0)
 *   - Contraction expansions (score 0.9)
 *   - Prefix completions from Trie for real (known) words (score 0.5)
 *   - QwertyGeometry-scored SymSpell corrections for unknown words
 *
 * In the JS harness, the Trie is not available, so the isRealWord branch
 * returns only the verbatim + contraction entries (no prefix completions).
 * When the word is NOT a real word, SymSpell candidates are scored using
 * QwertyGeometry.
 *
 * @param {import('./symspell.mjs').SymSpell} symSpell - A SymSpell instance
 * @param {Map<string, {count: number}>} [dictionary] - Full dictionary map for
 *   the isRealWord check (word -> {count}). Defaults to symSpell.dictionary.
 * @param {number} [realWordThreshold=2000] - Minimum count for a word to be
 *   considered "real" (known dictionary word).
 */
export class SymSpellProvider {
  constructor(symSpell, dictionary = null, realWordThreshold = 2000) {
    /** @type {import('./symspell.mjs').SymSpell} */
    this._symSpell = symSpell;
    /** @type {Map<string, {count: number}>} */
    this._dictionary = dictionary;
    /** @type {number} */
    this._realWordThreshold = realWordThreshold;
  }

  /**
   * Returns scored suggestions for the given input word.
   *
   * @param {string} word - The word to look up (will be lowercased).
   * @param {object} [opts]
   * @param {number} [opts.limit=8] - Max candidates to return.
   * @param {string} [opts.currentWord=word] - Original casing for the word.
   * @param {'top'|'all'|'closest'} [opts.verbosity='top'] - SymSpell verbosity.
   *   Default 'top' matches the Swift provider (only the best SymSpell candidate).
   *   Pass 'all' for broader candidate exploration in sweeps.
   * @returns {Array<{text: string, score: number, source: string, distance: number, isUnknownVerbatim: boolean}>}
   *   Sorted by score descending.
   */
  suggest(word, opts = {}) {
    const { limit = 8, currentWord = word, verbosity = 'top' } = opts;
    const lower = word.toLowerCase();
    if (!lower) return [];

    // Determine if the typed word is a "real" (known) dictionary word.
    const isRealWord = this._isRealWord(lower);

    // Contraction fast-path: checked BEFORE SymSpell so that
    // apostrophe-less forms like "dont" produce "don't" deterministically.
    const contract = expansion(lower);

    // When a contraction exists, it should be the PRIMARY candidate (leftmost
    // chip, highest score). The verbatim is demoted so it appears as a
    // secondary option the user can tap to keep the apostrophe-less form.
    const verbatimScore = contract ? 0.5 : 1.0;

    /** @type {Array<{text: string, score: number, source: string, distance: number, isUnknownVerbatim: boolean}>} */
    const results = [
      { text: currentWord, score: verbatimScore, source: 'symspell', distance: 0, isUnknownVerbatim: !isRealWord },
    ];

    if (contract) {
      results.unshift({
        text: contract,
        score: 1.0,
        source: 'contraction',
        distance: 0,
        isUnknownVerbatim: false,
      });
    }

    // Ambiguous contraction: the typed token is a real dictionary word with its
    // own meaning ("its" = possessive, "cant" = hypocritical talk), so a
    // deterministic flip would corrupt correct usage. The contraction form is
    // offered as a candidate at 0.5 — injected REGARDLESS of isRealWord,
    // alongside (not instead of) the trie-completion branch — and competes via
    // KenLM fusion. Autocorrect applies it only when the LM-margin gate in
    // topCorrection passes.
    const ambiguous = ambiguousExpansion(lower);
    if (ambiguous) {
      results.push({
        text: applyCapitalizationTemplate(currentWord, ambiguous),
        score: 0.5,
        source: 'ambiguousContraction',
        distance: 0,
        isUnknownVerbatim: false,
      });
    }

    if (isRealWord) {
      // Prefix completions from trie — not available in JS harness.
      // In the Swift, this adds trie completions at score 0.5.
      // Since we don't have a Trie, we just return verbatim + contraction.
      // This matches the current sweep behavior (the Apple-like guard
      // in runOne prevents correction of well-known words).
    } else {
      // Typo correction via SymSpell.
      // Always use 'all' internally so we can find the best non-identical
      // candidate. The input itself may appear at distance 0 (if it's in
      // the dictionary as a low-frequency word), which the identically-
      // named Swift filter `capped.lowercased() != word` excludes. Using
      // 'all' ensures the next-best candidate (distance > 0) is reachable.
      const allCorrections = this._symSpell.lookup(lower, undefined, 'all');

      // Filter out the input itself, then apply verbosity.
      const filtered = allCorrections.filter(c => c.term !== lower);
      const selected = verbosity === 'top'
        ? filtered.slice(0, 1)
        : filtered;

      for (const c of selected) {
        const qScore = qwertyScore(
          lower,
          c.term,
          c.distance,
          DEFAULTS.beta,
          DEFAULTS.doublingDiscount,
          DEFAULTS.transpositionDiscount,
        );
        results.push({
          text: c.term,
          score: qScore,
          source: 'symspell',
          distance: c.distance,
          isUnknownVerbatim: false,
        });
      }
    }

    // Sort by score descending.
    results.sort((a, b) => b.score - a.score);

    // Keep up to limit items, but always include the verbatim entry
    // (it should naturally be near the top with score 1.0).
    return results.slice(0, limit + 1);
  }

  /**
   * Check if a word is a "real" (known) dictionary word.
   * Mirrors the Swift's `trie.contains(word:) || LearnedWordsStore.shared.contains(word)`.
   * In the JS harness, we use dictionary presence with a minimum count threshold.
   *
   * @param {string} lower - Lowercased word.
   * @returns {boolean}
   */
  _isRealWord(lower) {
    if (!this._dictionary) return false;
    const entry = this._dictionary.get(lower);
    if (!entry) return false;
    return entry.count >= this._realWordThreshold;
  }
}
