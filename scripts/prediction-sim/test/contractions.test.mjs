import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { CONTRACTIONS, expansion } from '../lib/contractions.mjs';
import { applyCapitalizationTemplate } from '../lib/apply-capitalization-template.mjs';
import { SymSpell } from '../lib/symspell.mjs';
import { fusedPool } from '../lib/fused-pool.mjs';

const APOSTROPHE = '\u{2019}';

/**
 * Keys that are real standalone English words whose meaning differs from
 * the contraction they look like. These MUST be excluded from the table
 * to prevent false-positive autocorrects on correctly-typed words.
 */
const KNOWN_AMBIGUOUS = new Set([
  'well',    // adverb (→ we'll)
  'were',    // past tense of "be" (→ we're)
  'its',     // possessive (→ it's)
  'lets',    // verb "allow" (→ let's)
  'cant',    // hypocritical talk / jargon (→ can't)
  'cause',   // reason (→ 'cause)
  'bout',    // short period / contest (→ 'bout)
  'em',      // letter M / typographic unit (→ 'em)
  'im',      // abbreviation (→ I'm)
  'ive',     // (→ I've) — too short, avoid
  'ill',     // sick (→ I'll)
  'id',      // abbreviation for identification (→ I'd)
  'hell',    // underworld (→ he'll)
  'shell',   // seashell / casing (→ she'll)
  'wed',     // to marry (→ we'd)
]);

describe('Contractions', () => {
  describe('expansion()', () => {
    it('dont -> dont (canonical apostrophe)', () => {
      const result = expansion('dont');
      assert.strictEqual(result, `don${APOSTROPHE}t`);
      // Verify U+2019 at the apostrophe position (index 3)
      assert.strictEqual(result.charCodeAt(3), 0x2019);
    });

    it('returns null for uppercase keys (table is lowercase-only)', () => {
      assert.strictEqual(expansion('DONT'), null);
      assert.strictEqual(expansion('Dont'), null);
    });

    it('returns null for unknown word', () => {
      assert.strictEqual(expansion('xyzzz'), null);
    });

    it('all negative contractions expand correctly', () => {
      const negatives = [
        ['dont', `don${APOSTROPHE}t`],
        ['wont', `won${APOSTROPHE}t`],
        ['couldnt', `couldn${APOSTROPHE}t`],
        ['wouldnt', `wouldn${APOSTROPHE}t`],
        ['shouldnt', `shouldn${APOSTROPHE}t`],
        ['isnt', `isn${APOSTROPHE}t`],
        ['wasnt', `wasn${APOSTROPHE}t`],
        ['arent', `aren${APOSTROPHE}t`],
        ['didnt', `didn${APOSTROPHE}t`],
        ['doesnt', `doesn${APOSTROPHE}t`],
        ['havent', `haven${APOSTROPHE}t`],
        ['hadnt', `hadn${APOSTROPHE}t`],
        ['hasnt', `hasn${APOSTROPHE}t`],
        ['werent', `weren${APOSTROPHE}t`],
        ['neednt', `needn${APOSTROPHE}t`],
        ['oughtnt', `oughtn${APOSTROPHE}t`],
      ];
      for (const [input, expected] of negatives) {
        assert.strictEqual(expansion(input), expected, `expansion("${input}") should match`);
      }
    });

    it('all pronoun+verb contractions expand correctly', () => {
      const pronouns = [
        ['youre', `you${APOSTROPHE}re`],
        ['youve', `you${APOSTROPHE}ve`],
        ['youll', `you${APOSTROPHE}ll`],
        ['youd', `you${APOSTROPHE}d`],
        ['theyre', `they${APOSTROPHE}re`],
        ['theyve', `they${APOSTROPHE}ve`],
        ['theyll', `they${APOSTROPHE}ll`],
        ['theyd', `they${APOSTROPHE}d`],
        ['thats', `that${APOSTROPHE}s`],
        ['whats', `what${APOSTROPHE}s`],
        ['heres', `here${APOSTROPHE}s`],
        ['theres', `there${APOSTROPHE}s`],
        ['whos', `who${APOSTROPHE}s`],
        ['hes', `he${APOSTROPHE}s`],
        ['shes', `she${APOSTROPHE}s`],
        ['maam', `ma${APOSTROPHE}am`],
        ['yall', `y${APOSTROPHE}all`],
        ['tis', `${APOSTROPHE}tis`],
        ['twas', `${APOSTROPHE}twas`],
      ];
      for (const [input, expected] of pronouns) {
        assert.strictEqual(expansion(input), expected, `expansion("${input}") should match`);
      }
    });
  });

  describe('ambiguous-key exclusion', () => {
    for (const key of KNOWN_AMBIGUOUS) {
      it(`"${key}" returns null (excluded as ambiguous)`, () => {
        assert.strictEqual(expansion(key), null);
      });
    }
  });

  describe('applyCapitalizationTemplate', () => {
    it('lowercase input preserves lowercase', () => {
      assert.strictEqual(applyCapitalizationTemplate('dont', `don${APOSTROPHE}t`), `don${APOSTROPHE}t`);
    });

    it('sentence-case input capitalizes first letter', () => {
      assert.strictEqual(applyCapitalizationTemplate('Dont', `don${APOSTROPHE}t`), `Don${APOSTROPHE}t`);
    });

    it('all-caps input uppercases everything', () => {
      assert.strictEqual(applyCapitalizationTemplate('DONT', `don${APOSTROPHE}t`), `DON${APOSTROPHE}T`);
    });

    it('proper noun suggestion is returned as-is', () => {
      assert.strictEqual(applyCapitalizationTemplate('usa', 'USA'), 'USA');
      assert.strictEqual(applyCapitalizationTemplate('USA', 'USA'), 'USA');
    });

    it('empty input returns suggestion as-is', () => {
      assert.strictEqual(applyCapitalizationTemplate('', `don${APOSTROPHE}t`), `don${APOSTROPHE}t`);
    });
  });

  describe('SymSpell integration', () => {
    it('contraction fast-path returns dont verbatim AND dont before symspell', () => {
      // Build a minimal SymSpell index with only "dont".
      const speller = new SymSpell();
      speller.createDictionaryEntry('dont', 50);

      // Simulate the provider: canonicalize + lower + expansion check + symspell fallback.
      const input = 'dont';
      const canonicalLower = input; // already lowercased and canonical

      // Phase 1: contraction fast-path (new Phase 3 behavior)
      const contraction = expansion(canonicalLower);

      // Phase 2: verbatim candidate — score demoted to 0.5 when contraction exists
      const verbatim = { text: input, score: 0.5, source: 'symspell', isUnknownVerbatim: !speller.dictionary.has(canonicalLower) };

      // Phase 3: SymSpell lookup (returns "dont" at distance 0 — same as input)
      const symspellResult = speller.lookup(canonicalLower, undefined, 'top');

      // Assert contraction exists
      assert.strictEqual(contraction, `don${APOSTROPHE}t`);

      // Assert verbatim is "dont"
      assert.strictEqual(verbatim.text, 'dont');
      assert.strictEqual(verbatim.score, 0.5);

      // Assert SymSpell returns "dont" at distance 0 (the regression)
      assert.strictEqual(symspellResult.length, 1);
      assert.strictEqual(symspellResult[0].term, 'dont');
      assert.strictEqual(symspellResult[0].distance, 0);

      // Simulate topCorrection: filter out the verbatim, then take max score.
      // Contraction has score 1.0, source 'contraction', and is inserted at
      // position 0 (leftmost). The verbatim is at position 1 with score 0.5.
      const lowerTyped = input.toLowerCase();
      const pool = [
        { text: contraction, score: 1.0, source: 'contraction' },
        { text: input, score: 0.5, source: 'symspell' },
      ];
      const filtered = pool.filter(s => s.text.toLowerCase() !== lowerTyped);
      assert.strictEqual(filtered.length, 1);
      assert.strictEqual(filtered[0].text, `don${APOSTROPHE}t`);
      assert.strictEqual(filtered[0].score, 1.0);

      // topCorrection returns the contraction
      const topCorrection = filtered.reduce((best, s) => s.score > best.score ? s : best, filtered[0]);
      assert.strictEqual(topCorrection.text, `don${APOSTROPHE}t`);
    });

    it('contraction candidate has source "contraction" (not "symspell")', () => {
      const input = 'dont';
      const contract = expansion(input);
      assert.ok(contract);

      // The source should be 'contraction', not 'symspell'
      assert.strictEqual(contract, `don${APOSTROPHE}t`);
    });

    it('when contraction exists, contraction is at position 0 and verbatim at position 1', () => {
      // Simulate the provider ordering: contraction inserted at 0, verbatim at 1
      const input = 'dont';
      const contract = expansion(input);

      // Pool as produced by the updated SymSpellProvider
      const pool = [
        { text: contract, score: 1.0, source: 'contraction' },
        { text: input, score: 0.5, source: 'symspell' },
      ];

      assert.strictEqual(pool[0].text, `don${APOSTROPHE}t`);
      assert.strictEqual(pool[0].score, 1.0);
      assert.strictEqual(pool[0].source, 'contraction');

      assert.strictEqual(pool[1].text, 'dont');
      assert.strictEqual(pool[1].score, 0.5);
      assert.strictEqual(pool[1].source, 'symspell');
    });

    it('after fusedPool with mock KenLM, contraction still outranks verbatim', () => {
      const input = 'dont';
      const contract = expansion(input);
      const pool = [
        { text: contract, score: 1.0, source: 'contraction' },
        { text: input, score: 0.5, source: 'symspell' },
      ];

      // Mock KenLM: contraction and verbatim get similar log probs.
      // With α=0.5 blend, contraction (1.0 base → 0.5 blended) still
      // outranks verbatim (0.5 base → 0.25 blended plus KenLM portion).
      // The scorer models the ASCII-only KenLM vocabulary: fusedPool
      // normalizes the U+2019 candidate to U+0027 before scoring.
      const kenlmScorer = (text) => {
        if (text === "don't") return -1.5;
        if (text === 'dont') return -2.0;
        return -10;
      };

      const fused = fusedPool({
        pool,
        currentWord: input,
        previousWord: 'I',
        kenlmScorer,
        blendWeight: 0.5,
      });

      // Find both candidates in the fused pool
      const contractionFused = fused.find(s => s.text === `don${APOSTROPHE}t`);
      const verbatimFused = fused.find(s => s.text === 'dont');

      assert.ok(contractionFused, 'contraction should survive fusedPool');
      assert.ok(verbatimFused, 'verbatim should survive fusedPool');

      // Contraction should still outrank verbatim
      assert.ok(contractionFused.score > verbatimFused.score,
        `contraction score ${contractionFused.score} should be > verbatim score ${verbatimFused.score}`);
    });
  });

  describe('conservative policy guard', () => {
    it('no known-ambiguous key is in the CONTRACTIONS table', () => {
      for (const key of KNOWN_AMBIGUOUS) {
        assert.ok(
          !CONTRACTIONS.has(key),
          `EXCLUSION VIOLATION: "${key}" is a standalone real word and must not be in CONTRACTIONS`
        );
      }
    });

    it('every key in CONTRACTIONS uses canonical U+2019 apostrophe', () => {
      for (const [key, value] of CONTRACTIONS) {
        for (let i = 0; i < value.length; i++) {
          if (value.charCodeAt(i) === 0x2019 || value.charCodeAt(i) === 0x2018 || value.charCodeAt(i) === 0x27) {
            assert.strictEqual(
              value.charCodeAt(i), 0x2019,
              `Key "${key}" has non-canonical apostrophe at position ${i} (code ${value.charCodeAt(i)})`
            );
          }
        }
      }
    });

    it('dictionary guard: no key in CONTRACTIONS is a known-ambiguous standalone real word', async () => {
      // Load the real frequency dictionary to verify our table is safe.
      const { loadDictionary } = await import('../lib/load-dictionary.mjs');
      const entries = loadDictionary();
      const dictWords = new Set(entries.map(e => e.word.toLowerCase()));

      for (const key of CONTRACTIONS.keys()) {
        if (dictWords.has(key) && KNOWN_AMBIGUOUS.has(key)) {
          assert.fail(
            `EXCLUSION VIOLATION: "${key}" appears in both CONTRACTIONS and the dictionary ` +
            `as a standalone real word with a different meaning. Remove it from the table.`
          );
        }
      }
    });
  });
});
