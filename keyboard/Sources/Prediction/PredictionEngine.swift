import Foundation

// MARK: - Trie Node

final class TrieNode {
    var children: [Character: TrieNode] = [:]
    var frequency: Int = 0
    var isTerminal: Bool = false
}

// MARK: - Prediction Engine

final class PredictionEngine {

    private let root = TrieNode()
    private let totalWordCount: Int

    // MARK: - Initialization

    init() {
        let words = WordList.words
        totalWordCount = words.count
        for (index, word) in words.enumerated() {
            insert(word: word, frequency: max(1, totalWordCount - index))
        }
    }

    private func insert(word: String, frequency: Int) {
        var node = root
        for char in word {
            if let next = node.children[char] {
                node = next
            } else {
                let next = TrieNode()
                node.children[char] = next
                node = next
            }
        }
        node.isTerminal = true
        if frequency > node.frequency {
            node.frequency = frequency
        }
    }

    // MARK: - Suggestions

    /// Returns the top-N most frequent words matching the given prefix.
    /// - Parameters:
    ///   - prefix: The prefix to match (can be empty for default suggestions).
    ///   - limit: Maximum number of suggestions to return (default 3).
    /// - Returns: Array of suggested words, highest frequency first.
    func suggest(prefix: String, limit: Int = 3) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // Return the 3 most common words overall
            return defaultSuggestions(limit: limit)
        }

        // Normalize to lowercase for trie lookup
        let lowerPrefix = trimmed.lowercased()

        // Navigate to the prefix node
        var node = root
        for char in lowerPrefix {
            guard let next = node.children[char] else {
                return []
            }
            node = next
        }

        // Collect all words under this prefix
        var results: [(String, Int)] = []
        collectWords(from: node, prefix: lowerPrefix, results: &results)

        // Sort by frequency descending and take top N
        results.sort { $0.1 > $1.1 }
        let top = results.prefix(limit).map { $0.0 }

        // Preserve original capitalization style
        if trimmed.first?.isUppercase == true {
            return top.map { $0.capitalized }
        }
        return top
    }

    private func defaultSuggestions(limit: Int) -> [String] {
        var results: [(String, Int)] = []
        collectWords(from: root, prefix: "", results: &results)
        results.sort { $0.1 > $1.1 }
        return results.prefix(limit).map { $0.0 }
    }

    private func collectWords(from node: TrieNode, prefix: String, results: inout [(String, Int)]) {
        if node.isTerminal {
            results.append((prefix, node.frequency))
        }
        for (char, child) in node.children {
            collectWords(from: child, prefix: prefix + String(char), results: &results)
        }
    }
}
