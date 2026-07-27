import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { SymSpell } from '../lib/symspell.mjs';
import { SymSpellProvider, DEFAULTS } from '../lib/symspell-provider.mjs';
import { CANONICAL_APOSTROPHE } from '../lib/text-normalization.mjs';

describe('SymSpellProvider', () => {
  describe('suggest() — scoring with QwertyGeometry', () => {
    it('"bith" returns "both" scored ≈ 0.607, ranked above "bath"', () => {
      const speller = new SymSpell(2, 7);
      speller.createDictionaryEntry('both', 5000);
      speller.createDictionaryEntry('bath', 3000);

      // Dictionary map for isRealWord check (neither "bith" nor "bath"/"both" — wait,
      // both and bath ARE in the dictionary. But for isRealWord, we check the TYPED word.
      // "bith" is not in the dict, so isRealWord=false.
      const dict = new Map([
        ['both', { count: 5000 }],
        ['bath', { count: 3000 }],
      ]);

      const provider = new SymSpellProvider(speller, dict);

      const results = provider.suggest('bith', { verbosity: 'all' });

      // Should include verbatim "bith" at score 1.0
      const verbatim = results.find(s => s.text === 'bith');
      assert.ok(verbatim, 'result should include verbatim "bith"');
      assert.strictEqual(verbatim.score, 1.0);

      // Should include "both" with QwertyGeometry score ≈ 0.607
      const both = results.find(s => s.text === 'both');
      assert.ok(both, 'result should include "both"');
      assert.ok(Math.abs(both.score - 0.607) < 0.01,
        `"both" score ${both.score} ≈ 0.607`);

      // Should include "bath" with QwertyGeometry score ≈ 0.223
      const bath = results.find(s => s.text === 'bath');
      assert.ok(bath, 'result should include "bath"');
      assert.ok(Math.abs(bath.score - 0.223) < 0.01,
        `"bath" score ${bath.score} ≈ 0.223`);

      // "both" should be ranked above "bath"
      const bothIdx = results.indexOf(both);
      const bathIdx = results.indexOf(bath);
      assert.ok(bothIdx < bathIdx,
        `"both" (index ${bothIdx}) should be ranked above "bath" (index ${bathIdx})`);

      // "bith" (score 1.0) should be first
      assert.strictEqual(results[0].text, 'bith');
    });

    it('"dont" returns verbatim + contraction "don\'t" when "dont" is a real word', () => {
      const speller = new SymSpell(2, 7);
      speller.createDictionaryEntry('dont', 5000);
      speller.createDictionaryEntry(`don${CANONICAL_APOSTROPHE}t`, 100);

      // "dont" has count 5000 ≥ 2000 → isRealWord
      const dict = new Map([
        ['dont', { count: 5000 }],
      ]);

      const provider = new SymSpellProvider(speller, dict);

      const results = provider.suggest('dont', { verbosity: 'all' });

      // Verbatim "dont" at score 1.0
      const verbatim = results.find(s => s.text === 'dont');
      assert.ok(verbatim, 'result should include verbatim "dont"');
      assert.strictEqual(verbatim.score, 1.0);

      // Contraction "don't" at score 0.9
      const contraction = results.find(s => s.text === `don${CANONICAL_APOSTROPHE}t`);
      assert.ok(contraction, 'result should include contraction "don\'t"');
      assert.strictEqual(contraction.score, 0.9);
      assert.strictEqual(contraction.source, 'symspell');
      assert.strictEqual(contraction.distance, 0);

      // "dont" is a real word (high count), so no SymSpell corrections
      // Results should be exactly 2: verbatim + contraction
      assert.strictEqual(results.length, 2,
        `expected 2 results (verbatim + contraction), got ${results.length}`);

      // "dont" should be ranked first (score 1.0 > 0.9)
      assert.strictEqual(results[0].text, 'dont');
    });

    it('"dont" with low count returns SymSpell corrections, contraction at 0.9', () => {
      const speller = new SymSpell(2, 7);
      speller.createDictionaryEntry('dont', 50);
      // NOTE: don't is deliberately NOT in the SymSpell dictionary here.
      // The contraction table (contractions.mjs) provides "don't" at score 0.9
      // independently of SymSpell. If we added it to SymSpell, QwertyGeometry
      // would give it score 1.0 (apostrophe insertion cost = 0), masking the
      // contraction-path score.

      const dict = new Map([
        ['dont', { count: 50 }],        // 50 < 2000 → not a real word
      ]);

      const provider = new SymSpellProvider(speller, dict);

      const results = provider.suggest('dont', { verbosity: 'all' });

      // Verbatim "dont" at score 1.0
      const verbatim = results.find(s => s.text === 'dont');
      assert.ok(verbatim, 'result should include verbatim "dont"');
      assert.strictEqual(verbatim.score, 1.0);

      // Contraction "don't" at score 0.9 (from contraction table, not SymSpell)
      const contraction = results.find(s => s.text === `don${CANONICAL_APOSTROPHE}t`);
      assert.ok(contraction, 'result should include contraction "don\'t"');
      assert.strictEqual(contraction.score, 0.9);

      // Since "dont" is not a real word, SymSpell corrections are returned.
      assert.ok(results.length >= 2, `expected at least 2 results, got ${results.length}`);
    });

    it('"teh" returns "the" with transposition-discounted score', () => {
      const speller = new SymSpell(2, 7);
      speller.createDictionaryEntry('the', 100000);

      const dict = new Map([
        ['the', { count: 100000 }],
      ]);

      const provider = new SymSpellProvider(speller, dict);

      const results = provider.suggest('teh', { verbosity: 'all' });

      // Verbatim "teh" at score 1.0
      const verbatim = results.find(s => s.text === 'teh');
      assert.ok(verbatim, 'result should include verbatim "teh"');
      assert.strictEqual(verbatim.score, 1.0);

      // "the" should be scored with QwertyGeometry transposition discount
      const theResult = results.find(s => s.text === 'the');
      assert.ok(theResult, 'result should include "the"');
      // score("teh", "the", 2, 1.5) ≈ 0.122
      assert.ok(Math.abs(theResult.score - 0.122) < 0.01,
        `"the" score ${theResult.score} ≈ 0.122`);
    });
  });

  describe('suggest() — edge cases', () => {
    it('empty word returns empty array', () => {
      const speller = new SymSpell();
      const provider = new SymSpellProvider(speller, new Map());
      const results = provider.suggest('');
      assert.deepStrictEqual(results, []);
    });

    it('unknown word with no corrections returns only verbatim', () => {
      const speller = new SymSpell();
      const provider = new SymSpellProvider(speller, new Map());
      const results = provider.suggest('zzzzz', { verbosity: 'all' });
      assert.strictEqual(results.length, 1);
      assert.strictEqual(results[0].text, 'zzzzz');
      assert.strictEqual(results[0].score, 1.0);
    });

    it('correctly spelled real word returns only verbatim + contraction (if applicable)', () => {
      const speller = new SymSpell(2, 7);
      speller.createDictionaryEntry('hello', 10000);
      speller.createDictionaryEntry('world', 20000);

      const dict = new Map([
        ['hello', { count: 10000 }],
        ['world', { count: 20000 }],
      ]);

      const provider = new SymSpellProvider(speller, dict);

      // "hello" is a real word (10000 ≥ 2000)
      const results = provider.suggest('hello', { verbosity: 'all' });

      // Only verbatim — no contraction for "hello", and no SymSpell corrections (isRealWord)
      assert.strictEqual(results.length, 1);
      assert.strictEqual(results[0].text, 'hello');
      assert.strictEqual(results[0].score, 1.0);
    });
  });

  describe('DEFAULTS', () => {
    it('matches SharedConfig.Defaults', () => {
      assert.strictEqual(DEFAULTS.beta, 1.5, 'qwertyDistanceBeta');
      assert.strictEqual(DEFAULTS.doublingDiscount, 0.5, 'qwertyDoublingDiscount');
      assert.strictEqual(DEFAULTS.transpositionDiscount, 0.7, 'qwertyTranspositionDiscount');
    });
  });
});
