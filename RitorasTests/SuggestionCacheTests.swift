import XCTest

final class SuggestionCacheTests: XCTestCase {

    // MARK: - FNV-1a Hash

    func test_fnv1a_is_deterministic() {
        let a = ContextHash.fnv1a("hello world")
        let b = ContextHash.fnv1a("hello world")
        XCTAssertEqual(a, b)
    }

    func test_fnv1a_differs_on_different_input() {
        let a = ContextHash.fnv1a("hello")
        let b = ContextHash.fnv1a("hellp")
        XCTAssertNotEqual(a, b)
    }

    func test_fnv1a_differs_on_empty_vs_nonempty() {
        let a = ContextHash.fnv1a("")
        let b = ContextHash.fnv1a(" ")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Cache: Token Match

    func test_cache_returns_displayed_suggestion_when_token_matches() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        let result = cache.suggestion(at: 0, matchingLiveToken: 42)
        XCTAssertEqual(result, "red")
    }

    func test_cache_returns_correct_index_when_token_matches() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        XCTAssertEqual(cache.suggestion(at: 1, matchingLiveToken: 42), "receive")
        XCTAssertEqual(cache.suggestion(at: 2, matchingLiveToken: 42), "recent")
    }

    // MARK: - Cache: Token Mismatch

    func test_cache_returns_nil_when_token_mismatches() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        let result = cache.suggestion(at: 0, matchingLiveToken: 99)
        XCTAssertNil(result)
    }

    // MARK: - Cache: Out of Range

    func test_cache_returns_nil_for_out_of_range_index() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        XCTAssertNil(cache.suggestion(at: -1, matchingLiveToken: 42))
        XCTAssertNil(cache.suggestion(at: 3, matchingLiveToken: 42))
        XCTAssertNil(cache.suggestion(at: 100, matchingLiveToken: 42))
    }

    func test_empty_cache_returns_nil() {
        let cache = SuggestionDisplayCache()
        XCTAssertNil(cache.suggestion(at: 0, matchingLiveToken: 42))
    }

    // MARK: - Cache: Token Zero Escape Hatch

    func test_cache_token_zero_disables_stale_check() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 0)

        // Token 0 means "always match" — any live token should pass through.
        XCTAssertEqual(cache.suggestion(at: 0, matchingLiveToken: 0), "red")
        XCTAssertEqual(cache.suggestion(at: 0, matchingLiveToken: 1), "red")
        XCTAssertEqual(cache.suggestion(at: 0, matchingLiveToken: 99), "red")
    }

    // MARK: - decideSuggestionTap

    func test_decideSuggestionTap_passes_through_when_token_matches() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        let result = decideSuggestionTap(cache: cache, liveToken: 42, index: 0)
        XCTAssertEqual(result, "red")
    }

    func test_decideSuggestionTap_returns_nil_when_stale() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        let result = decideSuggestionTap(cache: cache, liveToken: 99, index: 0)
        XCTAssertNil(result)
    }

    func test_decideSuggestionTap_returns_nil_for_out_of_range() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        let result = decideSuggestionTap(cache: cache, liveToken: 42, index: 5)
        XCTAssertNil(result)
    }

    func test_decideSuggestionTap_returns_nil_for_negative_index() {
        var cache = SuggestionDisplayCache()
        cache.update(["red", "receive", "recent"], token: 42)

        let result = decideSuggestionTap(cache: cache, liveToken: 42, index: -1)
        XCTAssertNil(result)
    }
}
