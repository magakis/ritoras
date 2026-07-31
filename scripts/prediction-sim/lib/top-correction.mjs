// Pure-logic JS port of PredictionEngine.topCorrection().
// Kept in sync per AGENTS.md -> Test policy.

import { fusedPool } from './fused-pool.mjs';
import { fusionIsActive } from './fusion-is-active.mjs';
import { normalizeForKenLM } from './kenlm-normalize.mjs';

/**
 * Returns the highest-scoring correction candidate after fusion, or null if
 * no candidate meets the criteria. Mirrors the Swift
 * `PredictionEngine.topCorrection(forCurrentWord:lookupWord:previousWord:previousWord2:)`.
 *
 * @param {object} opts
 * @param {Array<{text:string,score:number,source:string}>} opts.pool - Pre-built suggestion pool.
 * @param {string} opts.currentWord - The word currently being typed.
 * @param {string|null|undefined} opts.previousWord - Previous word for KenLM context.
 * @param {string|null|undefined} opts.previousWord2 - Word before previous for KenLM context.
 * @param {function|null} opts.kenlmScorer - (candidate, prev, prev2) => log10 probability or null.
 * @param {boolean} opts.trigramReady - Whether trigram/KenLM provider is ready.
 * @param {number} [opts.blendWeight=0.5] - KenLM blend weight.
 * @param {number} [opts.absoluteLogProbFloor=-8] - Absolute KenLM log-prob floor.
 * @param {number} [opts.ambiguousContractionMargin=1.0] - Minimum KenLM log-prob
 *   advantage the contraction must hold over the typed literal to auto-flip.
 * @returns {{text:string,score:number,source:string}|null}
 */
export function topCorrection({
  pool,
  currentWord,
  previousWord,
  previousWord2,
  kenlmScorer,
  trigramReady,
  blendWeight = 0.5,
  absoluteLogProbFloor = -8.0,
  ambiguousContractionMargin = 1.0,
}) {
  const fused = fusedPool({ pool, currentWord, previousWord, previousWord2, kenlmScorer, blendWeight });
  const lowerTyped = currentWord.toLowerCase();

  // KenLM's vocabulary is ASCII-only: normalize the candidate and the context
  // words to U+0027 before scoring (mirrors TrigramProvider.rawLogProb).
  const prev = previousWord ? normalizeForKenLM(previousWord) : previousWord;
  const prev2 = previousWord2 ? normalizeForKenLM(previousWord2) : previousWord2;

  // Exclude .trigram source and the typed word itself.
  const candidates = fused.filter(s => s.source !== 'trigram' && s.text.toLowerCase() !== lowerTyped);
  if (candidates.length === 0) return null;

  const winner = candidates.reduce((best, s) => s.score > best.score ? s : best);

  // Absolute KenLM floor: reject contextually implausible candidates.
  if (fusionIsActive({ previousWord, trigramReady }) && kenlmScorer) {
    const logProb = kenlmScorer(normalizeForKenLM(winner.text), prev, prev2) ?? -10.0;
    if (logProb < absoluteLogProbFloor) return null;
  }

  // Ambiguous-contraction margin gate: never auto-flip a real dictionary word
  // ("its", "cant", "id") to its contraction form without LM context, and only
  // when KenLM clearly favors the contraction over the typed literal.
  if (winner.source === 'ambiguousContraction') {
    if (!fusionIsActive({ previousWord, trigramReady }) || !kenlmScorer) return null;
    const contractionLogProb = kenlmScorer(normalizeForKenLM(winner.text), prev, prev2) ?? -10.0;
    const typedLiteralLogProb = kenlmScorer(normalizeForKenLM(currentWord), prev, prev2) ?? -10.0;
    if (contractionLogProb - typedLiteralLogProb < ambiguousContractionMargin) return null;
  }

  return winner;
}
