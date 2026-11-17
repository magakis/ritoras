import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluate, selectConfidenceThreshold } from '../lib/autocorrect-controller.mjs';
import {
  bigramKenlmScorer,
  createBigramKenlmScorer,
  OOV_CONTEXT_CALIBRATION,
} from '../lib/bigram-kenlm-proxy.mjs';
import { normalizeForKenLM } from '../lib/kenlm-normalize.mjs';
import { topCorrection, topCorrectionOutcome } from '../lib/top-correction.mjs';

const fixture = JSON.parse(
  readFileSync(new URL('../fixtures/autocorrect-oov-contexts.json', import.meta.url), 'utf8'),
);

function getContext(testCase) {
  return {
    previousWord: testCase.previousWords.at(-1) ?? null,
    previousWord2: testCase.previousWords.at(-2) ?? null,
  };
}

describe('bigram KenLM proxy calibration', () => {
  it('keeps the anchor and sensitivity range explicit in the fixture', () => {
    assert.strictEqual(
      fixture.calibration.anchorPenaltyLog10,
      OOV_CONTEXT_CALIBRATION.anchorPenaltyLog10,
    );
    assert.deepStrictEqual(
      fixture.calibration.sensitivityRangeLog10,
      [...OOV_CONTEXT_CALIBRATION.sensitivityRangeLog10],
    );
    assert.strictEqual(fixture.calibration.floorLog10, -8.0);
  });

  it('provides the Tier-0 incident and two-word OOV/symbol/number/apostrophe cases', () => {
    const incident = fixture.cases.find(testCase => testCase.tier === 0);
    assert.ok(incident);
    assert.strictEqual(incident.id, 'tier-0-wiyh-eur50-so');
    assert.strictEqual(incident.typedWord, 'wiyh');
    assert.strictEqual(incident.intendedWord, 'with');
    assert.deepStrictEqual(incident.previousWords, ['€50', 'so']);
    assert.strictEqual(incident.deviceObservedScores.with, 1.0);
    assert.strictEqual(incident.deviceObservedScores.wish, 0.6277);
    assert.strictEqual(incident.deviceObservedScores.wiyh, 0.5);

    const contextClasses = new Set(fixture.cases.map(testCase => testCase.contextClass));
    for (const contextClass of [
      'currency',
      'number',
      'symbol',
      'curly-apostrophe-and-number',
      'curly-apostrophe',
    ]) {
      assert.ok(contextClasses.has(contextClass), `missing ${contextClass} context fixture`);
    }

    const curlyApostrophe = fixture.cases.find(testCase => testCase.id === 'curly-apostrophe-in-vocabulary');
    assert.strictEqual(
      normalizeForKenLM(curlyApostrophe.previousWords[0].toLowerCase()),
      curlyApostrophe.expectedKenlmPreviousWord2,
    );
  });

  it('pushes OOV-context winner scores below -8 across the calibration range', () => {
    const incident = fixture.cases.find(testCase => testCase.tier === 0);
    const { previousWord, previousWord2 } = getContext(incident);
    const [minimumPenalty, maximumPenalty] = OOV_CONTEXT_CALIBRATION.sensitivityRangeLog10;

    for (const penalty of [minimumPenalty, OOV_CONTEXT_CALIBRATION.anchorPenaltyLog10, maximumPenalty]) {
      const scorer = createBigramKenlmScorer(penalty);
      assert.ok(
        scorer('with', previousWord, previousWord2) < fixture.calibration.floorLog10,
        `penalty ${penalty} must reproduce the sub-floor incident score`,
      );
    }
  });

  it('leaves in-vocabulary context scores on the original bigram scale', () => {
    const inVocabulary = fixture.cases.find(testCase => testCase.id === 'curly-apostrophe-in-vocabulary');
    const { previousWord, previousWord2 } = getContext(inVocabulary);
    const calibrated = createBigramKenlmScorer(
      OOV_CONTEXT_CALIBRATION.sensitivityRangeLog10[1],
    );

    assert.strictEqual(
      calibrated('with', previousWord, previousWord2),
      bigramKenlmScorer('with', previousWord, null),
    );
    assert.ok(bigramKenlmScorer('with', 'so', null) > fixture.calibration.floorLog10);
  });

  it('rescues the Tier-0 incident through the conditional margin policy', () => {
    const incident = fixture.cases.find(testCase => testCase.tier === 0);
    const { previousWord, previousWord2 } = getContext(incident);
    const pool = [
      { text: incident.typedWord, score: 1.0, source: 'symspell' },
      { text: 'with', score: Math.exp(-0.5), source: 'symspell' },
      ...incident.appleGuesses.map(text => ({ text, score: 0.85, source: 'apple' })),
    ];
    const scorer = createBigramKenlmScorer();
    const common = {
      pool,
      currentWord: incident.typedWord,
      previousWord,
      previousWord2,
      kenlmScorer: scorer,
      trigramReady: true,
    };

    const baselineOutcome = topCorrectionOutcome({
      ...common,
      floorPolicy: 'absolute',
    });
    assert.strictEqual(baselineOutcome.cause, 'languageModelFloor');

    const rescuedOutcome = topCorrectionOutcome({
      ...common,
      absoluteLogProbFloor: fixture.calibration.floorLog10,
    });
    assert.strictEqual(rescuedOutcome.cause, 'candidate');
    assert.strictEqual(rescuedOutcome.candidate.text, incident.intendedWord);
    assert.strictEqual(rescuedOutcome.candidate.score, 1.0);
    assert.strictEqual(
      rescuedOutcome.rawLMLogProb,
      scorer(incident.intendedWord, previousWord, previousWord2),
    );
    assert.ok(rescuedOutcome.rawLMLogProb < fixture.calibration.floorLog10);
    const typedLiteralRawLMLogProb = scorer(incident.typedWord, previousWord, previousWord2);
    assert.ok(
      rescuedOutcome.rawLMLogProb - typedLiteralRawLMLogProb >= 2.0,
      'the incident winner clears the selected 2.0-log-prob margin',
    );

    const rescuedCorrection = topCorrection({
      ...common,
      absoluteLogProbFloor: fixture.calibration.floorLog10,
    });
    assert.ok(rescuedCorrection);
    assert.strictEqual(rescuedCorrection.text, incident.intendedWord);
    assert.ok(rescuedCorrection.score >= selectConfidenceThreshold({
      previousWord,
      trigramReady: true,
    }));

    const controllerDecision = evaluate({
      typedWord: incident.typedWord,
      origin: 'typing',
      topCorrection: rescuedCorrection,
      isLearned: false,
      isMisspelled: true,
      previousWord,
      trigramReady: true,
    });
    assert.strictEqual(controllerDecision.decision, 'correct');
  });
});
