import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import { loadDictionary } from '../lib/load-dictionary.mjs';
import { SymSpell } from '../lib/symspell.mjs';

const DICT_PATH = fileURLToPath(new URL('../../../keyboard/Sources/Prediction/Resources/frequency_dictionary_el_wordfreq_50k.txt', import.meta.url));

// Modern monotonic Greek allowlist (mirrors scripts/export_wordfreq.py's
// GREEK_ALLOWED): uppercase incl. accented (U+0386, U+0388–U+038A, U+038C,
// U+038E–U+0390, U+0391–U+03A9) + monotonic lowercase incl. σ ς (U+03AC–U+03CE).
const GREEK_ALLOWED = /^[\u0386\u0388-\u038A\u038C\u038E-\u0390\u0391-\u03A9\u03AC-\u03CE]+$/;

function readLines() {
  return fs.readFileSync(DICT_PATH, 'utf8').split('\n').filter(Boolean);
}

describe('bundled Greek dictionary (real file)', () => {
  it('has the "word count" format and no duplicate tokens', () => {
    const lines = readLines();
    assert.ok(lines.length > 40_000, `expected 40k+ entries, got ${lines.length}`);
    const seen = new Set();
    for (const line of lines) {
      assert.match(line, /^\S+ \d+$/, `malformed line: ${line}`);
      const word = line.slice(0, line.lastIndexOf(' '));
      assert.ok(!seen.has(word), `duplicate token: ${word}`);
      seen.add(word);
    }
  });

  it('contains only modern monotonic Greek tokens (no final σ, no polytonic/combining)', () => {
    const lines = readLines();
    for (const line of lines) {
      const word = line.slice(0, line.lastIndexOf(' '));
      assert.match(word, GREEK_ALLOWED, `token outside allowlist: ${word}`);
      assert.ok(!word.endsWith('σ'), `word-final medial sigma: ${word}`);
    }
  });

  it('contains high-frequency final-sigma forms της and τους', () => {
    const counts = new Map(loadDictionary(DICT_PATH).map(e => [e.word, e.count]));
    assert.ok(counts.has('της'), 'της must be present');
    assert.ok(counts.has('τους'), 'τους must be present');
    assert.ok(counts.get('της') >= 1_000_000, `της count ${counts.get('της')} must be >= 1,000,000`);
    assert.ok(counts.get('τους') >= 1_000_000, `τους count ${counts.get('τους')} must be >= 1,000,000`);
  });

  it('corrects τησ → της and matches τους exactly via SymSpell', () => {
    // Mirror the Swift loader pruning (Config.symspellMinWordFreq = 1500) to
    // keep the SymSpell build fast.
    const entries = loadDictionary(DICT_PATH).filter(e => e.count >= 1500);
    const speller = new SymSpell(2, 7);
    speller.bulkLoad(entries);
    speller.finalize();

    // τησ (medial sigma typo) → της (final sigma): Levenshtein substitution
    // σ→ς must be found at edit distance <= 1.
    const typo = speller.lookup('τησ', undefined, 'all').find(s => s.term === 'της');
    assert.ok(typo, 'SymSpell should find της for τησ');
    assert.ok(typo.distance <= 1, `expected edit distance <= 1, got ${typo.distance}`);

    // Exact match at distance 0 for the canonical final-sigma form.
    const exact = speller.lookup('τους', undefined, 'all').find(s => s.term === 'τους');
    assert.ok(exact, 'SymSpell should find τους verbatim');
    assert.strictEqual(exact.distance, 0);
  });
});
