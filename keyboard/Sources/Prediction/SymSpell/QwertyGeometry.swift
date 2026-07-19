import Foundation

/// QWERTY keyboard geometry for weighted edit-distance scoring.
///
/// Models the iOS keyboard's key-center positions as a 2D grid
/// (key-units, not pixels). Used to compute `adjacentKeyCost` so
/// that nearby-key substitutions (e→r) are scored milder than
/// far-key substitutions (r→m).
enum QwertyGeometry {

    // MARK: - Key Centers

    /// Key-center positions measured in key-width units on a standard
    /// iOS QWERTY layout.
    static let keyCenters: [Character: (x: Double, y: Double)] = {
        var centers: [Character: (x: Double, y: Double)] = [:]
        // Row 0: q w e r t y u i o p  (y=0)
        for (i, ch) in "qwertyuiop".enumerated() {
            centers[ch] = (Double(i), 0)
        }
        // Row 1: a s d f g h j k l  (y=1, offset 0.25)
        for (i, ch) in "asdfghjkl".enumerated() {
            centers[ch] = (Double(i) + 0.25, 1)
        }
        // Row 2: z x c v b n m  (y=2, offset 0.75)
        for (i, ch) in "zxcvbnm".enumerated() {
            centers[ch] = (Double(i) + 0.75, 2)
        }
        // Apostrophe — near L
        centers["'"] = (9.25, 1)
        return centers
    }()

    // MARK: - Basic Distance

    /// Compute the Euclidean distance between two characters' key centers.
    /// Returns 1.0 for unknown characters (neutral).
    static func distance(_ a: Character, _ b: Character) -> Double {
        guard let posA = keyCenters[a], let posB = keyCenters[b] else {
            return 1.0
        }
        let dx = posA.x - posB.x
        let dy = posA.y - posB.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Adjacent-key substitution cost.
    ///
    /// `distance / 3.0` clamped to `[0.1, 1.0]`. Same-key cost is 0.
    /// Returns 1.0 for unknown characters.
    static func adjacentKeyCost(_ a: Character, _ b: Character) -> Double {
        guard a != b else { return 0 }
        let raw = distance(a, b) / 3.0
        return min(max(raw, 0.1), 1.0)
    }

    // MARK: - Weighted Edit Distance

    /// Compute a QWERTY-geometry-aware weighted edit distance between
    /// `typed` and `candidate`.
    ///
    /// - Parameters:
    ///   - typed: The word the user typed (will be lowercased).
    ///   - candidate: The candidate from SymSpell.
    ///   - symSpellDistance: The raw Levenshtein distance from SymSpell.
    ///   - doublingDiscount: Discount applied for doubled-letter edits.
    ///   - transpositionDiscount: Discount applied for adjacent transpositions.
    /// - Returns: Weighted edit distance in `[0, ∞)`.
    static func weightedEditDistance(
        typed: String,
        candidate: String,
        symSpellDistance: Int,
        doublingDiscount: Double = 0.5,
        transpositionDiscount: Double = 0.7
    ) -> Double {
        let chars1 = Array(typed.lowercased())
        let chars2 = Array(candidate.lowercased())

        let result: Double
        if chars1.count == chars2.count {
            result = _weightedEditDistanceEqual(
                chars1, chars2,
                transpositionDiscount: transpositionDiscount
            )
        } else if chars1.count == chars2.count + 1 {
            result = _weightedEditDistanceInsertion(
                longer: chars1, shorter: chars2,
                doublingDiscount: doublingDiscount
            )
        } else if chars1.count + 1 == chars2.count {
            result = _weightedEditDistanceInsertion(
                longer: chars2, shorter: chars1,
                doublingDiscount: doublingDiscount
            )
        } else if abs(chars1.count - chars2.count) == 2 {
            result = _weightedEditDistanceDiff2(
                chars1, chars2,
                symSpellDistance: symSpellDistance,
                doublingDiscount: doublingDiscount,
                transpositionDiscount: transpositionDiscount
            )
        } else {
            result = Double(symSpellDistance)
        }

        return result
    }

    // MARK: - Score

    /// Convert a weighted edit distance to a `[0, 1]` probability.
    ///
    /// `score = exp(-beta * weightedEditDistance(...))`, clamped to `[0, 1]`.
    /// When `symSpellDistance == 0`, returns `1.0` (exact match).
    static func score(
        typed: String,
        candidate: String,
        symSpellDistance: Int,
        beta: Double,
        doublingDiscount: Double = 0.5,
        transpositionDiscount: Double = 0.7
    ) -> Double {
        guard symSpellDistance != 0 else { return 1.0 }
        let weighted = weightedEditDistance(
            typed: typed,
            candidate: candidate,
            symSpellDistance: symSpellDistance,
            doublingDiscount: doublingDiscount,
            transpositionDiscount: transpositionDiscount
        )
        return min(max(exp(-beta * weighted), 0.0), 1.0)
    }
}

// MARK: - Private Helpers

extension QwertyGeometry {

    /// Equal-length case: pure substitution with possible adjacent transposition.
    private static func _weightedEditDistanceEqual(
        _ chars1: [Character],
        _ chars2: [Character],
        transpositionDiscount: Double
    ) -> Double {
        var totalCost = 0.0
        var diffPositions: [Int] = []

        for i in 0..<chars1.count {
            if chars1[i] != chars2[i] {
                diffPositions.append(i)
                totalCost += adjacentKeyCost(chars1[i], chars2[i])
            }
        }

        // Detect single adjacent transposition (e.g. teh → the).
        if diffPositions.count == 2,
           diffPositions[0] + 1 == diffPositions[1],
           chars1[diffPositions[0]] == chars2[diffPositions[1]],
           chars1[diffPositions[1]] == chars2[diffPositions[0]]
        {
            totalCost *= transpositionDiscount
        }

        return totalCost
    }

    /// Length-diff-1 case: one insertion or deletion.
    /// `longer` has one more character than `shorter`.
    private static func _weightedEditDistanceInsertion(
        longer: [Character],
        shorter: [Character],
        doublingDiscount: Double
    ) -> Double {
        var bestCost = Double.infinity
        var isDoubling = false

        for delPos in 0..<longer.count {
            // Build aligned version of longer without char at delPos.
            var aligned: [Character] = []
            aligned.reserveCapacity(longer.count - 1)
            for i in 0..<longer.count {
                if i != delPos {
                    aligned.append(longer[i])
                }
            }

            // Compute substitution cost against shorter.
            var cost = 0.0
            for i in 0..<shorter.count {
                if shorter[i] != aligned[i] {
                    cost += adjacentKeyCost(shorter[i], aligned[i])
                }
            }

            // Check doubling: deleted/inserted char identical to neighbor.
            let deletedChar = longer[delPos]
            let hasDoubling = (delPos > 0 && longer[delPos - 1] == deletedChar)
                || (delPos < longer.count - 1 && longer[delPos + 1] == deletedChar)

            // Prefer best cost; on tie prefer the doubling alignment.
            if cost < bestCost || (cost == bestCost && hasDoubling && !isDoubling) {
                bestCost = cost
                isDoubling = hasDoubling
            }
        }

        if isDoubling {
            bestCost *= doublingDiscount
        }

        return bestCost
    }

    /// Length-diff-2 case: try all deletion pairs and return the
    /// lowest-cost geometry-aware alignment.
    ///
    /// When multiple alignments tie for the same cost, any of them
    /// yields the same objective value — no ambiguity in the score.
    private static func _weightedEditDistanceDiff2(
        _ chars1: [Character],
        _ chars2: [Character],
        symSpellDistance: Int,
        doublingDiscount: Double,
        transpositionDiscount: Double
    ) -> Double {
        let longer: [Character]
        let shorter: [Character]
        if chars1.count > chars2.count {
            longer = chars1
            shorter = chars2
        } else {
            longer = chars2
            shorter = chars1
        }

        var bestCost = Double.infinity

        for i in 0..<longer.count {
            for j in (i + 1)..<longer.count {
                var aligned: [Character] = []
                aligned.reserveCapacity(longer.count - 2)
                for k in 0..<longer.count {
                    if k != i, k != j {
                        aligned.append(longer[k])
                    }
                }

                var cost = 0.0
                for k in 0..<shorter.count {
                    if shorter[k] != aligned[k] {
                        cost += adjacentKeyCost(shorter[k], aligned[k])
                    }
                }

                if cost < bestCost {
                    bestCost = cost
                }
            }
        }

        return bestCost
    }
}
