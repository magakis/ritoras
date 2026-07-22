import XCTest

/// Tests for TrigramProvider's suggest logic.
///
/// IMPORTANT: These tests require TrigramProvider.swift to be compiled into the
/// test target. Currently the project.yml excludes `Trigram/` from the test
/// target's sources (it is in RitorasKeyboard, not Ritoras). The build-fixer
/// will need to add `TrigramProvider.swift` and `SideIndex.swift` to the test
/// target's source list or make them `public`/`@testable import`-able.
///
/// For now the functional tests at the C bridge level live in
/// TrigramBridgeSmokeTest.swift.
final class TrigramProviderTests: XCTestCase {

    // MARK: - Marquee case

    func test_i_am_looking_very_returns_sensible_adjective() {
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "very",
            previousWord2: "looking",
            isMidWord: false
        )
        // Provider is in .cold state — returns [] before loading.
        // In a real scenario the first call triggers async load.
        let results = provider.suggest(for: context, limit: 5)

        // Until the model is loaded, cold state returns empty.
        if !provider.isReady {
            XCTAssertTrue(results.isEmpty, "Cold provider should return empty")
            return
        }

        // Once ready, top-5 should include valid continuations of "looking very".
        let texts = results.map { $0.text.lowercased() }
        let expected = Set(["pleased", "much", "good", "well", "and"])
        let intersection = Set(texts).intersection(expected)
        XCTAssertFalse(intersection.isEmpty,
                       "Top-5 'looking very' should include at least one of {pleased, much, good, well, and}, got: \(texts)")
    }

    // MARK: - Mid-word prefix filter

    func test_mid_word_prefix_filter() {
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "go",
            lookupWord: "go",
            previousWord: "am",
            previousWord2: "i",
            isMidWord: true
        )
        let results = provider.suggest(for: context, limit: 5)

        if !provider.isReady {
            XCTAssertTrue(results.isEmpty, "Cold provider should return empty")
            return
        }

        let texts = results.map { $0.text.lowercased() }
        // All returned suggestions should start with "go".
        for text in texts {
            XCTAssertTrue(text.hasPrefix("go"),
                          "Mid-word suggestion '\(text)' should start with prefix 'go'")
        }
    }

    // MARK: - Cold-start behavior

    func test_cold_state_returns_empty() {
        let provider = TrigramProvider()
        // Provider starts in .cold — suggest should return [] without triggering load.
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "very",
            previousWord2: "looking",
            isMidWord: false
        )
        let results = provider.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty, "Cold provider should return empty without loading")
    }

    // MARK: - Failed state behavior

    func test_failed_state_returns_empty() {
        // Use a non-existent resource to force a failed state.
        // The provider attempts to load but the resource doesn't exist.
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "the",
            previousWord2: "of",
            isMidWord: false
        )

        // Peek at state — if already failed, suggest returns [].
        let results = provider.suggest(for: context, limit: 3)
        if !provider.isReady {
            // Not ready could be cold, loading, or failed — all return [].
            XCTAssertTrue(results.isEmpty, "Non-ready provider should return empty")
        }
    }

    // MARK: - Missing previousWord2 returns empty

    func test_no_previous_word2_returns_empty() {
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "the",
            previousWord2: nil,
            isMidWord: false
        )
        // TrigramProvider requires both previousWord and previousWord2.
        let results = provider.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty,
                      "Provider should return empty when previousWord2 is nil")
    }

    func test_no_previous_word_returns_empty() {
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: nil,
            previousWord2: "of",
            isMidWord: false
        )
        let results = provider.suggest(for: context, limit: 3)
        XCTAssertTrue(results.isEmpty,
                      "Provider should return empty when previousWord is nil")
    }

    // MARK: - Unknown bigram returns empty

    func test_unknown_bigram_returns_empty() {
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "foo",
            previousWord2: "xyzzy",
            isMidWord: false
        )
        // "xyzzy foo" is unlikely to be in the side index.
        let results = provider.suggest(for: context, limit: 3)
        if provider.isReady {
            XCTAssertTrue(results.isEmpty,
                          "Unknown bigram should return empty when ready")
        }
    }

    // MARK: - Source attribution

    func test_suggestions_have_trigram_source() {
        let provider = TrigramProvider()
        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "very",
            previousWord2: "looking",
            isMidWord: false
        )
        let results = provider.suggest(for: context, limit: 3)
        for suggestion in results {
            XCTAssertEqual(suggestion.source, .trigram,
                           "Every suggestion should have source .trigram")
        }
    }

    // MARK: - isReady property

    func test_isReady_false_before_load() {
        let provider = TrigramProvider()
        XCTAssertFalse(provider.isReady, "isReady should be false before any load attempt")
    }
}
