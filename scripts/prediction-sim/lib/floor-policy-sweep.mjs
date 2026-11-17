import { OOV_CONTEXT_CALIBRATION } from './bigram-kenlm-proxy.mjs';

// Fixed Phase-3 knob grids: relaxed floors [-9, -10, -12], proportional
// relaxations [1, 2, 4] log10 decades, and typed-literal margins [0.5, 1, 2].
const OOV_RELAXED_FLOORS = [-9.0, -10.0, -12.0];
const CONTEXT_FLOOR_RELAXATIONS = [1.0, 2.0, 4.0];
const TYPED_LITERAL_MARGINS = [0.5, 1.0, 2.0];

function makeCalibrationSensitivityValues([minimum, maximum]) {
  const minimumTenth = Math.round(minimum * 10);
  const maximumTenth = Math.round(maximum * 10);
  return Array.from(
    { length: maximumTenth - minimumTenth + 1 },
    (_, index) => (minimumTenth + index) / 10,
  );
}

function freezeCandidate(candidate) {
  return Object.freeze({
    ...candidate,
    parameters: Object.freeze(candidate.parameters),
  });
}

export const CALIBRATION_SENSITIVITY_VALUES = Object.freeze(
  makeCalibrationSensitivityValues(OOV_CONTEXT_CALIBRATION.sensitivityRangeLog10),
);

export const FLOOR_POLICY_CANDIDATES = Object.freeze([
  freezeCandidate({
    id: 'absolute-floor-baseline',
    shape: 'absolute-floor-baseline',
    label: 'Absolute-floor baseline',
    floorPolicy: 'absolute',
    parameters: {},
  }),
  freezeCandidate({
    id: 'floor-off',
    shape: 'floor-off',
    label: 'Floor-off endpoint',
    floorPolicy: 'off',
    parameters: {},
  }),
  ...OOV_RELAXED_FLOORS.map(floor => freezeCandidate({
    id: `oov-aware-relaxation-minus-${Math.abs(floor).toFixed(1)}`,
    shape: 'oov-aware-relaxation',
    label: `OOV-aware relaxation (floor ${floor.toFixed(1)})`,
    floorPolicy: 'oovAware',
    parameters: { oovRelaxedLogProbFloor: floor },
  })),
  ...CONTEXT_FLOOR_RELAXATIONS.map(relaxation => freezeCandidate({
    id: `context-adjusted-floor-${relaxation.toFixed(1)}`,
    shape: 'context-adjusted-floor',
    label: `Context-adjusted floor (max relaxation ${relaxation.toFixed(1)})`,
    floorPolicy: 'contextAdjusted',
    parameters: { contextFloorRelaxationLog10: relaxation },
  })),
  ...TYPED_LITERAL_MARGINS.map(margin => freezeCandidate({
    id: `typed-literal-margin-${margin.toFixed(1)}`,
    shape: 'typed-literal-margin',
    label: `Typed-literal margin (${margin.toFixed(1)})`,
    floorPolicy: 'typedLiteralMargin',
    parameters: { typedLiteralLogProbMargin: margin },
  })),
]);

/**
 * Replays every typo against calibrated fixture contexts. Their OOV status is
 * rechecked with built-in dictionary membership, not the KenLM proxy vocabulary.
 */
export function createOovContextStratum(typoPools, isBuiltInWord, contextCases) {
  if (typeof isBuiltInWord !== 'function') {
    throw new TypeError('OOV context generation requires built-in word membership');
  }
  if (!Array.isArray(contextCases)) {
    throw new TypeError('OOV context generation requires context fixtures');
  }

  const templates = contextCases
    .filter(testCase => testCase.expectedContextOov)
    .map(testCase => ({
      contextClass: testCase.contextClass,
      previousWord2: testCase.previousWords.at(-2) ?? null,
      previousWord: testCase.previousWords.at(-1) ?? null,
    }));
  const stratum = [];
  for (const { entry, pool } of typoPools) {
    for (const template of templates) {
      const contextTokens = [template.previousWord2, template.previousWord]
        .filter(token => typeof token === 'string' && token.length > 0);
      const oovTokenCount = contextTokens.filter(token => !isBuiltInWord(token)).length;
      if (oovTokenCount === 0) continue;

      stratum.push({
        entry: {
          ...entry,
          previousWord: template.previousWord,
          previousWord2: template.previousWord2,
        },
        pool,
        contextClass: template.contextClass,
        oovTokenCount,
      });
    }
  }
  return stratum;
}

/**
 * Applies the pre-registered rule across every calibration point. Qualification
 * is pointwise; aggregate outcome delta is minimized only after robustness.
 */
export function selectFloorPolicyWinner({
  policyResults,
  baselineId,
  calibrationValues,
}) {
  const baseline = policyResults.find(result => result.id === baselineId);
  if (!baseline) throw new Error(`Missing baseline policy result: ${baselineId}`);

  const baselineRunsByPenalty = new Map(
    baseline.calibrationRuns.map(run => [run.penalty, run]),
  );
  if (baselineRunsByPenalty.size !== calibrationValues.length) {
    throw new Error('Baseline calibration results do not match the sensitivity grid');
  }

  const reports = policyResults.map(result => {
    if (result.calibrationRuns.length !== calibrationValues.length) {
      throw new Error(`Incomplete calibration results for ${result.id}`);
    }

    const failuresByPenalty = [];
    let outcomeDeltaTotal = 0;
    let oovCorrectTotal = 0;
    let oovTotal = 0;

    for (const [index, run] of result.calibrationRuns.entries()) {
      const expectedPenalty = calibrationValues[index];
      if (run.penalty !== expectedPenalty) {
        throw new Error(`Unexpected calibration value for ${result.id}: ${run.penalty}`);
      }
      const baselineRun = baselineRunsByPenalty.get(run.penalty);
      if (!baselineRun) {
        throw new Error(`Missing baseline calibration result for ${run.penalty}`);
      }

      const failures = [];
      if (run.precision < baselineRun.precision) {
        failures.push('precision below baseline');
      }
      if (run.fpr > baselineRun.fpr) {
        failures.push('legit FPR above baseline');
      }
      if (run.tier0Total <= 0 || run.tier0Correct !== run.tier0Total) {
        failures.push('not all Tier-0 fixtures corrected');
      }
      if (failures.length > 0) failuresByPenalty.push({ penalty: run.penalty, failures });

      outcomeDeltaTotal += run.corpusOutcomeDelta;
      oovCorrectTotal += run.oovCorrect;
      oovTotal += run.oovTotal;
    }

    return {
      id: result.id,
      label: result.label,
      shape: result.shape,
      floorPolicy: result.floorPolicy,
      parameters: result.parameters,
      robust: failuresByPenalty.length === 0,
      failuresByPenalty,
      meanCorpusOutcomeDelta: outcomeDeltaTotal / calibrationValues.length,
      totalCorpusOutcomeDelta: outcomeDeltaTotal,
      oovRecall: oovTotal > 0 ? oovCorrectTotal / oovTotal : 0,
      calibrationRuns: result.calibrationRuns,
    };
  });

  const robustCandidates = reports.filter(report => report.robust);
  if (robustCandidates.length === 0) {
    return {
      baselineId,
      baseline: reports.find(report => report.id === baselineId),
      qualifiers: [],
      tieBreakSteps: [],
      winner: null,
      reports,
    };
  }

  // Every candidate has the same number of calibration points, so minimizing
  // the integer total is exactly minimizing mean outcome delta without float ties.
  const minimumOutcomeDelta = Math.min(
    ...robustCandidates.map(report => report.totalCorpusOutcomeDelta),
  );
  const qualifiers = robustCandidates
    .filter(report => report.totalCorpusOutcomeDelta === minimumOutcomeDelta)
    .sort((left, right) => right.oovRecall - left.oovRecall);
  const tieBreakSteps = [];

  let finalists = qualifiers;
  const highestOovRecall = Math.max(...finalists.map(report => report.oovRecall));
  const highestRecallFinalists = finalists.filter(
    report => report.oovRecall === highestOovRecall,
  );
  if (highestRecallFinalists.length < finalists.length) {
    tieBreakSteps.push({
      rule: 'higher-oov-recall',
      selectedIds: highestRecallFinalists.map(report => report.id),
      excludedIds: finalists
        .filter(report => report.oovRecall !== highestOovRecall)
        .map(report => report.id),
    });
    finalists = highestRecallFinalists;
  }

  if (finalists.length > 1) {
    const guardRetainingFinalists = finalists.filter(
      report => report.floorPolicy !== 'off',
    );
    if (
      guardRetainingFinalists.length > 0
      && guardRetainingFinalists.length < finalists.length
    ) {
      tieBreakSteps.push({
        rule: 'retain-rejection-guard',
        selectedIds: guardRetainingFinalists.map(report => report.id),
        excludedIds: finalists
          .filter(report => report.floorPolicy === 'off')
          .map(report => report.id),
      });
      finalists = guardRetainingFinalists;
    }
  }

  if (
    finalists.length > 1
    && finalists.every(report => report.shape === 'typed-literal-margin')
  ) {
    const largestMargin = Math.max(
      ...finalists.map(report => report.parameters.typedLiteralLogProbMargin),
    );
    const mostConservativeFinalists = finalists.filter(
      report => report.parameters.typedLiteralLogProbMargin === largestMargin,
    );
    if (mostConservativeFinalists.length < finalists.length) {
      tieBreakSteps.push({
        rule: 'largest-typed-literal-margin',
        margin: largestMargin,
        selectedIds: mostConservativeFinalists.map(report => report.id),
        excludedIds: finalists
          .filter(report => report.parameters.typedLiteralLogProbMargin !== largestMargin)
          .map(report => report.id),
      });
      finalists = mostConservativeFinalists;
    }
  }

  return {
    baselineId,
    baseline: reports.find(report => report.id === baselineId),
    qualifiers,
    tieBreakSteps,
    winner: finalists[0] ?? null,
    reports,
  };
}
