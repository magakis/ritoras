#!/usr/bin/env node

// Phase 5: Single-config precision/recall/FPR runner.
// Usage:
//   node scripts/prediction-sim/bin/precision-recall.mjs \
//     --blendWeight 0.5 --fusedThreshold 0.65 --unfusedThreshold 0.70 --floor -8.0
//
//  Pass --floor off to disable the absolute-log-prob floor.

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
// CLI argument parsing
// ---------------------------------------------------------------------------

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    blendWeight: 0.5,
    fusedThreshold: 0.65,
    unfusedThreshold: 0.70,
    floor: -8.0,
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--blendWeight':
        opts.blendWeight = parseFloat(args[++i]);
        break;
      case '--fusedThreshold':
        opts.fusedThreshold = parseFloat(args[++i]);
        break;
      case '--unfusedThreshold':
        opts.unfusedThreshold = parseFloat(args[++i]);
        break;
      case '--floor':
        const val = args[++i];
        opts.floor = val === 'off' ? -Infinity : parseFloat(val);
        break;
      default:
        console.error(`Unknown option: ${args[i]}`);
        process.exit(1);
    }
  }

  return opts;
}

// ---------------------------------------------------------------------------
// Scoring and pool building (same as sweep.mjs)
// ---------------------------------------------------------------------------

function candidateScore(distance, count, logMaxCount, typedWord, candidateWord) {
  if (distance === 0) return 1.0;
  const freqScore = Math.log10(count + 1) / logMaxCount;
  const base = Math.pow(freqScore, 1.2);
  const distPenalty = 1.0 + 0.15 * Math.max(0, distance - 1);
  const typedLen = typedWord.length;
  const candLen = candidateWord.length;
  const lenSim = candLen >= typedLen * 0.5 && candLen <= typedLen * 2
    ? Math.min(typedLen, candLen) / Math.max(typedLen, candLen)
    : 0.1;
  return Math.max(0.05, Math.min(1.0, (base / distPenalty) * lenSim));
}

let _symspellDict = null;

function buildPool(typedWord, symspell, logMaxCount) {
  const pool = [];
  const lowerTyped = typedWord.toLowerCase();

  const contract = expansion(lowerTyped);
  if (contract) {
    pool.push({ text: contract, score: 0.9, source: 'symspell' });
  }

  const candidates = symspell.lookup(typedWord, undefined, 'all');
  for (const c of candidates) {
    const score = candidateScore(c.distance, c.count, logMaxCount, typedWord, c.term);
    pool.push({ text: c.term, score, source: 'symspell' });
  }

  if (!pool.some(s => s.text.toLowerCase() === lowerTyped)) {
    pool.push({ text: typedWord, score: 1.0, source: 'symspell' });
  }

  return pool;
}

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

  const active = fusionIsActive({ previousWord, trigramReady: true });
  const threshold = active ? fusedThreshold : unfusedThreshold;

  if (result.score < threshold) return null;
  return result.text;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const opts = parseArgs();
  const floorLabel = !Number.isFinite(opts.floor) ? 'off' : opts.floor.toFixed(1);

  console.log('=== Precision / Recall / FPR ===');
  console.log(`  blendWeight:         ${opts.blendWeight}`);
  console.log(`  fusedThreshold:      ${opts.fusedThreshold}`);
  console.log(`  unfusedThreshold:    ${opts.unfusedThreshold}`);
  console.log(`  absoluteLogProbFloor: ${floorLabel}`);
  console.log('');

  // Load corpora
  const typoCorpus = JSON.parse(
    readFileSync(resolve(__dirname, '..', 'fixtures/typo-corpus.json'), 'utf8')
  );
  const legitCorpus = JSON.parse(
    readFileSync(resolve(__dirname, '..', 'fixtures/legit-words.json'), 'utf8')
  );
  console.log(`Corpora: ${typoCorpus.length} typos, ${legitCorpus.length} legit words.\n`);

  // Build SymSpell index
  console.log('Building SymSpell index...');
  const symspell = new SymSpell(2, 7);
  const dictEntries = loadDictionary();
  let maxCount = 0;
  for (const { word, count } of dictEntries) {
    symspell.createDictionaryEntry(word, count);
    if (count > maxCount) maxCount = count;
  }
  const logMaxCount = Math.log10(maxCount + 1);
  console.log(`  Done. maxCount=${maxCount}, logMaxCount=${logMaxCount.toFixed(2)}.\n`);

  // Build in-dictionary lookup for the Apple-like guard.
  _symspellDict = new Map(dictEntries.map(e => [e.word, { count: e.count }]));

  // Pre-compute pools
  const typoPools = typoCorpus.map(e => ({ entry: e, pool: buildPool(e.typedWord, symspell, logMaxCount) }));
  const legitPools = legitCorpus.map(e => ({ entry: e, pool: buildPool(e.word, symspell, logMaxCount) }));

  // Run typo corpus
  let tp = 0, fpTypo = 0;
  for (const { entry, pool } of typoPools) {
    const correction = runOne(entry.typedWord, entry.previousWord, pool,
      opts.blendWeight, opts.floor, opts.fusedThreshold, opts.unfusedThreshold);
    if (correction === null) continue;
    if (correction.toLowerCase() === entry.intendedWord.toLowerCase()) {
      tp++;
    } else {
      fpTypo++;
    }
  }

  // Run legit corpus
  let fpLegit = 0;
  for (const { entry, pool } of legitPools) {
    const correction = runOne(entry.word, entry.previousWord, pool,
      opts.blendWeight, opts.floor, opts.fusedThreshold, opts.unfusedThreshold);
    if (correction !== null) fpLegit++;
  }

  // Compute and print metrics
  const totalTypo = typoCorpus.length;
  const totalLegit = legitCorpus.length;
  const recall = tp / totalTypo;
  const precisionDenom = tp + fpTypo;
  const precision = precisionDenom > 0 ? tp / precisionDenom : 1.0;
  const fpr = fpLegit / totalLegit;

  console.log('--- Results ---');
  console.log(`  True positives (correct corrections):    ${tp}`);
  console.log(`  Wrong corrections (on typos):            ${fpTypo}`);
  console.log(`  False positives (on legit words):        ${fpLegit}`);
  console.log(`  Missed corrections:                      ${totalTypo - tp - fpTypo}`);
  console.log('');
  console.log(`  Precision:  ${(precision * 100).toFixed(1)}%  (${tp} / ${precisionDenom})`);
  console.log(`  Recall:     ${(recall * 100).toFixed(1)}%  (${tp} / ${totalTypo})`);
  console.log(`  FPR:        ${(fpr * 100).toFixed(1)}%  (${fpLegit} / ${totalLegit})`);
  console.log('');

  // Feasibility check
  const feasible = precision >= 0.95 && fpr <= 0.05;
  if (feasible) {
    console.log('✓ This operating point satisfies the constraint (precision ≥ 95%, FPR ≤ 5%).');
  } else {
    const failures = [];
    if (precision < 0.95) failures.push(`precision ${(precision * 100).toFixed(1)}% < 95%`);
    if (fpr > 0.05) failures.push(`FPR ${(fpr * 100).toFixed(1)}% > 5%`);
    console.log(`✗ Does NOT satisfy constraints: ${failures.join(', ')}.`);
  }
}

main();
