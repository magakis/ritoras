import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { shouldCapitalizeNext } from '../lib/auto-capitalizer.mjs';

describe('AutoCapitalizer.shouldCapitalizeNext', () => {
  // ──────────────────────────────────────────────
  // Start of field
  // ──────────────────────────────────────────────
  describe('start of field', () => {
    it('empty context → capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext(''), true);
    });

    it('whitespace-only context → capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('   '), true);
      assert.strictEqual(shouldCapitalizeNext('\n\t'), true);
    });

    it('leading opening quote at sentence start → capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('"'), true);
      assert.strictEqual(shouldCapitalizeNext('«'), true);
      assert.strictEqual(shouldCapitalizeNext('( '), true);
    });
  });

  // ──────────────────────────────────────────────
  // Terminal punctuation (English)
  // ──────────────────────────────────────────────
  describe('terminal punctuation — English', () => {
    it('"." at end → capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('Hello.'), true);
      assert.strictEqual(shouldCapitalizeNext('Hello. '), true);
    });

    it('"!" and "?" at end → capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('Hello!'), true);
      assert.strictEqual(shouldCapitalizeNext('Hello?'), true);
    });

    it('trailing closing quotes/brackets are transparent', () => {
      assert.strictEqual(shouldCapitalizeNext('Hello."'), true);
      assert.strictEqual(shouldCapitalizeNext('Hello.\u{201D}'), true);
      assert.strictEqual(shouldCapitalizeNext('Hello!)\u{201D}'), true);
    });

    it('";" is mid-sentence in English → no capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('Hello;'), false);
    });
  });

  // ──────────────────────────────────────────────
  // Terminal punctuation (Greek)
  // ──────────────────────────────────────────────
  describe('terminal punctuation — Greek', () => {
    it('";" is the Greek question mark → capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('Καλημέρα;', 'greek'), true);
      assert.strictEqual(shouldCapitalizeNext('γιατί;', 'greek'), true);
    });

    it('"." / "!" / "?" still terminal', () => {
      assert.strictEqual(shouldCapitalizeNext('Καλημέρα.', 'greek'), true);
      assert.strictEqual(shouldCapitalizeNext('Καλημέρα!', 'greek'), true);
      assert.strictEqual(shouldCapitalizeNext('Καλημέρα?', 'greek'), true);
    });

    it('mid-word text → no capitalize (Greek)', () => {
      assert.strictEqual(shouldCapitalizeNext('γεια', 'greek'), false);
    });
  });

  // ──────────────────────────────────────────────
  // Non-sentence-ending periods
  // ──────────────────────────────────────────────
  describe('periods that are NOT sentence ends', () => {
    it('known abbreviation (English) suppresses capitalisation', () => {
      assert.strictEqual(shouldCapitalizeNext('e.g.'), false);
      assert.strictEqual(shouldCapitalizeNext('Mr.'), false);
      assert.strictEqual(shouldCapitalizeNext('etc.'), false);
      assert.strictEqual(shouldCapitalizeNext('i.e.'), false);
    });

    it('abbreviation set is skipped for Greek — "mr." behaves as a sentence end', () => {
      // Greek has no abbreviation table; the token passes through to the
      // verified-sentence-end path.
      assert.strictEqual(shouldCapitalizeNext('mr.', 'greek'), true);
    });

    it('single-letter initial suppresses capitalisation', () => {
      assert.strictEqual(shouldCapitalizeNext('A.'), false);
      assert.strictEqual(shouldCapitalizeNext('J.'), false);
    });

    it('multi-initial pattern suppresses capitalisation', () => {
      assert.strictEqual(shouldCapitalizeNext('J.K.'), false);
      assert.strictEqual(shouldCapitalizeNext('U.S.A.'), false);
    });

    it('decimal period does not capitalise', () => {
      assert.strictEqual(shouldCapitalizeNext('3.14'), false);
      assert.strictEqual(shouldCapitalizeNext('v1.2.3'), false);
    });

    it('period followed by more token text (Hello.etc) does not capitalise', () => {
      // The trailing character is a letter, not the period — the default
      // mid-word path returns false.
      assert.strictEqual(shouldCapitalizeNext('Hello.etc'), false);
    });
  });

  // ──────────────────────────────────────────────
  // Mid-sentence punctuation
  // ──────────────────────────────────────────────
  describe('mid-sentence punctuation', () => {
    it('comma / colon / dash / ellipsis never capitalise', () => {
      assert.strictEqual(shouldCapitalizeNext('Hello,'), false);
      assert.strictEqual(shouldCapitalizeNext('Hello:'), false);
      assert.strictEqual(shouldCapitalizeNext('Hello -'), false);
      assert.strictEqual(shouldCapitalizeNext('Hello…'), false);
    });
  });

  // ──────────────────────────────────────────────
  // Default
  // ──────────────────────────────────────────────
  describe('default', () => {
    it('mid-word or mid-sentence letters → no capitalize', () => {
      assert.strictEqual(shouldCapitalizeNext('hello'), false);
      assert.strictEqual(shouldCapitalizeNext('Hello world'), false);
      assert.strictEqual(shouldCapitalizeNext('hello '), false);
    });

    it('unbounded context is truncated to the 200-char lookback', () => {
      const filler = 'a'.repeat(250);
      const context = `${filler}.`;
      assert.strictEqual(shouldCapitalizeNext(context), true);
    });
  });
});
