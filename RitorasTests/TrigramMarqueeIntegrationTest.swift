import XCTest

final class TrigramMarqueeIntegrationTest: XCTestCase {

    func test_i_am_looking_very_suggests_adjective() throws {
        let provider = TrigramProvider()
        let ready = XCTestExpectation(description: "warmup")
        provider.warmup { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5.0)

        try XCTSkipUnless(provider.isReady, "TrigramProvider not ready — model file missing from test bundle")

        let context = SuggestionContext(
            currentWord: "",
            lookupWord: "",
            previousWord: "very",
            previousWord2: "looking",
            isMidWord: false
        )
        let suggestions = provider.suggest(for: context, limit: 5)

        // Per Phase 1 verification: top-5 is ["pleased", "much", "and", "well", "good"]
        let expectedAdjectives: Set<String> = ["pleased", "much", "good", "well", "nice", "beautiful", "handsome", "tired"]
        let texts = Set(suggestions.map { $0.text.lowercased() })
        let intersection = texts.intersection(expectedAdjectives)
        XCTAssertFalse(intersection.isEmpty,
            "Expected at least one adjective in top-5; got: \(suggestions.map { $0.text })")
    }
}
