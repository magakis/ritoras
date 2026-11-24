#!/usr/bin/env node

// Measures the pre-registered autocorrect floor-policy candidates at the
// device-mirrored operating point and selects only across robust qualifiers.

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SymSpell } from '../lib/symspell.mjs';
import { SymSpellProvider } from '../lib/symspell-provider.mjs';
import { expansion } from '../lib/contractions.mjs';
import { topCorrection } from '../lib/top-correction.mjs';
import { DEFAULT_CONFIG, selectConfidenceThreshold } from '../lib/autocorrect-controller.mjs';
import { createBigramKenlmScorer } from '../lib/bigram-kenlm-proxy.mjs';
import { SYMSPELL_MIN_WORD_FREQ } from '../lib/sym-spell-blob.mjs';
import {
  CALIBRATION_SENSITIVITY_VALUES,
  createOovContextStratum,
  FLOOR_POLICY_CANDIDATES,
  selectFloorPolicyWinner,
} from '../lib/floor-policy-sweep.mjs';
import { loadDictionary } from '../lib/load-dictionary.mjs';
import { canonicalize } from '../lib/text-normalization.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CURRENT_FLOOR = -8.0;
const BASELINE_ID = 'absolute-floor-baseline';
const SWEEP_CONFIG = Object.freeze({
  blendWeight: 0.5,
  fusedThreshold: DEFAULT_CONFIG.minConfidenceScoreFused,
  unfusedThreshold: DEFAULT_CONFIG.minConfidenceScore,
});

let _symspellDict = null;
let _builtInWords = null;

function loadJSON(relativePath) {
  return JSON.parse(readFileSync(resolve(__dirname, '..', relativePath), 'utf8'));
}

function isBuiltInWord(word) {
  return _builtInWords.has(canonicalize(word.toLowerCase()));
}

/** Run the winner-selection and confidence gates for one corpus entry. */
function runOne(typedWord, previousWord, previousWord2, pool, policy, kenlmScorer) {
  // Mirror the existing UITextChecker/dictionary protection for valid words.
  const lower = typedWord.toLowerCase();
  if (_symspellDict && !expansion(lower)) {
    const exactEntry = _symspellDict.get(lower);
    if (exactEntry !== undefined && exactEntry.count >= 2000) {
      return null;
    }
  }

  const result = topCorrection({
    pool,
    currentWord: typedWord,
    previousWord,
    previousWord2,
    kenlmScorer,
    // The proxy already returns P(candidate | previousWord).
    contextScorer: () => 0,
    trigramReady: true,
    blendWeight: SWEEP_CONFIG.blendWeight,
    absoluteLogProbFloor: CURRENT_FLOOR,
    floorPolicy: policy.floorPolicy,
    isBuiltInWord,
    ...policy.parameters,
  });
  if (!result) return null;

  const threshold = selectConfidenceThreshold({
    previousWord,
    trigramReady: true,
    fusedThreshold: SWEEP_CONFIG.fusedThreshold,
    unfusedThreshold: SWEEP_CONFIG.unfusedThreshold,
  });
  return result.score >= threshold ? result.text : null;
}

function runTypoCorpus(typoPools, policy, kenlmScorer) {
  return typoPools.map(({ entry, pool }) => runOne(
    entry.typedWord,
    entry.previousWord,
    entry.previousWord2 ?? null,
    pool,
    policy,
    kenlmScorer,
  ));
}

function runLegitCorpus(legitPools, policy, kenlmScorer) {
  return legitPools.map(({ entry, pool }) => runOne(
    entry.word,
    entry.previousWord,
    entry.previousWord2 ?? null,
    pool,
    policy,
    kenlmScorer,
  ));
}

function runOovStratum(oovStratum, policy, kenlmScorer) {
  return oovStratum.map(({ entry, pool }) => runOne(
    entry.typedWord,
    entry.previousWord,
    entry.previousWord2,
    pool,
    policy,
    kenlmScorer,
  ));
}

function fixturePool(testCase) {
  return [
    { text: testCase.typedWord, score: 1.0, source: 'symspell' },
    { text: testCase.intendedWord, score: Math.exp(-0.5), source: 'symspell' },
    ...(testCase.appleGuesses ?? []).map(text => ({
      text,
      score: 0.85,
      source: 'apple',
    })),
  ];
}

function runTier0Fixtures(tier0Fixtures, policy, kenlmScorer) {
  return tier0Fixtures.map(testCase => {
    const previousWord = testCase.previousWords.at(-1) ?? null;
    const previousWord2 = testCase.previousWords.at(-2) ?? null;
    const correction = runOne(
      testCase.typedWord,
      previousWord,
      previousWord2,
      fixturePool(testCase),
      policy,
      kenlmScorer,
    );
    return correction?.toLowerCase() === testCase.intendedWord.toLowerCase();
  });
}

function countTypoOutcomes(typoCorpus, corrections) {
  let correct = 0;
  let incorrect = 0;
  for (const [index, entry] of typoCorpus.entries()) {
    const correction = corrections[index];
    if (correction === null) continue;
    if (correction.toLowerCase() === entry.intendedWord.toLowerCase()) {
      correct++;
    } else {
      incorrect++;
    }
  }
  return { correct, incorrect };
}

function countChangedOutcomes(candidateOutcomes, baselineOutcomes) {
  return candidateOutcomes.reduce(
    (changed, outcome, index) => changed + Number(!sameOutcome(outcome, baselineOutcomes[index])),
    0,
  );
}

function sameOutcome(left, right) {
  if (left === null || right === null) return left === right;
  return left.toLowerCase() === right.toLowerCase();
}

function measurePolicy({
  policy,
  typoCorpus,
  typoPools,
  legitPools,
  oovStratum,
  tier0Fixtures,
  kenlmScorer,
}) {
  const typoCorrections = runTypoCorpus(typoPools, policy, kenlmScorer);
  const legitCorrections = runLegitCorpus(legitPools, policy, kenlmScorer);
  const oovCorrections = runOovStratum(oovStratum, policy, kenlmScorer);
  const tier0Results = runTier0Fixtures(tier0Fixtures, policy, kenlmScorer);
  const { correct, incorrect } = countTypoOutcomes(typoCorpus, typoCorrections);
  const falsePositives = legitCorrections.filter(correction => correction !== null).length;
  const precisionDenominator = correct + incorrect;

  return {
    typoCorrections,
    legitCorrections,
    precision: precisionDenominator > 0 ? correct / precisionDenominator : 1.0,
    recall: correct / typoCorpus.length,
    fpr: falsePositives / legitPools.length,
    oovCorrect: oovCorrections.filter((correction, index) => (
      correction?.toLowerCase() === oovStratum[index].entry.intendedWord.toLowerCase()
    )).length,
    oovTotal: oovStratum.length,
    tier0Correct: tier0Results.filter(Boolean).length,
    tier0Total: tier0Results.length,
  };
}

function createPolicyResults({
  typoCorpus,
  typoPools,
  legitPools,
  oovStratum,
  tier0Fixtures,
}) {
  const results = FLOOR_POLICY_CANDIDATES.map(candidate => ({
    id: candidate.id,
    label: candidate.label,
    shape: candidate.shape,
    floorPolicy: candidate.floorPolicy,
    parameters: candidate.parameters,
    calibrationRuns: [],
  }));
  const resultById = new Map(results.map(result => [result.id, result]));
  const baselinePolicy = FLOOR_POLICY_CANDIDATES.find(candidate => candidate.id === BASELINE_ID);

  for (const penalty of CALIBRATION_SENSITIVITY_VALUES) {
    const kenlmScorer = createBigramKenlmScorer(penalty);
    const baselineMeasurement = measurePolicy({
      policy: baselinePolicy,
      typoCorpus,
      typoPools,
      legitPools,
      oovStratum,
      tier0Fixtures,
      kenlmScorer,
    });

    for (const policy of FLOOR_POLICY_CANDIDATES) {
      const measurement = policy.id === BASELINE_ID
        ? baselineMeasurement
        : measurePolicy({
          policy,
          typoCorpus,
          typoPools,
          legitPools,
          oovStratum,
          tier0Fixtures,
          kenlmScorer,
        });
      resultById.get(policy.id).calibrationRuns.push({
        penalty,
        precision: measurement.precision,
        recall: measurement.recall,
        fpr: measurement.fpr,
        oovCorrect: measurement.oovCorrect,
        oovTotal: measurement.oovTotal,
        tier0Correct: measurement.tier0Correct,
        tier0Total: measurement.tier0Total,
        corpusOutcomeDelta: countChangedOutcomes(
          measurement.typoCorrections.concat(measurement.legitCorrections),
          baselineMeasurement.typoCorrections.concat(baselineMeasurement.legitCorrections),
        ),
      });
    }
  }
  return results;
}

function percentage(value) {
  return `${(value * 100).toFixed(1)}%`;
}

function printTieBreakSteps(steps) {
  if (steps.length === 0) return;

  console.log('Tie-break steps:');
  for (const step of steps) {
    if (step.rule === 'higher-oov-recall') {
      console.log(
        `  Higher OOV recall retained ${step.selectedIds.join(', ')}; `
        + `excluded ${step.excludedIds.join(', ')}.`,
      );
    } else if (step.rule === 'retain-rejection-guard') {
      console.log(
        `  Rejection-guard preference retained ${step.selectedIds.join(', ')}; `
        + `excluded ${step.excludedIds.join(', ')}.`,
      );
    } else if (step.rule === 'largest-typed-literal-margin') {
      console.log(
        `  Largest qualifying typed-literal margin (${step.margin.toFixed(1)}) `
        + `selected ${step.selectedIds.join(', ')}; `
        + `excluded ${step.excludedIds.join(', ')}.`,
      );
    }
  }
}

function printSweepReport(selection) {
  console.log('\n=== Per-policy calibration results ===');
  console.log('`delta` counts changed outcomes across the 401 typo + 299 legit corpus entries.');
  console.log('OOV recall is measured on the generated OOV-context typo stratum.');

  for (const report of selection.reports) {
    const passingCount = report.calibrationRuns.filter(run => {
      const baselineRun = selection.baseline.calibrationRuns.find(
        baselineResult => baselineResult.penalty === run.penalty,
      );
      return run.precision >= baselineRun.precision
        && run.fpr <= baselineRun.fpr
        && run.tier0Total > 0
        && run.tier0Correct === run.tier0Total;
    }).length;
    const robustness = report.robust ? 'ROBUST' : 'NOT ROBUST';
    const isQualifier = selection.qualifiers.some(qualifier => qualifier.id === report.id);
    const qualification = isQualifier ? 'MIN-DELTA QUALIFIER' : 'NOT MIN-DELTA QUALIFIER';
    console.log(
      `\n${report.label} [${report.id}] — ${robustness}, ${qualification} `
      + `(${passingCount}/${CALIBRATION_SENSITIVITY_VALUES.length} points)`,
    );
    console.log(`  Mean corpus outcome delta: ${report.meanCorpusOutcomeDelta.toFixed(2)}`);
    console.log(`  Mean OOV-stratum recall:    ${percentage(report.oovRecall)}`);
    for (const run of report.calibrationRuns) {
      const baselineRun = selection.baseline.calibrationRuns.find(
        baselineResult => baselineResult.penalty === run.penalty,
      );
      const tier0 = `${run.tier0Correct}/${run.tier0Total}`;
      console.log(
        `  ${run.penalty.toFixed(1)}: precision=${percentage(run.precision)} `
        + `(baseline ${percentage(baselineRun.precision)}), recall=${percentage(run.recall)}`,
      );
      console.log(
        `       legitFPR=${percentage(run.fpr)} (baseline ${percentage(baselineRun.fpr)}), `
        + `OOVrecall=${percentage(run.oovTotal > 0 ? run.oovCorrect / run.oovTotal : 0)}, `
        + `Tier0=${tier0}, delta=${run.corpusOutcomeDelta}`,
      );
    }
    if (report.failuresByPenalty.length > 0) {
      const failures = report.failuresByPenalty.map(({ penalty, failures }) => (
        `${penalty.toFixed(1)}: ${failures.join(', ')}`
      ));
      console.log(`  Qualification failures: ${failures.join('; ')}`);
    }
  }

  console.log('\n=== Pre-registered selection ===');
  if (selection.qualifiers.length === 0) {
    console.log('Qualifiers: none.');
    console.log(
      'NO QUALIFIER — no policy meets baseline precision/FPR, Tier-0, '
      + 'and full-range robustness requirements.',
    );
    console.log('No winner selected; do not weaken the selection rule.');
    return;
  }

  console.log('Qualifiers (robust policies at minimum mean outcome delta):');
  for (const qualifier of selection.qualifiers) {
    console.log(
      `  ${qualifier.id}: mean delta=${qualifier.meanCorpusOutcomeDelta.toFixed(2)}, `
      + `mean OOV recall=${percentage(qualifier.oovRecall)}`,
    );
  }
  printTieBreakSteps(selection.tieBreakSteps);
  const winner = selection.winner;
  console.log(`Winner: ${winner.label} [${winner.id}]`);
  console.log(`  Shape: ${winner.shape}`);
  console.log(`  Parameters: ${JSON.stringify(winner.parameters)}`);
  console.log(`  Mean corpus outcome delta: ${winner.meanCorpusOutcomeDelta.toFixed(2)}`);
  console.log(`  Mean OOV-stratum recall: ${percentage(winner.oovRecall)}`);
  console.log(
    `  Calibration range: ${CALIBRATION_SENSITIVITY_VALUES[0].toFixed(1)}–`
    + `${CALIBRATION_SENSITIVITY_VALUES.at(-1).toFixed(1)} `
    + `(${winner.calibrationRuns.length} points)`,
  );
  for (const run of winner.calibrationRuns) {
    console.log(
      `  ${run.penalty.toFixed(1)}: precision=${percentage(run.precision)}, `
      + `recall=${percentage(run.recall)}, legitFPR=${percentage(run.fpr)}`,
    );
    console.log(
      `       OOVrecall=${percentage(run.oovTotal > 0 ? run.oovCorrect / run.oovTotal : 0)}, `
      + `Tier0=${run.tier0Correct}/${run.tier0Total}, delta=${run.corpusOutcomeDelta}`,
    );
  }
}

function main() {
  console.log('=== Autocorrect floor-policy sweep ===\n');

  const typoCorpus = loadJSON('fixtures/typo-corpus.json');
  const legitCorpus = loadJSON('fixtures/legit-words.json');
  const oovFixture = loadJSON('fixtures/autocorrect-oov-contexts.json');
  const tier0Fixtures = oovFixture.cases.filter(testCase => testCase.tier === 0);
  if (tier0Fixtures.length === 0) {
    throw new Error('The OOV fixture set must include at least one Tier-0 incident case');
  }

  const symspell = new SymSpell(2, 7);
  const dictEntries = loadDictionary();
  for (const { word, count } of dictEntries) {
    symspell.createDictionaryEntry(word, count);
  }
  _symspellDict = new Map(dictEntries.map(entry => [entry.word, { count: entry.count }]));
  _builtInWords = new Set(
    dictEntries
      .filter(entry => entry.count >= SYMSPELL_MIN_WORD_FREQ)
      .map(entry => canonicalize(entry.word.toLowerCase())),
  );
  const symspellProvider = new SymSpellProvider(symspell, _symspellDict);

  const typoPools = typoCorpus.map(entry => ({
    entry,
    pool: symspellProvider.suggest(entry.typedWord),
  }));
  const legitPools = legitCorpus.map(entry => ({
    entry,
    pool: symspellProvider.suggest(entry.word),
  }));
  const oovStratum = createOovContextStratum(
    typoPools,
    isBuiltInWord,
    oovFixture.cases,
  );
  if (oovStratum.length === 0) {
    throw new Error('No generated contexts were OOV under built-in dictionary membership');
  }

  console.log(`Corpora: ${typoCorpus.length} typos, ${legitCorpus.length} legit words.`);
  const oovContextClassCount = new Set(oovStratum.map(entry => entry.contextClass)).size;
  console.log(
    `OOV stratum: ${oovStratum.length} generated typo/context pairs `
    + `(${oovContextClassCount} context classes).`,
  );
  console.log(`Tier-0 incident fixtures: ${tier0Fixtures.length}.`);
  console.log(
    `Operating point: blend=${SWEEP_CONFIG.blendWeight.toFixed(1)}, `
    + `fused=${SWEEP_CONFIG.fusedThreshold.toFixed(2)}, `
    + `unfused=${SWEEP_CONFIG.unfusedThreshold.toFixed(2)}, `
    + `floor=${CURRENT_FLOOR.toFixed(1)}.`,
  );
  console.log(
    `OOV policy signal: context tokens absent from the Trie word list `
    + `(frequency ≥ ${SYMSPELL_MIN_WORD_FREQ}), after apostrophe canonicalization.`,
  );
  console.log('Margin policy signal: raw KenLM scores for the winner and typed literal.');
  console.log('No KenLM bridge or vocabulary/backoff API is used by any candidate.');
  console.log(`Calibration penalties: ${CALIBRATION_SENSITIVITY_VALUES.join(', ')}.`);
  console.log(
    `Candidates: ${FLOOR_POLICY_CANDIDATES.length} parameterizations across `
    + 'five pre-registered policy shapes.\n',
  );

  const policyResults = createPolicyResults({
    typoCorpus,
    typoPools,
    legitPools,
    oovStratum,
    tier0Fixtures,
  });
  const selection = selectFloorPolicyWinner({
    policyResults,
    baselineId: BASELINE_ID,
    calibrationValues: CALIBRATION_SENSITIVITY_VALUES,
  });
  printSweepReport(selection);
}

main();
