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

    // MARK: - Configuration

    let maxEditDistance: Int
    let prefixLength: Int

    // MARK: - Index

    // Interned storage: each unique dictionary word is stored ONCE in `words`
    // and referenced everywhere else by its `Int32` index (4 bytes instead of
    // a duplicated String — ~24 bytes per reference). Counts fit in Int32: the
    // largest frequency in the bundled dictionary is 53,703,180 ("the"), far
    // below Int32.max (2,147,483,647). The ceiling is guarded by a
    // precondition at insertion.
    private(set) var words: [String] = []
    private(set) var counts: [Int32] = []
    private(set) var wordToIndex: [String: Int32] = [:]

    // Delete-index storage: during loading, `pendingDeletes` maps a delete key
    // (an edited-down string) to the list of word indices that produce it.
    // finalize() freezes this into a CSR (compressed-sparse-row) layout —
    // one sorted key array, one offset table, one flat value buffer — so the
    // ~150k separate `[Int32]` array headers (~4.8 MB) are released.
    private var pendingDeletes: [String: [Int32]] = [:]
    private(set) var deleteKeys: [String] = []      // sorted lexicographically
    private(set) var deleteOffsets: [Int] = []      // keys.count + 1; offsets[i]..<offsets[i+1] into deleteValues
    private(set) var deleteValues: [Int32] = []     // flat: all index-lists concatenated
    private(set) var isFinalized = false

    // MARK: - Initialization

    init(maxEditDistance: Int = 2, prefixLength: Int = 7) {
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
    }

    // MARK: - Index Building

    /// Inserts a single word + frequency into the SymSpell index.
    func createDictionaryEntry(key: String, count: Int64) {
        let keyLower = key.lowercased()

        precondition(count <= Int64(Int32.max), "SymSpell count exceeds Int32.max: \(count)")

        // Intern the word once and reference it by index everywhere else.
        let idx: Int32
        if let existing = wordToIndex[keyLower] {
            idx = existing
            if count > Int64(counts[Int(idx)]) {
                counts[Int(idx)] = Int32(count)
            }
        } else {
            idx = Int32(words.count)
            words.append(keyLower)
            counts.append(Int32(count))
            wordToIndex[keyLower] = idx
        }

        // The word itself is a delete-key (0 edits) so we can find it by exact
        // match through the delete index as well.
        let prefix = String(keyLower.prefix(prefixLength))
        let deleteKeys = edits(word: prefix, editDistance: maxEditDistance)

        for deleteKey in deleteKeys {
            if pendingDeletes[deleteKey] != nil {
                if !pendingDeletes[deleteKey]!.contains(idx) {
                    pendingDeletes[deleteKey]!.append(idx)
                }
            } else {
                pendingDeletes[deleteKey] = [idx]
            }
        }
    }

    /// Returns the frequency count for a dictionary word (0 if not present).
    /// Keys are stored lowercased, so the caller must lowercase `word` before
    /// calling (matching the old `dictionary[k]` contract).
    func count(for word: String) -> Int64 {
        if let idx = wordToIndex[word] {
            return Int64(counts[Int(idx)])
        }
        return 0
    }

    /// Convenience: bulk-load from an array of (word, count) tuples.
    func bulkLoad(entries: [(String, Int64)]) {
        for (word, count) in entries {
            createDictionaryEntry(key: word, count: count)
        }
    }

    // MARK: - CSR Finalization

    /// Freeze the pending deletes map into a compact CSR layout and drop the
    /// intermediate map. Idempotent. Called by WordListLoader after the load
    /// loop; lookup falls back to `pendingDeletes` until this runs.
    func finalize() {
        guard !isFinalized else { return }
        // Sort keys lexicographically; pack values flat; build offsets.
        let sortedKeys = pendingDeletes.keys.sorted()
        deleteOffsets.reserveCapacity(sortedKeys.count + 1)
        deleteValues.reserveCapacity(pendingDeletes.values.reduce(0) { $0 + $1.count })
        var offset = 0
        for key in sortedKeys {
            let bucket = pendingDeletes[key]!
            deleteKeys.append(key)
            deleteOffsets.append(offset)
            deleteValues.append(contentsOf: bucket)
            offset += bucket.count
        }
        deleteOffsets.append(offset)   // sentinel: offsets.count == keys.count + 1
        pendingDeletes.removeAll()
        pendingDeletes = [:]           // release the map (and its ~150k array headers)
        isFinalized = true
    }

    /// Returns the index of `key` in the finalized `deleteKeys` array, or nil.
    private func binarySearchDeleteKey(_ key: String) -> Int? {
        var low = 0
        var high = deleteKeys.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let midKey = deleteKeys[mid]
            if midKey == key {
                return mid
            } else if midKey < key {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return nil
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

        // Phase 1: exact match (edit distance 0) via word index.
        if let idx = wordToIndex[inputLower] {
            suggestionSet[inputLower] = (Int64(counts[Int(idx)]), 0)
        }

        // Phase 2: edit-space search. Generate deletes of the input prefix and
        // match against the delete index.
        let inputPrefix = String(inputLower.prefix(prefixLength))
        let inputDeletes = edits(word: inputPrefix, editDistance: maxED)

        for deleteKey in inputDeletes {
            // Resolve the bucket: CSR slice when finalized, pending map
            // otherwise (lookup-before-finalize fallback, e.g. in tests).
            let bucket: [Int32]
            if isFinalized {
                guard let i = binarySearchDeleteKey(deleteKey) else { continue }
                bucket = Array(deleteValues[deleteOffsets[i]..<deleteOffsets[i + 1]])
            } else {
                guard let pendingBucket = pendingDeletes[deleteKey] else { continue }
                bucket = pendingBucket
            }

            for idx in bucket {
                let key = words[Int(idx)]
                if suggestionSet.keys.contains(key) { continue }

                // Verify actual edit distance.
                let dist = levenshteinDistance(inputLower, key)
                if dist <= maxED {
                    suggestionSet[key] = (Int64(counts[Int(idx)]), dist)
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

    deinit {
        FileLogger.shared.info(.dictionary, "SymSpell deinit",
            payload: ["wordsCount": words.count, "deleteKeysCount": deleteKeys.count, "deleteValuesCount": deleteValues.count, "isFinalized": isFinalized])
    }
}
