// Pure-logic JS port of a bigram KenLM scorer for the prediction-sim.
// This is a PROXY — not the real KenLM C library. It uses a pre-computed
// bigram-count table (fixtures/bigram-corpus.json) to compute log10
// probabilities for testing the fusion logic.
//
// Real KenLM (TrigramProvider) uses a compiled .klm binary model with full
// backoff and smoothing. This proxy matches the API surface:
//   scorer(candidate, previousWord, previousWord2) => log10 probability or -10

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CORPUS_PATH = resolve(__dirname, '../fixtures/bigram-corpus.json');

/** @type {{ unigrams: Record<string,number>, bigrams: Record<string,number> } | null} */
let _corpus = null;
/** @type {number | null} */
let _vocabSize = null;

function loadCorpus() {
  if (_corpus) return _corpus;
  const raw = readFileSync(CORPUS_PATH, 'utf8');
  _corpus = JSON.parse(raw);
  _vocabSize = Object.keys(_corpus.unigrams).length;
  return _corpus;
}

/**
 * Computes log10 P(candidate | previousWord) from the bigram-corpus fixture.
 * Uses add-k smoothing: (count(bigram) + 1) / (count(unigram) + V)
 * where V is the number of unique words in the unigram table.
 *
 * @param {string} candidate  The candidate word
 * @param {string|null|undefined} previousWord  The preceding word context
 * @param {string|null|undefined} _previousWord2  Ignored (bigram model)
 * @returns {number} log10 probability (always ≤ 0)
 */
export function bigramKenlmScorer(candidate, previousWord, _previousWord2) {
  if (!candidate || !previousWord) return -10.0;

  const corpus = loadCorpus();
  const prev = previousWord.toLowerCase();
  const cand = candidate.toLowerCase();

  const unigramCount = corpus.unigrams[prev] ?? 0;
  const bigramKey = `${prev} ${cand}`;
  const bigramCount = corpus.bigrams[bigramKey] ?? 0;

  // Add-k smoothing: (c + 1) / (u + V)
  const smoothedProb = (bigramCount + 1) / (unigramCount + _vocabSize);

  if (smoothedProb <= 0) return -10.0;
  return Math.log10(smoothedProb);
}
