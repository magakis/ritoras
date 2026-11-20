import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluate } from '../lib/autocorrect-controller.mjs';
import {
  RECENT_WORD_VERDICT,
  RecentWordBuffer,
  verdictForInlineEvaluation,
} from '../lib/recent-word-buffer.mjs';

function contextFor(typedWord) {
  return `earlier text ${typedWord} `;
}

function record(typedWord = 'wiyh', commitContextSuffix = contextFor(typedWord)) {
  return { typedWord, origin: 'typing', commitContextSuffix };
}

function evaluateWord({
  typedWord = 'wiyh',
  topCorrection = { text: 'with', score: 0.95, source: 'symspell' },
  isLearned = false,
  isMisspelled = true,
} = {}) {
  return evaluate({
    typedWord,
    origin: 'typing',
    topCorrection,
    isLearned,
    isMisspelled,
  });
}

describe('RecentWordBuffer inline verdicts', () => {
  it('keeps engine-not-ready and extraction-abort entries retro-eligible', () => {
    for (const reason of ['engine-not-ready', 'extraction-abort']) {
      const buffer = new RecentWordBuffer();
      buffer.append(record(), { inlineEvaluationScheduled: false });
      assert.strictEqual(buffer.candidates.length, 1, reason);
      assert.strictEqual(buffer.candidates[0].verdict, RECENT_WORD_VERDICT.NOT_EVALUATED);
    }
  });

  it('blocks a pending inline verdict from racing the retro scan', () => {
    const buffer = new RecentWordBuffer();
    buffer.append(record());

    assert.strictEqual(buffer.candidates.length, 0);

    buffer.markInlineEvaluationAborted('wiyh', contextFor('wiyh'));
    assert.strictEqual(buffer.candidates.length, 1);
    assert.strictEqual(buffer.candidates[0].verdict, RECENT_WORD_VERDICT.NOT_EVALUATED);
  });

  it('makes evaluation-pipeline leave-as-is outcomes retro-ineligible', () => {
    const settledRejections = [
      {
        reason: 'spellcheck-pass',
        reasonCode: 'autocorrect-spellcheck-pass',
        typedWord: 'wiyh',
        decision: evaluateWord({ isMisspelled: false }),
      },
      {
        reason: 'learned-word',
        reasonCode: 'autocorrect-learned-word',
        typedWord: 'wiyh',
        decision: evaluateWord({ isLearned: true }),
      },
      {
        reason: 'score-family',
        reasonCode: 'autocorrect-score-below-threshold',
        typedWord: 'wiyh',
        decision: evaluateWord({
          topCorrection: { text: 'with', score: 0.5, source: 'symspell' },
        }),
      },
      {
        reason: 'LM-floor',
        reasonCode: 'autocorrect-language-model-floor',
        typedWord: 'wiyh',
        decision: evaluateWord({ topCorrection: null }),
      },
      {
        reason: 'contraction-margin',
        reasonCode: 'autocorrect-contraction-margin',
        typedWord: 'wiyh',
        decision: evaluateWord({ topCorrection: null }),
      },
      {
        reason: 'pool-empty',
        reasonCode: 'autocorrect-pool-empty-after-filters',
        typedWord: 'wiyh',
        decision: evaluateWord({ topCorrection: null }),
      },
      {
        reason: 'first-letter-mismatch',
        reasonCode: 'autocorrect-first-letter-mismatch',
        typedWord: 'michael',
        decision: evaluateWord({
          typedWord: 'michael',
          topCorrection: { text: 'andrew', score: 0.95, source: 'symspell' },
        }),
      },
    ];

    for (const { reason, reasonCode, typedWord, decision } of settledRejections) {
      assert.strictEqual(decision.decision, 'leaveAsIs', reason);
      assert.strictEqual(
        verdictForInlineEvaluation(decision, { typedWord, reasonCode }),
        RECENT_WORD_VERDICT.EVALUATED_AND_REJECTED,
        reason,
      );
      const buffer = new RecentWordBuffer();
      buffer.append(record(typedWord));
      buffer.recordInlineEvaluation({
        typedWord,
        commitContextSuffix: contextFor(typedWord),
        decision,
        reasonCode,
      });
      assert.strictEqual(buffer.candidates.length, 0, reason);
    }
  });

  it('settles only landed corrections; an aborted apply re-opens the word', () => {
    const decision = evaluateWord();
    assert.strictEqual(decision.decision, 'correct');
    assert.strictEqual(
      verdictForInlineEvaluation(decision, { typedWord: 'wiyh', correctionApplied: true }),
      RECENT_WORD_VERDICT.EVALUATED_AND_APPLIED,
    );
    assert.strictEqual(
      verdictForInlineEvaluation(decision, { typedWord: 'wiyh' }),
      RECENT_WORD_VERDICT.NOT_EVALUATED,
    );

    const appliedBuffer = new RecentWordBuffer();
    appliedBuffer.append(record());
    appliedBuffer.recordInlineEvaluation({
      typedWord: 'wiyh',
      commitContextSuffix: contextFor('wiyh'),
      decision,
      reasonCode: 'autocorrect-candidate',
      correctionApplied: true,
    });
    assert.strictEqual(appliedBuffer.candidates.length, 0);

    const abortedApplyBuffer = new RecentWordBuffer();
    abortedApplyBuffer.append(record());
    abortedApplyBuffer.recordInlineEvaluation({
      typedWord: 'wiyh',
      commitContextSuffix: contextFor('wiyh'),
      decision,
      reasonCode: 'autocorrect-candidate',
      correctionApplied: false,
    });
    assert.strictEqual(abortedApplyBuffer.candidates.length, 1);
  });

  it('settles the shared digit/symbol exemption as an evaluated rejection', () => {
    const typedWord = '50€';
    const decision = evaluateWord({
      typedWord,
      topCorrection: { text: '5', score: 0.99, source: 'symspell' },
    });
    const buffer = new RecentWordBuffer();
    buffer.append(record(typedWord));
    buffer.recordInlineEvaluation({
      typedWord,
      commitContextSuffix: contextFor(typedWord),
      decision,
    });

    assert.strictEqual(decision.decision, 'leaveAsIs');
    assert.strictEqual(
      verdictForInlineEvaluation(decision, { typedWord }),
      RECENT_WORD_VERDICT.EVALUATED_AND_REJECTED,
    );
    assert.strictEqual(buffer.candidates.length, 0);
  });

  it('keeps evaluatedAndSkipped as the retro-scan consumption marker', () => {
    const buffer = new RecentWordBuffer();
    buffer.append(record(), { inlineEvaluationScheduled: false });
    buffer.markEvaluated('wiyh', contextFor('wiyh'));

    assert.strictEqual(buffer.candidates.length, 0);
  });

  it('marks the matching eligible entry, not a same-word pending record', () => {
    const buffer = new RecentWordBuffer();
    buffer.append(record('wiyh', 'older wiyh '));
    buffer.append(record('wiyh', 'newer wiyh '), { inlineEvaluationScheduled: false });

    buffer.markEvaluated('wiyh', 'newer wiyh ');

    assert.strictEqual(buffer.candidates.length, 0);
  });
});
