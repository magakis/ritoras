// Pure-logic JS port of PredictionEngine.fusedPool().
// Kept in sync per AGENTS.md -> Test policy.

import { normalizeForKenLM } from './kenlm-normalize.mjs';

/**
 * Apple-boost + KenLM re-score + dedup. Pure function over the input pool.
 * Mirrors the Swift `PredictionEngine.fusedPool(forCurrentWord:lookupWord:previousWord:previousWord2:)`.
 *
 * @param {object} opts
 * @param {Array<{text:string,score:number,source:string}>} opts.pool - Pre-built suggestion pool (from merged providers).
 * @param {string} opts.currentWord - The word currently being typed.
 * @param {string|null|undefined} opts.previousWord - Previous word for KenLM context.
 * @param {string|null|undefined} opts.previousWord2 - Word before previous for KenLM context.
 * @param {function|null} opts.kenlmScorer - (candidate, prev, prev2) => log10 probability or null.
 * @param {number} [opts.blendWeight=0.5] - KenLM blend weight (0 = pure SymSpell/Apple, 1 = pure KenLM).
 * @returns {Array<{text:string,score:number,source:string}>} Deduped, re-scored pool.
 */
export function fusedPool({ pool, currentWord, previousWord, previousWord2, kenlmScorer, blendWeight = 0.5 }) {
  let all = [...pool];

  // — Apple boost: when SymSpell max non-input score < 0.7, boost .apple entries ×1.2 capped at 1.0 —
  const symspellMaxNonInput = Math.max(0, ...all
    .filter(s => s.source === 'symspell' && s.text.toLowerCase() !== currentWord.toLowerCase())
    .map(s => s.score));

  if (symspellMaxNonInput < 0.7) {
    all = all.map(s => s.source === 'apple'
      ? { ...s, score: Math.min(s.score * 1.2, 1.0) }
      : s);
  }

  // — KenLM re-score: min-max normalize log probs, blend with original score —
  if (kenlmScorer) {
    // KenLM's vocabulary is ASCII-only: normalize the candidate and the context
    // words to U+0027 before scoring (mirrors TrigramProvider.rawLogProb).
    const prev = previousWord ? normalizeForKenLM(previousWord) : previousWord;
    const prev2 = previousWord2 ? normalizeForKenLM(previousWord2) : previousWord2;
    const scored = all.map(s => ({
      s,
      logProb: kenlmScorer(normalizeForKenLM(s.text), prev, prev2) ?? -10,
    }));

    if (scored.length > 0) {
      const logProbs = scored.map(x => x.logProb);
      const maxLog = Math.max(...logProbs);
      const minLog = Math.min(...logProbs);
      const range = Math.max(maxLog - minLog, 0.001);

      all = scored.map(({ s, logProb }) => {
        const normalizedKenLM = (logProb - minLog) / range;
        return { ...s, score: (1 - blendWeight) * s.score + blendWeight * normalizedKenLM };
      });
    }
  }

  // — Dedupe by text, keeping the highest score —
  const bestByText = new Map();
  for (const s of all) {
    const existing = bestByText.get(s.text);
    if (!existing || s.score > existing.score) bestByText.set(s.text, s);
  }

  return [...bestByText.values()];
}
