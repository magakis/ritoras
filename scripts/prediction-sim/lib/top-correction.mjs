// Pure-logic JS port of PredictionEngine.topCorrection().
// Kept in sync per AGENTS.md -> Test policy.

import { fusedPool } from './fused-pool.mjs';
import { fusionIsActive } from './fusion-is-active.mjs';

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
}) {
  const fused = fusedPool({ pool, currentWord, previousWord, previousWord2, kenlmScorer, blendWeight });
  const lowerTyped = currentWord.toLowerCase();

  // Exclude .trigram source and the typed word itself.
  const candidates = fused.filter(s => s.source !== 'trigram' && s.text.toLowerCase() !== lowerTyped);
  if (candidates.length === 0) return null;

  const winner = candidates.reduce((best, s) => s.score > best.score ? s : best);

  // Absolute KenLM floor: reject contextually implausible candidates.
  if (fusionIsActive({ previousWord, trigramReady }) && kenlmScorer) {
    const logProb = kenlmScorer(winner.text, previousWord, previousWord2) ?? -10.0;
    if (logProb < absoluteLogProbFloor) return null;
  }

  return winner;
}
