#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SymSpell } from '../lib/symspell.mjs';
import { loadCanonicalDictionary } from '../lib/word-list-loader.mjs';
import {
  SYMSPELL_MAX_EDIT_DISTANCE,
  SYMSPELL_MIN_WORD_FREQ,
  SYMSPELL_PREFIX_LENGTH,
  buildSymSpellBlob,
  fnv1a64,
  readSymSpellBlobHeader,
} from '../lib/sym-spell-blob.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '../../..');
const RESOURCE_DIR = path.resolve(REPO_ROOT, 'keyboard/Sources/Prediction/Resources');

const LANGUAGES = [
  {
    lang: 'en',
    wordlist: path.resolve(RESOURCE_DIR, 'frequency_dictionary_en_wordfreq_50k.txt'),
    blob: path.resolve(RESOURCE_DIR, 'symspell_index_en_v1.blob'),
  },
  {
    lang: 'el',
    wordlist: path.resolve(RESOURCE_DIR, 'frequency_dictionary_el_wordfreq_50k.txt'),
    blob: path.resolve(RESOURCE_DIR, 'symspell_index_el_v1.blob'),
  },
];

// These dimensions are the approved Phase 1 baseline for Config.swift's
// symspellMaxEditDistance=2, symspellPrefixLength=7, and
// symspellMinWordFreq=1500.
const EXPECTED_STATS = {
  en: {
    fileEntries: 49_999,
    wordCount: 23_158,
    deleteKeyCount: 230_403,
    deleteValueCount: 504_740,
    stringPoolBytes: 1_601_340,
    blobBytes: 5_741_504,
  },
  el: {
    fileEntries: 42_858,
    wordCount: 32_962,
    deleteKeyCount: 368_445,
    deleteValueCount: 818_618,
    stringPoolBytes: 4_701_713,
    blobBytes: 11_319_376,
  },
};

function formatInteger(value) {
  return value.toLocaleString('en-US');
}

function formatHash(value) {
  return `0x${value.toString(16).padStart(16, '0')}`;
}

function formatBytes(value) {
  return `${formatInteger(value)} (${(value / 1024).toFixed(1)} KiB)`;
}

function checkExpectedDimensions(stats) {
  const expected = EXPECTED_STATS[stats.lang];
  const fields = [
    'fileEntries',
    'wordCount',
    'deleteKeyCount',
    'deleteValueCount',
    'stringPoolBytes',
    'blobBytes',
  ];
  const mismatches = fields
    .filter(field => stats[field] !== expected[field])
    .map(field => `${field}: expected ${expected[field]}, got ${stats[field]}`);
  if (mismatches.length > 0) {
    throw new Error(`${stats.lang} SymSpell dimensions differ from the approved baseline; ${mismatches.join(', ')}`);
  }
}

function buildLanguage(language) {
  const sourceBytes = fs.readFileSync(language.wordlist);
  const sourceEntries = loadCanonicalDictionary(language.wordlist);
  const entries = sourceEntries.filter(entry => entry.count >= SYMSPELL_MIN_WORD_FREQ);
  const symspell = new SymSpell(SYMSPELL_MAX_EDIT_DISTANCE, SYMSPELL_PREFIX_LENGTH);
  symspell.bulkLoad(entries);
  symspell.finalize();

  const blob = buildSymSpellBlob(symspell, {
    lang: language.lang,
    maxEditDistance: SYMSPELL_MAX_EDIT_DISTANCE,
    prefixLength: SYMSPELL_PREFIX_LENGTH,
    wordlistFnv1a64: fnv1a64(sourceBytes),
  });

  const wordPoolBytes = symspell.words
    .reduce((total, word) => total + Buffer.byteLength(word, 'utf8') + 1, 0);
  const deleteKeyPoolBytes = symspell.deleteKeys
    .reduce((total, key) => total + Buffer.byteLength(key, 'utf8') + 1, 0);
  const stats = {
    lang: language.lang,
    fileEntries: sourceEntries.length,
    wordsLoaded: symspell.words.length,
    wordCount: symspell.words.length,
    deleteKeyCount: symspell.deleteKeys.length,
    deleteValueCount: symspell.deleteValues.length,
    wordPoolBytes,
    deleteKeyPoolBytes,
    stringPoolBytes: wordPoolBytes + deleteKeyPoolBytes,
    blobBytes: blob.length,
    wordlistFnv1a64: fnv1a64(sourceBytes),
    blobFnv1a64: blob.readBigUInt64LE(blob.length - 8),
  };
  checkExpectedDimensions(stats);
  fs.writeFileSync(language.blob, blob);
  return stats;
}

function printStats(stats) {
  const columns = [
    ['Lang', 'lang'],
    ['File entries', 'fileEntries'],
    ['Words loaded', 'wordsLoaded'],
    ['Delete keys', 'deleteKeyCount'],
    ['Delete values', 'deleteValueCount'],
    ['Word pool', 'wordPoolBytes'],
    ['Delete-key pool', 'deleteKeyPoolBytes'],
    ['String pool', 'stringPoolBytes'],
    ['Blob size', 'blobBytes'],
    ['Wordlist FNV-1a-64', 'wordlistFnv1a64'],
    ['Blob FNV-1a-64', 'blobFnv1a64'],
  ];
  const rows = stats.map(row => columns.map(([, key]) => {
    if (key.endsWith('Fnv1a64')) return formatHash(row[key]);
    if (key === 'lang') return row[key];
    if (key.endsWith('Bytes')) return formatBytes(row[key]);
    return formatInteger(row[key]);
  }));
  const widths = columns.map(([heading], index) => Math.max(
    heading.length,
    ...rows.map(row => row[index].length)
  ));
  const render = values => values.map((value, index) => value.padStart(widths[index])).join(' | ');
  console.log(render(columns.map(([heading]) => heading)));
  console.log(widths.map(width => '-'.repeat(width)).join('-+-'));
  for (const row of rows) console.log(render(row));
}

function checkLanguage(language) {
  const header = readSymSpellBlobHeader(language.blob);
  const sourceHash = fnv1a64(fs.readFileSync(language.wordlist));
  const expected = EXPECTED_STATS[language.lang];
  const errors = [];
  if (header.magic !== 'RSS1') errors.push(`magic ${JSON.stringify(header.magic)}`);
  if (header.formatVersion !== 1) errors.push(`formatVersion ${header.formatVersion}`);
  if (!header.langBytesValid) errors.push('invalid language padding');
  if (header.lang !== language.lang) errors.push(`lang ${header.lang}`);
  if (header.maxEditDistance !== SYMSPELL_MAX_EDIT_DISTANCE) {
    errors.push(`maxEditDistance ${header.maxEditDistance}`);
  }
  if (header.prefixLength !== SYMSPELL_PREFIX_LENGTH) errors.push(`prefixLength ${header.prefixLength}`);
  if (header.wordCount !== expected.wordCount) errors.push(`wordCount ${header.wordCount}`);
  if (header.deleteKeyCount !== expected.deleteKeyCount) {
    errors.push(`deleteKeyCount ${header.deleteKeyCount}`);
  }
  if (header.deleteValueCount !== expected.deleteValueCount) {
    errors.push(`deleteValueCount ${header.deleteValueCount}`);
  }
  if (expected.stringPoolBytes !== null && header.stringPoolBytes !== expected.stringPoolBytes) {
    errors.push(`stringPoolBytes ${header.stringPoolBytes}`);
  }
  if (header.wordlistFnv1a64 !== sourceHash) errors.push('stale wordlist hash');
  if (header.reserved.some(byte => byte !== 0)) errors.push('non-zero reserved header bytes');
  const blobBytes = fs.statSync(language.blob).size;
  if (expected.blobBytes !== null && blobBytes !== expected.blobBytes) {
    errors.push(`blobBytes ${blobBytes}`);
  }
  if (errors.length > 0) {
    throw new Error(`${language.lang} blob check failed: ${errors.join(', ')}`);
  }
  console.log(`${language.lang}: OK (${formatInteger(blobBytes)} bytes, wordlist ${formatHash(sourceHash)})`);
}

function main() {
  if (process.argv.includes('--check')) {
    for (const language of LANGUAGES) checkLanguage(language);
    return;
  }

  const stats = LANGUAGES.map(buildLanguage);
  printStats(stats);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
