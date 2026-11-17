import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  CALIBRATION_SENSITIVITY_VALUES,
  createOovContextStratum,
  FLOOR_POLICY_CANDIDATES,
  selectFloorPolicyWinner,
} from '../lib/floor-policy-sweep.mjs';

const oovFixture = JSON.parse(
  readFileSync(new URL('../fixtures/autocorrect-oov-contexts.json', import.meta.url), 'utf8'),
);

function makeRun(penalty, overrides = {}) {
  return {
    penalty,
    precision: 0.95,
    recall: 0.5,
    fpr: 0.02,
    oovCorrect: 6,
    oovTotal: 10,
    tier0Correct: 1,
    tier0Total: 1,
    corpusOutcomeDelta: 1,
    ...overrides,
  };
}

function makePolicyResult(
  id,
  calibrationValues,
  runOverrides = {},
  { shape = id, floorPolicy, parameters = {} } = {},
) {
  return {
    id,
    label: id,
    shape,
    floorPolicy,
    parameters,
    calibrationRuns: calibrationValues.map(penalty => makeRun(
      penalty,
      typeof runOverrides === 'function' ? runOverrides(penalty) : runOverrides,
    )),
  };
}

describe('floor-policy sweep candidates and strata', () => {
  it('registers the five planned shapes without silently dropping a candidate family', () => {
    const shapes = new Set(FLOOR_POLICY_CANDIDATES.map(candidate => candidate.shape));
    assert.deepStrictEqual([...shapes].sort(), [
      'absolute-floor-baseline',
      'context-adjusted-floor',
      'floor-off',
      'oov-aware-relaxation',
      'typed-literal-margin',
    ]);
  });

  it('sweeps the full 4.4–5.5 calibration range at tenth-point intervals', () => {
    assert.strictEqual(CALIBRATION_SENSITIVITY_VALUES[0], 4.4);
    assert.strictEqual(CALIBRATION_SENSITIVITY_VALUES.at(-1), 5.5);
    assert.deepStrictEqual(
      CALIBRATION_SENSITIVITY_VALUES,
      Array.from({ length: 12 }, (_, index) => Number((4.4 + index / 10).toFixed(1))),
    );
  });

  it('generates corpus variants only when built-in membership identifies OOV context', () => {
    const typoPools = [{
      entry: { typedWord: 'wiyh', intendedWord: 'with' },
      pool: [{ text: 'with', score: 0.9, source: 'symspell' }],
    }];
    const builtInWords = new Set(['so', 'it’s']);
    const stratum = createOovContextStratum(
      typoPools,
      word => builtInWords.has(word.toLowerCase()),
      oovFixture.cases,
    );

    assert.deepStrictEqual(
      stratum.map(({ contextClass }) => contextClass),
      ['currency', 'number', 'symbol', 'curly-apostrophe-and-number'],
    );
    assert.ok(stratum.every(entry => entry.oovTokenCount > 0));
    assert.ok(stratum.every(entry => entry.oovTokenCount === 1));
    assert.strictEqual(stratum[0].entry.previousWord, 'so');
    assert.strictEqual(stratum[0].entry.previousWord2, '€50');
    assert.strictEqual(stratum[3].entry.previousWord2, 'It’s');
    assert.throws(
      () => createOovContextStratum(typoPools, null, oovFixture.cases),
      /membership/,
    );
  });
});

describe('pre-registered floor-policy selection', () => {
  const calibrationValues = [4.4, 4.5, 5.5];

  it('requires every sensitivity point, minimizes outcome delta, then breaks ties by OOV recall', () => {
    const baseline = makePolicyResult('baseline', calibrationValues, {
      tier0Correct: 0,
    });
    const results = [
      baseline,
      makePolicyResult('small-delta-low-oov', calibrationValues, {
        corpusOutcomeDelta: 1,
        oovCorrect: 6,
      }),
      makePolicyResult('large-delta-high-oov', calibrationValues, {
        corpusOutcomeDelta: 2,
        oovCorrect: 10,
      }),
      makePolicyResult('small-delta-high-oov', calibrationValues, {
        corpusOutcomeDelta: 1,
        oovCorrect: 8,
      }),
      makePolicyResult('misses-tier0', calibrationValues, {
        tier0Correct: 0,
      }),
      makePolicyResult('fails-one-point', calibrationValues, penalty => (
        penalty === 5.5
          ? { fpr: 0.03 }
          : { corpusOutcomeDelta: 0 }
      )),
    ];

    const selection = selectFloorPolicyWinner({
      policyResults: results,
      baselineId: 'baseline',
      calibrationValues,
    });

    assert.strictEqual(selection.baseline.id, 'baseline');
    assert.deepStrictEqual(
      selection.qualifiers.map(result => result.id),
      ['small-delta-high-oov', 'small-delta-low-oov'],
    );
    assert.strictEqual(selection.winner.id, 'small-delta-high-oov');
    assert.strictEqual(selection.winner.meanCorpusOutcomeDelta, 1);
    assert.strictEqual(selection.winner.oovRecall, 0.8);
    assert.strictEqual(
      selection.reports.find(result => result.id === 'fails-one-point').robust,
      false,
    );
    assert.strictEqual(
      selection.reports.find(result => result.id === 'misses-tier0').robust,
      false,
    );
  });

  it('resolves full delta-and-recall ties by retaining the guard and choosing the largest margin', () => {
    const baseline = makePolicyResult('baseline', calibrationValues, {
      tier0Correct: 0,
    });
    const tiedRuns = {
      corpusOutcomeDelta: 0,
      oovCorrect: 3,
    };
    const results = [
      baseline,
      makePolicyResult('floor-off', calibrationValues, tiedRuns, {
        shape: 'floor-off',
        floorPolicy: 'off',
      }),
      ...[0.5, 1.0, 2.0].map(margin => makePolicyResult(
        `typed-literal-margin-${margin.toFixed(1)}`,
        calibrationValues,
        tiedRuns,
        {
          shape: 'typed-literal-margin',
          floorPolicy: 'typedLiteralMargin',
          parameters: { typedLiteralLogProbMargin: margin },
        },
      )),
    ];

    const selection = selectFloorPolicyWinner({
      policyResults: results,
      baselineId: 'baseline',
      calibrationValues,
    });

    assert.deepStrictEqual(
      selection.qualifiers.map(result => result.id),
      [
        'floor-off',
        'typed-literal-margin-0.5',
        'typed-literal-margin-1.0',
        'typed-literal-margin-2.0',
      ],
    );
    assert.strictEqual(selection.winner.id, 'typed-literal-margin-2.0');
    assert.deepStrictEqual(
      selection.tieBreakSteps.map(({ rule }) => rule),
      ['retain-rejection-guard', 'largest-typed-literal-margin'],
    );
    assert.deepStrictEqual(selection.tieBreakSteps[0], {
      rule: 'retain-rejection-guard',
      selectedIds: [
        'typed-literal-margin-0.5',
        'typed-literal-margin-1.0',
        'typed-literal-margin-2.0',
      ],
      excludedIds: ['floor-off'],
    });
    assert.deepStrictEqual(selection.tieBreakSteps[1], {
      rule: 'largest-typed-literal-margin',
      margin: 2,
      selectedIds: ['typed-literal-margin-2.0'],
      excludedIds: ['typed-literal-margin-0.5', 'typed-literal-margin-1.0'],
    });
  });

  it('returns an explicit empty qualifier set when no candidate meets every rule', () => {
    const baseline = makePolicyResult('baseline', calibrationValues, {
      tier0Correct: 0,
    });
    const candidate = makePolicyResult('not-qualified', calibrationValues, {
      precision: 0.94,
    });
    const selection = selectFloorPolicyWinner({
      policyResults: [baseline, candidate],
      baselineId: 'baseline',
      calibrationValues,
    });

    assert.deepStrictEqual(selection.qualifiers, []);
    assert.strictEqual(selection.winner, null);
    assert.deepStrictEqual(
      selection.reports.find(result => result.id === 'not-qualified').failuresByPenalty,
      calibrationValues.map(penalty => ({
        penalty,
        failures: ['precision below baseline'],
      })),
    );
  });
});
