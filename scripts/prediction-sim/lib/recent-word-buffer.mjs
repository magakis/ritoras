// Pure-logic JS mirror of keyboard/Sources/Prediction/Autocorrect/RecentWordBuffer.swift.

import { containsNumberOrSymbol } from './autocorrect-controller.mjs';

export const RECENT_WORD_VERDICT = Object.freeze({
  NOT_EVALUATED: 'notEvaluated',
  PENDING: 'pending',
  EVALUATED_AND_REJECTED: 'evaluatedAndRejected',
  EVALUATED_AND_APPLIED: 'evaluatedAndApplied',
});

const CAPACITY = 4;
const MIN_WORD_LENGTH = 2;
const MAX_WORD_LENGTH = 25;
const SETTLED_REJECTION_REASONS = new Set([
  'autocorrect-spellcheck-pass',
  'autocorrect-learned-word',
  'autocorrect-score-below-threshold',
  'autocorrect-language-model-floor',
  'autocorrect-contraction-margin',
  'autocorrect-pool-empty-after-filters',
  'autocorrect-first-letter-mismatch',
  'autocorrect-same-word',
]);

export function verdictForInlineEvaluation(decision, {
  typedWord = '',
  reasonCode = null,
  correctionApplied = false,
} = {}) {
  if (
    decision?.decision === 'leaveAsIs'
    && (SETTLED_REJECTION_REASONS.has(reasonCode) || containsNumberOrSymbol(typedWord))
  ) {
    return RECENT_WORD_VERDICT.EVALUATED_AND_REJECTED;
  }
  if (decision?.decision === 'correct' && correctionApplied) {
    return RECENT_WORD_VERDICT.EVALUATED_AND_APPLIED;
  }
  return RECENT_WORD_VERDICT.NOT_EVALUATED;
}

export class RecentWordBuffer {
  #entries = [];

  append(record, { inlineEvaluationScheduled = true } = {}) {
    if (this.#entries.length === CAPACITY) this.#entries.shift();
    this.#entries.push({
      ...record,
      evaluatedAndSkipped: false,
      verdict: inlineEvaluationScheduled
        ? RECENT_WORD_VERDICT.PENDING
        : RECENT_WORD_VERDICT.NOT_EVALUATED,
    });
  }

  recordInlineEvaluation({
    typedWord,
    commitContextSuffix,
    decision,
    reasonCode = null,
    correctionApplied = false,
  }) {
    this.#updatePendingRecord(
      typedWord,
      commitContextSuffix,
      verdictForInlineEvaluation(decision, {
        typedWord,
        reasonCode,
        correctionApplied,
      }),
    );
  }

  markInlineEvaluationAborted(typedWord, commitContextSuffix) {
    this.#updatePendingRecord(
      typedWord,
      commitContextSuffix,
      RECENT_WORD_VERDICT.NOT_EVALUATED,
    );
  }

  markEvaluated(typedWord, commitContextSuffix) {
    let entry;
    for (let index = this.#entries.length - 1; index >= 0; index -= 1) {
      const record = this.#entries[index];
      if (
        record.typedWord === typedWord
        && record.commitContextSuffix === commitContextSuffix
        && !record.evaluatedAndSkipped
        && record.verdict === RECENT_WORD_VERDICT.NOT_EVALUATED
      ) {
        entry = record;
        break;
      }
    }
    if (entry) entry.evaluatedAndSkipped = true;
  }

  get candidates() {
    return this.#entries
      .filter(record => (
        record.origin === 'typing'
        && !record.evaluatedAndSkipped
        && record.verdict === RECENT_WORD_VERDICT.NOT_EVALUATED
        && record.typedWord.length >= MIN_WORD_LENGTH
        && record.typedWord.length <= MAX_WORD_LENGTH
      ))
      .map(record => ({ ...record }));
  }

  #updatePendingRecord(typedWord, commitContextSuffix, verdict) {
    for (let index = this.#entries.length - 1; index >= 0; index -= 1) {
      const record = this.#entries[index];
      if (
        record.typedWord === typedWord
        && record.commitContextSuffix === commitContextSuffix
        && record.verdict === RECENT_WORD_VERDICT.PENDING
      ) {
        record.verdict = verdict;
        return;
      }
    }
  }
}
