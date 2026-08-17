import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { finalSigma, shouldRevertSigma } from '../lib/greek-text.mjs';

describe('finalSigma', () => {
  it('converts a trailing σ to ς in a multi-char word', () => {
    assert.strictEqual(finalSigma('καλοσ'), 'καλος');
  });

  it('converts a trailing σ to ς in a longer word', () => {
    assert.strictEqual(finalSigma('άνθρωποσ'), 'άνθρωπος');
  });

  it('converts a two-character word ending in σ', () => {
    assert.strictEqual(finalSigma('οσ'), 'ος');
  });

  it('leaves the single-letter word σ untouched (length < 2)', () => {
    assert.strictEqual(finalSigma('σ'), 'σ');
  });

  it('leaves uppercase Σ untouched', () => {
    assert.strictEqual(finalSigma('Σ'), 'Σ');
  });

  it('leaves an all-caps word untouched (Σ not converted)', () => {
    assert.strictEqual(finalSigma('ΚΑΛΟΣ'), 'ΚΑΛΟΣ');
  });

  it('is idempotent on a word already ending in ς', () => {
    assert.strictEqual(finalSigma('καλος'), 'καλος');
  });

  it('is a no-op when the word does not end in σ', () => {
    assert.strictEqual(finalSigma('καλο'), 'καλο');
    assert.strictEqual(finalSigma('γεια'), 'γεια');
  });

  it('is a no-op on empty and single-char non-σ words', () => {
    assert.strictEqual(finalSigma(''), '');
    assert.strictEqual(finalSigma('α'), 'α');
  });

  it('does not convert when the trailing character is punctuation (word + comma)', () => {
    // The caller extracts the word before passing it; a trailing comma must not
    // be mistaken for the word's final character.
    assert.strictEqual(finalSigma('καλοσ,'), 'καλοσ,');
  });

  it('converts only the final σ, leaving earlier σ characters medial', () => {
    assert.strictEqual(finalSigma('συσ'), 'συς');
  });
});

describe('shouldRevertSigma', () => {
  it('returns true when the cursor is directly after an auto-converted ς', () => {
    assert.ok(shouldRevertSigma('καλος'));
  });

  it('returns true for a two-character word ending in ς', () => {
    assert.ok(shouldRevertSigma('ος'));
  });

  it('returns false for an empty context', () => {
    assert.ok(!shouldRevertSigma(''));
  });

  it('returns false for a single-character context', () => {
    assert.ok(!shouldRevertSigma('ς'));
  });

  it('returns false when the last character is σ (medial form, not converted)', () => {
    assert.ok(!shouldRevertSigma('καλοσ'));
  });

  it('returns false when the last character is a plain letter', () => {
    assert.ok(!shouldRevertSigma('καλο'));
  });

  it('returns false when the ς is preceded by whitespace (not word-internal)', () => {
    assert.ok(!shouldRevertSigma('α ς'));
  });

  it('returns false when the ς is preceded by punctuation', () => {
    assert.ok(!shouldRevertSigma('.ς'));
  });

  it('returns false when a punctuation commit trigger still separates the cursor from the ς', () => {
    assert.ok(!shouldRevertSigma('καλος,'));
    assert.ok(!shouldRevertSigma('καλος '));
  });

  it('returns true when the ς is preceded by an uppercase letter (uppercase stems are still letters)', () => {
    assert.ok(shouldRevertSigma('Ας'));
  });
});
