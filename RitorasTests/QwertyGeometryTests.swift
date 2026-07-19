import XCTest

final class QwertyGeometryTests: XCTestCase {

    // MARK: - Basic Distance

    func test_adjacent_keys_have_low_cost() {
        // e and r are adjacent on row 0 (positions 2 and 3).
        // a and p are far apart (row 1 offset 0 vs row 0 position 9).
        let eR = QwertyGeometry.adjacentKeyCost("e", "r")
        let aP = QwertyGeometry.adjacentKeyCost("a", "p")

        XCTAssertLessThan(eR, aP, "Adjacent keys (e↔r) should cost less than far keys (a↔p)")
        // e→r: distance 1, cost = 1/3 ≈ 0.333
        XCTAssertEqual(eR, 1.0 / 3.0, accuracy: 1e-6)
    }

    func test_far_keys_have_high_cost() {
        // a at (0.25, 1), p at (9, 0) — far apart.
        let cost = QwertyGeometry.adjacentKeyCost("a", "p")
        // Euclidean distance: sqrt((0.25-9)^2 + (1-0)^2) ≈ sqrt(76.5625 + 1) ≈ sqrt(77.5625) ≈ 8.807
        // raw = 8.807/3 ≈ 2.936, clamped to 1.0
        XCTAssertEqual(cost, 1.0, accuracy: 0.1,
                       "Far keys (a↔p) should have cost near 1.0, got \(cost)")
    }

    func test_unknown_char_neutral() {
        let cost = QwertyGeometry.adjacentKeyCost("1", "2")
        XCTAssertEqual(cost, 1.0, "Unknown chars should return neutral cost 1.0")
    }

    func test_same_key_cost_zero() {
        let cost = QwertyGeometry.adjacentKeyCost("a", "a")
        XCTAssertEqual(cost, 0.0, "Same key should have zero cost")
    }

    // MARK: - Score

    func test_score_match_is_one() {
        let s = QwertyGeometry.score(typed: "hello", candidate: "hello",
                                     symSpellDistance: 0, beta: 1.5)
        XCTAssertEqual(s, 1.0, "Exact match (distance 0) should score 1.0")
    }

    func test_score_adjacent_typo_beats_far_typo() {
        // hellp → hello: p vs o, adjacent on row 0 (positions 9 and 8).
        let adjacent = QwertyGeometry.score(typed: "hellp", candidate: "hello",
                                            symSpellDistance: 1, beta: 1.5)

        // hellm → hello: m vs o, far apart (row 2 vs row 0).
        let far = QwertyGeometry.score(typed: "hellm", candidate: "hello",
                                       symSpellDistance: 1, beta: 1.5)

        XCTAssertGreaterThan(adjacent, far,
                             "Adjacent-key typo should outscore far-key typo")
    }

    func test_doubling_discount() {
        // "recieve" → "receive": a transposition, which also fires a discount.
        // weighted edit distance should be less than 2 * adjacentKeyCost("e","i")
        let w = QwertyGeometry.weightedEditDistance(typed: "recieve", candidate: "receive",
                                                     symSpellDistance: 2)
        let rawTwoLetters = 2.0 * QwertyGeometry.adjacentKeyCost("e", "i")
        XCTAssertLessThan(w, rawTwoLetters,
                          "Discount should make weighted distance < raw pair cost")
        // transposition: 2 * 1.0 * 0.7 = 1.4 < 2.0
        XCTAssertEqual(w, 1.4, accuracy: 1e-6)
    }

    func test_transposition_discount() {
        // "teh" → "the": adjacent transposition of e↔h.
        let w = QwertyGeometry.weightedEditDistance(typed: "teh", candidate: "the",
                                                     symSpellDistance: 2)
        // adjacentKeyCost(e,h) + adjacentKeyCost(h,e) = 1.0 + 1.0 = 2.0
        // transposition discount: 2.0 * 0.7 = 1.4
        let undiscounted = QwertyGeometry.adjacentKeyCost("e", "h")
                         + QwertyGeometry.adjacentKeyCost("h", "e")
        XCTAssertLessThan(w, undiscounted,
                          "Transposition discount should reduce weighted distance")
        XCTAssertEqual(w, undiscounted * 0.7, accuracy: 1e-6)
    }

    func test_score_range_is_zero_to_one() {
        // Spot-check across various scenarios.
        let cases: [(typed: String, candidate: String, distance: Int)] = [
            ("hellp", "hello", 1),
            ("hellm", "hello", 1),
            ("teh", "the", 2),
            ("recieve", "receive", 2),
            ("helo", "hello", 1),
            ("hello", "helo", 1),
            ("xyz", "abc", 3),
        ]
        for (typed, candidate, distance) in cases {
            let s = QwertyGeometry.score(typed: typed, candidate: candidate,
                                         symSpellDistance: distance, beta: 1.5)
            XCTAssertGreaterThanOrEqual(s, 0.0,
                                        "Score should be >= 0 for \(typed)→\(candidate), got \(s)")
            XCTAssertLessThanOrEqual(s, 1.0,
                                     "Score should be <= 1 for \(typed)→\(candidate), got \(s)")
        }
    }

    // MARK: - Distance-2 Ambiguous Alignment

    func test_distance_2_ambiguous_alignment_uses_geometry() {
        // "appple" → "aple": three consecutive 'p' chars (positions 1-3).
        // Deleting any two of them yields the same alignment "aple" with cost 0.
        // Three deletion pairs tie → OLD code would fall back to
        // Double(symSpellDistance) = 2.0, discarding geometry entirely.
        let w = QwertyGeometry.weightedEditDistance(typed: "appple", candidate: "aple",
                                                     symSpellDistance: 2)
        // All remaining chars match perfectly → geometry-aware cost is 0.
        XCTAssertEqual(w, 0.0, accuracy: 1e-6,
                       "Best alignment cost should be 0 (all remaining chars match)")
        XCTAssertLessThan(w, 2.0,
                          "Geometry-aware cost should beat flat fallback 2.0")
    }

    func test_distance_2_far_key_pairs_not_discarded() {
        // "apzq" → "ab": each deletion pair leaves one character that must be
        // substituted: 'q'↔'b', 'z'↔'b', or 'p'↔'b'. All three are far-apart
        // key pairs whose cost clamps to 1.0. The function returns 1.0 (the
        // geometry-aware cost) rather than the flat fallback 2.0.
        let w = QwertyGeometry.weightedEditDistance(typed: "apzq", candidate: "ab",
                                                     symSpellDistance: 2)
        // Every deletion pair yields cost = min(max(adjacentKeyCost, 0.1), 1.0) = 1.0
        XCTAssertEqual(w, 1.0, accuracy: 1e-6,
                       "All far-key substitutions clamp to 1.0 → best cost = 1.0")
        XCTAssertLessThan(w, 2.0,
                          "Geometry-aware 1.0 beats flat fallback 2.0")
    }
}
