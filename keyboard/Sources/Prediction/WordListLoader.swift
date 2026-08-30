import Foundation

/// Loads the bundled frequency dictionary into SymSpell and Trie.
///
/// The resource files `frequency_dictionary_en_wordfreq_50k.txt` and
/// `frequency_dictionary_el_wordfreq_50k.txt` contain ~50,000 English / ~46,800
/// Greek words (wordfreq Zipf-derived) with their frequency counts, one per line:
///   `word count`
enum WordListLoader {

    /// Parsed entry from the frequency dictionary.
    struct Entry {
        let word: String
        let count: Int64
    }

    /// The bundled filename (without extension) for a language.
    private static func resourceName(for language: KeyboardLanguage) -> String {
        switch language {
        case .english: return "frequency_dictionary_en_wordfreq_50k"
        case .greek: return "frequency_dictionary_el_wordfreq_50k"
        }
    }

    private static let resourceExtension = "txt"

    /// Returns the URL for the bundled frequency dictionary in the keyboard extension's bundle.
    /// - Parameter language: The language whose dictionary to resolve (defaults to English,
    ///                       preserving existing call sites).
    static func bundledURL(language: KeyboardLanguage = .english) -> URL? {
        return Bundle.main.url(forResource: resourceName(for: language), withExtension: resourceExtension)
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
            entries.append(Entry(word: ApostropheNormalizer.canonicalize(word), count: count))
        }

        return entries
    }

    /// Stream-loads the frequency dictionary line-by-line into an optional
    /// SymSpell index and a Trie, periodically checking phys_footprint (private
    /// dirty memory). If memory exceeds `maxPhysFootprintBytes`, the load is
    /// aborted with a warning and the partial vocabulary is kept.
    ///
    /// - Parameters:
    ///   - url: URL to the .txt file.
    ///   - symSpell: The optional SymSpell instance to populate. Pass nil when
    ///               the index is supplied by a mapped blob.
    ///   - trie: The Trie instance to populate.
    ///   - maxPhysFootprintBytes: phys_footprint threshold in bytes. Defaults to the shared config value.
    ///   - pruneBelow: Optional minimum frequency threshold for pruning.
    /// - Returns: Number of words loaded.
    @discardableResult
    static func loadStreamed(
        from url: URL,
        into symSpell: SymSpell?,
        trie: Trie,
        maxPhysFootprintBytes: UInt64 = SharedConfig.Defaults.maxPhysFootprintDuringLoad,
        pruneBelow: Int64? = nil,
        buildSessionId: String? = nil
    ) throws -> Int {
        let diagnosticsEnabled = SharedConfig.Defaults.predictionDebugLoggingEnabled
        let streamStart = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        if diagnosticsEnabled {
            FileLogger.shared.debug(.dictionary, "word list stream start", payload: [
                "pathSuffix": String(url.path.suffix(96)),
                "symSpellEnabled": symSpell != nil,
                "pruneBelow": pruneBelow ?? 0,
                "maxFootprint": maxPhysFootprintBytes,
                "buildSessionId": buildSessionId ?? "none"
            ])
        }
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            if diagnosticsEnabled {
                FileLogger.shared.debug(.dictionary, "word list stream open failed", payload: [
                    "pathSuffix": String(url.path.suffix(96)),
                    "buildSessionId": buildSessionId ?? "none"
                ])
            }
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

                let didInsert: Bool = autoreleasepool {
                    guard let line = String(data: lineData, encoding: .utf8) else { return false }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return false }

                    // Format: "word count"
                    guard let spaceIndex = trimmed.lastIndex(of: " ") else { return false }
                    let word = String(trimmed[..<spaceIndex])
                    let countStr = String(trimmed[trimmed.index(after: spaceIndex)...])
                    guard let count = Int64(countStr) else { return false }

                    // Apply frequency pruning if configured.
                    if let minFreq = pruneBelow, count < minFreq { return false }

                    let canonicalWord = ApostropheNormalizer.canonicalize(word)
                    if let symSpell = symSpell {
                        symSpell.createDictionaryEntry(key: canonicalWord, count: count)
                    }
                    trie.insert(word: canonicalWord)
                    return true
                }

                guard didInsert else { continue }

                wordCount += 1

                if wordCount % 10_000 == 0, diagnosticsEnabled {
                    FileLogger.shared.debug(.dictionary, "word list stream progress", payload: [
                        "entriesLoaded": wordCount,
                        "trieInsertTotal": wordCount,
                        "symSpellEnabled": symSpell != nil,
                        "buildSessionId": buildSessionId ?? "none"
                    ])
                }

                // Periodic memory check every 5000 words.
                if wordCount % 5000 == 0 {
                    let physFootprint = MemoryMonitor.currentFootprint()
                    if physFootprint > maxPhysFootprintBytes {
                        if diagnosticsEnabled {
                            FileLogger.shared.debug(.dictionary, "word list memory guard triggered", payload: [
                                "physFootprint": physFootprint,
                                "maxPhysFootprint": maxPhysFootprintBytes,
                                "entriesLoaded": wordCount,
                                "trieInsertTotal": wordCount,
                                "elapsedMs": (DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000,
                                "buildSessionId": buildSessionId ?? "none"
                            ])
                        }
                        FileLogger.shared.error(.dictionary, "memory threshold exceeded during word list load", payload: ["physFootprint": physFootprint, "maxPhysFootprint": maxPhysFootprintBytes, "wordsLoaded": wordCount, "buildSessionId": buildSessionId ?? "none"])
                        if let symSpell = symSpell {
                            symSpell.finalize() // release the pending deletes map even on the abort path
                        }
                        return wordCount
                    }
                }
            }
        }

        if let symSpell = symSpell {
            symSpell.finalize()
        }

        if diagnosticsEnabled {
            FileLogger.shared.debug(.dictionary, "word list stream complete", payload: [
                "entriesLoaded": wordCount,
                "trieInsertTotal": wordCount,
                "symSpellFinalized": symSpell != nil,
                "elapsedMs": (DispatchTime.now().uptimeNanoseconds - streamStart) / 1_000_000,
                "buildSessionId": buildSessionId ?? "none",
                "footprint": MemoryMonitor.currentFootprint(),
                "resident": MemoryMonitor.currentResidentSize()
            ])
        }
        return wordCount
    }



    enum WordListError: Error, LocalizedError {
        case bundledFileNotFound
        case fileOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledFileNotFound:
                return "frequency_dictionary_<lang>_wordfreq_50k.txt not found in bundle. Ensure it is included in Copy Bundle Resources."
            case .fileOpenFailed(let path):
                return "Could not open file at \(path)"
            }
        }
    }
}
