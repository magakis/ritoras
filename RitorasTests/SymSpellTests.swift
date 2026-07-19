import XCTest

final class SymSpellTests: XCTestCase {

    private var symSpell: SymSpell!

    override func setUpWithError() throws {
        try super.setUpWithError()
        symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)

        // Load the bundled frequency dictionary.
        // First check the test bundle, then the main (keyboard) bundle.
        let testBundle = Bundle(for: SymSpellTests.self)
        let url = testBundle.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                                 withExtension: "txt")
            ?? Bundle.main.url(forResource: "frequency_dictionary_en_wordfreq_50k",
                               withExtension: "txt")
        guard let url = url else {
            throw XCTSkip("frequency_dictionary_en_wordfreq_50k.txt not found in any bundle")
        }

        let entries = try WordListLoader.load(from: url)
        for entry in entries {
            symSpell.createDictionaryEntry(key: entry.word, count: entry.count)
        }
    }

    // MARK: - Known Typos (≥20)

    func test_teh_suggests_the() {
        let results = symSpell.lookup(input: "teh", verbosity: .top)
        XCTAssertEqual(results.first?.term, "the", "teh should correct to the, got \(results.first?.term ?? "nil")")
    }

    func test_recieve_suggests_receive() {
        let results = symSpell.lookup(input: "recieve", verbosity: .top)
        XCTAssertEqual(results.first?.term, "receive", "recieve should correct to receive")
    }

    func test_definately_suggests_definitely() {
        let results = symSpell.lookup(input: "definately", verbosity: .top)
        XCTAssertEqual(results.first?.term, "definitely", "definately should correct to definitely")
    }

    func test_seperate_suggests_separate() {
        let results = symSpell.lookup(input: "seperate", verbosity: .top)
        XCTAssertEqual(results.first?.term, "separate", "seperate should correct to separate")
    }

    func test_occured_suggests_occurred() {
        let results = symSpell.lookup(input: "occured", verbosity: .top)
        XCTAssertEqual(results.first?.term, "occurred", "occured should correct to occurred")
    }

    func test_untill_suggests_until() {
        let results = symSpell.lookup(input: "untill", verbosity: .top)
        XCTAssertEqual(results.first?.term, "until", "untill should correct to until")
    }

    func test_wich_suggests_which() {
        let results = symSpell.lookup(input: "wich", verbosity: .top)
        XCTAssertEqual(results.first?.term, "which", "wich should correct to which")
    }

    func test_becuase_suggests_because() {
        let results = symSpell.lookup(input: "becuase", verbosity: .top)
        XCTAssertEqual(results.first?.term, "because", "becuase should correct to because")
    }

    func test_accomodate_suggests_accommodate() {
        let results = symSpell.lookup(input: "accomodate", verbosity: .top)
        XCTAssertEqual(results.first?.term, "accommodate", "accomodate should correct to accommodate")
    }

    func test_calender_suggests_calendar() {
        let results = symSpell.lookup(input: "calender", verbosity: .top)
        XCTAssertEqual(results.first?.term, "calendar", "calender should correct to calendar")
    }

    func test_cemetary_suggests_cemetery() {
        let results = symSpell.lookup(input: "cemetary", verbosity: .top)
        XCTAssertEqual(results.first?.term, "cemetery", "cemetary should correct to cemetery")
    }

    func test_embarass_suggests_embarrass() {
        let results = symSpell.lookup(input: "embarass", verbosity: .top)
        XCTAssertEqual(results.first?.term, "embarrass", "embarass should correct to embarrass")
    }

    func test_goverment_suggests_government() {
        let results = symSpell.lookup(input: "goverment", verbosity: .top)
        XCTAssertEqual(results.first?.term, "government", "goverment should correct to government")
    }

    func test_harrass_suggests_harass() {
        let results = symSpell.lookup(input: "harrass", verbosity: .top)
        XCTAssertEqual(results.first?.term, "harass", "harrass should correct to harass")
    }

    func test_independant_suggests_independent() {
        let results = symSpell.lookup(input: "independant", verbosity: .top)
        XCTAssertEqual(results.first?.term, "independent", "independant should correct to independent")
    }

    func test_liason_suggests_liaison() {
        let results = symSpell.lookup(input: "liason", verbosity: .top)
        XCTAssertEqual(results.first?.term, "liaison", "liason should correct to liaison")
    }

    func test_mischievious_suggests_mischievous() {
        let results = symSpell.lookup(input: "mischievious", verbosity: .top)
        XCTAssertEqual(results.first?.term, "mischievous", "mischievious should correct to mischievous")
    }

    func test_neccessary_suggests_necessary() {
        let results = symSpell.lookup(input: "neccessary", verbosity: .top)
        XCTAssertEqual(results.first?.term, "necessary", "neccessary should correct to necessary")
    }

    func test_paralel_suggests_parallel() {
        let results = symSpell.lookup(input: "paralel", verbosity: .top)
        XCTAssertEqual(results.first?.term, "parallel", "paralel should correct to parallel")
    }

    func test_pronounciation_suggests_pronunciation() {
        let results = symSpell.lookup(input: "pronounciation", verbosity: .top)
        XCTAssertEqual(results.first?.term, "pronunciation", "pronounciation should correct to pronunciation")
    }

    func test_publicaly_suggests_publicly() {
        let results = symSpell.lookup(input: "publicaly", verbosity: .top)
        XCTAssertEqual(results.first?.term, "publicly", "publicaly should correct to publicly")
    }

    // MARK: - Real Words

    func test_the_returns_self() {
        let results = symSpell.lookup(input: "the", verbosity: .top)
        XCTAssertEqual(results.first?.term, "the", "real word 'the' should return itself")
        XCTAssertEqual(results.first?.distance, 0, "exact match should have distance 0")
    }

    func test_hello_returns_self() {
        let results = symSpell.lookup(input: "hello", verbosity: .top)
        XCTAssertEqual(results.first?.term, "hello", "real word 'hello' should return itself")
    }

    func test_world_returns_self() {
        let results = symSpell.lookup(input: "world", verbosity: .top)
        XCTAssertEqual(results.first?.term, "world", "real word 'world' should return itself")
    }

    func test_swift_returns_self() {
        let results = symSpell.lookup(input: "swift", verbosity: .top)
        XCTAssertEqual(results.first?.term, "swift", "real word 'swift' should return itself")
    }

    // MARK: - Case Insensitivity

    func test_case_insensitive_teh() {
        let lower = symSpell.lookup(input: "teh", verbosity: .top)
        let upper = symSpell.lookup(input: "TEH", verbosity: .top)
        XCTAssertEqual(lower.first?.term, upper.first?.term,
                       "TEH and teh should produce same correction")
    }

    // MARK: - Verbosity

    func test_top_returns_one_result() {
        let results = symSpell.lookup(input: "teh", verbosity: .top)
        XCTAssertLessThanOrEqual(results.count, 2, ".top should return at most 1 result (plus self)")
    }

    func test_all_returns_multiple_results() {
        let results = symSpell.lookup(input: "teh", verbosity: .all)
        XCTAssertGreaterThan(results.count, 0, ".all should return at least 1 result")
    }

    // MARK: - Distance Verification

    func test_teh_distance_is_2() {
        let results = symSpell.lookup(input: "teh", verbosity: .all)
        guard let theResult = results.first(where: { $0.term == "the" }) else {
            XCTFail("teh should suggest the")
            return
        }
        XCTAssertLessThanOrEqual(theResult.distance, 2, "the distance from teh should be ≤2")
    }

    func test_exact_match_distance_zero() {
        let results = symSpell.lookup(input: "the", verbosity: .top)
        XCTAssertEqual(results.first?.distance, 0)
    }

    // MARK: - Performance (Issue #3)

    /// Verifies that unrecognized input (no corrections within edit distance)
    /// returns [] quickly, without the O(n) full-dictionary scan that was
    /// incorrectly present in Phase 3 of the original implementation.
    func test_unrecognized_input_returns_empty_fast() {
        let start = CFAbsoluteTimeGetCurrent()

        // "xzqw" is not a real word and has no close correction.
        let results = symSpell.lookup(input: "xzqw", editDistance: 2, verbosity: .top)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        XCTAssertTrue(results.isEmpty,
                      "Unrecognized input should yield no corrections, got \(results)")
        XCTAssertLessThan(elapsed, 5.0,
                          "lookup(\"xzqw\") should complete in <5ms without O(n) scan, took \(String(format: "%.2f", elapsed))ms")
    }
}
