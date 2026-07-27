import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { SymSpell, levenshteinDistance } from '../lib/symspell.mjs';
import { CANONICAL_APOSTROPHE } from '../lib/text-normalization.mjs';

describe('SymSpell', () => {
  describe('levenshteinDistance', () => {
    it('kitten vs sitting === 3', () => {
      assert.strictEqual(levenshteinDistance('kitten', 'sitting'), 3);
    });

    it('dont vs don\'t === 1', () => {
      const dont = 'dont';
      const dontCanon = `don${CANONICAL_APOSTROPHE}t`;
      assert.strictEqual(levenshteinDistance(dont, dontCanon), 1);
    });

    it('empty string special cases', () => {
      assert.strictEqual(levenshteinDistance('', 'abc'), 3);
      assert.strictEqual(levenshteinDistance('abc', ''), 3);
      assert.strictEqual(levenshteinDistance('', ''), 0);
    });

    it('identical strings have distance 0', () => {
      assert.strictEqual(levenshteinDistance('hello', 'hello'), 0);
    });
  });

  describe('createDictionaryEntry and lookup', () => {
    it('REGRESSION: dont returns dont at distance 0 with dont in dictionary', () => {
      // This confirms SymSpell offers NO correction for "dont" —
      // the contraction table (Phase 3) is necessary.
      const speller = new SymSpell();
      speller.createDictionaryEntry('dont', 50);
      speller.createDictionaryEntry(`don${CANONICAL_APOSTROPHE}t`, 100);

      const result = speller.lookup('dont', undefined, 'top');
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].term, 'dont');
      assert.strictEqual(result[0].distance, 0);
    });

    it('don\'t (U+2019) returns itself at distance 0', () => {
      const speller = new SymSpell();
      speller.createDictionaryEntry('dont', 50);
      speller.createDictionaryEntry(`don${CANONICAL_APOSTROPHE}t`, 100);

      const input = `don${CANONICAL_APOSTROPHE}t`;
      const result = speller.lookup(input, undefined, 'top');
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].term, `don${CANONICAL_APOSTROPHE}t`);
      assert.strictEqual(result[0].distance, 0);
    });

    it('don\'t (U+0027) matches don\'t (U+2019) after canonicalization', () => {
      // The caller canonicalizes before lookup. This test confirms that
      // SymSpell itself is codepoint-agnostic — if the caller passes
      // already-canonicalized input, it matches the canonicalized dictionary.
      const speller = new SymSpell();
      speller.createDictionaryEntry(`don${CANONICAL_APOSTROPHE}t`, 100);

      // Simulate: input "don't" (U+0027) has already been canonicalized by the caller
      // to "don\u{2019}t" before being passed to symspell.lookup
      const input = `don${CANONICAL_APOSTROPHE}t`; // already canonical
      const result = speller.lookup(input, undefined, 'top');
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].term, `don${CANONICAL_APOSTROPHE}t`);
      assert.strictEqual(result[0].distance, 0);
    });

    it('teh -> the at distance 2', () => {
      // Standard Levenshtein distance (no transposition): "teh"->"the" = 2
      // (delete 'e' + insert 'e', or two substitutions).
      const speller = new SymSpell();
      speller.createDictionaryEntry('the', 1000);

      const result = speller.lookup('teh', undefined, 'top');
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].term, 'the');
      assert.strictEqual(result[0].distance, 2);
    });

    it('bith with dictionary containing both', () => {
      const speller = new SymSpell();
      speller.createDictionaryEntry('both', 1000);

      const result = speller.lookup('bith', undefined, 'top');

      // "bith" -> edits on prefix "bith" (length 4, all of it since prefixLength=7 > 4)
      //   delete count 1: "ith", "bth", "bih", "bit"
      //   delete count 2: "th", "ih", "it", "bh", "bt", "bi"
      // "both" index has delete keys of "both":
      //   delete count 1: "oth", "bth", "boh", "bot"
      //   delete count 2: "th", "oh", "ot", "bh", "bt", "bo"
      // Common keys: "bth" (both delete key) and "bith" delete key
      // Levenshtein("bith", "both") = 1 (i->o substitution)
      // So result should be "both" at distance 1
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].term, 'both');
      assert.strictEqual(result[0].distance, 1);
    });

    it('lookup with verbosity all returns all suggestions within distance', () => {
      const speller = new SymSpell();
      speller.createDictionaryEntry('the', 1000);
      speller.createDictionaryEntry('they', 500);
      speller.createDictionaryEntry('then', 300);

      const result = speller.lookup('teh', undefined, 'all');
      // Standard Levenshtein (no transposition) with maxEditDistance=2:
      //   levenshtein("teh","the")  = 2  (insert h → delete e → the)
      //   levenshtein("teh","they") = 2  (insert h → match e → sub h→y)
      //   levenshtein("teh","then") = 2  (insert h → match e → sub h→n)
      // All three entries are within distance 2.
      assert.strictEqual(result.length, 3);
      assert.strictEqual(result[0].term, 'the');
      assert.strictEqual(result[0].distance, 2);
      assert.strictEqual(result[0].count, 1000);
      // Second and third are sorted by count descending.
      assert.strictEqual(result[1].term, 'they');
      assert.strictEqual(result[2].term, 'then');
    });

    it('empty lookup returns empty array', () => {
      const speller = new SymSpell();
      const result = speller.lookup('', undefined, 'top');
      assert.deepStrictEqual(result, []);
    });

    it('unknown word returns empty array', () => {
      const speller = new SymSpell();
      speller.createDictionaryEntry('hello', 100);
      const result = speller.lookup('zzzzz', undefined, 'top');
      assert.deepStrictEqual(result, []);
    });
  });

  describe('load-dictionary integration', () => {
    it('real dictionary: lookup("dont") returns "dont" at distance 0', async () => {
      // Build an index from the real dictionary and verify the dont regression.
      // This is a sanity check that the port works at scale.
      const speller = new SymSpell();

      // Load the real dictionary (non-canonical — as the Swift would do before Phase 2,
      // relying on the canonicalization boundary at the loader).
      const { loadDictionary } = await import('../lib/load-dictionary.mjs');
      const entries = loadDictionary();
      for (const { word, count } of entries) {
        speller.createDictionaryEntry(word, count);
      }

      const result = speller.lookup('dont', undefined, 'top');
      assert.ok(result.length >= 1, 'expected at least one result for "dont"');
      // "dont" is in the real dictionary as a standalone word
      const topResult = result[0];
      assert.strictEqual(topResult.distance, 0);
      assert.strictEqual(topResult.term, 'dont');
    });
  });
});
