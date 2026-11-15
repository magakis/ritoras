import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  AutocorrectWordLearningTracker,
  DEFAULT_CONFIG,
  WORD_LEARNING_COMMIT_THRESHOLD,
  WordOriginTracker,
  evaluate,
  isMisspelledForAutocorrect,
  preserveCase,
} from '../lib/autocorrect-controller.mjs';

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

  describe('repeat-commit learning gate', () => {
    it('corrects a typed-once typo even when UITextChecker accepts an unlisted token', () => {
      const learner = new AutocorrectWordLearningTracker();
      assert.strictEqual(learner.recordCommit('gojng'), false);
      const isMisspelled = isMisspelledForAutocorrect({
        typedWord: 'gojng',
        systemSpellCheckerReportsMisspelled: false,
        isBuiltInWord: false,
      });

      const result = evaluate({
        typedWord: 'gojng',
        origin: 'typing',
        topCorrection: { text: 'going', score: 0.95, source: 'symspell' },
        isLearned: false,
        isMisspelled,
      });

      assert.strictEqual(result.decision, 'correct');
      assert.strictEqual(result.correction, 'going');
    });

    it('does not count a typo that autocorrect removed, but learns three manually retained commits', () => {
      const learner = new AutocorrectWordLearningTracker();
      for (let count = 0; count < WORD_LEARNING_COMMIT_THRESHOLD; count++) {
        assert.strictEqual(learner.recordCommit('gojng', 'gojng'), false);
      }
      assert.strictEqual(learner.recordCommit('gojng'), false);
      assert.strictEqual(learner.recordCommit('gojng'), false);
      assert.strictEqual(learner.recordCommit('gojng'), true);
    });

    it('learns and exempts a custom word after three manually retained occurrences', () => {
      const learner = new AutocorrectWordLearningTracker();
      assert.strictEqual(WORD_LEARNING_COMMIT_THRESHOLD, 3);
      assert.strictEqual(learner.recordCommit('Ritoras'), false);
      assert.strictEqual(learner.recordCommit('ritoras'), false);
      const shouldLearn = learner.recordCommit('RITORAS');
      assert.strictEqual(shouldLearn, true);

      const result = evaluate({
        typedWord: 'Ritoras',
        origin: 'typing',
        topCorrection: { text: 'Rita', score: 0.95, source: 'symspell' },
        isLearned: shouldLearn,
        isMisspelled: isMisspelledForAutocorrect({
          typedWord: 'Ritoras',
          systemSpellCheckerReportsMisspelled: false,
          isBuiltInWord: false,
        }),
      });

      assert.strictEqual(result.decision, 'leaveAsIs');
    });
  });

  describe('capitalized non-dictionary words', () => {
    it('protects proper nouns before the learning threshold but still corrects lowercase tokens', () => {
      for (let count = 0; count < 2; count++) {
        const isMisspelled = isMisspelledForAutocorrect({
          typedWord: 'Michael',
          systemSpellCheckerReportsMisspelled: false,
          isBuiltInWord: false,
        });
        const result = evaluate({
          typedWord: 'Michael',
          origin: 'typing',
          topCorrection: { text: 'micheal', score: 0.95, source: 'symspell' },
          isLearned: false,
          isMisspelled,
        });

        assert.strictEqual(result.decision, 'leaveAsIs');
      }

      const lowercaseResult = evaluate({
        typedWord: 'michael',
        origin: 'typing',
        topCorrection: { text: 'micheal', score: 0.95, source: 'symspell' },
        isLearned: false,
        isMisspelled: isMisspelledForAutocorrect({
          typedWord: 'michael',
          systemSpellCheckerReportsMisspelled: false,
          isBuiltInWord: false,
        }),
      });

      assert.strictEqual(lowercaseResult.decision, 'correct');
      assert.strictEqual(lowercaseResult.correction, 'micheal');
    });
  });

  describe('suggestion-tap origin lifetime', () => {
    it('protects the tapped candidate, then allows autocorrect on the next typed word', () => {
      const origin = new WordOriginTracker();
      origin.markSuggestionTap();

      const tappedCandidate = evaluate({
        typedWord: 'Ritoras',
        origin: origin.current,
        topCorrection: { text: 'Rita', score: 0.95, source: 'symspell' },
        isLearned: false,
        isMisspelled: true,
      });
      assert.strictEqual(tappedCandidate.decision, 'leaveAsIs');

      origin.resetToTyping();
      const nextWord = evaluate({
        typedWord: 'gojng',
        origin: origin.current,
        topCorrection: { text: 'going', score: 0.95, source: 'symspell' },
        isLearned: false,
        isMisspelled: true,
      });
      assert.strictEqual(nextWord.decision, 'correct');
      assert.strictEqual(nextWord.correction, 'going');
    });
  });

  // ──────────────────────────────────────────────
  // Language gate (Phase 3: Greek)
  // ──────────────────────────────────────────────
  describe('language gate', () => {
    it('"id" → "I\'d" still applies for English (default language)', () => {
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

    it('never applies the capital-I pronoun rule for Greek', () => {
      // Greek has no apostrophe contractions; the "i'" rule must not fire even
      // on a token shaped like an English contraction.
      const result = evaluate({
        typedWord: 'id',
        origin: 'typing',
        topCorrection: { text: `I${APOSTROPHE}d`, score: 0.9, source: 'ambiguousContraction' },
        isLearned: false,
        isMisspelled: false,
        language: 'greek',
      });
      assert.strictEqual(result.decision, 'correct');
      // Pure lowercase case-shape transform, no "I" flip.
      assert.strictEqual(result.correction, `i${APOSTROPHE}d`);
    });

    it('Greek case preservation via uppercased keeps tonos (ά → Ά)', () => {
      assert.strictEqual(preserveCase('Ά', 'ά', 'greek'), 'Ά');
      assert.strictEqual(preserveCase('ά', 'Ά', 'greek'), 'ά');
    });

    it('English preserveCase unchanged with explicit language', () => {
      assert.strictEqual(preserveCase('id', `i${APOSTROPHE}d`, 'english'), `I${APOSTROPHE}d`);
      assert.strictEqual(preserveCase('Hello', 'world', 'english'), 'World');
    });
  });
});
