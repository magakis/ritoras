// Mid-word pinning logic: faithful port of PredictionEngine.suggestions().
// Empty-prefix branch: simplified approximation (no Swift default-suggestion fallback).
// Kept in sync per AGENTS.md -> Test policy.

import { fusedPool } from './fused-pool.mjs';

/**
 * Returns suggestion strings mirroring the Swift
 * `PredictionEngine.suggestions(forCurrentWord:lookupWord:previousWord:previousWord2:limit:)`.
 *
 * In the empty-prefix case (no current word), the pool is fused, sorted, and
 * the top N display strings are returned — no verbatim to pin.
 *
 * In the mid-word case, the pool is fused, the verbatim entry is pinned to
 * position #1, and the remaining slots are filled by corrections sorted by
 * score descending. Unknown words (isUnknownVerbatim) are returned quoted.
 *
 * @param {object} opts
 * @param {Array<{text:string,score:number,source:string,isUnknownVerbatim?:boolean}>} opts.pool - Pre-built suggestion pool.
 * @param {string} opts.currentWord - The word currently being typed (empty when after whitespace).
 * @param {string|null|undefined} opts.previousWord - Previous word for KenLM context.
 * @param {string|null|undefined} opts.previousWord2 - Word before previous for KenLM context.
 * @param {function|null} opts.kenlmScorer - (candidate, prev, prev2) => log10 probability or null.
 * @param {number} [opts.blendWeight=0.5] - KenLM blend weight.
 * @param {number} [opts.limit=3] - Maximum number of suggestions to return.
 * @returns {string[]} Sorted suggestion strings.
 */
export function suggestions({ pool, currentWord, previousWord, previousWord2, kenlmScorer, blendWeight = 0.5, limit = 3 }) {
  // ──────────────────────────────────────────────
  // EMPTY-PREFIX CASE: cursor is after whitespace
  // ──────────────────────────────────────────────
  if (!currentWord) {
    const fused = fusedPool({ pool, currentWord, previousWord, previousWord2, kenlmScorer, blendWeight });

    return fused
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map(s => s.text);
  }

  // ──────────────────────────────────────────────
  // MID-WORD CASE: user is typing a word
  // ──────────────────────────────────────────────
  const fused = fusedPool({ pool, currentWord, previousWord, previousWord2, kenlmScorer, blendWeight });
  const lowerCurrent = currentWord.toLowerCase();

  // — Pin verbatim/current word to #1 (iOS QuickType convention),
  // then sort corrections by score descending —
  const verbatim = fused.find(s => s.text.toLowerCase() === lowerCurrent);
  const corrections = fused
    .filter(s => s.text.toLowerCase() !== lowerCurrent)
    .sort((a, b) => b.score - a.score);

  let pinned;
  if (verbatim != null) {
    pinned = [verbatim, ...corrections.slice(0, Math.max(limit - 1, 0))];
  } else {
    pinned = corrections.slice(0, limit);
  }

  return pinned
    .slice(0, limit)
    .map(s => s.isUnknownVerbatim ? `"${s.text}"` : s.text);
}
