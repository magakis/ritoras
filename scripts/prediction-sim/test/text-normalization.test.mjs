import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { CANONICAL_APOSTROPHE, isApostropheVariant, canonicalize, BOUNDARY_QUOTES } from '../lib/text-normalization.mjs';

describe('canonicalize', () => {
  it('converts U+0027 straight apostrophe to U+2019', () => {
    const input = "don't";  // U+0027
    const result = canonicalize(input);
    assert.strictEqual(result, "don\u{2019}t");
    assert.strictEqual(result.charCodeAt(3), 0x2019);
  });

  it('converts U+2018 left single quote to U+2019', () => {
    const input = "don\u{2018}t";
    const result = canonicalize(input);
    assert.strictEqual(result, "don\u{2019}t");
    assert.strictEqual(result.charCodeAt(3), 0x2019);
  });

  it('is idempotent on U+2019 input', () => {
    const input = "don\u{2019}t";
    const result = canonicalize(input);
    assert.strictEqual(result, "don\u{2019}t");
    assert.strictEqual(result.charCodeAt(3), 0x2019);
  });

  it('double canonicalize is a no-op', () => {
    const input = "it\u{0027}s";
    const once = canonicalize(input);
    const twice = canonicalize(once);
    assert.strictEqual(twice, once);
  });

  it('is no-op on apostrophe-free input', () => {
    assert.strictEqual(canonicalize('hello'), 'hello');
  });

  it('handles mixed variants in one string', () => {
    // O\u{0027}Brien -> O\u{2019}Brien
    const input = "O\u{0027}Brien";
    const result = canonicalize(input);
    assert.strictEqual(result, "O\u{2019}Brien");
    assert.strictEqual(result.charCodeAt(1), 0x2019);
  });
});

describe('isApostropheVariant', () => {
  it('returns true for U+0027', () => {
    assert.ok(isApostropheVariant('\u{0027}'));
  });
  it('returns true for U+2018', () => {
    assert.ok(isApostropheVariant('\u{2018}'));
  });
  it('returns true for U+2019', () => {
    assert.ok(isApostropheVariant('\u{2019}'));
  });
  it('returns false for "a"', () => {
    assert.ok(!isApostropheVariant('a'));
  });
  it('returns false for double quote', () => {
    assert.ok(!isApostropheVariant('"'));
  });
  it('returns false for a digit', () => {
    assert.ok(!isApostropheVariant('5'));
  });
});

describe('BOUNDARY_QUOTES', () => {
  it('includes straight double quote', () => {
    assert.ok(BOUNDARY_QUOTES.has('"'));
  });
  it('includes U+2019 (right single quote)', () => {
    assert.ok(BOUNDARY_QUOTES.has('\u{2019}'));
  });
  it('includes U+2018 (left single quote)', () => {
    assert.ok(BOUNDARY_QUOTES.has('\u{2018}'));
  });
  it('does not include a plain letter', () => {
    assert.ok(!BOUNDARY_QUOTES.has('a'));
  });
  it('includes guillemets', () => {
    assert.ok(BOUNDARY_QUOTES.has('«'));
    assert.ok(BOUNDARY_QUOTES.has('»'));
  });
  it('includes CJK corner brackets', () => {
    assert.ok(BOUNDARY_QUOTES.has('「'));
    assert.ok(BOUNDARY_QUOTES.has('」'));
    assert.ok(BOUNDARY_QUOTES.has('『'));
    assert.ok(BOUNDARY_QUOTES.has('』'));
  });
  it('includes low double quote', () => {
    assert.ok(BOUNDARY_QUOTES.has('„'));
  });
  it('does not include straight apostrophe U+0027', () => {
    // Straight apostrophe is NOT in BOUNDARY_QUOTES — it's handled by
    // stripTrailingNonApostrophePunctuation which treats it as a word-internal
    // character. Only the curly variants (which serve as boundary quotes)
    // are members of this set.
    assert.ok(!BOUNDARY_QUOTES.has('\u{0027}'));
  });
});
