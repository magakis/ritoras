#!/usr/bin/env node

// Phase 5: Parameter sweep over the autocorrect threshold space.
// Builds the SymSpell index once, pre-computes all suggestion pools,
// then runs every parameter combination against the typo + legit corpora.

import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SymSpell } from '../lib/symspell.mjs';
import { expansion } from '../lib/contractions.mjs';
import { topCorrection } from '../lib/top-correction.mjs';
import { fusionIsActive } from '../lib/fusion-is-active.mjs';
import { bigramKenlmScorer } from '../lib/bigram-kenlm-proxy.mjs';
import { loadDictionary } from '../lib/load-dictionary.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function loadJSON(relativePath) {
  return JSON.parse(readFileSync(resolve(__dirname, '..', relativePath), 'utf8'));
}

/** Score a SymSpell candidate.
 *
 *  Uses nonlinear frequency weighting (freqScore^1.2) to differentiate
 *  candidates, with mild distance penalty and length-similarity factor.
 *
 *  Length-similarity prevents egregious false positives (e.g. "cat" → "a")
 *  that the real system blocks via Apple UITextChecker + QWERTY geometry
 *  which are absent from this JS port.
 *
 *  distance=0 → 1.0 (the typed word itself).
 *
 *  Typical ranges:
 *    d=1, same-length, very common (both):  ~0.71 — near 0.70 unfused
 *    d=1, same-length, common (definitely): ~0.53 — below most thresholds
 *    d=2, same-length, highest-freq (the):   ~0.87 — above 0.70 unfused
 */
function candidateScore(distance, count, logMaxCount, typedWord, candidateWord) {
  if (distance === 0) return 1.0;

  const freqScore = Math.log10(count + 1) / logMaxCount;
  const base = Math.pow(freqScore, 1.2);
  const distPenalty = 1.0 + 0.15 * Math.max(0, distance - 1);

  // Length similarity: min(tlen, clen) / max(tlen, clen)
  const typedLen = typedWord.length;
  const candLen = candidateWord.length;
  const lenSim = candLen >= typedLen * 0.5 && candLen <= typedLen * 2
    ? Math.min(typedLen, candLen) / Math.max(typedLen, candLen)
    : 0.1;

  return Math.max(0.05, Math.min(1.0, (base / distPenalty) * lenSim));
}

/** Build a full suggestion pool for `typedWord`. The pool includes:
 *   - A verbatim entry (score 1.0) for the typed word itself
 *   - SymSpell candidates scored by distance + frequency
 *   - Contraction expansions at score 0.9
 * The pool is the same regardless of sweep parameters — only the fusion
 * scoring changes per combination. */
function buildPool(typedWord, symspell, logMaxCount) {
  const pool = [];
  const lowerTyped = typedWord.toLowerCase();

  // Contraction expansions (score 0.9)
  const contract = expansion(lowerTyped);
  if (contract) {
    pool.push({ text: contract, score: 0.9, source: 'symspell' });
  }

  // SymSpell candidates
  const candidates = symspell.lookup(typedWord, undefined, 'all');
  for (const c of candidates) {
    const score = candidateScore(c.distance, c.count, logMaxCount, typedWord, c.term);
    pool.push({ text: c.term, score, source: 'symspell' });
  }

  // Always include the typed word itself (verbatim entry that topCorrection
  // filters out). This mirrors the Apple spell-checker behaviour.
  if (!pool.some(s => s.text.toLowerCase() === lowerTyped)) {
    pool.push({ text: typedWord, score: 1.0, source: 'symspell' });
  }

  return pool;
}

/** SymSpell dictionary reference for in-dictionary checks.
 *  Populated once in main(). */
let _symspellDict = null;

/** Run the autocorrect pipeline for one entry. Returns the correction text
 *  if one fires (score >= threshold), or null if no correction applies.
 *
 *  Simulates Apple UITextChecker: when the typed word is a valid dictionary
 *  word (distance 0 found by SymSpell) with non-trivial frequency, the system
 *  does NOT auto-correct it unless the word is a contraction fast-path entry.
 */
function runOne(typedWord, previousWord, pool, blendWeight, absoluteLogProbFloor,
                fusedThreshold, unfusedThreshold) {
  // Apple-like guard: skip well-known dictionary words (≥2000 count) but
  // always process contractions.
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
    previousWord2: null,
    kenlmScorer: bigramKenlmScorer,
    trigramReady: true,
    blendWeight,
    absoluteLogProbFloor,
  });

  if (!result) return null;

  // Determine which threshold applies.
  const active = fusionIsActive({ previousWord, trigramReady: true });
  const threshold = active ? fusedThreshold : unfusedThreshold;

  if (result.score < threshold) return null;
  return result.text;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  console.log('=== Phase 5: Parameter Sweep ===\n');

  // ---- Load corpora ----
  const typoCorpus = loadJSON('fixtures/typo-corpus.json');
  const legitCorpus = loadJSON('fixtures/legit-words.json');
  console.log(`Loaded ${typoCorpus.length} typos, ${legitCorpus.length} legit words.\n`);

  // ---- Build SymSpell index ----
  console.log('Building SymSpell index from frequency dictionary...');
  const symspell = new SymSpell(2, 7);
  const dictEntries = loadDictionary();
  let maxCount = 0;
  for (const { word, count } of dictEntries) {
    symspell.createDictionaryEntry(word, count);
    if (count > maxCount) maxCount = count;
  }
  const logMaxCount = Math.log10(maxCount + 1);
  console.log(`  Indexed ${dictEntries.length} entries, maxCount=${maxCount}, logMaxCount=${logMaxCount.toFixed(2)}.\n`);

  // Build the in-dictionary lookup for the Apple-like guard.
  _symspellDict = new Map(dictEntries.map(e => [e.word, { count: e.count }]));

  // ---- Pre-compute pools ----
  // Pools don't depend on sweep parameters, so build once.
  console.log('Pre-computing suggestion pools...');
  const typoPools = typoCorpus.map((e, i) => {
    const pool = buildPool(e.typedWord, symspell, logMaxCount);
    return { entry: e, pool };
  });
  const legitPools = legitCorpus.map((e, i) => {
    const pool = buildPool(e.word, symspell, logMaxCount);
    return { entry: e, pool };
  });
  console.log(`  Pre-computed ${typoPools.length} typo pools + ${legitPools.length} legit pools.\n`);

  // ---- Sweep parameter space ----
  const blendValues = [0.3, 0.4, 0.5, 0.6];
  const fusedThresholdValues = [0.60, 0.65, 0.70];
  const unfusedThresholdValues = [0.65, 0.70, 0.75];
  const floorValues = [-6.0, -8.0, -10.0, -Infinity];

  const totalCombos = blendValues.length * fusedThresholdValues.length
    * unfusedThresholdValues.length * floorValues.length;

  console.log(`Sweeping ${totalCombos} parameter combinations...\n`);

  /** @type {Array<{blend:number, fusedThresh:number, unfusedThresh:number, floor:number, precision:number, recall:number, fpr:number}>} */
  const results = [];

  let combo = 0;
  const startTime = Date.now();

  for (const blend of blendValues) {
    for (const fusedThresh of fusedThresholdValues) {
      for (const unfusedThresh of unfusedThresholdValues) {
        for (const floor of floorValues) {
          const floorLabel = !Number.isFinite(floor) ? 'off' : floor.toFixed(1);

          // -- Run typo corpus --
          let tp = 0;   // correction fires and matches intendedWord
          let fpTypo = 0; // correction fires but wrong word
          for (const { entry, pool } of typoPools) {
            const correction = runOne(
              entry.typedWord, entry.previousWord, pool,
              blend, floor, fusedThresh, unfusedThresh
            );
            if (correction === null) continue; // no correction fired
            if (correction.toLowerCase() === entry.intendedWord.toLowerCase()) {
              tp++;
            } else {
              fpTypo++;
            }
          }

          // -- Run legit corpus --
          let fpLegit = 0;
          for (const { entry, pool } of legitPools) {
            const correction = runOne(
              entry.word, entry.previousWord, pool,
              blend, floor, fusedThresh, unfusedThresh
            );
            if (correction !== null) fpLegit++;
          }

          // -- Compute metrics --
          const totalTypo = typoCorpus.length;
          const totalLegit = legitCorpus.length;
          const recall = tp / totalTypo;
          const precisionDenom = tp + fpTypo;
          const precision = precisionDenom > 0 ? tp / precisionDenom : 1.0;
          const fpr = fpLegit / totalLegit;

          results.push({
            blend,
            fusedThresh,
            unfusedThresh,
            floor,
            floorLabel,
            precision,
            recall,
            fpr,
          });

          combo++;
          if (combo % 36 === 0 || combo === totalCombos) {
            const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
            process.stderr.write(`  ${combo}/${totalCombos} combos (${elapsed}s)\r`);
          }
        }
      }
    }
  }

  const totalTime = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\n  ${totalCombos}/${totalCombos} combos done in ${totalTime}s.\n`);

  // ---- Rank results ----
  // Constraint: precision >= 0.95 AND fpr <= 0.05
  // Best = max recall among those that satisfy the constraint.
  const feasible = results.filter(r => r.precision >= 0.95 && r.fpr <= 0.05);
  feasible.sort((a, b) => b.recall - a.recall);

  if (feasible.length === 0) {
    console.log('⚠️  NO feasible operating point found within constraints (precision ≥ 0.95, FPR ≤ 0.05).\n');
    console.log('Showing top-5 by recall (any precision/FPR):\n');
    const byRecall = [...results].sort((a, b) => b.recall - a.recall).slice(0, 5);
    printTable(byRecall);
    console.log('\nKeeping current defaults.\n');
    process.exit(0);
  }

  // Print header for feasible results
  const topK = feasible.slice(0, 10);
  console.log(`Feasible operating points (precision ≥ 0.95, FPR ≤ 0.05): ${feasible.length} found.`);
  console.log(`Top ${topK.length} (sorted by recall):\n`);
  printTable(topK);

  // Best operating point
  const best = feasible[0];
  console.log('\n=== RECOMMENDED OPERATING POINT ===');
  console.log(`  blendWeight (α):               ${best.blend.toFixed(1)}`);
  console.log(`  fusedThreshold:                ${best.fusedThresh.toFixed(2)}`);
  console.log(`  unfusedThreshold:              ${best.unfusedThresh.toFixed(2)}`);
  console.log(`  absoluteLogProbFloor:          ${best.floorLabel}`);
  console.log(`  ---`);
  console.log(`  Precision:                     ${(best.precision * 100).toFixed(1)}%`);
  console.log(`  Recall:                        ${(best.recall * 100).toFixed(1)}%`);
  console.log(`  False-positive rate (legit):   ${(best.fpr * 100).toFixed(1)}%`);

  // Check if the best is at or near the defaults
  const defaults = { blend: 0.5, fusedThresh: 0.65, unfusedThresh: 0.70, floor: -8.0 };
  const isDefault = best.blend === defaults.blend
    && best.fusedThresh === defaults.fusedThresh
    && best.unfusedThresh === defaults.unfusedThresh
    && best.floor === defaults.floor;

  if (isDefault) {
    console.log('\nThe sweep validated the current defaults as optimal (or very near).');
  } else {
    // Find the default combo in the results for comparison
    const defaultResult = results.find(r =>
      r.blend === defaults.blend
      && r.fusedThresh === defaults.fusedThresh
      && r.unfusedThresh === defaults.unfusedThresh
      && r.floor === defaults.floor
    );
    if (defaultResult) {
      console.log('\nComparison with current defaults:');
      console.log(`  Defaults:  precision=${(defaultResult.precision * 100).toFixed(1)}%, recall=${(defaultResult.recall * 100).toFixed(1)}%, fpr=${(defaultResult.fpr * 100).toFixed(1)}%`);
      console.log(`  Best:      precision=${(best.precision * 100).toFixed(1)}%, recall=${(best.recall * 100).toFixed(1)}%, fpr=${(best.fpr * 100).toFixed(1)}%`);
    }
  }
}

function printTable(rows) {
  const header = `${'α'.padStart(5)} | ${'fusedThr'.padStart(9)} | ${'unfusedThr'.padStart(10)} | ${'floor'.padStart(6)} | ${'precision'.padStart(9)} | ${'recall'.padStart(6)} | ${'fpr'.padStart(5)}`;
  const sep = '-'.repeat(header.length);
  console.log(header);
  console.log(sep);
  for (const r of rows) {
    const floorLabel = !Number.isFinite(r.floor) ? 'off' : r.floor.toFixed(1);
    const line =
      `${r.blend.toFixed(1).padStart(5)} | ` +
      `${r.fusedThresh.toFixed(2).padStart(9)} | ` +
      `${r.unfusedThresh.toFixed(2).padStart(10)} | ` +
      `${floorLabel.padStart(6)} | ` +
      `${(r.precision * 100).toFixed(1).padStart(8)}% | ` +
      `${(r.recall * 100).toFixed(1).padStart(5)}% | ` +
      `${(r.fpr * 100).toFixed(1).padStart(4)}%`;
    console.log(line);
  }
}

main();
