import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluate, DEFAULT_CONFIG } from '../lib/autocorrect-controller.mjs';

const APOSTROPHE = '\u{2019}';

describe('AutocorrectController.evaluate', () => {
  describe('.ambiguousContraction branch', () => {
    it('bypasses isMisspelled (token is a real word) and corrects', () => {
      const result = evaluate({
        typedWord: 'its',
        origin: 'typing',
        topCorrection: { text: `it${APOSTROPHE}s`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'correct');
      assert.strictEqual(result.correction, `it${APOSTROPHE}s`);
    });

    it('still respects isLearned', () => {
      const result = evaluate({
        typedWord: 'its',
        origin: 'typing',
        topCorrection: { text: `it${APOSTROPHE}s`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: true,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('still respects the confidence threshold', () => {
      const result = evaluate({
        typedWord: 'its',
        origin: 'typing',
        topCorrection: { text: `it${APOSTROPHE}s`, score: 0.5, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
        config: { ...DEFAULT_CONFIG, minConfidenceScore: 0.7 },
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('does NOT open the misspelled gate for other sources (regression)', () => {
      // A plain symspell correction on a correctly-spelled word stays blocked.
      const result = evaluate({
        typedWord: 'its',
        origin: 'typing',
        topCorrection: { text: 'itchy', score: 0.9, source: 'symspell' },
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('"id" → "I\'d": preserveCase keeps the capital-I pronoun', () => {
      const result = evaluate({
        typedWord: 'id',
        origin: 'typing',
        topCorrection: { text: `I${APOSTROPHE}d`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'correct');
      assert.strictEqual(result.correction, `I${APOSTROPHE}d`);
    });

    it('"ill" → "I\'ll": preserveCase keeps the capital-I pronoun', () => {
      const result = evaluate({
        typedWord: 'ill',
        origin: 'typing',
        topCorrection: { text: `I${APOSTROPHE}ll`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'correct');
      assert.strictEqual(result.correction, `I${APOSTROPHE}ll`);
    });
  });

  describe('deterministic .contraction still bypasses all gates', () => {
    it('"dont" → "don\'t" even when learned, correctly spelled, and low-confidence', () => {
      const result = evaluate({
        typedWord: 'dont',
        origin: 'typing',
        topCorrection: { text: `don${APOSTROPHE}t`, score: 0.4, source: 'contraction' },
        isLearned: true,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'correct');
      assert.strictEqual(result.correction, `don${APOSTROPHE}t`);
    });
  });

  describe('shared gates', () => {
    it('locked origins never re-correct (even ambiguousContraction)', () => {
      const result = evaluate({
        typedWord: 'its',
        origin: 'suggestionTap',
        topCorrection: { text: `it${APOSTROPHE}s`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('enforces length guards', () => {
      const result = evaluate({
        typedWord: 'i',
        origin: 'typing',
        topCorrection: { text: `I${APOSTROPHE}`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('no candidate → leaveAsIs', () => {
      const result = evaluate({
        typedWord: 'its',
        origin: 'typing',
        topCorrection: null,
        isLearned: false,
        isMisspelled: false,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('never "corrects" to the same word (case-insensitive)', () => {
      const result = evaluate({
        typedWord: 'Its',
        origin: 'typing',
        topCorrection: { text: 'its', score: 0.9, source: 'symspell' },
        isLearned: false,
        isMisspelled: true,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });

    it('first-letter mismatch is rejected', () => {
      const result = evaluate({
        typedWord: 'michael',
        origin: 'typing',
        topCorrection: { text: 'andrew', score: 0.9, source: 'symspell' },
        isLearned: false,
        isMisspelled: true,
      });
      assert.strictEqual(result.decision, 'leaveAsIs');
    });
  });
});
