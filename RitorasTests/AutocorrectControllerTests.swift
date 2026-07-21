import XCTest

final class AutocorrectControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSuggestion(text: String, score: Double, source: Suggestion.Source = .apple) -> Suggestion {
        Suggestion(text: text, score: score, source: source)
    }

    // MARK: - LOCKED Origins

    func test_suggestionTapOrigin_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .suggestionTap,
            topCorrection: makeSuggestion(text: "the", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    func test_autocorrectAppliedOrigin_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .autocorrectApplied,
            topCorrection: makeSuggestion(text: "the", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - Length Guards

    func test_word_shorter_than_minLength_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "a",
            origin: .typing,
            topCorrection: makeSuggestion(text: "I", score: 0.99),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    func test_word_longer_than_maxLength_returns_leaveAsIs() {
        let longWord = String(repeating: "a", count: 30)
        let result = AutocorrectController.evaluate(
            typedWord: longWord,
            origin: .typing,
            topCorrection: makeSuggestion(text: "b", score: 0.99),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - Learned Words

    func test_isLearned_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .typing,
            topCorrection: makeSuggestion(text: "the", score: 0.99),
            isLearned: true,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - No Candidate

    func test_nil_candidate_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .typing,
            topCorrection: nil,
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - Same Word

    func test_candidate_text_matches_typed_case_insensitive_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "hello",
            origin: .typing,
            topCorrection: makeSuggestion(text: "Hello", score: 0.99),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - Score Threshold

    func test_score_below_threshold_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .typing,
            topCorrection: makeSuggestion(text: "the", score: 0.5),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - Happy Path

    func test_happy_path_returns_correct_with_case_preserved() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .typing,
            topCorrection: makeSuggestion(text: "the", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "teh", correction: "the"))
    }

    // MARK: - Case Preservation

    func test_case_preservation_lowercase_typed() {
        let result = AutocorrectController.evaluate(
            typedWord: "hello",
            origin: .typing,
            topCorrection: makeSuggestion(text: "hallo", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "hello", correction: "hallo"))
    }

    func test_case_preservation_capitalized_typed() {
        let result = AutocorrectController.evaluate(
            typedWord: "Hello",
            origin: .typing,
            topCorrection: makeSuggestion(text: "hallo", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "Hello", correction: "Hallo"))
    }

    func test_case_preservation_uppercase_typed() {
        let result = AutocorrectController.evaluate(
            typedWord: "HELLO",
            origin: .typing,
            topCorrection: makeSuggestion(text: "hallo", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "HELLO", correction: "HALLO"))
    }

    func test_case_preservation_lowercase_typed_with_mixed_case_correction() {
        // When the correction has its own internal uppercase pattern (proper noun),
        // lowercasing strips it and then no further transform is applied for lowercase input.
        let result = AutocorrectController.evaluate(
            typedWord: "hello",
            origin: .typing,
            topCorrection: makeSuggestion(text: "hotDog", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "hello", correction: "hotdog"))
    }

    // MARK: - Custom Config

    func test_custom_config_threshold_rejects_low_score() {
        let strictConfig = AutocorrectController.Config(
            minWordLength: 2,
            maxWordLength: 25,
            minConfidenceScore: 0.9
        )
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .typing,
            topCorrection: makeSuggestion(text: "the", score: 0.85),
            isLearned: false,
            isMisspelled: true,
            config: strictConfig
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    // MARK: - Misspelling Check

    func testEvaluate_returnsLeaveAsIs_whenWordIsNotMisspelled() {
        let result = AutocorrectController.evaluate(
            typedWord: "me",
            origin: .typing,
            topCorrection: makeSuggestion(text: "message", score: 0.9),
            isLearned: false,
            isMisspelled: false
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    func testEvaluate_appliesCorrection_whenWordIsMisspelled() {
        let result = AutocorrectController.evaluate(
            typedWord: "helol",
            origin: .typing,
            topCorrection: makeSuggestion(text: "hello", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "helol", correction: "hello"))
    }

    // MARK: - WordOriginTracker State Transitions

    func test_wordOriginTracker_starts_as_typing() {
        var tracker = WordOriginTracker()
        XCTAssertEqual(tracker.current, .typing)
    }

    func test_wordOriginTracker_markSuggestionTap() {
        var tracker = WordOriginTracker()
        tracker.markSuggestionTap()
        XCTAssertEqual(tracker.current, .suggestionTap)
    }

    func test_wordOriginTracker_markAutocorrectApplied() {
        var tracker = WordOriginTracker()
        tracker.markAutocorrectApplied()
        XCTAssertEqual(tracker.current, .autocorrectApplied)
    }

    func test_wordOriginTracker_resetToTyping() {
        var tracker = WordOriginTracker()
        tracker.markAutocorrectApplied()
        XCTAssertEqual(tracker.current, .autocorrectApplied)
        tracker.resetToTyping()
        XCTAssertEqual(tracker.current, .typing)
    }

    // MARK: - First-Letter Preservation

    func test_candidate_with_different_first_letter_returns_leaveAsIs() {
        let result = AutocorrectController.evaluate(
            typedWord: "michael",
            origin: .typing,
            topCorrection: makeSuggestion(text: "apple", score: 0.95),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .leaveAsIs)
    }

    func test_candidate_with_matching_first_letter_still_corrects() {
        let result = AutocorrectController.evaluate(
            typedWord: "teh",
            origin: .typing,
            topCorrection: makeSuggestion(text: "the", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "teh", correction: "the"))
    }

    func test_first_letter_check_is_case_insensitive() {
        let result = AutocorrectController.evaluate(
            typedWord: "Teh",
            origin: .typing,
            topCorrection: makeSuggestion(text: "the", score: 0.85),
            isLearned: false,
            isMisspelled: true
        )
        XCTAssertEqual(result, .correct(typedWord: "Teh", correction: "The"))
    }
}
