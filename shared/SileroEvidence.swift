import Foundation

struct SileroEvidenceConfiguration {
    static let defaultStartThreshold = 0.45
    static let defaultStopThreshold = 0.30
    static let defaultSmoothingSteps = 5

    let startThreshold: Double
    let stopThreshold: Double
    let smoothingSteps: Int

    init(
        startThreshold: Double = defaultStartThreshold,
        stopThreshold: Double = defaultStopThreshold,
        smoothingSteps: Int = defaultSmoothingSteps
    ) {
        let normalizedStartThreshold = Self.clampFinite(
            startThreshold,
            fallback: Self.defaultStartThreshold,
            minimum: 0.10,
            maximum: 0.90
        )
        self.startThreshold = normalizedStartThreshold
        self.stopThreshold = min(
            Self.clampFinite(
                stopThreshold,
                fallback: Self.defaultStopThreshold,
                minimum: 0.10,
                maximum: 0.90
            ),
            normalizedStartThreshold
        )
        self.smoothingSteps = min(max(smoothingSteps, 1), 15)
    }

    private static func clampFinite(
        _ value: Double,
        fallback: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        let finiteValue = value.isFinite ? value : fallback
        return min(max(finiteValue, minimum), maximum)
    }
}

struct SileroEvidenceDecision {
    let rawProbability: Double
    let smoothedProbability: Double
    let evidence: VADEvidence
}

/// Applies ramp-in moving-average smoothing and the three Silero evidence bands.
final class SileroEvidenceProcessor {
    let configuration: SileroEvidenceConfiguration
    private var recentProbabilities: [Double] = []
    private(set) var latestDecision: SileroEvidenceDecision?

    init(configuration: SileroEvidenceConfiguration) {
        self.configuration = configuration
    }

    @discardableResult
    func consume(_ probability: Double) -> SileroEvidenceDecision {
        let rawProbability = probability.isFinite
            ? min(max(probability, 0.0), 1.0)
            : 0.0
        recentProbabilities.append(rawProbability)
        if recentProbabilities.count > configuration.smoothingSteps {
            recentProbabilities.removeFirst(
                recentProbabilities.count - configuration.smoothingSteps
            )
        }

        let smoothedProbability = recentProbabilities.reduce(0.0, +)
            / Double(recentProbabilities.count)
        let evidence: VADEvidence
        if smoothedProbability >= configuration.startThreshold {
            evidence = .strong
        } else if smoothedProbability >= configuration.stopThreshold {
            evidence = .continuing
        } else {
            evidence = .silence
        }

        let decision = SileroEvidenceDecision(
            rawProbability: rawProbability,
            smoothedProbability: smoothedProbability,
            evidence: evidence
        )
        latestDecision = decision
        return decision
    }

    func reset() {
        recentProbabilities.removeAll(keepingCapacity: true)
        latestDecision = nil
    }
}
