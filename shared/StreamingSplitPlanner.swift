import Foundation

enum StreamingSplitReason: String {
    case pause
    case cap
}

struct StreamingSplitPoint {
    let offsetSamples: Int
    let reason: StreamingSplitReason
}

/// Sample-count-only forced-split planning. Audio storage remains owned by the
/// recorder; this type only remembers the latest usable confirmed silence run.
final class StreamingSplitPlanner {
    let maxUtteranceSamples: Int
    let usablePauseSamples: Int
    let minimumUtteranceSamples: Int
    let overlapSamples: Int

    private(set) var totalSamples = 0
    private var silenceRunSamples = 0
    private(set) var latestUsablePauseEndSamples: Int?

    init(
        maxUtteranceSamples: Int,
        usablePauseSamples: Int = 4_800,
        minimumUtteranceSamples: Int = 16_000,
        overlapSamples: Int = 0
    ) {
        self.maxUtteranceSamples = max(0, maxUtteranceSamples)
        self.usablePauseSamples = max(0, usablePauseSamples)
        self.minimumUtteranceSamples = max(0, minimumUtteranceSamples)
        self.overlapSamples = max(0, overlapSamples)
    }

    func begin(initialSamples: Int) {
        totalSamples = max(0, initialSamples)
        silenceRunSamples = 0
        latestUsablePauseEndSamples = nil
    }

    func append(evidence: StreamingEndpointEvidence, durationSamples: Int) {
        let samples = max(0, durationSamples)
        guard samples > 0 else { return }

        if evidence == .silence {
            silenceRunSamples += samples
        } else {
            silenceRunSamples = 0
        }

        let nextTotal = totalSamples + samples
        if evidence == .silence,
           silenceRunSamples >= usablePauseSamples,
           nextTotal >= minimumUtteranceSamples {
            latestUsablePauseEndSamples = nextTotal
        }
        totalSamples = nextTotal
    }

    func splitPoint() -> StreamingSplitPoint? {
        guard totalSamples >= maxUtteranceSamples, maxUtteranceSamples > 0 else {
            return nil
        }
        if let pauseEnd = latestUsablePauseEndSamples {
            let offset = max(1, pauseEnd - overlapSamples)
            return StreamingSplitPoint(
                offsetSamples: min(offset, maxUtteranceSamples),
                reason: .pause
            )
        }
        return StreamingSplitPoint(offsetSamples: maxUtteranceSamples, reason: .cap)
    }

    func reset() {
        totalSamples = 0
        silenceRunSamples = 0
        latestUsablePauseEndSamples = nil
    }
}
