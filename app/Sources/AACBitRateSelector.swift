enum AACBitRateSelectionRule: String, Equatable, Sendable {
    case targetSupported
    case highestBelowTarget
    case nearestAboveTarget
    case conservativeFallback
}

struct AACBitRateRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double

    func contains(_ bitRate: Int) -> Bool {
        minimum <= Double(bitRate) && Double(bitRate) <= maximum
    }
}

struct AACBitRateSelection: Equatable, Sendable {
    let bitRate: Int
    let rule: AACBitRateSelectionRule
}

enum AACBitRateSelector {
    static func conservativeFallback(sourceSampleRate: Int) -> AACBitRateSelection {
        AACBitRateSelection(
            bitRate: sourceSampleRate == 16_000 ? 32_000 : 64_000,
            rule: .conservativeFallback)
    }

    static func select(
        availableRanges: [AACBitRateRange],
        applicableBitRates: [Int],
        targetBitRate: Int,
        fallbackBitRate: Int
    ) -> AACBitRateSelection {
        let supportedBitRates = Array(Set(applicableBitRates.filter { bitRate in
            bitRate > 0 && availableRanges.contains { $0.contains(bitRate) }
        })).sorted()

        guard !supportedBitRates.isEmpty else {
            return AACBitRateSelection(
                bitRate: fallbackBitRate,
                rule: .conservativeFallback)
        }
        if supportedBitRates.contains(targetBitRate) {
            return AACBitRateSelection(bitRate: targetBitRate, rule: .targetSupported)
        }
        if let highestBelowTarget = supportedBitRates.last(where: { $0 < targetBitRate }) {
            return AACBitRateSelection(
                bitRate: highestBelowTarget,
                rule: .highestBelowTarget)
        }
        return AACBitRateSelection(
            bitRate: supportedBitRates[0],
            rule: .nearestAboveTarget)
    }
}
