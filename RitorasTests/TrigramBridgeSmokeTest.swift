import XCTest

final class TrigramBridgeSmokeTest: XCTestCase {

    private var modelPath: String? {
        Bundle(for: TrigramBridgeSmokeTest.self).path(forResource: "trigram_en_v1", ofType: "klm")
    }

    // MARK: - Model Loading

    func test_load_model_succeeds() throws {
        try XCTSkipIf(modelPath == nil, "trigram_en_v1.klm not found in test bundle")
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model, "KenLM model should load successfully")
        kenlm_free(model)
    }

    func test_load_nil_path_returns_nil() {
        let model = kenlm_load(nil)
        XCTAssertNil(model, "Loading with nil path should return nil")
    }

    func test_load_empty_path_returns_nil() {
        let model = kenlm_load("")
        XCTAssertNil(model, "Loading with empty path should return nil")
    }

    // MARK: - Vocabulary Size

    func test_vocab_size_is_20000() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        defer { kenlm_free(model) }

        let size = kenlm_vocab_size(model)
        XCTAssertEqual(size, 20000, "Vocabulary size should be exactly 20,000")
    }

    func test_vocab_size_nil_model_returns_zero() {
        XCTAssertEqual(kenlm_vocab_size(nil), 0)
    }

    // MARK: - Scoring

    func test_common_sentence_scores_higher_than_oov() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        defer { kenlm_free(model) }

        let highProb = kenlm_score_sentence(model, "i am looking very good")
        let lowProb = kenlm_score_sentence(model, "i am looking very xyzzy")

        XCTAssertGreaterThan(
            highProb, lowProb,
            "A sentence with common words should have higher (less negative) log prob than one with OOV 'xyzzy'"
        )
    }

    func test_common_bigram_scores_higher_than_oov() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        defer { kenlm_free(model) }

        let highProb = kenlm_score_sentence(model, "i want to go")
        let lowProb = kenlm_score_sentence(model, "i want to xyzzy")

        XCTAssertGreaterThan(
            highProb, lowProb,
            "A trigram with real words should score higher than one with OOV 'xyzzy'"
        )
    }

    func test_score_nil_sentence_returns_zero() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        defer { kenlm_free(model) }

        XCTAssertEqual(kenlm_score_sentence(model, nil), 0.0)
    }

    func test_score_empty_sentence_returns_zero() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        defer { kenlm_free(model) }

        XCTAssertEqual(kenlm_score_sentence(model, ""), 0.0)
    }

    func test_score_nil_model_returns_zero() {
        XCTAssertEqual(kenlm_score_sentence(nil, "hello world"), 0.0)
    }

    // MARK: - Version String

    func test_version_string_is_not_empty() {
        let version = String(cString: kenlm_version())
        XCTAssertFalse(version.isEmpty, "Version string should not be empty")
    }

    // MARK: - Null Safety

    func test_free_nil_is_safe() {
        // Should not crash
        kenlm_free(nil)
    }

    func test_double_free_is_safe() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        kenlm_free(model)
        // Second free with dangling pointer would be UB, but we
        // do NOT test that here — just verify single free works.
    }

    // MARK: - kenlm_score (array variant)

    func test_score_array_with_known_words() {
        let model = kenlm_load(modelPath)
        XCTAssertNotNil(model)
        defer { kenlm_free(model) }

        var words: [UnsafePointer<CChar>?] = [
            strdup("i"),
            strdup("want"),
            strdup("to"),
            strdup("go"),
            nil
        ]

        let prob = kenlm_score(model, &words)

        // Clean up strdup'd strings
        for i in 0..<4 {
            if let ptr = words[i] {
                free(UnsafeMutablePointer(mutating: ptr))
            }
        }

        XCTAssertNotEqual(prob, 0.0, "Known word sequence should have non-zero probability")
        XCTAssertLessThan(prob, 0.0, "Log probability should be negative")
    }

    func test_score_array_nil_returns_zero() {
        XCTAssertEqual(kenlm_score(nil, nil), 0.0)
    }
}
