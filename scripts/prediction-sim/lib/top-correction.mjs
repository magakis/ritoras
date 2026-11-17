// Pure-logic JS port of PredictionEngine.topCorrection().
// Kept in sync per AGENTS.md -> Test policy.

import { fusedPool } from './fused-pool.mjs';
import { fusionIsActive } from './fusion-is-active.mjs';
import { normalizeForKenLM } from './kenlm-normalize.mjs';

/**
 * Classifies the top-correction gate and retains its winner and operands.
 * Mirrors `PredictionEngine.topCorrectionOutcome(...)`.
 *
 * @param {object} opts
 * @param {Array<{text:string,score:number,source:string}>} opts.pool - Pre-built suggestion pool.
 * @param {string} opts.currentWord - The word currently being typed.
 * @param {string} [opts.lookupWord=opts.currentWord] - The dictionary lookup word.
 * @param {string|null|undefined} opts.previousWord - Previous word for KenLM context.
 * @param {string|null|undefined} opts.previousWord2 - Word before previous for KenLM context.
 * @param {function|null} opts.kenlmScorer - (candidate, prev, prev2) => log10 probability or null.
 * @param {boolean} opts.trigramReady - Whether trigram/KenLM provider is ready.
 * @param {number} [opts.blendWeight=0.5] - KenLM blend weight.
 * @param {number} [opts.absoluteLogProbFloor=-8] - Absolute KenLM log-prob floor.
 * @param {'absolute'|'off'|'oovAware'|'contextAdjusted'|'typedLiteralMargin'}
 *   [opts.floorPolicy='typedLiteralMargin'] Floor policy; the default conditionally
 *   rescues sub-floor winners whose raw score clears the typed-literal margin.
 * @param {function} [opts.isBuiltInWord] - Built-in dictionary membership for
 *   context tokens. Required by OOV-aware policies.
 * @param {number} [opts.oovRelaxedLogProbFloor] - Floor used by `oovAware`.
 * @param {number} [opts.contextFloorRelaxationLog10] - Maximum floor relaxation
 *   for a fully OOV context, scaled by the OOV-token fraction.
 * @param {number} [opts.typedLiteralLogProbMargin=2.0] - Minimum winner advantage
 *   over the typed literal for `typedLiteralMargin`.
 * @param {number} [opts.ambiguousContractionMargin=1.0] - Minimum KenLM log-prob
 *   advantage the contraction must hold over the typed literal to auto-flip.
 * @returns {{cause:string,candidate:object|null,rawLMLogProb:number|null,
 *   typedLiteralRawLMLogProb?:number,typedLiteralLogProbMargin?:number,
 *   absoluteLogProbFloor?:number}}
 */
export function topCorrectionOutcome({
  pool,
  currentWord,
  lookupWord = currentWord,
  previousWord,
  previousWord2,
  kenlmScorer,
  trigramReady,
  blendWeight = 0.5,
  absoluteLogProbFloor = -8.0,
  floorPolicy = 'typedLiteralMargin',
  isBuiltInWord,
  oovRelaxedLogProbFloor,
  contextFloorRelaxationLog10,
  typedLiteralLogProbMargin = 2.0,
  ambiguousContractionMargin = 1.0,
}) {
  if (currentWord.length === 0 || lookupWord.length === 0) {
    return { cause: 'emptyInput', candidate: null, rawLMLogProb: null };
  }
  validateFloorPolicyOptions({
    floorPolicy,
    absoluteLogProbFloor,
    isBuiltInWord,
    oovRelaxedLogProbFloor,
    contextFloorRelaxationLog10,
    typedLiteralLogProbMargin,
  });

  const fused = fusedPool({
    pool,
    currentWord,
    previousWord,
    previousWord2,
    kenlmScorer,
    blendWeight,
  });
  const lowerTyped = currentWord.toLowerCase();

  // KenLM's vocabulary is ASCII-only: normalize the candidate and the context
  // words to U+0027 before scoring (mirrors TrigramProvider.rawLogProb).
  const prev = previousWord ? normalizeForKenLM(previousWord) : previousWord;
  const prev2 = previousWord2 ? normalizeForKenLM(previousWord2) : previousWord2;

  // Exclude .trigram source and the typed word itself.
  const candidates = fused.filter(
    s => s.source !== 'trigram' && s.text.toLowerCase() !== lowerTyped
  );
  if (candidates.length === 0) {
    return { cause: 'poolEmptyAfterFilters', candidate: null, rawLMLogProb: null };
  }

  const winner = candidates.reduce((best, s) => s.score > best.score ? s : best);
  let rawLMLogProb = null;

  // The selected policy preserves the absolute floor and evaluates the literal
  // margin only for a sub-floor winner.
  if (fusionIsActive({ previousWord, trigramReady }) && kenlmScorer) {
    const logProb = kenlmScorer(
      normalizeForKenLM(winner.text),
      prev,
      prev2
    ) ?? -10.0;
    rawLMLogProb = logProb;
    const floorRejection = floorPolicyRejection({
      floorPolicy,
      logProb,
      currentWord,
      previousWord,
      previousWord2,
      kenlmScorer,
      absoluteLogProbFloor,
      isBuiltInWord,
      oovRelaxedLogProbFloor,
      contextFloorRelaxationLog10,
      typedLiteralLogProbMargin,
      prev,
      prev2,
    });
    if (floorRejection !== null) {
      return {
        cause: 'languageModelFloor',
        candidate: winner,
        rawLMLogProb: logProb,
        ...floorRejection,
      };
    }
  }

  // Ambiguous-contraction margin gate: never auto-flip a real dictionary word
  // ("its", "cant", "id") to its contraction form without LM context, and only
  // when KenLM clearly favors the contraction over the typed literal.
  if (winner.source === 'ambiguousContraction') {
    if (!fusionIsActive({ previousWord, trigramReady }) || !kenlmScorer) {
      return { cause: 'contractionMargin', candidate: winner, rawLMLogProb: null };
    }
    const contractionLogProb = kenlmScorer(
      normalizeForKenLM(winner.text),
      prev,
      prev2
    ) ?? -10.0;
    const typedLiteralLogProb = kenlmScorer(
      normalizeForKenLM(currentWord),
      prev,
      prev2
    ) ?? -10.0;
    rawLMLogProb = contractionLogProb;
    if (contractionLogProb - typedLiteralLogProb < ambiguousContractionMargin) {
      return {
        cause: 'contractionMargin',
        candidate: winner,
        rawLMLogProb: contractionLogProb,
      };
    }
  }

  return { cause: 'candidate', candidate: winner, rawLMLogProb };
}

const FLOOR_POLICIES = new Set([
  'absolute',
  'off',
  'oovAware',
  'contextAdjusted',
  'typedLiteralMargin',
]);

function validateFloorPolicyOptions({
  floorPolicy,
  absoluteLogProbFloor,
  isBuiltInWord,
  oovRelaxedLogProbFloor,
  contextFloorRelaxationLog10,
  typedLiteralLogProbMargin,
}) {
  if (!FLOOR_POLICIES.has(floorPolicy)) {
    throw new RangeError(`Unknown floor policy: ${floorPolicy}`);
  }
  if (floorPolicy === 'oovAware') {
    if (typeof isBuiltInWord !== 'function') {
      throw new TypeError('oovAware floor policy requires isBuiltInWord');
    }
    if (
      !Number.isFinite(oovRelaxedLogProbFloor)
      || oovRelaxedLogProbFloor > absoluteLogProbFloor
    ) {
      throw new RangeError(
        'oovRelaxedLogProbFloor must be finite and no stricter than the absolute floor',
      );
    }
  }
  if (floorPolicy === 'contextAdjusted') {
    if (typeof isBuiltInWord !== 'function') {
      throw new TypeError('contextAdjusted floor policy requires isBuiltInWord');
    }
    if (!Number.isFinite(contextFloorRelaxationLog10) || contextFloorRelaxationLog10 < 0) {
      throw new RangeError('contextFloorRelaxationLog10 must be finite and non-negative');
    }
  }
  if (
    floorPolicy === 'typedLiteralMargin'
    && (!Number.isFinite(typedLiteralLogProbMargin) || typedLiteralLogProbMargin < 0)
  ) {
    throw new RangeError('typedLiteralLogProbMargin must be finite and non-negative');
  }
}

function floorPolicyRejection({
  floorPolicy,
  logProb,
  currentWord,
  previousWord,
  previousWord2,
  kenlmScorer,
  absoluteLogProbFloor,
  isBuiltInWord,
  oovRelaxedLogProbFloor,
  contextFloorRelaxationLog10,
  typedLiteralLogProbMargin,
  prev,
  prev2,
}) {
  if (floorPolicy === 'off') {
    return null;
  }
  if (floorPolicy === 'absolute') {
    return logProb < absoluteLogProbFloor ? {} : null;
  }
  if (!(logProb < absoluteLogProbFloor)) {
    return null;
  }
  if (floorPolicy === 'oovAware') {
    const { oovTokenCount } = countOovContextTokens({
      previousWord,
      previousWord2,
      isBuiltInWord,
    });
    const effectiveFloor = oovTokenCount > 0
      ? oovRelaxedLogProbFloor
      : absoluteLogProbFloor;
    return logProb < effectiveFloor ? {} : null;
  }
  if (floorPolicy === 'contextAdjusted') {
    const { oovTokenCount, contextTokenCount } = countOovContextTokens({
      previousWord,
      previousWord2,
      isBuiltInWord,
    });
    const oovFraction = contextTokenCount > 0 ? oovTokenCount / contextTokenCount : 0;
    const effectiveFloor = absoluteLogProbFloor
      - contextFloorRelaxationLog10 * oovFraction;
    return logProb < effectiveFloor ? {} : null;
  }
  if (floorPolicy === 'typedLiteralMargin') {
    // Keep the old floor's accepted set; only a sub-floor winner can be rescued.
    const typedLiteralRawLMLogProb = kenlmScorer(
      normalizeForKenLM(currentWord),
      prev,
      prev2,
    ) ?? -10.0;
    if (logProb - typedLiteralRawLMLogProb < typedLiteralLogProbMargin) {
      return {
        typedLiteralRawLMLogProb,
        typedLiteralLogProbMargin,
        absoluteLogProbFloor,
      };
    }
    return null;
  }
  return null;
}

function countOovContextTokens({ previousWord, previousWord2, isBuiltInWord }) {
  const contextTokens = [previousWord2, previousWord]
    .filter(token => typeof token === 'string' && token.length > 0);
  const oovTokenCount = contextTokens.filter(token => !isBuiltInWord(token)).length;
  return { oovTokenCount, contextTokenCount: contextTokens.length };
}

/**
 * Returns the highest-scoring correction candidate when no selection gate
 * rejects it. Existing simulation callers keep the same candidate-or-null API.
 */
export function topCorrection(opts) {
  const outcome = topCorrectionOutcome(opts);
  return outcome.cause === 'candidate' ? outcome.candidate : null;
}
