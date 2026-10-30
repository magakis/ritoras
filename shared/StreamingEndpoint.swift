import Foundation

// Pure-logic endpoint decisions; continuous audio retention remains owned by
// StreamingAudioRecorder.

enum StreamingEndpointEvidence: String {
    case strong
    case continuing
    case ambiguous
    case silence
}

enum StreamingEndpointState: String {
    case idle
    case onsetPending
    case speechActive
    case endPending
}

enum StreamingEndpointFinalizeKind: String {
    case endpoint
    case stop
}

enum StreamingEndpointDecision {
    case none
    case startUtterance
    case continueUtterance
    case finalizeUtterance(kind: StreamingEndpointFinalizeKind)
}

struct StreamingEndpointConfiguration {
    let onsetSamples: Int
    let endEvidenceSamples: Int
    let endpointSilenceSamples: Int
    let resumeSamples: Int
    let ambiguousRescueSamples: Int
    let ambiguousDecayEnabled: Bool
    let ambiguousDecayGraceSamples: Int
    let ambiguousDecayRate: Double

    init(
        onsetSamples: Int = 1_120,
        endEvidenceSamples: Int = 1_600,
        endpointSilenceSamples: Int = 11_200,
        resumeSamples: Int = 1_920,
        ambiguousRescueSamples: Int = 5_120,
        ambiguousDecayEnabled: Bool = false,
        ambiguousDecayGraceSamples: Int = 12_800,
        ambiguousDecayRate: Double = 0.75
    ) {
        let normalizedOnsetSamples = max(160, onsetSamples)
        let normalizedEndEvidenceSamples = max(160, endEvidenceSamples)
        let normalizedEndpointSilenceSamples = max(160, endpointSilenceSamples)
        // Resume above endpoint silence is permitted but inert: evidence classes
        // are mutually exclusive, so endpoint silence wins before resume can accrue.
        let normalizedResumeSamples = max(160, resumeSamples)
        let normalizedAmbiguousRescueSamples = max(160, ambiguousRescueSamples)
        let normalizedAmbiguousDecayGraceSamples = max(
            min(max(ambiguousDecayGraceSamples, 1_600), 32_000),
            normalizedAmbiguousRescueSamples
        )
        let normalizedAmbiguousDecayRate = ambiguousDecayRate.isFinite
            ? min(max(ambiguousDecayRate, 0.0), 1.0)
            : 0.75

        self.onsetSamples = normalizedOnsetSamples
        self.endEvidenceSamples = min(
            normalizedEndEvidenceSamples,
            normalizedEndpointSilenceSamples
        )
        self.endpointSilenceSamples = normalizedEndpointSilenceSamples
        self.resumeSamples = normalizedResumeSamples
        self.ambiguousRescueSamples = normalizedAmbiguousRescueSamples
        self.ambiguousDecayEnabled = ambiguousDecayEnabled
        self.ambiguousDecayGraceSamples = normalizedAmbiguousDecayGraceSamples
        self.ambiguousDecayRate = normalizedAmbiguousDecayRate
    }
}

final class StreamingEndpoint {
    let configuration: StreamingEndpointConfiguration
    private(set) var state: StreamingEndpointState = .idle
    private(set) var utteranceDurationSamples = 0
    private(set) var accumulatedSilenceSamples = 0.0
    private(set) var resumeEvidenceSamples = 0
    private(set) var ambiguousRunSamples = 0.0
    private(set) var accumulatedAmbiguousCreditSamples = 0.0
    private(set) var lastFrameAmbiguousCreditSamples = 0.0
    private(set) var lastDecisionSilenceSamples: Double?
    private(set) var lastDecisionAmbiguousCreditSamples: Double?
    private(set) var lastDecisionAmbiguousRunSamples: Double?
    private(set) var lastDecisionAmbiguousFrameCreditSamples: Double?
    private(set) var onsetEvidenceSamples = 0

    init(configuration: StreamingEndpointConfiguration = StreamingEndpointConfiguration()) {
        self.configuration = configuration
    }

    func process(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        let samples = max(0, durationSamples)
        lastFrameAmbiguousCreditSamples = 0
        lastDecisionSilenceSamples = nil
        lastDecisionAmbiguousCreditSamples = nil
        lastDecisionAmbiguousRunSamples = nil
        lastDecisionAmbiguousFrameCreditSamples = nil
        if configuration.ambiguousDecayEnabled {
            return processWithAmbiguousDecay(evidence: evidence, durationSamples: samples)
        }
        switch state {
        case .idle:
            return processIdle(evidence: evidence, durationSamples: samples)
        case .onsetPending:
            return processOnset(evidence: evidence, durationSamples: samples)
        case .speechActive:
            return processActive(evidence: evidence, durationSamples: samples)
        case .endPending:
            return processEndPending(evidence: evidence, durationSamples: samples)
        }
    }

    func forceFinalize(kind: StreamingEndpointFinalizeKind) -> StreamingEndpointDecision {
        guard state != .idle else { return .none }
        guard state != .onsetPending else {
            reset()
            return .none
        }
        reset()
        return .finalizeUtterance(kind: kind)
    }

    func reset() {
        state = .idle
        utteranceDurationSamples = 0
        accumulatedSilenceSamples = 0
        resumeEvidenceSamples = 0
        ambiguousRunSamples = 0
        accumulatedAmbiguousCreditSamples = 0
        lastFrameAmbiguousCreditSamples = 0
        lastDecisionSilenceSamples = nil
        lastDecisionAmbiguousCreditSamples = nil
        lastDecisionAmbiguousRunSamples = nil
        lastDecisionAmbiguousFrameCreditSamples = nil
        onsetEvidenceSamples = 0
    }

    private func processIdle(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        guard evidence == .strong else { return .none }
        state = .onsetPending
        onsetEvidenceSamples = durationSamples
        if onsetEvidenceSamples >= configuration.onsetSamples {
            return beginUtterance()
        }
        return .none
    }

    private func processOnset(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        guard evidence == .strong else {
            reset()
            return .none
        }
        onsetEvidenceSamples += durationSamples
        if onsetEvidenceSamples < configuration.onsetSamples {
            return .none
        }
        return beginUtterance()
    }

    private func beginUtterance() -> StreamingEndpointDecision {
        state = .speechActive
        utteranceDurationSamples = onsetEvidenceSamples
        accumulatedSilenceSamples = 0
        resumeEvidenceSamples = 0
        ambiguousRunSamples = 0
        accumulatedAmbiguousCreditSamples = 0
        return .startUtterance
    }

    private func processActive(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        utteranceDurationSamples += durationSamples
        switch evidence {
        case .strong, .continuing:
            accumulatedSilenceSamples = 0
            return .continueUtterance
        case .ambiguous:
            // Match speech-like treatment in scripts/prediction-sim/lib/streaming-endpoint.mjs:183–187.
            accumulatedSilenceSamples = 0
            return .continueUtterance
        case .silence:
            accumulatedSilenceSamples += Double(durationSamples)
            guard accumulatedSilenceSamples >= Double(configuration.endEvidenceSamples) else {
                return .continueUtterance
            }
            state = .endPending
            return .continueUtterance
        }
    }

    private func processEndPending(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        utteranceDurationSamples += durationSamples
        switch evidence {
        case .ambiguous:
            ambiguousRunSamples += Double(durationSamples)
            guard ambiguousRunSamples >= Double(configuration.ambiguousRescueSamples) else {
                return .continueUtterance
            }
            state = .speechActive
            accumulatedSilenceSamples = 0
            resumeEvidenceSamples = 0
            ambiguousRunSamples = 0
            return .continueUtterance
        case .silence:
            ambiguousRunSamples = 0
            accumulatedSilenceSamples += Double(durationSamples)
            resumeEvidenceSamples = 0
            guard accumulatedSilenceSamples >= Double(configuration.endpointSilenceSamples) else {
                return .continueUtterance
            }
            return finalizeForEndpoint()
        case .strong, .continuing:
            // Resume evidence pauses the silence timer but cannot cancel the
            // pending end until the resume threshold is reached.
            ambiguousRunSamples = 0
            resumeEvidenceSamples += durationSamples
            guard resumeEvidenceSamples >= configuration.resumeSamples else {
                return .continueUtterance
            }
            state = .speechActive
            accumulatedSilenceSamples = 0
            resumeEvidenceSamples = 0
            return .continueUtterance
        }
    }

    private func processWithAmbiguousDecay(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        switch state {
        case .idle:
            return processIdle(evidence: evidence, durationSamples: durationSamples)
        case .onsetPending:
            return processOnset(evidence: evidence, durationSamples: durationSamples)
        case .speechActive, .endPending:
            utteranceDurationSamples += durationSamples
        }

        switch evidence {
        case .strong, .continuing:
            ambiguousRunSamples = 0
            if state == .speechActive {
                accumulatedSilenceSamples = 0
                accumulatedAmbiguousCreditSamples = 0
                resumeEvidenceSamples = 0
                return .continueUtterance
            }

            resumeEvidenceSamples += durationSamples
            guard resumeEvidenceSamples >= configuration.resumeSamples else {
                return .continueUtterance
            }
            state = .speechActive
            accumulatedSilenceSamples = 0
            accumulatedAmbiguousCreditSamples = 0
            resumeEvidenceSamples = 0
            return .continueUtterance

        case .ambiguous:
            let runBeforeFrame = ambiguousRunSamples
            ambiguousRunSamples += Double(durationSamples)
            // Compute this frame's beyond-grace slice once, before any state hop.
            let beyondGraceSamples = max(
                0.0,
                ambiguousRunSamples - max(
                    runBeforeFrame,
                    Double(configuration.ambiguousDecayGraceSamples)
                )
            )
            let creditSamples = beyondGraceSamples * configuration.ambiguousDecayRate
            lastFrameAmbiguousCreditSamples = creditSamples
            accumulatedSilenceSamples += creditSamples
            accumulatedAmbiguousCreditSamples += creditSamples

            guard accumulatedSilenceSamples < Double(configuration.endpointSilenceSamples) else {
                return finalizeForEndpoint()
            }
            if state == .speechActive,
               accumulatedSilenceSamples >= Double(configuration.endEvidenceSamples) {
                state = .endPending
            }
            if state == .endPending,
               ambiguousRunSamples >= Double(configuration.ambiguousRescueSamples) {
                // Rescue returns to active without discarding either endpoint counter.
                state = .speechActive
                resumeEvidenceSamples = 0
            }
            return .continueUtterance

        case .silence:
            accumulatedSilenceSamples += Double(durationSamples)
            if state == .endPending {
                resumeEvidenceSamples = 0
            }
            guard accumulatedSilenceSamples < Double(configuration.endpointSilenceSamples) else {
                return finalizeForEndpoint()
            }
            if state == .speechActive,
               accumulatedSilenceSamples >= Double(configuration.endEvidenceSamples) {
                state = .endPending
            }
            return .continueUtterance
        }
    }

    private func finalizeForEndpoint() -> StreamingEndpointDecision {
        let decisionSilenceSamples = accumulatedSilenceSamples
        let decisionAmbiguousCreditSamples = accumulatedAmbiguousCreditSamples
        let decisionAmbiguousRunSamples = ambiguousRunSamples
        let decisionAmbiguousFrameCreditSamples = lastFrameAmbiguousCreditSamples
        reset()
        lastDecisionSilenceSamples = decisionSilenceSamples
        lastDecisionAmbiguousCreditSamples = decisionAmbiguousCreditSamples
        lastDecisionAmbiguousRunSamples = decisionAmbiguousRunSamples
        lastDecisionAmbiguousFrameCreditSamples = decisionAmbiguousFrameCreditSamples
        return .finalizeUtterance(kind: .endpoint)
    }
}
