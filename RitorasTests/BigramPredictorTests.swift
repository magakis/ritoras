import XCTest

final class BigramPredictorTests: XCTestCase {

    // MARK: - Test Data

    /// Synthetic bigram data matching `word1 word2 count` format.
    /// - `"I"` → am(100), have(80), think(60), will(40), can(20)
    /// - `"the"` → same(100), first(80), other(60), only(40), new(20)
    /// - `"she"` → is(8) — above the default minCount=5
    /// - `"aaron"` → and(3) — below minCount=5, should be pruned
    private let testLines = [
        "I am 100",
        "I have 80",
        "I think 60",
        "I will 40",
        "I can 20",
        "the same 100",
        "the first 80",
        "the other 60",
        "the only 40",
        "the new 20",
        "she is 8",
        "aaron and 3",
    ]

    private func makePredictor(extraLines: [String] = [], minCount: Int = 5) -> BigramPredictor {
        let predictor = BigramPredictor(minCount: minCount)
        predictor.loadFromLines(testLines + extraLines)
        return predictor
    }

    // MARK: - Top Followers for Real Words

    func test_I_top_followers_include_am_have_think() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 5)
        let texts = results.map { $0.text.lowercased() }
        XCTAssertTrue(texts.contains("am"), "Top follower of 'I' should include 'am', got: \(texts)")
        XCTAssertTrue(texts.contains("have"), "Top follower of 'I' should include 'have', got: \(texts)")
        XCTAssertTrue(texts.contains("think"), "Top follower of 'I' should include 'think', got: \(texts)")
    }

    func test_I_top_followers_sorted_by_count_descending() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 5)
        let texts = results.map { $0.text.lowercased() }
        // am(100), have(80), think(60), will(40), can(20)
        XCTAssertEqual(texts, ["am", "have", "think", "will", "can"],
                       "Followers should be sorted by count descending")
    }

    func test_the_top_followers_include_same_first_other() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "the", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 5)
        let texts = results.map { $0.text.lowercased() }
        XCTAssertTrue(texts.contains("same"), "Top follower of 'the' should include 'same', got: \(texts)")
        XCTAssertTrue(texts.contains("first"), "Top follower of 'the' should include 'first', got: \(texts)")
        XCTAssertTrue(texts.contains("other"), "Top follower of 'the' should include 'other', got: \(texts)")
    }

    // MARK: - OOV Previous Word

    func test_oov_previous_word_returns_empty() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "xzqw", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty, "OOV previous word should return empty")
    }

    func test_oov_previous_word_does_not_crash() {
        let predictor = makePredictor()
        // Should not crash with unusual words or nil.
        let contexts: [SuggestionContext] = [
            SuggestionContext(currentWord: "", lookupWord: "", previousWord: nil, isMidWord: false),
            SuggestionContext(currentWord: "", lookupWord: "", previousWord: "xzqw123!@#", isMidWord: false),
            SuggestionContext(currentWord: "", lookupWord: "", previousWord: "", isMidWord: false),
            SuggestionContext(currentWord: "test", lookupWord: "test", previousWord: "@@@", isMidWord: true),
        ]
        for ctx in contexts {
            let results = predictor.suggest(for: ctx, limit: 3)
            XCTAssertNotNil(results, "Should not crash for any input")
        }
    }

    // MARK: - Empty CurrentWord (after whitespace)

    func test_empty_currentWord_returns_top_followers() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "she", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        let texts = results.map { $0.text.lowercased() }
        // "she" has exactly one follower: "is"(8)
        XCTAssertEqual(texts, ["is"], "Empty currentWord should return top followers")
    }

    func test_empty_currentWord_limit_is_respected() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 2)
        XCTAssertEqual(results.count, 2, "Should return at most limit suggestions")
        XCTAssertEqual(results[0].text.lowercased(), "am", "First should be 'am' (highest count)")
        XCTAssertEqual(results[1].text.lowercased(), "have", "Second should be 'have'")
    }

    // MARK: - Non-empty CurrentWord (mid-word)

    func test_mid_word_returns_prefix_filtered_followers() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "w", lookupWord: "w", previousWord: "I", isMidWord: true)
        let results = predictor.suggest(for: context, limit: 3)
        let texts = results.map { $0.text.lowercased() }
        // Followers of "I" starting with "w": "will"(40)
        XCTAssertEqual(texts, ["will"], "Should return followers starting with prefix 'w'")
    }

    func test_mid_word_prefix_no_match_returns_empty() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "zzz", lookupWord: "zzz", previousWord: "I", isMidWord: true)
        let results = predictor.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty, "No followers with prefix 'zzz'")
    }

    func test_mid_word_scores_are_lower_than_empty_prefix_scores() {
        let predictor = makePredictor()
        // Empty prefix: should have normalized scores (e.g., "am" → 1.0)
        let emptyCtx = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let emptyResults = predictor.suggest(for: emptyCtx, limit: 3)

        // Mid-word: scores multiplied by 0.5
        let midCtx = SuggestionContext(currentWord: "w", lookupWord: "w", previousWord: "I", isMidWord: true)
        let midResults = predictor.suggest(for: midCtx, limit: 3)

        if !emptyResults.isEmpty, !midResults.isEmpty {
            XCTAssertLessThan(midResults[0].score, emptyResults[0].score,
                              "Mid-word scores should be lower than empty-prefix scores")
        }
    }

    // MARK: - Score Normalization

    func test_scores_are_normalized_to_0_1_range() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 5)
        for suggestion in results {
            XCTAssertGreaterThan(suggestion.score, 0.0, "Score should be > 0")
            XCTAssertLessThanOrEqual(suggestion.score, 1.0, "Score should be ≤ 1.0")
        }
        // "am" (count 100) is the max → normalized to 1.0
        if let first = results.first {
            XCTAssertEqual(first.score, 1.0, accuracy: 0.001,
                           "Top follower should have score 1.0")
        }
    }

    // MARK: - bigramMinCount Pruning

    func test_bigram_min_count_prunes_low_frequency_entries() {
        let predictor = makePredictor(minCount: 5)
        // "aaron and 3" is below minCount → should not be in the map.
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "aaron", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty, "'aaron' should be pruned (count 3 < minCount 5)")
    }

    func test_bigram_min_count_keeps_entries_above_threshold() {
        let predictor = makePredictor(minCount: 5)
        // "she is 8" is above minCount → should be present.
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "she", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        let texts = results.map { $0.text.lowercased() }
        XCTAssertEqual(texts, ["is"], "'she' should not be pruned (count 8 ≥ minCount 5)")
    }

    // MARK: - Lazy Load / isReady

    func test_suggest_returns_empty_before_ready() {
        let predictor = BigramPredictor(minCount: 5)
        // isReady starts as false — suggest should return [] regardless of input.
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty, "suggest() should return [] before isReady is true")
    }

    func test_suggest_returns_results_after_load() {
        let predictor = BigramPredictor(minCount: 5)
        // Before load: empty.
        let before = predictor.suggest(
            for: SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false),
            limit: 3
        )
        XCTAssertTrue(before.isEmpty, "Should be empty before loading")

        // After load: has data.
        predictor.loadFromLines(testLines)
        let after = predictor.suggest(
            for: SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false),
            limit: 3
        )
        XCTAssertFalse(after.isEmpty, "Should return results after loading")
    }

    // MARK: - Source Attribution

    func test_suggestions_have_bigram_source() {
        let predictor = makePredictor()
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        for suggestion in results {
            XCTAssertEqual(suggestion.source, .bigram,
                           "Every suggestion should have source .bigram")
        }
    }

    // MARK: - Cross-case: Empty PreviousWord

    func test_empty_previousWord_returns_empty() {
        let predictor = makePredictor()
        // previousWord "" is treated as "no previous word".
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "", isMidWord: false)
        let results = predictor.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty, "Empty previousWord string should return empty")
    }

    // MARK: - Thread Safety (Issue #2)

    /// Exercises the concurrent load → suggest path to verify no crash from
    /// the data race that existed before the `os_unfair_lock` fix.
    /// Loads on a background queue while calling `suggest` from main; should
    /// never crash or return inconsistent results.
    func test_concurrent_load_and_suggest_no_crash() {
        let predictor = BigramPredictor(minCount: 5)
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: "I", isMidWord: false)
        let loadFinished = XCTestExpectation(description: "load finished")

        // Start loading on a background queue.
        DispatchQueue.global(qos: .default).async {
            predictor.loadFromLines(self.testLines)
            loadFinished.fulfill()
        }

        // Concurrently call suggest from this (main) thread.
        var suggestResults: [[Suggestion]] = []
        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            let results = predictor.suggest(for: context, limit: 3)
            suggestResults.append(results)
        }

        wait(for: [loadFinished], timeout: 5.0)

        // Verify no crash and eventual consistency.
        let nonEmptyResults = suggestResults.filter { !$0.isEmpty }
        // "I" is in testLines, so at some point suggest should return results.
        XCTAssertFalse(nonEmptyResults.isEmpty,
                       "suggest should eventually return results for 'I'")
    }
}
