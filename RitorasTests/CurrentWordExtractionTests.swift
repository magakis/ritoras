import XCTest

final class CurrentWordExtractionTests: XCTestCase {

    // MARK: - Basic Extraction

    func test_empty_context() {
        let result = CurrentWordExtractor.extract(from: nil)
        XCTAssertEqual(result.currentWord, "")
        XCTAssertEqual(result.lookupWord, "")
        XCTAssertNil(result.previousWord)
    }

    func test_empty_string() {
        let result = CurrentWordExtractor.extract(from: "")
        XCTAssertEqual(result.currentWord, "")
        XCTAssertEqual(result.lookupWord, "")
        XCTAssertNil(result.previousWord)
    }

    func test_whitespace_only() {
        let result = CurrentWordExtractor.extract(from: "   ")
        XCTAssertEqual(result.currentWord, "")
        XCTAssertEqual(result.lookupWord, "")
        XCTAssertNil(result.previousWord)
    }

    func test_single_word() {
        let result = CurrentWordExtractor.extract(from: "hello")
        XCTAssertEqual(result.currentWord, "hello")
        XCTAssertEqual(result.lookupWord, "hello")
        XCTAssertNil(result.previousWord)
    }

    func test_two_words() {
        let result = CurrentWordExtractor.extract(from: "hello world")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertEqual(result.previousWord, "hello")
    }

    func test_three_words() {
        let result = CurrentWordExtractor.extract(from: "the quick brown")
        XCTAssertEqual(result.currentWord, "brown")
        XCTAssertEqual(result.lookupWord, "brown")
        XCTAssertEqual(result.previousWord, "quick")
    }

    // MARK: - Punctuation (Previous Word)

    func test_previous_strips_trailing_period() {
        let result = CurrentWordExtractor.extract(from: "hello. world")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertEqual(result.previousWord, "hello")
    }

    func test_previous_strips_trailing_comma() {
        let result = CurrentWordExtractor.extract(from: "hello, world")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertEqual(result.previousWord, "hello")
    }

    func test_previous_strips_multiple_punctuation() {
        let result = CurrentWordExtractor.extract(from: "hello!! world")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertEqual(result.previousWord, "hello")
    }

    func test_previous_returns_nil_when_only_punctuation() {
        let result = CurrentWordExtractor.extract(from: "!!! world")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertNil(result.previousWord)
    }

    // MARK: - Punctuation (Current Word → lookupWord)

    func test_current_trailing_comma_stripped_in_lookupWord() {
        let result = CurrentWordExtractor.extract(from: "hello,")
        XCTAssertEqual(result.currentWord, "hello,")
        XCTAssertEqual(result.lookupWord, "hello")
    }

    func test_current_trailing_period_stripped_in_lookupWord() {
        let result = CurrentWordExtractor.extract(from: "world.")
        XCTAssertEqual(result.currentWord, "world.")
        XCTAssertEqual(result.lookupWord, "world")
    }

    func test_current_trailing_question_mark_stripped_in_lookupWord() {
        let result = CurrentWordExtractor.extract(from: "what?")
        XCTAssertEqual(result.currentWord, "what?")
        XCTAssertEqual(result.lookupWord, "what")
    }

    func test_current_apostrophe_preserved_in_lookupWord() {
        let result = CurrentWordExtractor.extract(from: "don't")
        XCTAssertEqual(result.currentWord, "don't")
        XCTAssertEqual(result.lookupWord, "don't")
    }

    func test_current_apostrophe_in_name_preserved_in_lookupWord() {
        let result = CurrentWordExtractor.extract(from: "O'Brien")
        XCTAssertEqual(result.currentWord, "O'Brien")
        XCTAssertEqual(result.lookupWord, "O'Brien")
    }

    func test_current_no_punctuation_lookupWord_equals_currentWord() {
        let result = CurrentWordExtractor.extract(from: "hello")
        XCTAssertEqual(result.currentWord, "hello")
        XCTAssertEqual(result.lookupWord, "hello")
    }

    func test_current_all_punctuation_lookupWord_empty() {
        let result = CurrentWordExtractor.extract(from: "!!!")
        XCTAssertEqual(result.currentWord, "!!!")
        XCTAssertEqual(result.lookupWord, "")
    }

    // MARK: - Edge Cases

    func test_leading_whitespace() {
        let result = CurrentWordExtractor.extract(from: "  hello world")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertEqual(result.previousWord, "hello")
    }

    func test_trailing_whitespace() {
        let result = CurrentWordExtractor.extract(from: "hello world ")
        XCTAssertEqual(result.currentWord, "world")
        XCTAssertEqual(result.lookupWord, "world")
        XCTAssertEqual(result.previousWord, "hello")
    }

    func test_newlines_in_context() {
        let result = CurrentWordExtractor.extract(from: "hello\nworld\nfoo")
        XCTAssertEqual(result.currentWord, "foo")
        XCTAssertEqual(result.lookupWord, "foo")
        XCTAssertEqual(result.previousWord, "world")
    }

    func test_current_word_with_hyphen() {
        let result = CurrentWordExtractor.extract(from: "well known")
        XCTAssertEqual(result.currentWord, "known")
        XCTAssertEqual(result.lookupWord, "known")
        XCTAssertEqual(result.previousWord, "well")
    }

    func test_previous_with_no_trailing_punctuation() {
        let result = CurrentWordExtractor.extract(from: "dear friend")
        XCTAssertEqual(result.currentWord, "friend")
        XCTAssertEqual(result.lookupWord, "friend")
        XCTAssertEqual(result.previousWord, "dear")
    }
}
