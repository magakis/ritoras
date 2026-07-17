import Foundation

// MARK: - Trie Node

final class TrieNode {
    var children: [Character: TrieNode] = [:]
    var frequency: Int64 = 0
    var isTerminal: Bool = false
}

// MARK: - Trie

/// A lightweight prefix trie backed by frequency data.
/// Rebuilt from the bundled frequency dictionary (82,765 words).
final class Trie {

    private let root = TrieNode()
    private(set) var wordCount: Int = 0

    // MARK: - Loading

    /// Loads words from a frequency-dictionary file (format: "word count" per line).
    func load(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: .whitespaces)
            guard parts.count >= 2 else { continue }
            let word = parts[0]
            guard let count = Int64(parts[1]) else { continue }
            insert(word: word, frequency: count)
        }
    }

    /// Bulk-load from parsed (word, count) tuples.
    func bulkLoad(words: [(String, Int64)]) {
        for (word, count) in words {
            insert(word: word, frequency: count)
        }
    }

    // MARK: - Insertion

    /// Inserts a single word with its frequency into the trie.
    /// Package-internal so streaming loaders can insert one word at a time.
    func insert(word: String, frequency: Int64) {
        var node = root
        for char in word.lowercased() {
            if let next = node.children[char] {
                node = next
            } else {
                let next = TrieNode()
                node.children[char] = next
                node = next
            }
        }
        if !node.isTerminal {
            wordCount += 1
        }
        node.isTerminal = true
        if frequency > node.frequency {
            node.frequency = frequency
        }
    }

    // MARK: - Query

    /// Returns true if the word exists in the trie (exact match).
    func contains(word: String) -> Bool {
        var node = root
        for char in word.lowercased() {
            guard let next = node.children[char] else { return false }
            node = next
        }
        return node.isTerminal
    }

    /// Returns the top-N most frequent words matching the given prefix.
    func suggest(prefix: String, limit: Int = 3) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultSuggestions(limit: limit)
        }

        let lowerPrefix = trimmed.lowercased()

        // Navigate to the prefix node.
        var node = root
        for char in lowerPrefix {
            guard let next = node.children[char] else {
                return []
            }
            node = next
        }

        // Collect all words under this prefix.
        var results: [(String, Int64)] = []
        collectWords(from: node, prefix: lowerPrefix, results: &results)

        // Sort by frequency descending and take top N.
        results.sort { $0.1 > $1.1 }
        let top = results.prefix(limit).map { $0.0 }

        // Preserve original capitalization style.
        if trimmed.first?.isUppercase == true {
            return top.map { $0.capitalized }
        }
        return top
    }

    private func defaultSuggestions(limit: Int) -> [String] {
        var results: [(String, Int64)] = []
        collectWords(from: root, prefix: "", results: &results)
        results.sort { $0.1 > $1.1 }
        return results.prefix(limit).map { $0.0 }
    }

    private func collectWords(from node: TrieNode, prefix: String, results: inout [(String, Int64)]) {
        if node.isTerminal {
            results.append((prefix, node.frequency))
        }
        for (char, child) in node.children {
            collectWords(from: child, prefix: prefix + String(char), results: &results)
        }
    }
}
