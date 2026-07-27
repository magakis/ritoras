import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { SymSpell } from '../lib/symspell.mjs';
import { LearnedWordsStore } from '../lib/learned-words-store.mjs';
import { canonicalize, CANONICAL_APOSTROPHE } from '../lib/text-normalization.mjs';

describe('Apostrophe normalization integration', () => {
  let speller;
  let entries;

  it('load real dictionary via canonical loader', async () => {
    const { loadCanonicalDictionary } = await import('../lib/word-list-loader.mjs');
    entries = loadCanonicalDictionary();
    assert.ok(entries.length > 1000, 'dictionary should have >1000 entries');

    speller = new SymSpell();
    for (const { word, count } of entries) {
      speller.createDictionaryEntry(word, count);
    }
  });

  it('don\'t in all three variants returns same result', () => {
    // U+2019 (canonical right single quote)
    const result2019 = speller.lookup(`don${CANONICAL_APOSTROPHE}t`, undefined, 'top');
    assert.strictEqual(result2019.length, 1);
    assert.strictEqual(result2019[0].term, `don${CANONICAL_APOSTROPHE}t`);
    assert.strictEqual(result2019[0].distance, 0);

    // U+0027 (straight apostrophe) — should match via canonicalization at caller layer
    const inputU27 = canonicalize("don't");
    const resultU27 = speller.lookup(inputU27, undefined, 'top');
    assert.strictEqual(resultU27.length, 1);
    assert.strictEqual(resultU27[0].term, `don${CANONICAL_APOSTROPHE}t`);
    assert.strictEqual(resultU27[0].distance, 0);

    // U+2018 (left single quote)
    const inputU18 = canonicalize("don\u{2018}t");
    const resultU18 = speller.lookup(inputU18, undefined, 'top');
    assert.strictEqual(resultU18.length, 1);
    assert.strictEqual(resultU18[0].term, `don${CANONICAL_APOSTROPHE}t`);
    assert.strictEqual(resultU18[0].distance, 0);

    // All three lookup results are the same term
    assert.strictEqual(result2019[0].term, resultU27[0].term);
    assert.strictEqual(resultU27[0].term, resultU18[0].term);
  });

  it('it\'s in all three variants returns same result', () => {
    const expectedTerm = `it${CANONICAL_APOSTROPHE}s`;

    const result2019 = speller.lookup(`it${CANONICAL_APOSTROPHE}s`, undefined, 'top');
    assert.strictEqual(result2019.length, 1);
    assert.strictEqual(result2019[0].term, expectedTerm);
    assert.strictEqual(result2019[0].distance, 0);

    const resultU27 = speller.lookup(canonicalize("it's"), undefined, 'top');
    assert.strictEqual(resultU27[0].term, expectedTerm);
    assert.strictEqual(resultU27[0].distance, 0);

    const resultU18 = speller.lookup(canonicalize("it\u{2018}s"), undefined, 'top');
    assert.strictEqual(resultU18[0].term, expectedTerm);
    assert.strictEqual(resultU18[0].distance, 0);

    assert.strictEqual(result2019[0].term, resultU27[0].term);
    assert.strictEqual(resultU27[0].term, resultU18[0].term);
  });

  it('learned word added in one variant matches contains in another variant', () => {
    const store = new LearnedWordsStore();

    // Add with U+0027
    store.add("can't");

    // Check with U+2019
    assert.ok(store.contains(`can${CANONICAL_APOSTROPHE}t`));

    // Check with U+2018
    assert.ok(store.contains("can\u{2018}t"));

    // Add with U+2019
    store.add(`won${CANONICAL_APOSTROPHE}t`);

    // Check with U+0027
    assert.ok(store.contains("won't"));

    // Idempotent — same word in different variant doesn't duplicate
    assert.strictEqual(store.allWords().length, 2);
  });
});
