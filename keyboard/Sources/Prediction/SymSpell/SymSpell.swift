// MIT License
//
// Copyright (c) 2020 Wolf Garbe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// This is a Swift port of SymSpell (https://github.com/wolfgarbe/SymSpell).

import Foundation

/// SymSpell: Symmetric Delete spelling correction algorithm.
///
/// Generates all possible deletes (removing 1 or 2 characters) from each
/// dictionary word's prefix and indexes them. At lookup time, deletes of the
/// input are generated the same way and matched against the index — the edit
/// distance is then verified via Levenshtein to filter false positives.
final class SymSpell {

    // MARK: - Verbosity

    enum Verbosity {
        /// Top suggestion only (lowest edit distance, highest frequency).
        case top
        /// All suggestions within maxEditDistance.
        case all
        /// All suggestions within maxEditDistance.
        case closest
    }

    // MARK: - Types

    struct Term: Hashable {
        let term: String
        let count: Int64
    }

    // MARK: - Configuration

    let maxEditDistance: Int
    let prefixLength: Int

    // MARK: - Index

    /// Maps a delete key (an edited-down string) to the list of dictionary terms
    /// that produce it. The key is a delete of the dictionary word's prefix.
    private(set) var deletes: [String: [Term]] = [:]

    /// Maps each dictionary word to its frequency count for O(1) exact-lookup.
    private(set) var dictionary: [String: Int64] = [:]

    // MARK: - Initialization

    init(maxEditDistance: Int = 2, prefixLength: Int = 7) {
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
    }

    // MARK: - Index Building

    /// Inserts a single word + frequency into the SymSpell index.
    func createDictionaryEntry(key: String, count: Int64) {
        let keyLower = key.lowercased()

        // Store the exact entry.
        if count > dictionary[keyLower] ?? 0 {
            dictionary[keyLower] = count
        }

        // The word itself is a delete-key (0 edits) so we can find it by exact
        // match through the delete index as well.
        let prefix = String(keyLower.prefix(prefixLength))
        let deleteKeys = edits(word: prefix, editDistance: maxEditDistance)

        for deleteKey in deleteKeys {
            let term = Term(term: keyLower, count: count)
            if deletes[deleteKey] != nil {
                if !deletes[deleteKey]!.contains(where: { $0.term == keyLower }) {
                    deletes[deleteKey]!.append(term)
                }
            } else {
                deletes[deleteKey] = [term]
            }
        }
    }

    /// Convenience: bulk-load from an array of (word, count) tuples.
    func bulkLoad(words: [(String, Int64)]) {
        for (word, count) in words {
            createDictionaryEntry(key: word, count: count)
        }
    }

    // MARK: - Lookup

    /// Returns suggestions for the given input term.
    /// - Parameters:
    ///   - input: The word to look up (can be a typo or correctly spelled word).
    ///   - editDistance: Maximum edit distance (default: configured maxEditDistance).
    ///   - verbosity: How many suggestions to return (default: .top).
    /// - Returns: Array of (term, count, distance) tuples, sorted by relevance.
    func lookup(
        input: String,
        editDistance: Int? = nil,
        verbosity: Verbosity = .top
    ) -> [(term: String, count: Int64, distance: Int)] {
        let maxED = editDistance ?? maxEditDistance
        let inputLower = input.lowercased()
        var suggestionSet: [String: (count: Int64, distance: Int)] = [:]

        // Phase 1: exact match (edit distance 0) via dictionary lookup.
        if let count = dictionary[inputLower] {
            suggestionSet[inputLower] = (count, 0)
        }

        // Phase 2: edit-space search. Generate deletes of the input prefix and
        // match against the delete index.
        let inputPrefix = String(inputLower.prefix(prefixLength))
        let inputDeletes = edits(word: inputPrefix, editDistance: maxED)

        for deleteKey in inputDeletes {
            guard let matches = deletes[deleteKey] else { continue }
            for term in matches {
                let key = term.term
                if suggestionSet.keys.contains(key) { continue }

                // Verify actual edit distance.
                let dist = levenshteinDistance(inputLower, key)
                if dist <= maxED {
                    suggestionSet[key] = (term.count, dist)
                }
            }
        }

        // NOTE: No full-dictionary fallback here. The canonical SymSpell algorithm
        // guarantees that any correction within maxEditDistance is found by looking
        // up the input's own delete-variants in the precomputed `deletes` map.
        // If suggestionSet is empty, no correction exists within maxEditDistance.
        // (https://github.com/wolfgarbe/SymSpell)

        // Sort: edit distance ascending, then frequency descending.
        let sorted = suggestionSet
            .map { (term: $0.key, count: $0.value.count, distance: $0.value.distance) }
            .sorted { a, b in
                if a.distance != b.distance { return a.distance < b.distance }
                return a.count > b.count
            }

        switch verbosity {
        case .top:
            return Array(sorted.prefix(1))
        case .all, .closest:
            return sorted
        }
    }

    // MARK: - Edit Generation

    /// Recursively generates all strings obtainable by deleting 0 up to
    /// `editDistance` characters from `word` (order-preserving).
    private func edits(word: String, editDistance: Int) -> Set<String> {
        var results: Set<String> = [word]
        guard editDistance > 0, !word.isEmpty else { return results }

        let chars = Array(word)
        let n = chars.count
        let maxDelete = min(editDistance, n)

        // Generate all combinations of position-subsets to delete for each depth.
        for deleteCount in 1...maxDelete {
            var indices = Array(0..<deleteCount)
            while true {
                var result = ""
                var di = 0
                for i in 0..<n {
                    if di < deleteCount && indices[di] == i {
                        di += 1 // skip
                    } else {
                        result.append(chars[i])
                    }
                }
                results.insert(result)

                // Next combination (lexicographic).
                var j = deleteCount - 1
                while j >= 0 && indices[j] == n - deleteCount + j {
                    j -= 1
                }
                if j < 0 { break }
                indices[j] += 1
                for k in (j + 1)..<deleteCount {
                    indices[k] = indices[k - 1] + 1
                }
            }
        }

        return results
    }

    // MARK: - Levenshtein Distance

    /// Computes the Levenshtein edit distance between two strings.
    func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        guard m > 0 else { return n }
        guard n > 0 else { return m }

        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            current[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            (previous, current) = (current, previous)
        }

        return previous[n]
    }
}
