import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { topCorrectionOutcome } from '../lib/top-correction.mjs';

describe('topCorrectionOutcome', () => {
  it('classifies empty input before consulting the candidate pool', () => {
    const outcome = topCorrectionOutcome({
      pool: [],
      currentWord: '',
      lookupWord: '',
      previousWord: null,
      previousWord2: null,
      kenlmScorer: null,
      trigramReady: false,
    });

    assert.deepStrictEqual(outcome, {
      cause: 'emptyInput',
      candidate: null,
      rawLMLogProb: null,
    });
  });

  it('distinguishes a pool emptied by literal and trigram exclusions', () => {
    const outcome = topCorrectionOutcome({
      pool: [
        { text: 'typed', score: 1, source: 'symspell' },
        { text: 'next', score: 0.9, source: 'trigram' },
      ],
      currentWord: 'typed',
      previousWord: null,
      previousWord2: null,
      kenlmScorer: null,
      trigramReady: false,
    });

    assert.deepStrictEqual(outcome, {
      cause: 'poolEmptyAfterFilters',
      candidate: null,
      rawLMLogProb: null,
    });
  });

  it('records every operand when a sub-floor winner fails the margin rescue', () => {
    const outcome = topCorrectionOutcome({
      pool: [
        { text: 'wiyh', score: 1, source: 'symspell' },
        { text: 'with', score: 1, source: 'symspell' },
        { text: 'wrong', score: 0, source: 'symspell' },
      ],
      currentWord: 'wiyh',
      previousWord: 'so',
      previousWord2: '€50',
      kenlmScorer: candidate => (candidate === 'with' ? -9.25 : -10),
      trigramReady: true,
      blendWeight: 0.5,
      absoluteLogProbFloor: -8,
    });

    assert.strictEqual(outcome.cause, 'languageModelFloor');
    assert.deepStrictEqual(outcome.candidate, {
      text: 'with',
      score: 1,
      source: 'symspell',
    });
    assert.strictEqual(outcome.rawLMLogProb, -9.25);
    assert.strictEqual(outcome.typedLiteralRawLMLogProb, -10);
    assert.strictEqual(outcome.typedLiteralLogProbMargin, 2);
    assert.strictEqual(outcome.absoluteLogProbFloor, -8);
    assert.ok(outcome.rawLMLogProb < outcome.absoluteLogProbFloor);
    assert.ok(
      outcome.rawLMLogProb - outcome.typedLiteralRawLMLogProb
        < outcome.typedLiteralLogProbMargin,
    );
  });

  it('classifies an ambiguous contraction rejected by the LM margin', () => {
    const outcome = topCorrectionOutcome({
      pool: [
        { text: 'its', score: 1, source: 'symspell' },
        { text: 'it’s', score: 0.5, source: 'ambiguousContraction' },
      ],
      currentWord: 'its',
      previousWord: 'dog',
      previousWord2: null,
      kenlmScorer: candidate => (candidate === "it's" ? -2 : -2.5),
      trigramReady: true,
      ambiguousContractionMargin: 1,
    });

    assert.strictEqual(outcome.cause, 'contractionMargin');
    assert.strictEqual(outcome.candidate.text, 'it’s');
    assert.strictEqual(outcome.rawLMLogProb, -2);
  });
});
