import XCTest

final class BackspaceRevertMatcherTests: XCTestCase {

    // MARK: - Happy Path (immediate post-autocorrect)

    func test_word_with_trailing_space_matches() {
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "the "))
    }

    func test_word_without_trailing_space_matches() {
        // UITextProxy quirk: trailing space sometimes omitted from documentContextBeforeInput.
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "the"))
    }

    func test_word_after_other_text_with_trailing_space_matches() {
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "Hello the "))
    }

    func test_word_after_other_text_without_trailing_space_matches() {
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "Hello the"))
    }

    // MARK: - Multiple Trailing Whitespace

    func test_word_with_two_trailing_spaces_matches() {
        // User typed an extra space; lastAutoCorrection is normally cleared by textDidChange
        // before this can match, but the matcher itself tolerates the suffix.
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "the  "))
    }

    // MARK: - Case Insensitivity

    func test_case_insensitive_match() {
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "Michael", inContext: "hello michael "))
    }

    func test_case_insensitive_match_uppercase_word() {
        XCTAssertTrue(BackspaceRevertMatcher.isCursorRightAfter(word: "THE", inContext: "the "))
    }

    // MARK: - Substring Rejection

    func test_substring_does_not_match() {
        // "NotMichael" must not match "Michael" — char before must be whitespace.
        XCTAssertFalse(BackspaceRevertMatcher.isCursorRightAfter(word: "Michael", inContext: "NotMichael"))
    }

    func test_word_glued_to_following_letters_does_not_match() {
        // Cursor inside a longer word — not a revert position.
        XCTAssertFalse(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "theatre"))
    }

    // MARK: - Rejections

    func test_context_shorter_than_word_rejects() {
        XCTAssertFalse(BackspaceRevertMatcher.isCursorRightAfter(word: "hello", inContext: "hi "))
    }

    func test_context_ending_with_different_word_rejects() {
        XCTAssertFalse(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: "hello "))
    }

    func test_empty_context_rejects() {
        XCTAssertFalse(BackspaceRevertMatcher.isCursorRightAfter(word: "the", inContext: ""))
    }

    func test_empty_word_rejects() {
        XCTAssertFalse(BackspaceRevertMatcher.isCursorRightAfter(word: "", inContext: "anything"))
    }
}
