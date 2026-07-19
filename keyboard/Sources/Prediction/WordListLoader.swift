import Foundation
import os

/// Loads the bundled frequency dictionary into SymSpell and Trie.
///
/// The resource file `frequency_dictionary_en_wordfreq_50k.txt` contains
/// ~50,000 English words (wordfreq Zipf-derived) with their frequency counts, one per line:
///   `word count`
enum WordListLoader {

    /// Parsed entry from the frequency dictionary.
    struct Entry {
        let word: String
        let count: Int64
    }

    /// The bundled filename (without extension).
    private static let resourceName = "frequency_dictionary_en_wordfreq_50k"
    private static let resourceExtension = "txt"

    /// Returns the URL for the bundled frequency dictionary in the keyboard extension's bundle.
    static func bundledURL() -> URL? {
        return Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// Loads and parses the frequency dictionary from a URL.
    /// - Parameter url: URL to the .txt file.
    /// - Returns: Array of parsed entries.
    static func load(from url: URL) throws -> [Entry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var entries: [Entry] = []
        entries.reserveCapacity(83000)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Format: "word count"
            guard let spaceIndex = trimmed.lastIndex(of: " ") else { continue }
            let word = String(trimmed[..<spaceIndex])
            let countStr = String(trimmed[trimmed.index(after: spaceIndex)...])

            guard let count = Int64(countStr) else { continue }
            entries.append(Entry(word: word, count: count))
        }

        return entries
    }

    /// Loads the bundled dictionary and populates both a SymSpell index and a Trie.
    /// - Parameters:
    ///   - symSpell: The SymSpell instance to populate.
    ///   - trie: The Trie instance to populate.
    ///   - pruneBelow: Optional minimum frequency threshold for pruning (e.g., 50).
    /// - Returns: Number of words loaded.
    @discardableResult
    static func loadInto(symSpell: SymSpell, trie: Trie, pruneBelow: Int64? = nil) throws -> Int {
        guard let url = bundledURL() else {
            throw WordListError.bundledFileNotFound
        }
        let entries = try load(from: url)

        let filtered: [Entry]
        if let minFreq = pruneBelow {
            filtered = entries.filter { $0.count >= minFreq }
        } else {
            filtered = entries
        }

        for entry in filtered {
            symSpell.createDictionaryEntry(key: entry.word, count: entry.count)
        }
        trie.bulkLoad(words: filtered.map { ($0.word, $0.count) })

        return filtered.count
    }

    /// Stream-loads the frequency dictionary line-by-line into SymSpell and Trie,
    /// periodically checking resident memory. If memory exceeds `maxResidentBytes`,
    /// the load is aborted with a warning and the partial vocabulary is kept.
    ///
    /// - Parameters:
    ///   - url: URL to the .txt file.
    ///   - symSpell: The SymSpell instance to populate.
    ///   - trie: The Trie instance to populate.
    ///   - maxResidentBytes: Memory threshold in bytes. Defaults to the shared config value.
    ///   - pruneBelow: Optional minimum frequency threshold for pruning.
    /// - Returns: Number of words loaded.
    @discardableResult
    static func loadStreamed(
        from url: URL,
        into symSpell: SymSpell,
        trie: Trie,
        maxResidentBytes: UInt64 = SharedConfig.Defaults.maxResidentBytesDuringLoad,
        pruneBelow: Int64? = nil
    ) throws -> Int {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw WordListError.fileOpenFailed(url.path)
        }
        defer { fileHandle.closeFile() }

        let chunkSize = 4096
        var buffer = Data()
        var wordCount = 0

        while true {
            let data = fileHandle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            buffer.append(data)

            // Process all complete lines in the buffer.
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[..<newlineIndex]
                buffer = buffer[(newlineIndex + 1)...]

                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // Format: "word count"
                guard let spaceIndex = trimmed.lastIndex(of: " ") else { continue }
                let word = String(trimmed[..<spaceIndex])
                let countStr = String(trimmed[trimmed.index(after: spaceIndex)...])
                guard let count = Int64(countStr) else { continue }

                // Apply frequency pruning if configured.
                if let minFreq = pruneBelow, count < minFreq { continue }

                symSpell.createDictionaryEntry(key: word, count: count)
                trie.insert(word: word, frequency: count)
                wordCount += 1

                // Periodic memory check every 5000 words.
                if wordCount % 5000 == 0 {
                    let resident = getResidentBytes()
                    if resident > maxResidentBytes {
                        os_log(.error,
                               "WordListLoader: memory threshold exceeded (%llu bytes > %llu bytes) — aborting load after %d words",
                               resident, maxResidentBytes, wordCount)
                        return wordCount
                    }
                }
            }
        }

        return wordCount
    }

    // MARK: - Memory Monitoring

    /// Returns the current resident memory of this process in bytes,
    /// or 0 if the Mach call fails.
    static func getResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    enum WordListError: Error, LocalizedError {
        case bundledFileNotFound
        case fileOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledFileNotFound:
                return "frequency_dictionary_en_wordfreq_50k.txt not found in bundle. Ensure it is included in Copy Bundle Resources."
            case .fileOpenFailed(let path):
                return "Could not open file at \(path)"
            }
        }
    }
}
