// Pure-logic JS port of a bigram KenLM scorer for the prediction-sim.
// This is a PROXY — not the real KenLM C library. It uses a pre-computed
// bigram-count table (fixtures/bigram-corpus.json) to compute log10
// probabilities for testing the fusion logic.
//
// Real KenLM (TrigramProvider) uses a compiled .klm binary model with full
// backoff and smoothing. This proxy matches the API surface:
//   scorer(candidate, previousWord, previousWord2) => log10 probability or -10
//
// Calibration is anchored to the device trace, which proves only that the
// incident winner scored below the -8.0 floor (not its exact raw value). For
// an OOV context, the default 4.5-decade penalty moves the weakest old smoothed
// score (1/V ≈ -3.70) below the floor. The 4.4–5.5 sensitivity range keeps the
// sub-floor result robust without claiming an exact KenLM measurement.

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizeForKenLM } from './kenlm-normalize.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CORPUS_PATH = resolve(__dirname, '../fixtures/bigram-corpus.json');

export const OOV_CONTEXT_CALIBRATION = Object.freeze({
  anchorPenaltyLog10: 4.5,
  sensitivityRangeLog10: Object.freeze([4.4, 5.5]),
});

/** @type {{ unigrams: Record<string,number>, bigrams: Record<string,number> } | null} */
let _corpus = null;
/** @type {number | null} */
let _vocabSize = null;
/** @type {number | null} */
let _maxUnigramCount = null;

function loadCorpus() {
  if (_corpus) return _corpus;
  const raw = readFileSync(CORPUS_PATH, 'utf8');
  _corpus = JSON.parse(raw);
  _vocabSize = Object.keys(_corpus.unigrams).length;
  _maxUnigramCount = Object.values(_corpus.unigrams)
    .reduce((maximum, count) => Math.max(maximum, count), 0);
  return _corpus;
}

/**
 * Creates a bigram proxy with an explicit OOV-context calibration value.
 *
 * For in-vocabulary contexts, the existing add-one bigram score is unchanged.
 * When either context token is OOV, a unigram rank prior preserves candidate
 * ordering and the calibrated penalty models the device-observed floor collapse.
 * This is intentionally conservative: the downward adjustment can suppress
 * corrections, but cannot make an OOV-context correction more likely.
 *
 * @param {number} oovContextPenaltyLog10 - Positive log10 decades subtracted
 *   from scores in OOV contexts.
 * @returns {(candidate: string, previousWord: string|null|undefined,
 *   previousWord2?: string|null) => number}
 */
export function createBigramKenlmScorer(
  oovContextPenaltyLog10 = OOV_CONTEXT_CALIBRATION.anchorPenaltyLog10,
) {
  if (!Number.isFinite(oovContextPenaltyLog10) || oovContextPenaltyLog10 < 0) {
    throw new RangeError('OOV context penalty must be a finite non-negative number');
  }

  return function scoreBigramKenlm(candidate, previousWord, previousWord2) {
    return scoreWithBigramCorpus(
      candidate,
      previousWord,
      previousWord2,
      oovContextPenaltyLog10,
    );
  };
}

/**
 * Computes the calibrated log10 proxy score from the bigram-corpus fixture.
 * The base score uses add-one smoothing:
 * (count(bigram) + 1) / (count(unigram) + V).
 *
 * @param {string} candidate  The candidate word
 * @param {string|null|undefined} previousWord  The preceding word context
 * @param {string|null|undefined} previousWord2  The word before previousWord
 * @param {number} oovContextPenaltyLog10  Calibration applied to OOV contexts
 * @returns {number} log10 probability (always ≤ 0)
 */
function scoreWithBigramCorpus(candidate, previousWord, previousWord2, oovContextPenaltyLog10) {
  if (!candidate || !previousWord) return -10.0;

  const corpus = loadCorpus();
  const prev = normalizeForKenLM(previousWord.toLowerCase());
  const prev2 = previousWord2
    ? normalizeForKenLM(previousWord2.toLowerCase())
    : null;
  const cand = normalizeForKenLM(candidate.toLowerCase());

  const unigramCount = corpus.unigrams[prev] ?? 0;
  const bigramKey = `${prev} ${cand}`;
  const bigramCount = corpus.bigrams[bigramKey] ?? 0;

  // Add-k smoothing: (c + 1) / (u + V)
  const smoothedProb = (bigramCount + 1) / (unigramCount + _vocabSize);

  if (smoothedProb <= 0) return -10.0;

  const logProb = Math.log10(smoothedProb);
  const contextTokens = [prev, prev2].filter(Boolean);
  const hasOovContext = contextTokens.some(token => !Object.hasOwn(corpus.unigrams, token));
  if (!hasOovContext) return logProb;

  const candidateCount = corpus.unigrams[cand] ?? 0;
  const unigramRankPrior = Math.log10((candidateCount + 1) / (_maxUnigramCount + 1));
  return logProb + unigramRankPrior - oovContextPenaltyLog10;
}

export const bigramKenlmScorer = createBigramKenlmScorer();
