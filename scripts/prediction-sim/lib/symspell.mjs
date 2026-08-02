// Pure-logic JS port of keyboard/Sources/Prediction/SymSpell/SymSpell.swift.
// Kept in sync per AGENTS.md -> Test policy.

/**
 * SymSpell: Symmetric Delete spelling correction algorithm.
 *
 * Generates all possible deletes (removing 1 or 2 characters) from each
 * dictionary word's prefix and indexes them. At lookup time, deletes of the
 * input are generated the same way and matched against the index — the edit
 * distance is then verified via Levenshtein to filter false positives.
 */
export class SymSpell {
  /**
   * @param {number} maxEditDistance - Maximum edit distance (default 2).
   * @param {number} prefixLength - Prefix length for delete-key generation (default 7).
   */
  constructor(maxEditDistance = 2, prefixLength = 7) {
    this.maxEditDistance = maxEditDistance;
    this.prefixLength = prefixLength;

    // Interned storage mirroring the Swift: each unique dictionary word is
    // stored ONCE in `words` and referenced everywhere else by its index.
    /** @type {string[]} */
    this.words = [];

    /** @type {number[]} */
    this.counts = [];

    /** @type {Map<string, number>} */
    this.wordToIndex = new Map();

    /** @type {Map<string, number[]>} */
    this.deletes = new Map();
  }

  // ---------------------------------------------------------------
  // Index Building
  // ---------------------------------------------------------------

  /**
   * Inserts a single word + frequency into the SymSpell index.
   * @param {string} key
   * @param {number} count
   */
  createDictionaryEntry(key, count) {
    const keyLower = key.toLowerCase();

    // Intern the word once and reference it by index everywhere else.
    let idx;
    if (this.wordToIndex.has(keyLower)) {
      idx = this.wordToIndex.get(keyLower);
      if (count > this.counts[idx]) {
        this.counts[idx] = count;
      }
    } else {
      idx = this.words.length;
      this.words.push(keyLower);
      this.counts.push(count);
      this.wordToIndex.set(keyLower, idx);
    }

    // The word itself is a delete-key (0 edits) so we can find it by exact
    // match through the delete index as well.
    const prefix = keyLower.slice(0, this.prefixLength);
    const deleteKeys = this._edits(prefix, this.maxEditDistance);

    for (const deleteKey of deleteKeys) {
      const list = this.deletes.get(deleteKey);
      if (list) {
        if (!list.includes(idx)) {
          list.push(idx);
        }
      } else {
        this.deletes.set(deleteKey, [idx]);
      }
    }
  }

  /**
   * Returns the frequency count for a dictionary word (0 if not present).
   * @param {string} word
   * @returns {number}
   */
  countFor(word) {
    const idx = this.wordToIndex.get(word);
    return idx === undefined ? 0 : this.counts[idx];
  }

  /**
   * Convenience: bulk-load from an array of {word, count}.
   * @param {Array<{word: string, count: number}>} words
   */
  bulkLoad(words) {
    for (const { word, count } of words) {
      this.createDictionaryEntry(word, count);
    }
  }

  // ---------------------------------------------------------------
  // Lookup
  // ---------------------------------------------------------------

  /**
   * @typedef {'top'|'all'|'closest'} Verbosity
   */

  /**
   * Returns suggestions for the given input term.
   * @param {string} input - The word to look up.
   * @param {number} [editDistance] - Maximum edit distance (default: configured maxEditDistance).
   * @param {Verbosity} [verbosity='top'] - How many suggestions to return.
   * @returns {Array<{term: string, count: number, distance: number}>}
   */
  lookup(input, editDistance, verbosity = 'top') {
    const maxED = editDistance ?? this.maxEditDistance;
    const inputLower = input.toLowerCase();
    /** @type {Map<string, {count: number, distance: number}>} */
    const suggestionSet = new Map();

    // Phase 1: exact match (edit distance 0) via word index.
    const exactIdx = this.wordToIndex.get(inputLower);
    if (exactIdx !== undefined) {
      suggestionSet.set(inputLower, {
        count: this.counts[exactIdx],
        distance: 0,
      });
    }

    // Phase 2: edit-space search. Generate deletes of the input prefix and
    // match against the delete index.
    const inputPrefix = inputLower.slice(0, this.prefixLength);
    const inputDeletes = this._edits(inputPrefix, maxED);

    for (const deleteKey of inputDeletes) {
      const matches = this.deletes.get(deleteKey);
      if (!matches) continue;

      for (const idx of matches) {
        const key = this.words[idx];
        if (suggestionSet.has(key)) continue;

        // Verify actual edit distance.
        const dist = this.levenshteinDistance(inputLower, key);
        if (dist <= maxED) {
          suggestionSet.set(key, { count: this.counts[idx], distance: dist });
        }
      }
    }

    // NOTE: No full-dictionary fallback here. The canonical SymSpell algorithm
    // guarantees that any correction within maxEditDistance is found by looking
    // up the input's own delete-variants in the precomputed deletes map.
    // If suggestionSet is empty, no correction exists within maxEditDistance.

    // Sort: edit distance ascending, then frequency descending.
    const sorted = [...suggestionSet.entries()]
      .map(([term, { count, distance }]) => ({ term, count, distance }))
      .sort((a, b) => {
        if (a.distance !== b.distance) return a.distance - b.distance;
        return b.count - a.count;
      });

    switch (verbosity) {
      case 'top':
        return sorted.slice(0, 1);
      case 'all':
      case 'closest':
        return sorted;
      default:
        return sorted;
    }
  }

  // ---------------------------------------------------------------
  // Edit Generation
  // ---------------------------------------------------------------

  /**
   * Recursively generates all strings obtainable by deleting 0 up to
   * `editDistance` characters from `word` (order-preserving).
   * @param {string} word
   * @param {number} editDistance
   * @returns {Set<string>}
   */
  _edits(word, editDistance) {
    const results = new Set([word]);
    if (editDistance <= 0 || word.length === 0) return results;

    const chars = [...word];
    const n = chars.length;
    const maxDelete = Math.min(editDistance, n);

    // Generate all combinations of position-subsets to delete for each depth.
    for (let deleteCount = 1; deleteCount <= maxDelete; deleteCount++) {
      const indices = Array.from({ length: deleteCount }, (_, i) => i);

      while (true) {
        let result = '';
        let di = 0;
        for (let i = 0; i < n; i++) {
          if (di < deleteCount && indices[di] === i) {
            di++; // skip
          } else {
            result += chars[i];
          }
        }
        results.add(result);

        // Next combination (lexicographic).
        let j = deleteCount - 1;
        while (j >= 0 && indices[j] === n - deleteCount + j) {
          j--;
        }
        if (j < 0) break;
        indices[j]++;
        for (let k = j + 1; k < deleteCount; k++) {
          indices[k] = indices[k - 1] + 1;
        }
      }
    }

    return results;
  }

  // ---------------------------------------------------------------
  // Levenshtein Distance
  // ---------------------------------------------------------------

  /**
   * Computes the Levenshtein edit distance between two strings.
   * @param {string} a
   * @param {string} b
   * @returns {number}
   */
  levenshteinDistance(a, b) {
    const aChars = [...a];
    const bChars = [...b];
    const m = aChars.length;
    const n = bChars.length;

    if (m === 0) return n;
    if (n === 0) return m;

    let previous = Array.from({ length: n + 1 }, (_, i) => i);
    let current = new Array(n + 1).fill(0);

    for (let i = 1; i <= m; i++) {
      current[0] = i;
      for (let j = 1; j <= n; j++) {
        const cost = aChars[i - 1] === bChars[j - 1] ? 0 : 1;
        current[j] = Math.min(
          previous[j] + 1,       // deletion
          current[j - 1] + 1,    // insertion
          previous[j - 1] + cost // substitution
        );
      }
      [previous, current] = [current, previous];
    }

    return previous[n];
  }
}

/**
 * Standalone Levenshtein distance function (no SymSpell instance needed).
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
export function levenshteinDistance(a, b) {
  return new SymSpell().levenshteinDistance(a, b);
}
