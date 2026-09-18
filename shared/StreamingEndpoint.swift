import Foundation

// Pure-logic endpoint decisions. Audio storage and pre-roll buffering remain
// owned by StreamingAudioRecorder.

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
    case startUtterance(withPreRollSamples: Int)
    case continueUtterance
    case finalizeUtterance(kind: StreamingEndpointFinalizeKind)
}

struct StreamingEndpointConfiguration {
    let onsetSamples: Int
    let endEvidenceSamples: Int
    let endpointSilenceSamples: Int
    let resumeSamples: Int
    let ambiguousRescueSamples: Int
    let preRollSamples: Int

    init(
        onsetSamples: Int = 1_120,
        endEvidenceSamples: Int = 1_600,
        endpointSilenceSamples: Int = 11_200,
        resumeSamples: Int = 1_920,
        ambiguousRescueSamples: Int = 5_120,
        preRollSamples: Int = 4_000
    ) {
        self.onsetSamples = onsetSamples
        self.endEvidenceSamples = endEvidenceSamples
        self.endpointSilenceSamples = endpointSilenceSamples
        self.resumeSamples = resumeSamples
        self.ambiguousRescueSamples = ambiguousRescueSamples
        self.preRollSamples = preRollSamples
    }
}

final class StreamingEndpoint {
    let configuration: StreamingEndpointConfiguration
    private(set) var state: StreamingEndpointState = .idle
    private(set) var utteranceDurationSamples = 0
    private(set) var accumulatedSilenceSamples = 0
    private(set) var resumeEvidenceSamples = 0
    private(set) var ambiguousEvidenceSamples = 0
    private(set) var onsetEvidenceSamples = 0

    init(configuration: StreamingEndpointConfiguration = StreamingEndpointConfiguration()) {
        self.configuration = configuration
    }

    func process(
        evidence: StreamingEndpointEvidence,
        durationSamples: Int
    ) -> StreamingEndpointDecision {
        let samples = max(0, durationSamples)
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
        ambiguousEvidenceSamples = 0
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
        utteranceDurationSamples = configuration.preRollSamples + onsetEvidenceSamples
        accumulatedSilenceSamples = 0
        resumeEvidenceSamples = 0
        ambiguousEvidenceSamples = 0
        return .startUtterance(withPreRollSamples: configuration.preRollSamples)
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
            return .continueUtterance
        case .silence:
            accumulatedSilenceSamples += durationSamples
            guard accumulatedSilenceSamples >= configuration.endEvidenceSamples else {
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
            ambiguousEvidenceSamples += durationSamples
            guard ambiguousEvidenceSamples >= configuration.ambiguousRescueSamples else {
                return .continueUtterance
            }
            state = .speechActive
            accumulatedSilenceSamples = 0
            resumeEvidenceSamples = 0
            ambiguousEvidenceSamples = 0
            return .continueUtterance
        case .silence:
            ambiguousEvidenceSamples = 0
            accumulatedSilenceSamples += durationSamples
            resumeEvidenceSamples = 0
            guard accumulatedSilenceSamples >= configuration.endpointSilenceSamples else {
                return .continueUtterance
            }
            reset()
            return .finalizeUtterance(kind: .endpoint)
        case .strong, .continuing:
            // Resume evidence pauses the silence timer but cannot cancel the
            // pending end until the resume threshold is reached.
            ambiguousEvidenceSamples = 0
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
}
