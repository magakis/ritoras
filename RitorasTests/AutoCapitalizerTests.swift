import XCTest

final class AutoCapitalizerTests: XCTestCase {

    // MARK: - Start / Whitespace

    func test_empty_input() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: ""), true)
    }

    func test_only_space() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: " "), true)
    }

    func test_only_newline() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "\n"), true)
    }

    func test_multiple_whitespace_and_newlines() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "   \n  "), true)
    }

    // MARK: - Terminal Punctuation

    func test_period_space_triggers_capitalization() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hi. "), true)
    }

    func test_exclamation_space_triggers_capitalization() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hi! "), true)
    }

    func test_question_space_triggers_capitalization() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hi? "), true)
    }

    func test_period_newline_triggers_capitalization() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hi.\n"), true)
    }

    func test_period_multiple_newlines_triggers_capitalization() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hi.\n\n"), true)
    }

    func test_bare_newline_triggers_capitalization() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "\n"), true)
    }

    // MARK: - Closing-Quote Transparency

    func test_closing_quote_after_period() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "He said \"Hi. \" "), true)
    }

    func test_closing_bracket_after_period() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hi.\u{300D} "), true)
    }

    // MARK: - Opening-Quote Transparency

    func test_opening_quote_alone_at_start() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "\""), true)
    }

    func test_opening_quote_then_space_at_start() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "\" "), true)
    }

    func test_opening_quote_with_text_mid_sentence() {
        // Opening quote mid-sentence is NOT a sentence start — should NOT trigger.
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "and \"he said "), false)
    }

    func test_open_paren_at_start() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "("), true)
    }

    func test_open_paren_with_space_at_start() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "( "), true)
    }

    // MARK: - Non-Triggering Mid Punctuation

    func test_comma_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "hi, "), false)
    }

    func test_colon_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "hi: "), false)
    }

    func test_semicolon_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "hi; "), false)
    }

    func test_hyphen_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "hi - "), false)
    }

    func test_em_dash_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "hi \u{2014} "), false)
    }

    func test_ellipsis_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "hi\u{2026} "), false)
    }

    // MARK: - Period Without Space

    func test_period_without_trailing_whitespace_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Hello.etc"), false)
    }

    // MARK: - Decimals / IPs / Versions

    func test_decimal_number_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "3.14 "), false)
    }

    func test_ip_address_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "192.168.0.1 "), false)
    }

    func test_version_string_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "v1.2.3 "), false)
    }

    func test_decimal_in_sentence_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "score is 7.5 "), false)
    }

    // MARK: - Abbreviations

    func test_i_e_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "i.e. "), false)
    }

    func test_e_g_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "e.g. "), false)
    }

    func test_mr_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Mr. "), false)
    }

    func test_dr_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Dr. "), false)
    }

    func test_etc_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "etc. "), false)
    }

    func test_u_s_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "U.S. "), false)
    }

    func test_jan_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Jan. "), false)
    }

    func test_mon_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Mon. "), false)
    }

    func test_a_m_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "a.m. "), false)
    }

    func test_ph_d_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "Ph.D. "), false)
    }

    // MARK: - Initials

    func test_double_initials_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "J.K. "), false)
    }

    func test_name_with_middle_initial_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "George W. "), false)
    }

    func test_single_initial_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "A. "), false)
    }

    // MARK: - Sentence After Abbreviation (Sanity)

    func test_sentence_end_after_abbreviation_and_word() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "I saw Mr. Smith. "), true)
    }

    // MARK: - Scripts Without Case

    func test_japanese_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "こんにちは "), false)
    }

    func test_arabic_does_not_trigger() {
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: "مرحبا "), false)
    }

    // MARK: - Lookback Bound

    func test_lookback_bound_300_char_still_triggers() {
        // Build a 300-character string ending with ". " — the suffix (200 chars)
        // should still contain the terminal punctuation.
        let prefix = String(repeating: "a", count: 298)
        let context = prefix + ". "
        XCTAssertEqual(prefix.count, 298)
        XCTAssertEqual(context.count, 300)
        XCTAssertEqual(AutoCapitalizer.shouldCapitalizeNext(contextBeforeCursor: context), true)
    }
}
