import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { extract } from '../lib/recent-words-extractor.mjs';

describe('RecentWordsExtractor.extract (JS port)', () => {

  describe('empty / null context', () => {
    it('extract(null) -> []', () => {
      assert.deepStrictEqual(extract(null), []);
    });

    it('extract(undefined) -> []', () => {
      assert.deepStrictEqual(extract(undefined), []);
    });

    it('extract("") -> []', () => {
      assert.deepStrictEqual(extract(''), []);
    });
  });

  describe('maxCount guards', () => {
    it('extract("hello ", 0) -> []', () => {
      assert.deepStrictEqual(extract('hello ', 0), []);
    });

    it('extract("hello ", -1) -> []', () => {
      assert.deepStrictEqual(extract('hello ', -1), []);
    });
  });

  describe('single committed word', () => {
    it('extract("hello ") — one word, offset 1', () => {
      assert.deepStrictEqual(extract('hello '), [
        { word: 'hello', lookupWord: 'hello', offsetFromCursorEnd: 1 },
      ]);
    });
  });

  describe('multiple committed words', () => {
    it('extract("one two three ") — three words, most recent first, offsets grow', () => {
      assert.deepStrictEqual(extract('one two three '), [
        { word: 'three', lookupWord: 'three', offsetFromCursorEnd: 1 },
        { word: 'two', lookupWord: 'two', offsetFromCursorEnd: 7 },
        { word: 'one', lookupWord: 'one', offsetFromCursorEnd: 11 },
      ]);
    });

    it('offsetFromCursorEnd is smallest for the most recent word (correctness anchor)', () => {
      const result = extract('one two three ');
      assert.strictEqual(result.length, 3);
      assert.ok(result[0].offsetFromCursorEnd < result[1].offsetFromCursorEnd);
      assert.ok(result[1].offsetFromCursorEnd < result[2].offsetFromCursorEnd);
    });
  });

  describe('trailing punctuation', () => {
    it('extract("recieve, please. ") — display keeps punctuation, lookup strips it, offsets point at body end', () => {
      assert.deepStrictEqual(extract('recieve, please. '), [
        { word: 'please.', lookupWord: 'please', offsetFromCursorEnd: 2 },
        { word: 'recieve,', lookupWord: 'recieve', offsetFromCursorEnd: 10 },
      ]);
    });

    it('extract("hello  ") — multiple trailing spaces counted in the offset', () => {
      assert.deepStrictEqual(extract('hello  '), [
        { word: 'hello', lookupWord: 'hello', offsetFromCursorEnd: 2 },
      ]);
    });

    it('extract("!!! ") — punctuation-only token: lookup falls back to the display form', () => {
      assert.deepStrictEqual(extract('!!! '), [
        { word: '!!!', lookupWord: '!!!', offsetFromCursorEnd: 1 },
      ]);
    });
  });

  describe('apostrophes (don\u2019t handling)', () => {
    it('extract("don\'t ") — U+0027 canonicalized to U+2019 in lookupWord', () => {
      const result = extract("don't ");
      assert.strictEqual(result.length, 1);
      assert.strictEqual(result[0].word, "don't");
      assert.strictEqual(result[0].lookupWord, "don\u{2019}t");
      assert.strictEqual(result[0].lookupWord.charCodeAt(3), 0x2019);
      assert.strictEqual(result[0].offsetFromCursorEnd, 1);
    });

    it('extract("dont ") — no apostrophe: lookupWord unchanged', () => {
      assert.deepStrictEqual(extract('dont '), [
        { word: 'dont', lookupWord: 'dont', offsetFromCursorEnd: 1 },
      ]);
    });

    it('extract("don\u{2019}t ") — already-canonical apostrophe is a no-op', () => {
      const result = extract("don\u{2019}t ");
      assert.strictEqual(result[0].word, "don\u{2019}t");
      assert.strictEqual(result[0].lookupWord, "don\u{2019}t");
    });

    it('extract("James\' ") — trailing apostrophe stripped from a FINISHED word; body ends 2 chars before cursor', () => {
      assert.deepStrictEqual(extract("James' "), [
        { word: "James'", lookupWord: 'James', offsetFromCursorEnd: 2 },
      ]);
    });

    it('extract("cats\' ") — possessive trailing apostrophe stripped from a FINISHED word; body ends 2 chars before cursor', () => {
      assert.deepStrictEqual(extract("cats' "), [
        { word: "cats'", lookupWord: 'cats', offsetFromCursorEnd: 2 },
      ]);
    });
  });

  describe('cursor mid-word', () => {
    it('extract("the quick bro") — in-progress word excluded, committed words kept', () => {
      assert.deepStrictEqual(extract('the quick bro'), [
        { word: 'quick', lookupWord: 'quick', offsetFromCursorEnd: 4 },
        { word: 'the', lookupWord: 'the', offsetFromCursorEnd: 10 },
      ]);
    });

    it('extract("hello") — only an in-progress word: empty result', () => {
      assert.deepStrictEqual(extract('hello'), []);
    });
  });

  describe('maxCount cap', () => {
    it('extract("one two three four five ", 3) — keeps the 3 most recent', () => {
      assert.deepStrictEqual(extract('one two three four five ', 3), [
        { word: 'five', lookupWord: 'five', offsetFromCursorEnd: 1 },
        { word: 'four', lookupWord: 'four', offsetFromCursorEnd: 6 },
        { word: 'three', lookupWord: 'three', offsetFromCursorEnd: 11 },
      ]);
    });
  });

  describe('non-space whitespace separators', () => {
    it('extract("one\\ttwo\\nthree") — tab and newline are token boundaries', () => {
      assert.deepStrictEqual(extract('one\ttwo\nthree'), [
        { word: 'two', lookupWord: 'two', offsetFromCursorEnd: 6 },
        { word: 'one', lookupWord: 'one', offsetFromCursorEnd: 10 },
      ]);
    });
  });
});
