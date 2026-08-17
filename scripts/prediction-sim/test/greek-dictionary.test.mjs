import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { loadDictionary } from '../lib/load-dictionary.mjs';
import { loadCanonicalDictionary } from '../lib/word-list-loader.mjs';
import { SymSpell } from '../lib/symspell.mjs';
import { SymSpellProvider } from '../lib/symspell-provider.mjs';
import { score as qwertyScore } from '../lib/qwerty-geometry.mjs';

const FIXTURE_PATH = fileURLToPath(new URL('../fixtures/greek-words.txt', import.meta.url));

describe('Greek word-list fixture', () => {
  it('parses with the same "word count" format as the bundled dictionaries', () => {
    const entries = loadDictionary(FIXTURE_PATH);
    assert.ok(entries.length > 40, `fixture should have 40+ words, got ${entries.length}`);
    for (const { word, count } of entries) {
      assert.ok(word.length > 0, 'word must be non-empty');
      assert.ok(Number.isInteger(count) && count > 0, `count for "${word}" must be a positive integer`);
    }
    // Spot-check known Greek entries survive canonicalization (no apostrophes
    // in Greek tokens, so canonicalize must be a no-op).
    const canonical = loadCanonicalDictionary(FIXTURE_PATH);
    assert.ok(canonical.some(e => e.word === 'καλημέρα'), 'fixture contains καλημέρα');
    assert.deepStrictEqual(canonical, loadDictionary(FIXTURE_PATH).map(e => ({
      word: e.word, count: e.count,
    })), 'canonicalize is a no-op on Greek words');
  });
});

describe('Greek SymSpell + provider', () => {
  it('corrects a Greek typo with a geometry-aware score', () => {
    const entries = loadDictionary(FIXTURE_PATH);
    const speller = new SymSpell(2, 7);
    speller.bulkLoad(entries);
    speller.finalize();

    // "καλημερα" (missing tonos) → "καλημέρα", edit distance 1
    const lookup = speller.lookup('καλημερα', undefined, 'all');
    const hit = lookup.find(c => c.term === 'καλημέρα');
    assert.ok(hit, 'SymSpell should find καλημέρα for the tonos-less typo');
    assert.strictEqual(hit.distance, 1);

    // The provider scores it with QwertyGeometry: the only edit is ε→έ,
    // and accented Greek characters are not in the key map, so the fallback
    // neutral distance 1.0 applies → cost 1/3 → score exp(-1.5/3) ≈ 0.607.
    const expected = qwertyScore('καλημερα', 'καλημέρα', 1, 1.5);
    const dict = new Map(entries.map(e => [e.word, { count: e.count }]));
    const provider = new SymSpellProvider(speller, dict);
    const results = provider.suggest('καλημερα', { verbosity: 'all' });
    const correction = results.find(s => s.text === 'καλημέρα');
    assert.ok(correction, 'provider should suggest καλημέρα');
    assert.ok(Math.abs(correction.score - expected) < 0.001,
      `καλημέρα score ${correction.score} ≈ ${expected}`);
  });

  it('treats a high-frequency Greek word as real (verbatim only)', () => {
    const entries = loadDictionary(FIXTURE_PATH);
    const speller = new SymSpell(2, 7);
    speller.bulkLoad(entries);
    const dict = new Map(entries.map(e => [e.word, { count: e.count }]));
    const provider = new SymSpellProvider(speller, dict);

    const results = provider.suggest('και', { verbosity: 'all' });
    // "και" count 32M ≥ 2000 → real word → verbatim only, no corrections.
    assert.strictEqual(results.length, 1);
    assert.strictEqual(results[0].text, 'και');
    assert.strictEqual(results[0].score, 1.0);
  });

  it('unknown Greek word returns only the verbatim candidate', () => {
    const speller = new SymSpell(2, 7);
    speller.bulkLoad(loadDictionary(FIXTURE_PATH));
    const provider = new SymSpellProvider(speller, new Map());
    const results = provider.suggest('μπλαμπλα', { verbosity: 'all' });
    assert.strictEqual(results.length, 1);
    assert.strictEqual(results[0].text, 'μπλαμπλα');
    assert.strictEqual(results[0].isUnknownVerbatim, true);
  });
});
