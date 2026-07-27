import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { extract } from '../lib/current-word-extractor.mjs';

describe('CurrentWordExtractor.extract (JS port)', () => {

  describe('mid-word (cursor not at boundary)', () => {
    it('extract("for bith") — canonical "for bith" test', () => {
      const result = extract('for bith');
      assert.strictEqual(result.currentWord, 'bith');
      assert.strictEqual(result.lookupWord, 'bith');
      assert.strictEqual(result.previousWord, 'for');
      assert.strictEqual(result.previousWord2, null);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('strips leading straight double-quote', () => {
      const result = extract('"hello');
      assert.strictEqual(result.currentWord, '"hello');
      assert.strictEqual(result.lookupWord, 'hello');
      assert.strictEqual(result.previousWord, null);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('strips leading curly apostrophe-quote U+2019 (as in \'em)', () => {
      const input = '\u{2019}em';
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, 'em');
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('preserves interior apostrophe U+0027 and canonicalizes (don\'t)', () => {
      const input = "don't";  // U+0027
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, "don\u{2019}t");
      assert.strictEqual(result.lookupWord.charCodeAt(3), 0x2019);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('preserves interior apostrophe (O\'Brien)', () => {
      const input = "O'Brien";  // U+0027
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, "O\u{2019}Brien");
      assert.strictEqual(result.lookupWord.charCodeAt(1), 0x2019);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('preserves trailing possessive apostrophe (James\')', () => {
      const input = "James'";  // U+0027
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, "James\u{2019}");
      assert.strictEqual(result.lookupWord.charCodeAt(5), 0x2019);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('preserves possessive apostrophe (cat\'s)', () => {
      const input = "cat's";  // U+0027
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, "cat\u{2019}s");
      assert.strictEqual(result.lookupWord.charCodeAt(3), 0x2019);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('strips two leading double-quotes (the double-quote bug)', () => {
      const input = '""hello';
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, 'hello');
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('canonicalize is no-op when apostrophe is already U+2019', () => {
      const input = "don\u{2019}t";
      const result = extract(input);
      assert.strictEqual(result.currentWord, input);
      assert.strictEqual(result.lookupWord, input);
      assert.strictEqual(result.isAtWordBoundary, false);
    });

    it('extracts previousWord and previousWord2 from context with 3 tokens', () => {
      const result = extract('the quick brown');
      assert.strictEqual(result.currentWord, 'brown');
      assert.strictEqual(result.lookupWord, 'brown');
      assert.strictEqual(result.previousWord, 'quick');
      assert.strictEqual(result.previousWord2, 'the');
      assert.strictEqual(result.isAtWordBoundary, false);
    });
  });

  describe('cursor at word boundary (trailing space)', () => {
    it('extract("hello, ") — trailing space, comma stripped from previous', () => {
      const result = extract('hello, ');
      assert.strictEqual(result.currentWord, '');
      assert.strictEqual(result.lookupWord, '');
      assert.strictEqual(result.previousWord, 'hello');
      assert.strictEqual(result.previousWord2, null);
      assert.strictEqual(result.isAtWordBoundary, true);
    });

    it('extract("cats\' ") — trailing apostrophe stripped from FINISHED word', () => {
      const input = "cats' ";  // U+0027 trailing possessive in finished word
      const result = extract(input);
      assert.strictEqual(result.currentWord, '');
      assert.strictEqual(result.lookupWord, '');
      // stripTrailingPunctuation strips ALL punctuation from finished words,
      // including apostrophes. This is the EXISTING behavior and must NOT change.
      assert.strictEqual(result.previousWord, 'cats');
      assert.strictEqual(result.isAtWordBoundary, true);
    });

    it('extract("") — empty context', () => {
      const result = extract('');
      assert.strictEqual(result.currentWord, '');
      assert.strictEqual(result.lookupWord, '');
      assert.strictEqual(result.previousWord, null);
      assert.strictEqual(result.previousWord2, null);
      assert.strictEqual(result.isAtWordBoundary, true);
    });

    it('extract(null) — null context', () => {
      const result = extract(null);
      assert.strictEqual(result.currentWord, '');
      assert.strictEqual(result.lookupWord, '');
      assert.strictEqual(result.previousWord, null);
      assert.strictEqual(result.previousWord2, null);
      assert.strictEqual(result.isAtWordBoundary, true);
    });

    it('extract(undefined) — undefined context', () => {
      const result = extract(undefined);
      assert.strictEqual(result.currentWord, '');
      assert.strictEqual(result.lookupWord, '');
      assert.strictEqual(result.previousWord, null);
      assert.strictEqual(result.previousWord2, null);
      assert.strictEqual(result.isAtWordBoundary, true);
    });

    it('extract("hello world ") — trailing space, two previous words', () => {
      const result = extract('hello world ');
      assert.strictEqual(result.currentWord, '');
      assert.strictEqual(result.lookupWord, '');
      assert.strictEqual(result.previousWord, 'world');
      assert.strictEqual(result.previousWord2, 'hello');
      assert.strictEqual(result.isAtWordBoundary, true);
    });

    it('extract("hello world") — no trailing space, mid-word', () => {
      const result = extract('hello world');
      assert.strictEqual(result.currentWord, 'world');
      assert.strictEqual(result.lookupWord, 'world');
      assert.strictEqual(result.previousWord, 'hello');
      assert.strictEqual(result.previousWord2, null);
      assert.strictEqual(result.isAtWordBoundary, false);
    });
  });

  describe('edge cases', () => {
    it('previousWord null when only one token', () => {
      const result = extract('hello');
      assert.strictEqual(result.currentWord, 'hello');
      assert.strictEqual(result.previousWord, null);
      assert.strictEqual(result.previousWord2, null);
    });

    it('strips leading guillemet', () => {
      const result = extract('\u{00AB}bonjour');
      assert.strictEqual(result.lookupWord, 'bonjour');
      assert.strictEqual(result.currentWord, '\u{00AB}bonjour');
    });

    it('strips leading CJK corner bracket', () => {
      const result = extract('\u{300C}word');
      assert.strictEqual(result.lookupWord, 'word');
      assert.strictEqual(result.currentWord, '\u{300C}word');
    });
  });
});
