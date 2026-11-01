import Foundation

/// Configuration for the energy-based second opinion that supplements Silero.
struct EnergyEvidenceConfiguration {
    let enabled: Bool
    let onsetElevationDb: Double
    let onsetSustainMs: Int
    let continuationElevationDb: Double
    let cooldownMs: Int

    init(
        enabled: Bool = SharedConfig.Defaults.energyRecallEnabledDefault,
        onsetElevationDb: Double = SharedConfig.Defaults.energyOnsetElevationDbDefault,
        onsetSustainMs: Int = SharedConfig.Defaults.energyOnsetSustainMsDefault,
        continuationElevationDb: Double = SharedConfig.Defaults.energyContinuationElevationDbDefault,
        cooldownMs: Int = SharedConfig.Defaults.energyCooldownMsDefault
    ) {
        let finiteOnsetElevationDb = onsetElevationDb.isFinite
            ? onsetElevationDb
            : SharedConfig.Defaults.energyOnsetElevationDbDefault
        let finiteContinuationElevationDb = continuationElevationDb.isFinite
            ? continuationElevationDb
            : SharedConfig.Defaults.energyContinuationElevationDbDefault
        self.enabled = enabled
        self.onsetElevationDb = min(max(finiteOnsetElevationDb, 10.0), 60.0)
        self.onsetSustainMs = min(max(onsetSustainMs, 100), 5_000)
        self.continuationElevationDb = min(max(finiteContinuationElevationDb, 0.0), 30.0)
        self.cooldownMs = min(max(cooldownMs, 0), 10_000)
    }
}

/// Energy evidence returned for one analyzed frame.
struct EnergyEvidenceOpinion {
    /// True when an onset qualifies, and while recorder mode awaits endpoint acceptance.
    let suppliesStrong: Bool
    /// True on qualifying frames while an energy-originated utterance is active.
    let suppliesContinuing: Bool
}

/// Produces floor-relative energy evidence without estimating or changing the floor.
/// A qualifying sustained onset returns strong evidence. Recorder use can hold that
/// opinion until the endpoint accepts onset; accepted energy-originated utterances
/// then use the continuation margin until `noteUtteranceEnded()` is called.
final class EnergyEvidenceProcessor {
    let configuration: EnergyEvidenceConfiguration
    private let requiresEndpointOnsetAcceptance: Bool

    private var elapsedMilliseconds = 0.0
    private var consecutiveOnsetMilliseconds = 0.0
    private var energyOriginatedUtteranceIsActive = false
    private var awaitingEndpointOnsetAcceptance = false
    private var cooldownDeadlineMilliseconds: Double?

    /// Creates a processor with bounded defaults or the supplied session configuration.
    /// Pass `SharedConfig.energyRecallConfiguration()` to apply App Group overrides.
    init(
        configuration: EnergyEvidenceConfiguration = EnergyEvidenceConfiguration(),
        requiresEndpointOnsetAcceptance: Bool = false
    ) {
        self.configuration = configuration
        self.requiresEndpointOnsetAcceptance = requiresEndpointOnsetAcceptance
    }

    /// Processes one frame; its duration advances both sustain and cooldown time.
    /// A frame below the onset margin resets consecutive sustain. Its duration is
    /// accrued before its level is evaluated, so cooldown opens at the deadline frame.
    func process(
        frameDb: Double,
        floorDb: Double,
        frameDurationMs: Double
    ) -> EnergyEvidenceOpinion {
        let elapsedFrameMilliseconds = frameDurationMs.isFinite
            ? max(0, frameDurationMs)
            : 0
        elapsedMilliseconds += elapsedFrameMilliseconds

        guard configuration.enabled else {
            return EnergyEvidenceOpinion(suppliesStrong: false, suppliesContinuing: false)
        }
        guard frameDb.isFinite, floorDb.isFinite else {
            consecutiveOnsetMilliseconds = 0
            return EnergyEvidenceOpinion(suppliesStrong: false, suppliesContinuing: false)
        }

        if energyOriginatedUtteranceIsActive {
            if awaitingEndpointOnsetAcceptance {
                return EnergyEvidenceOpinion(suppliesStrong: true, suppliesContinuing: false)
            }
            consecutiveOnsetMilliseconds = 0
            return EnergyEvidenceOpinion(
                suppliesStrong: false,
                suppliesContinuing: frameDb >= floorDb + configuration.continuationElevationDb
            )
        }

        if frameDb >= floorDb + configuration.onsetElevationDb {
            consecutiveOnsetMilliseconds = min(
                Double(configuration.onsetSustainMs),
                consecutiveOnsetMilliseconds + elapsedFrameMilliseconds
            )
        } else {
            consecutiveOnsetMilliseconds = 0
        }

        let cooldownHasElapsed = cooldownDeadlineMilliseconds.map {
            elapsedMilliseconds >= $0
        } ?? true
        guard consecutiveOnsetMilliseconds >= Double(configuration.onsetSustainMs),
              cooldownHasElapsed else {
            return EnergyEvidenceOpinion(suppliesStrong: false, suppliesContinuing: false)
        }

        energyOriginatedUtteranceIsActive = true
        awaitingEndpointOnsetAcceptance = requiresEndpointOnsetAcceptance
        consecutiveOnsetMilliseconds = 0
        return EnergyEvidenceOpinion(suppliesStrong: true, suppliesContinuing: false)
    }

    /// Transitions a held strong opinion to continuation after the endpoint starts.
    func noteEnergyOriginatedOnsetAccepted() {
        guard configuration.enabled else { return }
        awaitingEndpointOnsetAcceptance = false
    }

    /// Starts or restarts cooldown after a chunk emitted from energy-originated evidence.
    /// This does not end continuation eligibility; call `noteUtteranceEnded()` separately.
    func noteEnergyOriginatedEmission() {
        guard configuration.enabled else { return }
        cooldownDeadlineMilliseconds = elapsedMilliseconds + Double(configuration.cooldownMs)
    }

    /// Ends continuation eligibility and clears any partial onset run; cooldown remains.
    func noteUtteranceEnded() {
        energyOriginatedUtteranceIsActive = false
        awaitingEndpointOnsetAcceptance = false
        consecutiveOnsetMilliseconds = 0
    }
}
