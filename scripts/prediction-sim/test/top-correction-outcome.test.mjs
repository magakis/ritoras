import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { topCorrectionOutcome } from '../lib/top-correction.mjs';

describe('topCorrectionOutcome', () => {
  function incidentOutcome(overrides = {}) {
    return topCorrectionOutcome({
      pool: [{ text: 'current', score: 1, source: 'symspell' }],
      currentWord: 'currebt',
      previousWord: 'the', // The keyboard already applied thw → the.
      previousWord2: 'was',
      kenlmScorer: word => (word === 'current' ? -8.125 : -9.814),
      trigramReady: true,
      ...overrides,
    });
  }

  it('accepts the device incident only after subtracting its context score', () => {
    const old = incidentOutcome();
    assert.equal(old.cause, 'languageModelFloor');
    assert.equal(old.conditionalLMLogProb, old.rawLMLogProb);
    assert.equal(old.typedLiteralRawLMLogProb, -9.814);
    assert.deepEqual(incidentOutcome({ contextScorer: () => null }), old);

    const corrected = incidentOutcome({
      contextScorer: (prev, prev2) => {
        assert.deepEqual([prev2, prev], ['was', 'the']);
        return -2;
      },
    });
    assert.equal(corrected.cause, 'candidate');
    assert.equal(corrected.candidate.text, 'current');
    assert.equal(corrected.rawLMLogProb, -8.125);
    assert.equal(corrected.conditionalLMLogProb, -6.125);
  });

  it('keeps the rescue conditional and preserves old accepts with a one-word context', () => {
    for (const [joint, typed, expected, literalCalls] of [
      [-9, -10.75, 'languageModelFloor', 1],
      [-9, -11, 'candidate', 1],
      [-8, -8, 'candidate', 0],
      [-7, -6, 'candidate', 0],
    ]) {
      let calls = 0;
      const outcome = incidentOutcome({
        previousWord2: undefined,
        contextScorer: (prev, prev2) => {
          assert.deepEqual([prev, prev2], ['the', undefined]);
          return -0.5;
        },
        kenlmScorer: word => {
          if (word === 'current') return joint;
          calls++;
          return typed;
        },
      });
      assert.equal(outcome.cause, expected);
      assert.equal(outcome.conditionalLMLogProb, joint + 0.5);
      assert.equal(calls, literalCalls);
      assert.equal(incidentOutcome({
        kenlmScorer: word => (word === 'current' ? joint : typed),
      }).cause, expected);
    }
  });

  it('does not evaluate a floor without a preceding word or subtract from a missing score', () => {
    const contextScorer = () => assert.fail('context score should not be requested');
    const noContext = incidentOutcome({ previousWord: null, contextScorer });
    assert.equal(noContext.cause, 'candidate');
    assert.equal(noContext.conditionalLMLogProb, undefined);
    const noJoint = incidentOutcome({ kenlmScorer: () => null, contextScorer });
    assert.equal(noJoint.cause, 'languageModelFloor');
    assert.equal(noJoint.conditionalLMLogProb, -10);
  });

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
