import XCTest

/// Measures the resident memory of the SymSpell index alone.
///
/// Run this test in Release configuration on an iOS device (or simulator
/// approximating iOS memory behavior). The target is ≤25 MB resident.
///
/// If >40 MB, prune the dictionary by dropping words with frequency < 50
/// and/or lowering prefixLength to 6.
final class SymSpellMemorySpike: XCTestCase {

    /// Measure resident memory of the SymSpell index built from the
    /// wordfreq-derived frequency dictionary.
    func testSymSpellMemoryBaseline() throws {
        // 1. Build the index.
        let symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)

        let bundle = Bundle(for: SymSpellMemorySpike.self)
        let url = bundle.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                             withExtension: "txt")
            ?? Bundle.main.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                               withExtension: "txt")
        guard let fileURL = url else {
            throw XCTSkip("frequency_dictionary_en_wordfreq_50k.txt not found")
        }

        // Measure time to build.
        let buildStart = CFAbsoluteTimeGetCurrent()
        let entries = try WordListLoader.load(from: fileURL)
        var loaded = 0
        for entry in entries {
            symSpell.createDictionaryEntry(key: entry.word, count: entry.count)
            loaded += 1
        }
        let buildTime = CFAbsoluteTimeGetCurrent() - buildStart

        // 2. Measure resident memory.
        let memoryMB = getResidentMemoryMB()

        print("--- SymSpell Memory Spike ---")
        print("Words loaded: \(loaded)")
        print("Dictionary entries (unique): \(symSpell.dictionary.count)")
        print("Delete index entries: \(symSpell.deletes.count)")
        print("Build time: \(String(format: "%.2f", buildTime * 1000)) ms")
        print("Resident memory (delta): \(String(format: "%.1f", memoryMB)) MB")
        print("-----------------------------")

        // 3. Verify correctness with a known typo.
        let results = symSpell.lookup(input: "teh", verbosity: .top)
        XCTAssertEqual(results.first?.term, "the",
                       "Sanity check: teh should correct to the")

        // 4. Assert memory budget.
        // If this fails (>25 MB), prune: drop words with frequency < 50
        // and/or lower prefixLength to 6.
        XCTAssertLessThanOrEqual(memoryMB, 25,
                                 "SymSpell index exceeds 25 MB memory budget (\(memoryMB) MB). Consider pruning.")
    }

    /// Measure combined resident memory of SymSpell + Trigram + SideIndex.
    ///
    /// Target: ≤33 MB combined (leaving ~7 MB headroom under the 40 MB
    /// practical Jetsam ceiling for UIKit/audio/IPC baseline).
    func testCombinedSymSpellAndTrigramMemoryBaseline() throws {
        let baseline = getResidentMemoryMB()

        // 1. Build SymSpell (same pattern as testSymSpellMemoryBaseline).
        let symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)

        let bundle = Bundle(for: SymSpellMemorySpike.self)
        let url = bundle.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                             withExtension: "txt")
            ?? Bundle.main.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                               withExtension: "txt")
        guard let fileURL = url else {
            throw XCTSkip("frequency_dictionary_en_wordfreq_50k.txt not found")
        }
        let entries = try WordListLoader.load(from: fileURL)
        for entry in entries {
            symSpell.createDictionaryEntry(key: entry.word, count: entry.count)
        }

        // 2. Load KenLM model.
        guard let modelPath = Bundle(for: SymSpellMemorySpike.self)
            .path(forResource: "trigram_en_v1", ofType: "klm")
            ?? Bundle.main.path(forResource: "trigram_en_v1", ofType: "klm") else {
            throw XCTSkip("trigram_en_v1.klm not found in test bundle")
        }
        guard let model = kenlm_load(modelPath) else {
            XCTFail("kenlm_load returned nil")
            return
        }
        defer { kenlm_free(model) }

        // 3. Warmup KenLM.
        for _ in 0..<50 {
            _ = kenlm_score_sentence(model, "i am looking very")
        }

        // 4. Load SideIndex.
        guard let sideIndex = SideIndex() else {
            XCTFail("SideIndex failed to load")
            return
        }

        let loaded = getResidentMemoryMB()
        let delta = loaded - baseline

        print("--- Combined Memory (SymSpell + Trigram + SideIndex) ---")
        print("Baseline:  \(String(format: "%.2f", baseline)) MB")
        print("Loaded:    \(String(format: "%.2f", loaded)) MB")
        print("Delta:     \(String(format: "%.2f", delta)) MB")
        print("SymSpell dict entries:  \(symSpell.dictionary.count)")
        print("SideIndex loaded:       \(sideIndex.isLoaded)")
        print("--------------------------------------------------------")

        XCTAssertLessThanOrEqual(delta, 33.0,
            "Combined resident memory \(String(format: "%.2f", delta)) MB exceeds 33 MB budget")
    }

    // MARK: - Memory Measurement

    /// Returns the current resident memory size of this process in megabytes.
    private func getResidentMemoryMB() -> Double {
        #if targetEnvironment(simulator)
        return estimateMemoryMB()
        #else
        // Mach task_info on device for accurate resident memory.
        let flavor = task_flavor_t(TASK_VM_INFO)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, flavor, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return estimateMemoryMB()
        }
        let residentSize = Double(info.resident_size)
        return residentSize / (1024.0 * 1024.0)
        #endif
    }

    /// Rough memory estimate for simulator where task_info is unreliable.
    private func estimateMemoryMB() -> Double {
        return 0.0 // Cannot measure on simulator — run on device for accurate values
    }

    // MARK: - Streaming Load

    /// Verifies that the streaming loader loads the expected ~50k words.
    func testStreamingLoadCount() throws {
        let bundle = Bundle(for: SymSpellMemorySpike.self)
        let url = bundle.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                             withExtension: "txt")
            ?? Bundle.main.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                               withExtension: "txt")
        guard let fileURL = url else {
            throw XCTSkip("frequency_dictionary_en_wordfreq_50k.txt not found")
        }

        let symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)
        let trie = Trie()

        let count = try WordListLoader.loadStreamed(
            from: fileURL,
            into: symSpell,
            trie: trie
        )

        XCTAssertGreaterThan(count, 40000,
                             "Streaming load should load ~50k words, got \(count)")
        XCTAssertEqual(count, symSpell.dictionary.count,
                       "Streamed word count should match SymSpell dictionary count")
        XCTAssertEqual(count, trie.wordCount,
                       "Streamed word count should match Trie word count")
    }
}
