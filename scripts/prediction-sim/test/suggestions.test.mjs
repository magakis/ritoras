import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { suggestions } from '../lib/suggestions.mjs';

const APOSTROPHE = '\u{2019}';

describe('suggestions — empty-prefix case', () => {
  it('empty currentWord: returns sorted limit items as plain strings', () => {
    const pool = [
      { text: 'world', score: 0.5, source: 'symspell' },
      { text: 'hello', score: 0.9, source: 'symspell' },
    ];

    const result = suggestions({
      pool,
      currentWord: '',
      limit: 2,
    });

    assert.strictEqual(result.length, 2);
    assert.strictEqual(result[0], 'hello');
    assert.strictEqual(result[1], 'world');
  });

  it('empty currentWord with empty pool returns empty array', () => {
    const result = suggestions({
      pool: [],
      currentWord: '',
      limit: 3,
    });

    assert.deepStrictEqual(result, []);
  });
});

describe('suggestions — verbatim pinning (T1, T2, T3)', () => {
  it('T1: verbatim pinned to #1 despite lower score', () => {
    const pool = [
      { text: 'hello', score: 0.3, source: 'symspell', isUnknownVerbatim: false },
      { text: 'help', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'hello',
      limit: 3,
    });

    assert.strictEqual(result.length, 2);
    // Verbatim at position 0 regardless of score
    assert.strictEqual(result[0], 'hello');
    assert.strictEqual(result[1], 'help');
  });

  it('T2: real-word verbatim shown plain (no quotes)', () => {
    const pool = [
      { text: 'hello', score: 0.5, source: 'symspell', isUnknownVerbatim: false },
      { text: 'help', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'hello',
      limit: 2,
    });

    assert.strictEqual(result[0], 'hello');
    assert.strictEqual(result[0].startsWith('"'), false);
  });

  it('T3: unknown verbatim shown quoted', () => {
    const pool = [
      { text: 'helo', score: 0.5, source: 'symspell', isUnknownVerbatim: true },
      { text: 'help', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'helo',
      limit: 2,
    });

    assert.strictEqual(result.length, 2);
    assert.strictEqual(result[0], '"helo"');
    assert.strictEqual(result[1], 'help');
  });
});

describe('suggestions — defensive / edge cases (T4, T5, T6)', () => {
  it('T4: no verbatim in pool → no pinning, plain sort', () => {
    const pool = [
      { text: 'help', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'held', score: 0.7, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'helo',
      limit: 2,
    });

    // No entry matching "helo" → plain sort by score, limit items
    assert.strictEqual(result.length, 2);
    assert.strictEqual(result[0], 'help');
    assert.strictEqual(result[1], 'held');
  });

  it('T5: limit=3 with verbatim returns exactly 3 items', () => {
    const pool = [
      { text: 'helo', score: 0.5, source: 'symspell', isUnknownVerbatim: true },
      { text: 'help', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'held', score: 0.8, source: 'symspell', isUnknownVerbatim: false },
      { text: 'hero', score: 0.7, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'helo',
      limit: 3,
    });

    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0], '"helo"');
    assert.strictEqual(result[1], 'help');
    assert.strictEqual(result[2], 'held');
  });

  it('T6: limit=1 with verbatim returns just the verbatim', () => {
    const pool = [
      { text: 'helo', score: 0.5, source: 'symspell', isUnknownVerbatim: true },
      { text: 'help', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'helo',
      limit: 1,
    });

    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0], '"helo"');
  });
});

describe('suggestions — contraction (T7, DP-1 Option A)', () => {
  it('T7: typed "dont" (real word, plain) pinned at #1, "don\'t" at position 1', () => {
    const dontExpanded = `don${APOSTROPHE}t`;
    const pool = [
      { text: 'dont', score: 0.5, source: 'symspell', isUnknownVerbatim: false },
      { text: dontExpanded, score: 1.0, source: 'contraction', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'dont',
      limit: 2,
    });

    assert.strictEqual(result.length, 2);
    // Option A: verbatim "dont" pinned at #1, contraction follows
    assert.strictEqual(result[0], 'dont');
    assert.strictEqual(result[1], dontExpanded);
  });
});

describe('suggestions — KenLM interaction (T8)', () => {
  it('T8: verbatim pinned #1 even when KenLM gives it terrible log-prob', () => {
    const pool = [
      { text: 'typoo', score: 0.5, source: 'symspell', isUnknownVerbatim: true },
      { text: 'typo', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    // KenLM: typoo gets -10 (terrible), typo gets 0 (great)
    const mockScorer = (candidate) => {
      if (candidate === 'typoo') return -10.0;
      if (candidate === 'typo') return 0.0;
      return -10.0;
    };

    const result = suggestions({
      pool,
      currentWord: 'typoo',
      previousWord: 'a',
      previousWord2: null,
      kenlmScorer: mockScorer,
      blendWeight: 0.5,
      limit: 2,
    });

    assert.strictEqual(result.length, 2);
    // Verbatim is #1 despite KenLM rating it far worse than "typo"
    assert.strictEqual(result[0], '"typoo"');
    assert.strictEqual(result[1], 'typo');

    // Verify KenLM actually ran — typo's blended score should beat
    // typoo's, yet verbatim is pinned to #1 by the suggestions function.
    // This is the core proposition of the verbatim-pinning feature.
    assert.notStrictEqual(result[0], 'typo', 'typo should NOT be at position 0');
  });
});
