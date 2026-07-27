// Pure-logic JS port of shared/LearnedWordsStore.swift.
// Kept in sync per AGENTS.md -> Test policy.
// The JS version is an in-memory test fixture — no on-disk persistence.

import { canonicalize } from './text-normalization.mjs';

const DEFAULT_MAX_LEARNED_WORDS = 1000;

/**
 * In-memory port of LearnedWordsStore with symmetric canonicalization.
 * No persistence — used as a test fixture.
 */
export class LearnedWordsStore {
  /**
   * @param {number} [maxLearnedWords=1000]
   */
  constructor(maxLearnedWords = DEFAULT_MAX_LEARNED_WORDS) {
    this.maxLearnedWords = maxLearnedWords;
    /** @type {Set<string>} */
    this.cache = new Set();
    /** @type {string[]} */
    this.insertionOrder = [];
  }

  /**
   * Adds a word to the store, with symmetric canonicalization.
   * @param {string} word
   */
  add(word) {
    const normalized = canonicalize(word.toLowerCase().trim());
    if (!normalized) return;
    if (this.cache.has(normalized)) return;

    this.cache.add(normalized);
    this.insertionOrder.push(normalized);

    if (this.cache.size > this.maxLearnedWords) {
      const oldest = this.insertionOrder.shift();
      this.cache.delete(oldest);
    }
  }

  /**
   * Returns true when the word has been learned (case-insensitive, canonicalized).
   * @param {string} word
   * @returns {boolean}
   */
  contains(word) {
    return this.cache.has(canonicalize(word.toLowerCase().trim()));
  }

  /**
   * Returns all learned words in sorted order.
   * @returns {string[]}
   */
  allWords() {
    return [...this.cache].sort();
  }

  /**
   * Returns all learned words in most-recently-added-first order.
   * @returns {string[]}
   */
  allWordsMostRecentFirst() {
    return [...this.insertionOrder].reverse();
  }

  /**
   * Removes all learned words.
   */
  clear() {
    this.cache.clear();
    this.insertionOrder = [];
  }

  /**
   * Removes a single word.
   * @param {string} word
   */
  remove(word) {
    const normalized = canonicalize(word.toLowerCase().trim());
    if (!this.cache.has(normalized)) return;
    this.cache.delete(normalized);
    this.insertionOrder = this.insertionOrder.filter(w => w !== normalized);
  }

  /**
   * Reloads from an array of persisted words (simulates re-reading UserDefaults).
   * Applies canonicalization during load, same as init.
   * @param {string[]} stored
   */
  reload(stored) {
    if (stored && stored.length > 0) {
      const trimmed = stored.length > this.maxLearnedWords
        ? stored.slice(-this.maxLearnedWords)
        : stored;
      const canonicalized = trimmed.map(w => canonicalize(w));
      this.cache = new Set(canonicalized);
      this.insertionOrder = canonicalized;
    } else {
      this.cache = new Set();
      this.insertionOrder = [];
    }
  }
}
