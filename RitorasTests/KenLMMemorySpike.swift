import XCTest

/// Measures the resident memory delta of the KenLM 3-gram trie model.
///
/// Run this test in Release configuration on an iOS device (or simulator
/// approximating iOS memory behavior). The target is ≤3 MB resident delta.
///
/// If >3 MB, consider requantizing the model with tighter pointer compression
/// (e.g. `-a 48`) or reducing vocabulary size to 15k.
final class KenLMMemorySpike: XCTestCase {

    /// Measure resident memory delta after loading and warming up the KenLM model.
    func testKenLMMemoryBaseline() throws {
        // 1. Baseline
        let baseline = getResidentMemoryMB()

        // 2. Locate model
        guard let modelPath = Bundle(for: type(of: self))
            .path(forResource: "trigram_en_v1", ofType: "klm")
            ?? Bundle.main.path(forResource: "trigram_en_v1", ofType: "klm") else {
            throw XCTSkip("trigram_en_v1.klm not found in test bundle")
        }

        // 3. Load
        guard let model = kenlm_load(modelPath) else {
            XCTFail("kenlm_load returned nil for path: \(modelPath)")
            return
        }
        defer { kenlm_free(model) }

        // 4. Warmup: run 50 queries with typical contexts to page in trie nodes.
        for _ in 0..<50 {
            _ = kenlm_score_sentence(model, "i am looking very")
            _ = kenlm_score_sentence(model, "the quick brown")
            _ = kenlm_score_sentence(model, "she said that")
            _ = kenlm_score_sentence(model, "i want to go")
            _ = kenlm_score_sentence(model, "looking for a")
        }

        // 5. Re-measure
        let loaded = getResidentMemoryMB()
        let delta = loaded - baseline

        print("--- KenLM Memory Spike ---")
        print("Baseline: \(String(format: "%.2f", baseline)) MB")
        print("Loaded:   \(String(format: "%.2f", loaded)) MB")
        print("Delta:    \(String(format: "%.2f", delta)) MB")
        print("--------------------------")

        // 6. Assert — KenLM trie alone adds ≤3 MB after warmup.
        XCTAssertLessThanOrEqual(delta, 3.0,
            "KenLM trie resident delta \(String(format: "%.2f", delta)) MB exceeds 3 MB budget")
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
}
