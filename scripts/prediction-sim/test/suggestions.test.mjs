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

describe('suggestions — sticky rescue (previous keystroke completions)', () => {
  it('SR1: long completion survives at the next longer prefix', () => {
    // At "app" the bar showed [app, application, apply]. The user types "l"
    // → "appl". The fresh pool ranks short corrections above "application"
    // (KenLM's long-word bias), so without the rescue "application" drops out.
    const pool = [
      { text: 'appl', score: 1.0, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apples', score: 0.8, source: 'symspell', isUnknownVerbatim: false },
      { text: 'application', score: 0.5, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'appl',
      limit: 3,
      previousSuggestions: ['app', 'application', 'apply'],
    });

    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0], 'appl'); // verbatim pinned #1
    assert.ok(result.includes('application'), 'application should survive');
  });

  it('SR2: previous suggestion that no longer matches the prefix is dropped', () => {
    // "apple"/"application" were shown at "app"; the user typed "appr", which
    // is not their prefix, so neither may be rescued.
    const pool = [
      { text: 'appr', score: 1.0, source: 'symspell', isUnknownVerbatim: false },
      { text: 'approve', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'appr',
      limit: 3,
      previousSuggestions: ['app', 'apple', 'application'],
    });

    assert.strictEqual(result.length, 2);
    assert.strictEqual(result[0], 'appr');
    assert.ok(!result.includes('apple'));
    assert.ok(!result.includes('application'));
  });

  it('SR3: verbatim stays #1, rescued items fill remaining slots; previous suggestion equal to the current word is skipped', () => {
    const pool = [
      { text: 'appl', score: 1.0, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    // 'appl' itself was shown before and equals the current word — the strict
    // prefix check drops it; 'application' fills the remaining slot.
    const result = suggestions({
      pool,
      currentWord: 'appl',
      limit: 3,
      previousSuggestions: ['appl', 'application'],
    });

    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0], 'appl');
    assert.strictEqual(result[1], 'apple');
    assert.strictEqual(result[2], 'application');
  });

  it('SR4: result never exceeds limit when rescued items displace corrections', () => {
    const pool = [
      { text: 'appl', score: 1.0, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apples', score: 0.8, source: 'symspell', isUnknownVerbatim: false },
      { text: 'applause', score: 0.7, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'appl',
      limit: 3,
      previousSuggestions: ['app', 'application', 'apply', 'appliance'],
    });

    assert.ok(result.length <= 3, 'result must never exceed limit');
    assert.strictEqual(result[0], 'appl');
    assert.ok(result.includes('application'));
  });

  it('SR5: case-insensitive prefix match, original case preserved', () => {
    const pool = [
      { text: 'Appl', score: 1.0, source: 'symspell', isUnknownVerbatim: false },
      { text: 'Apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'appl',
      limit: 3,
      previousSuggestions: ['Application', 'Apply'],
    });

    assert.strictEqual(result[0], 'Appl'); // verbatim keeps its cased form
    assert.ok(result.includes('Application'), 'rescued with original casing');
  });

  it('SR6: empty currentWord → no rescue', () => {
    const pool = [
      { text: 'hello', score: 0.9, source: 'symspell' },
      { text: 'world', score: 0.5, source: 'symspell' },
    ];

    const result = suggestions({
      pool,
      currentWord: '',
      limit: 3,
      previousSuggestions: ['application', 'apply'],
    });

    assert.deepStrictEqual(result, ['hello', 'world']);
  });

  it('SR7: default previousSuggestions (null) → identical to pre-rescue behavior', () => {
    const pool = [
      { text: 'appl', score: 1.0, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apples', score: 0.8, source: 'symspell', isUnknownVerbatim: false },
    ];

    const withoutRescue = suggestions({ pool, currentWord: 'appl', limit: 3 });
    assert.deepStrictEqual(withoutRescue, ['appl', 'apple', 'apples']);
  });

  it('SR8: no verbatim in the pool — rescue appends to the top corrections (verbatim == null branch)', () => {
    // Pool has only corrections (nothing equals "appl"), so the pinning logic
    // takes the verbatim == null branch (corrections.slice(0, limit)). A still
    // valid prefix completion from the previous keystroke is appended into the
    // unfilled slot.
    const pool = [
      { text: 'apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apply', score: 0.8, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'appl',
      limit: 3,
      previousSuggestions: ['application'],
    });

    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0], 'apple'); // no verbatim — top correction leads
    assert.strictEqual(result[1], 'apply');
    assert.strictEqual(result[2], 'application');
  });

  it('SR9: fill-then-displace — a 2nd rescue item displaces the lowest-ranked correction', () => {
    // Result starts short (2 items vs limit 3): the 1st rescue fills the slot,
    // the 2nd rescue triggers the displacement path, pushing out the
    // lowest-ranked non-verbatim correction.
    const pool = [
      { text: 'apple', score: 0.9, source: 'symspell', isUnknownVerbatim: false },
      { text: 'apples', score: 0.7, source: 'symspell', isUnknownVerbatim: false },
    ];

    const result = suggestions({
      pool,
      currentWord: 'appl',
      limit: 3,
      previousSuggestions: ['application', 'appliance'],
    });

    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0], 'apple'); // top pick never displaced
    assert.ok(result.includes('application'), '1st rescue filled the short list');
    assert.ok(result.includes('appliance'), '2nd rescue present after displacement');
    assert.ok(!result.includes('apples'), 'lowest-ranked correction displaced');
  });
});
