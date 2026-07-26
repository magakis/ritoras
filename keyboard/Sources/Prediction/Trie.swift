import Foundation

// MARK: - Trie Node

final class TrieNode {
    var children: [Character: TrieNode] = [:]
    var isTerminal: Bool = false
}

// MARK: - Trie

/// A lightweight prefix trie for prefix completion and real-word checks.
/// Rebuilt from the bundled frequency dictionary (82,765 words).
final class Trie {

    private let root = TrieNode()
    private(set) var wordCount: Int = 0

    // MARK: - Insertion

    /// Inserts a single word into the trie.
    /// Package-internal so streaming loaders can insert one word at a time.
    func insert(word: String) {
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

    /// Returns words matching the given prefix.
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
        var results: [String] = []
        collectWords(from: node, prefix: lowerPrefix, results: &results)

        return Array(results.prefix(limit))
    }

    private func defaultSuggestions(limit: Int) -> [String] {
        var results: [String] = []
        collectWords(from: root, prefix: "", results: &results)
        return Array(results.prefix(limit))
    }

    private func collectWords(from node: TrieNode, prefix: String, results: inout [String]) {
        if node.isTerminal {
            results.append(prefix)
        }
        for (char, child) in node.children {
            collectWords(from: child, prefix: prefix + String(char), results: &results)
        }
    }
}
