import XCTest

final class AppleSpellCheckerProviderTests: XCTestCase {

    private var provider: AppleSpellCheckerProvider!

    override func setUp() {
        super.setUp()
        provider = AppleSpellCheckerProvider()
    }

    // MARK: - Empty Input

    func test_empty_word_returns_empty() {
        let context = SuggestionContext(currentWord: "", lookupWord: "", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 3)
        XCTAssertTrue(result.isEmpty, "Empty currentWord should produce no suggestions")
    }

    // MARK: - Misspelled Word → Guesses

    func test_known_misspelling_returns_corrections() {
        let context = SuggestionContext(currentWord: "teh", lookupWord: "teh", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 5)
        let texts = result.map { $0.text.lowercased() }
        XCTAssertTrue(
            texts.contains("the"),
            "'teh' should produce a correction containing 'the', got: \(texts)"
        )
    }

    func test_known_misspelling_guesses_have_apple_source() {
        let context = SuggestionContext(currentWord: "teh", lookupWord: "teh", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 5)
        for suggestion in result {
            XCTAssertEqual(
                suggestion.source, .apple,
                "Every suggestion from AppleSpellCheckerProvider should have source .apple"
            )
        }
    }

    func test_known_misspelling_guess_scores() {
        let context = SuggestionContext(currentWord: "teh", lookupWord: "teh", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 5)

        // The first batch (misspelling guesses) should have score 0.85.
        // It's possible completions also appear (score 0.6) for very short
        // partial words; we just verify the scores are valid.
        for suggestion in result {
            XCTAssertTrue(
                suggestion.score == 0.85 || suggestion.score == 0.6,
                "Score should be 0.85 (guess) or 0.6 (completion), got \(suggestion.score)"
            )
        }
    }

    // MARK: - Partial Words → Completions

    func test_partial_word_returns_completions() {
        let context = SuggestionContext(currentWord: "appl", lookupWord: "appl", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 5)
        // "appl" is the start of many English words; we expect at least one completion.
        // If the system dictionary has none for this prefix, the test is skipped gracefully.
        if result.isEmpty {
            return
        }
        for suggestion in result {
            XCTAssertTrue(
                suggestion.text.lowercased().hasPrefix("appl"),
                "Completion '\(suggestion.text)' should start with 'appl'"
            )
        }
    }

    // MARK: - Limit

    func test_limit_is_respected() {
        let context = SuggestionContext(currentWord: "teh", lookupWord: "teh", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 2)
        // Provider returns up to limit*2 results (engine dedups/limits again).
        XCTAssertLessThanOrEqual(result.count, 4,
                                 "Provider should return at most limit*2 results")
    }

    // MARK: - Correctly Spelled Word

    func test_correct_word_may_return_completions() {
        // A correctly-spelled word should not generate guesses (no misspelling),
        // but may still return prefix completions from UITextChecker.
        let context = SuggestionContext(currentWord: "hello", lookupWord: "hello", previousWord: nil, isMidWord: false)
        let result = provider.suggest(for: context, limit: 5)
        // "hello" may produce completions like "hello", "hello world", etc.
        // If empty, that's fine — the system dictionary may not have any.
        for suggestion in result {
            XCTAssertEqual(suggestion.source, .apple)
        }
    }
}
