import XCTest

/// Measures per-query latency of the TrigramProvider and the underlying KenLM
/// C bridge. Enforces p99 ≤ 5 ms per the Phase 2 budget.
///
/// Run on an iOS device (or simulator) in Release configuration.
final class TrigramLatencyTest: XCTestCase {

    private var provider: TrigramProvider?

    override func setUp() {
        super.setUp()
        let p = TrigramProvider()
        let ready = XCTestExpectation(description: "provider ready")
        p.warmup { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5.0)
        provider = p.isReady ? p : nil
    }

    override func tearDown() {
        provider = nil
        super.tearDown()
    }

    /// Measures the TrigramProvider.suggest(for:limit:) latency with a known
    /// bigram context ("i am") that exists in the side index.
    func testTrigramQueryLatency() throws {
        guard let provider = provider else {
            throw XCTSkip("TrigramProvider not ready — model file may be missing from test bundle")
        }

        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "am",
            previousWord2: "i",
            isMidWord: false
        )

        var latencies: [Double] = []
        latencies.reserveCapacity(1000)

        // Warmup: 50 iterations to stabilize caches.
        for _ in 0..<50 {
            _ = provider.suggest(for: context, limit: 3)
        }

        // Measure 1000 iterations for p99.
        for _ in 0..<1000 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = provider.suggest(for: context, limit: 3)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 // ms
            latencies.append(elapsed)
        }

        latencies.sort()
        let p99 = latencies[989] // 0-indexed: 990th element
        let avg = latencies.reduce(0, +) / Double(latencies.count)

        print("--- TrigramProvider Query Latency (1000 samples) ---")
        print("Average: \(String(format: "%.3f", avg)) ms")
        print("p99:     \(String(format: "%.3f", p99)) ms")
        print("---------------------------------------------------")

        XCTAssertLessThanOrEqual(p99, 5.0,
            "p99 TrigramProvider query latency \(String(format: "%.3f", p99)) ms exceeds 5 ms budget")
    }

    /// Measures raw kenlm_score_sentence C bridge latency.
    func testTrigramScoreLatency() throws {
        guard let modelPath = Bundle(for: type(of: self))
            .path(forResource: "trigram_en_v1", ofType: "klm")
            ?? Bundle.main.path(forResource: "trigram_en_v1", ofType: "klm") else {
            throw XCTSkip("trigram_en_v1.klm not found in test bundle")
        }

        guard let model = kenlm_load(modelPath) else {
            XCTFail("kenlm_load returned nil for path: \(modelPath)")
            return
        }
        defer { kenlm_free(model) }

        let sentence = "i am looking very good"

        var latencies: [Double] = []
        latencies.reserveCapacity(1000)

        // Warmup.
        for _ in 0..<50 {
            _ = kenlm_score_sentence(model, sentence)
        }

        // Measure 1000 iterations for p99.
        for _ in 0..<1000 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = kenlm_score_sentence(model, sentence)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 // ms
            latencies.append(elapsed)
        }

        latencies.sort()
        let p99 = latencies[989]
        let avg = latencies.reduce(0, +) / Double(latencies.count)

        print("--- KenLM Score Latency (1000 samples) ---")
        print("Average: \(String(format: "%.3f", avg)) ms")
        print("p99:     \(String(format: "%.3f", p99)) ms")
        print("------------------------------------------")

        XCTAssertLessThanOrEqual(p99, 5.0,
            "p99 raw score latency \(String(format: "%.3f", p99)) ms exceeds 5 ms budget")
    }
}
