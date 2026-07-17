import XCTest

final class LearnedWordsStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LearnedWordsStore.shared.clear()
    }

    // MARK: - Add & Contains

    func test_add_and_contains() {
        let store = LearnedWordsStore.shared
        store.add("Ritoras")

        XCTAssertTrue(store.contains("Ritoras"),
                      "Should find 'Ritoras' after adding it")
    }

    func test_case_insensitive_contains() {
        let store = LearnedWordsStore.shared
        store.add("Ritoras")

        XCTAssertTrue(store.contains("ritoras"),
                      "Lookup should be case-insensitive")
        XCTAssertTrue(store.contains("RITORAS"),
                      "Lookup should be case-insensitive (uppercase)")
    }

    func test_add_empty_does_nothing() {
        let store = LearnedWordsStore.shared
        store.add("")

        XCTAssertEqual(store.allWords().count, 0,
                       "Empty string should not be added")
    }

    func test_add_whitespace_only_does_nothing() {
        let store = LearnedWordsStore.shared
        store.add("   ")

        XCTAssertEqual(store.allWords().count, 0,
                       "Whitespace-only string should not be added")
    }

    // MARK: - Dedup

    func test_dedup_same_word() {
        let store = LearnedWordsStore.shared
        store.add("word")
        store.add("Word")  // Same word, different casing

        XCTAssertEqual(store.allWords().count, 1,
                       "Duplicate (case-insensitive) should be deduped")
    }

    // MARK: - All Words

    func test_allWords_returns_sorted() {
        let store = LearnedWordsStore.shared
        store.add("zebra")
        store.add("apple")
        store.add("banana")

        let words = store.allWords()
        XCTAssertEqual(words, ["apple", "banana", "zebra"],
                       "allWords should return words in sorted order")
    }

    // MARK: - Persistence

    func test_persistence_to_user_defaults() {
        LearnedWordsStore.shared.add("persistword")
        LearnedWordsStore.shared.add("anotherword")

        // Verify data was written to the backing UserDefaults.
        let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
            ?? UserDefaults.standard
        let stored = defaults.array(forKey: "learnedWords") as? [String] ?? []

        XCTAssertTrue(stored.contains("persistword"),
                      "Word should be persisted to UserDefaults")
        XCTAssertTrue(stored.contains("anotherword"),
                      "Another word should be persisted to UserDefaults")
    }

    // MARK: - Clear

    func test_clear_removes_all() {
        let store = LearnedWordsStore.shared
        store.add("something")

        XCTAssertTrue(store.contains("something"),
                      "Word should be present after add")

        store.clear()

        XCTAssertFalse(store.contains("something"),
                       "Word should not be present after clear")
        XCTAssertTrue(store.allWords().isEmpty,
                      "allWords should be empty after clear")
    }

    func test_clear_removes_from_user_defaults() {
        let store = LearnedWordsStore.shared
        store.add("temporary")

        store.clear()

        let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
            ?? UserDefaults.standard
        let stored = defaults.array(forKey: "learnedWords") as? [String] ?? []
        XCTAssertFalse(stored.contains("temporary"),
                        "Word should be removed from UserDefaults after clear")
    }

    // MARK: - Persistence Verification (Issue #4)

    /// Verifies that after adding a word, the write is verifiable by readback
    /// (checks the `persist()` method's guarantee).
    func test_persist_write_is_verifiable_by_readback() {
        let store = LearnedWordsStore.shared
        store.add("verifyword")

        let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
            ?? UserDefaults.standard

        // Read back the array we just wrote.
        let stored = defaults.array(forKey: "learnedWords") as? [String]
        XCTAssertNotNil(stored, "Readback after write should not be nil")
        XCTAssertTrue(stored!.contains("verifyword"),
                      "Word 'verifyword' should be found in UserDefaults after add")
    }

    func test_persist_after_add_count_matches() {
        let store = LearnedWordsStore.shared
        store.add("countword1")
        store.add("countword2")

        let defaults = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
            ?? UserDefaults.standard
        let stored = defaults.array(forKey: "learnedWords") as? [String] ?? []
        XCTAssertEqual(stored.count, 2,
                       "UserDefaults should contain exactly 2 words after adding 2 distinct words")
    }
}
