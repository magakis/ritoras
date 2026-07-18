import XCTest

final class PredictionEngineTests: XCTestCase {

    // MARK: - Mock Provider

    private struct MockProvider: SuggestionProvider {
        let suggestions: [Suggestion]

        func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion] {
            return Array(suggestions.prefix(limit))
        }
    }

    // MARK: - Merge & Dedup

    func test_empty_engine_returns_empty() {
        let engine = PredictionEngine()
        let result = engine.suggestions(forCurrentWord: "hello", lookupWord: "hello", limit: 3)
        XCTAssertTrue(result.isEmpty, "Engine with no providers should return empty")
    }

    func test_single_provider_returns_suggestions() {
        let engine = PredictionEngine()
        let provider = MockProvider(suggestions: [
            Suggestion(text: "hello", score: 1.0, source: .symspell),
            Suggestion(text: "world", score: 0.8, source: .symspell),
        ])
        engine.addProvider(provider)

        let result = engine.suggestions(forCurrentWord: "hel", lookupWord: "hel", limit: 3)
        XCTAssertEqual(result, ["hello", "world"])
    }

    func test_dedup_keeps_highest_score() {
        let engine = PredictionEngine()
        let provider1 = MockProvider(suggestions: [
            Suggestion(text: "the", score: 0.9, source: .symspell),
            Suggestion(text: "them", score: 0.6, source: .symspell),
        ])
        let provider2 = MockProvider(suggestions: [
            Suggestion(text: "the", score: 1.0, source: .apple),
            Suggestion(text: "there", score: 0.7, source: .apple),
        ])
        engine.addProvider(provider1)
        engine.addProvider(provider2)

        let result = engine.suggestions(forCurrentWord: "the", lookupWord: "the", limit: 3)
        // "the" should appear once, with the higher score from provider2.
        XCTAssertTrue(result.contains("the"), "the should be in results")
        XCTAssertTrue(result.contains("them"), "them should be in results")
        XCTAssertTrue(result.contains("there"), "there should be in results")
        XCTAssertEqual(result.count, 3)
    }

    func test_limit_is_respected() {
        let engine = PredictionEngine()
        let provider = MockProvider(suggestions: [
            Suggestion(text: "a", score: 1.0, source: .symspell),
            Suggestion(text: "b", score: 0.9, source: .symspell),
            Suggestion(text: "c", score: 0.8, source: .symspell),
            Suggestion(text: "d", score: 0.7, source: .symspell),
        ])
        engine.addProvider(provider)

        let result = engine.suggestions(forCurrentWord: "", lookupWord: "", limit: 2)
        XCTAssertEqual(result.count, 2)
    }

    func test_sort_by_score_descending() {
        let engine = PredictionEngine()
        let provider = MockProvider(suggestions: [
            Suggestion(text: "low", score: 0.3, source: .symspell),
            Suggestion(text: "high", score: 0.9, source: .symspell),
            Suggestion(text: "mid", score: 0.6, source: .symspell),
        ])
        engine.addProvider(provider)

        let result = engine.suggestions(forCurrentWord: "test", lookupWord: "test", limit: 3)
        XCTAssertEqual(result, ["high", "mid", "low"],
                       "Suggestions should sort by score descending")
    }

    func test_previousWord_passed_to_context() {
        let engine = PredictionEngine()
        let expectation = XCTestExpectation(description: "Provider received context")

        class ExpectationProvider: SuggestionProvider {
            let expectation: XCTestExpectation
            init(_ exp: XCTestExpectation) { self.expectation = exp }
            func suggest(for context: SuggestionContext, limit: Int) -> [Suggestion] {
                if context.previousWord == "dear" {
                    expectation.fulfill()
                }
                return []
            }
        }

        engine.addProvider(ExpectationProvider(expectation))
        _ = engine.suggestions(forCurrentWord: "friend", lookupWord: "friend", previousWord: "dear", limit: 3)
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Next-Word Prediction Integration

    func test_no_previous_word_returns_hardcoded_fallback() {
        let engine = PredictionEngine()
        let result = engine.suggestions(forCurrentWord: "", lookupWord: "", previousWord: nil, limit: 3)
        XCTAssertEqual(result, ["the", "I", "and"])
    }

    func test_next_word_prediction_returns_bigram_followers() {
        let engine = PredictionEngine()
        let predictor = BigramPredictor(minCount: 1)
        predictor.loadFromLines([
            "I am 100",
            "I have 80",
            "I think 60",
        ])
        engine.addProvider(predictor)

        let result = engine.suggestions(forCurrentWord: "", lookupWord: "", previousWord: "I", limit: 3)
        XCTAssertEqual(result, ["am", "have", "think"],
                       "Engine should return top bigram followers for 'I' when currentWord is empty")
    }

    // MARK: - topCorrection

    func test_topCorrection_empty_engine_returns_nil() {
        let engine = PredictionEngine()
        let result = engine.topCorrection(forCurrentWord: "hello", lookupWord: "hello")
        XCTAssertNil(result, "Engine with no providers should return nil")
    }

    func test_topCorrection_returns_highest_scoring_non_bigram() {
        let engine = PredictionEngine()
        let provider = MockProvider(suggestions: [
            Suggestion(text: "teh", score: 0.9, source: .bigram),
            Suggestion(text: "the", score: 0.85, source: .apple),
            Suggestion(text: "teh", score: 0.7, source: .symspell),
        ])
        engine.addProvider(provider)

        let result = engine.topCorrection(forCurrentWord: "teh", lookupWord: "teh")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "the")
        XCTAssertEqual(result?.score, 0.85)
        XCTAssertEqual(result?.source, .apple)
    }

    func test_topCorrection_preserves_score() {
        let engine = PredictionEngine()
        let provider = MockProvider(suggestions: [
            Suggestion(text: "weather", score: 0.95, source: .symspell),
        ])
        engine.addProvider(provider)

        let result = engine.topCorrection(forCurrentWord: "weathr", lookupWord: "weathr")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "weather")
        XCTAssertEqual(result?.score, 0.95)
        XCTAssertEqual(result?.source, .symspell)
    }
}
