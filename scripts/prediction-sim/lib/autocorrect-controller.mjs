// Pure-logic JS port of keyboard/Sources/Prediction/Autocorrect/AutocorrectController.swift.
// Kept in sync per AGENTS.md -> Test policy.

import { canonicalize } from './text-normalization.mjs';
import { fusionIsActive } from './fusion-is-active.mjs';

/** Matches the two Swift autocorrect thresholds in SharedConfig.Defaults. */
export const DEFAULT_CONFIG = {
  minWordLength: 2,
  maxWordLength: 25,
  minConfidenceScore: 0.7,
  minConfidenceScoreFused: 0.65,
};

/** Mirrors WordOrigin: only `.typing` is re-evaluable on separator press. */
export const ORIGIN_TYPING = 'typing';
export const ORIGIN_SUGGESTION_TAP = 'suggestionTap';
export const WORD_LEARNING_COMMIT_THRESHOLD = 3;
const MAX_TRACKED_WORDS = 512;

/**
 * Mirrors KeyboardViewController's confidence-threshold selection:
 * 0.65 when KenLM fusion is active, otherwise 0.70.
 */
export function selectConfidenceThreshold({
  previousWord,
  trigramReady,
  fusedThreshold = DEFAULT_CONFIG.minConfidenceScoreFused,
  unfusedThreshold = DEFAULT_CONFIG.minConfidenceScore,
}) {
  return fusionIsActive({ previousWord, trigramReady })
    ? fusedThreshold
    : unfusedThreshold;
}

/** Minimal mirror of WordOriginTracker for suggestion-tap input sequences. */
export class WordOriginTracker {
  current = ORIGIN_TYPING;

  markSuggestionTap() {
    this.current = ORIGIN_SUGGESTION_TAP;
  }

  resetToTyping() {
    this.current = ORIGIN_TYPING;
  }
}

/** Tracks repeated commits; Swift persists the same counts in UserDefaults. */
export class AutocorrectWordLearningTracker {
  #commitCounts = new Map();

  constructor(threshold = WORD_LEARNING_COMMIT_THRESHOLD) {
    this.threshold = threshold;
  }

  recordCommit(word, lastAutoCorrectionTypedWord = null) {
    const key = canonicalize(word.toLowerCase().trim());
    if (!key) return false;

    if (lastAutoCorrectionTypedWord !== null) {
      const correctedAwayKey = canonicalize(lastAutoCorrectionTypedWord.toLowerCase().trim());
      if (key === correctedAwayKey) return false;
    }

    const nextCount = (this.#commitCounts.get(key) ?? 0) + 1;
    if (nextCount >= this.threshold) {
      this.#commitCounts.delete(key);
      return true;
    }
    if (!this.#commitCounts.has(key) && this.#commitCounts.size >= MAX_TRACKED_WORDS) {
      const [oldestKey] = this.#commitCounts.keys();
      this.#commitCounts.delete(oldestKey);
    }
    this.#commitCounts.set(key, nextCount);
    return false;
  }
}

/** A process-local UITextChecker word cannot make an unlisted token trusted. */
export function isMisspelledForAutocorrect({
  typedWord,
  systemSpellCheckerReportsMisspelled,
  isBuiltInWord,
}) {
  const firstCharacter = Array.from(typedWord)[0];
  const isCapitalized = firstCharacter !== undefined
    && firstCharacter === firstCharacter.toUpperCase()
    && firstCharacter !== firstCharacter.toLowerCase();

  return systemSpellCheckerReportsMisspelled || (!isCapitalized && !isBuiltInWord);
}

/**
 * Mirrors AutocorrectController.Decision:
 *   - { decision: 'correct', typedWord, correction }
 *   - { decision: 'leaveAsIs' }
 *
 * @param {object} opts
 * @param {string} opts.typedWord - The word the user actually typed.
 * @param {string} opts.origin - 'typing' | 'suggestionTap' | 'autocorrectApplied'.
 * @param {{text:string,score:number,source:string}|null} opts.topCorrection - Best
 *   correction candidate from the prediction engine, or null.
 * @param {boolean} opts.isLearned - Whether the word is in the user's learned-word store.
 * @param {boolean} opts.isMisspelled - Whether the autocorrect dictionary policy treats the token as unknown.
 * @param {string} [opts.language='english'] - Active keyboard language ('english'|'greek').
 *   Defaults to English, preserving existing call sites. Only the case-preservation
 *   step is language-sensitive.
 * @param {string|null} [opts.previousWord] - Context used to determine whether
 *   KenLM fusion is active.
 * @param {boolean} [opts.trigramReady=false] - Whether the KenLM provider is ready.
 * @param {object} [opts.config] - Tunable thresholds (defaults from SharedConfig.Defaults).
 * @returns {{decision:string, typedWord?:string, correction?:string}}
 */
export function evaluate({
  typedWord,
  origin,
  topCorrection,
  isLearned,
  isMisspelled,
  language = 'english',
  previousWord = null,
  trigramReady = false,
  config = DEFAULT_CONFIG,
}) {
  // LOCKED origins — never re-correct.
  if (origin !== ORIGIN_TYPING) return { decision: 'leaveAsIs' };

  // Length guards (UITextChecker ~25-char cap; ignore trivial 1-2 char tokens).
  if (typedWord.length < config.minWordLength || typedWord.length > config.maxWordLength) {
    return { decision: 'leaveAsIs' };
  }

  // Contraction candidates are deterministic — they bypass the isLearned,
  // isMisspelled, and threshold gates because the contraction table represents
  // a high-confidence mapping the user almost certainly wants ("dont" → "don't").
  const isContraction = topCorrection?.source === 'contraction';

  // Ambiguous-contraction candidates (its → it's) bypass ONLY the isMisspelled
  // gate: the typed token is a real dictionary word, so the system dictionary
  // reports it as correctly spelled and would otherwise block the correction.
  // They still respect isLearned and the confidence threshold — the LM-margin
  // gate in topCorrection already established the contraction is favored.
  const isAmbiguousContraction = topCorrection?.source === 'ambiguousContraction';

  // The user has explicitly or repeatedly accepted this word before.
  if (!isContraction && isLearned) return { decision: 'leaveAsIs' };

  // Only correct genuinely misspelled words. This prevents "me" → "message",
  // "and" → "Andrew", etc.
  if (!isContraction && !isAmbiguousContraction && !isMisspelled) {
    return { decision: 'leaveAsIs' };
  }

  // No candidate available.
  if (!topCorrection) return { decision: 'leaveAsIs' };
  const candidate = topCorrection;

  // Don't "correct" to the same word (case-insensitive).
  if (candidate.text.toLowerCase() === typedWord.toLowerCase()) {
    return { decision: 'leaveAsIs' };
  }

  // Confidence threshold (skipped for deterministic contractions).
  const minConfidenceScore = selectConfidenceThreshold({
    previousWord,
    trigramReady,
    fusedThreshold: config.minConfidenceScoreFused,
    unfusedThreshold: config.minConfidenceScore,
  });
  if (!isContraction && candidate.score < minConfidenceScore) {
    return { decision: 'leaveAsIs' };
  }

  // First-letter preservation: without it a typed "michael" can be "corrected"
  // to a higher-frequency word starting with a different letter. Comparison is
  // case-insensitive so "Teh" → "the" still fires.
  if (typedWord.toLowerCase()[0] !== candidate.text.toLowerCase()[0]) {
    return { decision: 'leaveAsIs' };
  }

  // Apply case preservation.
  const cased = preserveCase(typedWord, candidate.text, language);
  return { decision: 'correct', typedWord, correction: cased };
}

/**
 * Lowercases `correction` then re-applies the case shape of `typed`.
 *
 * - "hello" + "world" → "world"  (typed is lowercase)
 * - "Hello" + "world" → "World"  (typed is Capitalized)
 * - "HELLO" + "world" → "WORLD"  (typed is ALL CAPS)
 * - "HELLO" + "hello" → "HELLO"  (correction matches typed after uppercasing)
 *
 * Mirrors the Swift `String.capitalized` with a simple first-char-uppercase /
 * rest-lowercase rule (English-only keyboard).
 *
 * The "i'" pronoun rule is English orthography only — Greek has no apostrophe
 * contractions, so for 'greek' the correction is left exactly as the
 * case-shape transform produced (byte-identical Greek output).
 *
 * @param {string} typed - The word the user typed (case template).
 * @param {string} correction - The candidate to case.
 * @param {string} [language='english'] - Active keyboard language ('english'|'greek').
 * @returns {string}
 */
export function preserveCase(typed, correction, language = 'english') {
  if (typed.length === 0) return correction;
  let result;
  if (typed === typed.toUpperCase()) {
    result = correction.toUpperCase();
  } else if (typed === capitalize(typed)) {
    result = capitalize(correction);
  } else {
    result = correction.toLowerCase();
  }
  // English orthography: the standalone pronoun "i" is always capitalized ("I")
  // even after lowercase case-preservation — "id" → "I'd", not "i'd".
  if (language === 'english' && result[0] === 'i' && (result[1] === "'" || result[1] === '\u{2019}')) {
    return 'I' + result.slice(1);
  }
  return result;
}

function capitalize(s) {
  if (s.length === 0) return s;
  return s[0].toUpperCase() + s.slice(1).toLowerCase();
}
