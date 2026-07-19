import XCTest

final class SymSpellProviderTests: XCTestCase {

    // MARK: - Capitalization Template (pure function)

    func test_sentence_case_applies_capitalization() {
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "Hello", to: "hello")
        XCTAssertEqual(result, "Hello")
    }

    func test_sentence_case_from_teh_to_the() {
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "Teh", to: "the")
        XCTAssertEqual(result, "The")
    }

    func test_all_caps_uppercases_suggestion() {
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "HELLO", to: "hello")
        XCTAssertEqual(result, "HELLO")
    }

    func test_lowercase_leaves_suggestion_unchanged() {
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "hello", to: "hello")
        XCTAssertEqual(result, "hello")
    }

    func test_proper_noun_preserved_after_sentence_case() {
        // "USA" already contains uppercase beyond position 0 → preserved.
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "Hello", to: "USA")
        XCTAssertEqual(result, "USA")
    }

    func test_proper_noun_iPhone_preserved() {
        // "iPhone" has uppercase beyond position 0 → preserved.
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "hello", to: "iPhone")
        XCTAssertEqual(result, "iPhone")
    }

    func test_all_caps_proper_noun_preserved() {
        // "USA" already has uppercase beyond position 0 → preserved even in all-caps input.
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "HELLO", to: "USA")
        XCTAssertEqual(result, "USA")
    }

    func test_sentence_case_short_input() {
        // Single-character input "A" — first is uppercase, rest is empty → sentence case.
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "A", to: "an")
        XCTAssertEqual(result, "An")
    }

    func test_all_caps_short_input() {
        let result = SymSpellProvider.applyCapitalizationTemplate(from: "I", to: "am")
        XCTAssertEqual(result, "am", "Single char 'I' does not satisfy count > 1 for all-caps, so lowercase rule applies")
    }

    // MARK: - Integration: SymSpellProvider suggestions respect capitalization

    private func makeProvider() -> SymSpellProvider {
        let symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)
        let trie = Trie()

        // Load the bundled frequency dictionary.
        let testBundle = Bundle(for: SymSpellProviderTests.self)
        let url = testBundle.url(forResource: "frequency_dictionary_en_82_765",
                                 withExtension: "txt")
            ?? Bundle.main.url(forResource: "frequency_dictionary_en_82_765",
                               withExtension: "txt")

        if let url = url, let entries = try? WordListLoader.load(from: url) {
            for entry in entries {
                symSpell.createDictionaryEntry(key: entry.word, count: entry.count)
                trie.insert(word: entry.word)
            }
        }

        return SymSpellProvider(symSpell: symSpell, trie: trie)
    }

    func test_sentence_case_input_returns_capitalized_suggestions() {
        let provider = makeProvider()
        let context = SuggestionContext(
            currentWord: "Hello",
            lookupWord: "Hello",
            previousWord: nil,
            isMidWord: true
        )
        let results = provider.suggest(for: context, limit: 3)
        // All suggestions (beyond the first, which is the input itself)
        // should start with uppercase H (or be preserved as proper nouns).
        for suggestion in results.dropFirst() {
            // If the suggestion contains uppercase beyond position 0, it's a proper noun — skip.
            let afterFirst = suggestion.text.dropFirst()
            if afterFirst.contains(where: { $0.isUppercase }) {
                continue
            }
            XCTAssertTrue(
                suggestion.text.first?.isUppercase ?? false,
                "Suggestion '\(suggestion.text)' should start with uppercase for sentence-case input 'Hello'"
            )
        }
    }

    func test_capitalized_typo_corrections_are_capitalized() {
        let provider = makeProvider()
        let context = SuggestionContext(
            currentWord: "Teh",
            lookupWord: "Teh",
            previousWord: nil,
            isMidWord: true
        )
        let results = provider.suggest(for: context, limit: 3)
        // "Teh" is a typo of "the" — corrections should be capitalized to "The".
        for suggestion in results.dropFirst() {
            let afterFirst = suggestion.text.dropFirst()
            if afterFirst.contains(where: { $0.isUppercase }) {
                continue
            }
            XCTAssertTrue(
                suggestion.text.first?.isUppercase ?? false,
                "Correction '\(suggestion.text)' for capitalized typo 'Teh' should start with uppercase"
            )
        }
    }

    func test_lowercase_input_preserves_lowercase_suggestions() {
        let provider = makeProvider()
        let context = SuggestionContext(
            currentWord: "hello",
            lookupWord: "hello",
            previousWord: nil,
            isMidWord: true
        )
        let results = provider.suggest(for: context, limit: 3)
        // The input chip is "hello", suggestions should stay lowercase.
        for suggestion in results.dropFirst() {
            // Proper nouns are left as-is.
            let afterFirst = suggestion.text.dropFirst()
            if afterFirst.contains(where: { $0.isUppercase }) {
                continue
            }
            // Should not be capitalized.
            if let first = suggestion.text.first {
                XCTAssertTrue(
                    first.isLowercase,
                    "Suggestion '\(suggestion.text)' should remain lowercase for lowercase input 'hello'"
                )
            }
        }
    }

    // MARK: - QWERTY Geometry-Aware Scoring Integration

    func test_provider_prefers_adjacent_key_typo() {
        let provider = makeProvider()
        let context = SuggestionContext(
            currentWord: "teh",
            lookupWord: "teh",
            previousWord: nil,
            isMidWord: true
        )
        let results = provider.suggest(for: context, limit: 5)
        let theSuggestion = results.first(where: { $0.text.lowercased() == "the" })
        XCTAssertNotNil(theSuggestion, "Provider should suggest 'the' for typo 'teh'")
        if let suggestion = theSuggestion {
            XCTAssertGreaterThan(suggestion.score, 0.0,
                                 "teh→the score should be positive with QWERTY-aware scoring")
            XCTAssertLessThanOrEqual(suggestion.score, 1.0,
                                     "teh→the score should not exceed 1.0")
        }
    }

    func test_provider_geometry_aware_score_for_recieve() {
        let provider = makeProvider()
        let context = SuggestionContext(
            currentWord: "recieve",
            lookupWord: "recieve",
            previousWord: nil,
            isMidWord: true
        )
        let results = provider.suggest(for: context, limit: 5)
        let receiveSuggestion = results.first(where: { $0.text.lowercased() == "receive" })
        XCTAssertNotNil(receiveSuggestion, "Provider should suggest 'receive' for typo 'recieve'")
        if let suggestion = receiveSuggestion {
            XCTAssertGreaterThan(suggestion.score, 0.0,
                                 "recieve→receive score should be positive with QWERTY-aware scoring")
            XCTAssertLessThanOrEqual(suggestion.score, 1.0,
                                     "recieve→receive score should not exceed 1.0")
        }
    }
}
