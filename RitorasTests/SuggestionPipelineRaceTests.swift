import XCTest

final class SuggestionPipelineRaceTests: XCTestCase {

    // MARK: - Tap uses displayed array, not fresh query

    func test_tap_uses_displayed_array_not_fresh_query() {
        var cache = SuggestionDisplayCache()

        // Simulate: prediction engine returned ["red", "receive", "recent"] at display time.
        cache.update(["red", "receive", "recent"], token: 100)

        // User taps the first suggestion (index 0) — live token still matches.
        let result = decideSuggestionTap(cache: cache, liveToken: 100, index: 0)

        // Must return "red" — the originally displayed suggestion, NOT whatever
        // a fresh query would return at tap time.
        XCTAssertEqual(result, "red")
    }

    func test_tap_uses_middle_index_from_displayed_array() {
        var cache = SuggestionDisplayCache()
        cache.update(["the", "them", "there"], token: 200)

        let result = decideSuggestionTap(cache: cache, liveToken: 200, index: 1)
        XCTAssertEqual(result, "them")
    }

    func test_tap_uses_last_index_from_displayed_array() {
        var cache = SuggestionDisplayCache()
        cache.update(["a", "an", "the"], token: 300)

        let result = decideSuggestionTap(cache: cache, liveToken: 300, index: 2)
        XCTAssertEqual(result, "the")
    }

    // MARK: - Stale tap detection

    func test_stale_tap_returns_nil() {
        var cache = SuggestionDisplayCache()

        // Display suggestions when context token was 100.
        cache.update(["red", "receive", "recent"], token: 100)

        // By tap time, the user has typed more and the live token has changed to 999.
        // The cache should detect the mismatch and return nil.
        let result = decideSuggestionTap(cache: cache, liveToken: 999, index: 0)
        XCTAssertNil(result)
    }

    func test_stale_tap_nil_with_large_token_difference() {
        var cache = SuggestionDisplayCache()
        cache.update(["hello", "world"], token: UInt64.max)

        let result = decideSuggestionTap(cache: cache, liveToken: 0, index: 0)
        XCTAssertNil(result)
    }

    func test_consecutive_taps_first_valid_second_stale() {
        var cache = SuggestionDisplayCache()

        // First display.
        cache.update(["red", "receive", "recent"], token: 100)
        XCTAssertNotNil(decideSuggestionTap(cache: cache, liveToken: 100, index: 0))

        // Token changes (user typed more) before the second tap.
        let result = decideSuggestionTap(cache: cache, liveToken: 200, index: 1)
        XCTAssertNil(result)
    }

    // MARK: - Token zero backward-compat

    func test_token_zero_always_passes_through() {
        var cache = SuggestionDisplayCache()

        // Display with token 0 (backward-compat mode — stale-check disabled).
        cache.update(["red", "receive", "recent"], token: 0)

        // Any live token passes through.
        XCTAssertEqual(decideSuggestionTap(cache: cache, liveToken: 0, index: 0), "red")
        XCTAssertEqual(decideSuggestionTap(cache: cache, liveToken: 1, index: 1), "receive")
        XCTAssertEqual(decideSuggestionTap(cache: cache, liveToken: 999, index: 2), "recent")
    }

    func test_token_zero_with_empty_cache() {
        let cache = SuggestionDisplayCache()
        // Token 0 but no displayed items — should still return nil (out of range).
        XCTAssertNil(decideSuggestionTap(cache: cache, liveToken: 0, index: 0))
    }

    // MARK: - Display-time stale-write guard

    func test_lookup_applied_when_tokens_match() {
        // Tokens match → lookup should be applied.
        XCTAssertTrue(shouldApplyLookupResult(capturedToken: 100, liveToken: 100))
    }

    func test_lookup_dropped_when_tokens_mismatch() {
        // User typed more during lookup → tokens differ → drop stale result.
        XCTAssertFalse(shouldApplyLookupResult(capturedToken: 100, liveToken: 999))
    }

    func test_lookup_applied_when_captured_token_zero() {
        // Zero captured token disables the guard (backward-compat escape hatch).
        XCTAssertTrue(shouldApplyLookupResult(capturedToken: 0, liveToken: 999))
    }

    func test_lookup_applied_when_both_tokens_zero() {
        // Both zero: symmetric case, escape hatch fires.
        XCTAssertTrue(shouldApplyLookupResult(capturedToken: 0, liveToken: 0))
    }

    func test_lookup_dropped_with_large_token_difference() {
        // Captured token != 0 and differs from live token → drop.
        XCTAssertFalse(shouldApplyLookupResult(capturedToken: UInt64.max, liveToken: 0))
    }
}
