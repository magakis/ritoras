import XCTest

final class WordListLoaderTests: XCTestCase {

    func test_bundled_file_exists_and_loads() throws {
        let url = WordListLoader.bundledURL()
        XCTAssertNotNil(url, "Bundled frequency dictionary URL should not be nil")

        let entries = try WordListLoader.load(from: url!)
        XCTAssertGreaterThan(entries.count, 40_000,
                             "Wordfreq dictionary should have more than 40,000 entries, got \(entries.count)")
    }

    func test_every_entry_has_word_and_positive_count() throws {
        guard let url = WordListLoader.bundledURL() else {
            XCTFail("Bundled frequency dictionary not found")
            return
        }

        let entries = try WordListLoader.load(from: url)
        let sample = entries.prefix(1000)
        for entry in sample {
            XCTAssertFalse(entry.word.isEmpty, "Every entry should have a non-empty word")
            XCTAssertGreaterThan(entry.count, 0, "Every entry should have a positive count")
        }
    }

    func test_known_top_words_present() throws {
        guard let url = WordListLoader.bundledURL() else {
            XCTFail("Bundled frequency dictionary not found")
            return
        }

        let entries = try WordListLoader.load(from: url)
        let words = Set(entries.map { $0.word.lowercased() })
        XCTAssertTrue(words.contains("the"), "Dictionary should contain 'the'")
        XCTAssertTrue(words.contains("be"), "Dictionary should contain 'be'")
        XCTAssertTrue(words.contains("and"), "Dictionary should contain 'and'")
    }

    func test_loadInto_populates_symspell_and_trie() throws {
        let symSpell = SymSpell(maxEditDistance: 2)
        let trie = Trie()

        let count = try WordListLoader.loadInto(symSpell: symSpell, trie: trie)
        XCTAssertGreaterThan(count, 0, "Should load words into SymSpell and Trie")
        XCTAssertTrue(trie.contains(word: "the"),
                      "Trie should contain 'the' after loadInto")
    }
}
