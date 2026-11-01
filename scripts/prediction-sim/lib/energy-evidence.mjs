export const DEFAULT_ENERGY_RECALL_ENABLED = true;
export const DEFAULT_ENERGY_ONSET_ELEVATION_DB = 30;
export const DEFAULT_ENERGY_ONSET_SUSTAIN_MS = 1_000;
export const DEFAULT_ENERGY_CONTINUATION_ELEVATION_DB = 10;
export const DEFAULT_ENERGY_COOLDOWN_MS = 2_000;
export const DEFAULT_ENERGY_MAX_CONTINUATION_SEC = 12;

function clampFinite(value, fallback, minimum, maximum) {
  const finiteValue = Number.isFinite(value) ? value : fallback;
  return Math.min(maximum, Math.max(minimum, finiteValue));
}

function clampInteger(value, fallback, minimum, maximum) {
  const finiteValue = Number.isFinite(value) ? value : fallback;
  return Math.trunc(Math.min(maximum, Math.max(minimum, finiteValue)));
}

export function normalizeEnergyEvidenceConfig({
  energyRecallEnabled = DEFAULT_ENERGY_RECALL_ENABLED,
  energyOnsetElevationDb = DEFAULT_ENERGY_ONSET_ELEVATION_DB,
  energyOnsetSustainMs = DEFAULT_ENERGY_ONSET_SUSTAIN_MS,
  energyContinuationElevationDb = DEFAULT_ENERGY_CONTINUATION_ELEVATION_DB,
  energyCooldownMs = DEFAULT_ENERGY_COOLDOWN_MS,
  energyMaxContinuationSec = DEFAULT_ENERGY_MAX_CONTINUATION_SEC,
} = {}) {
  return {
    enabled: typeof energyRecallEnabled === 'boolean'
      ? energyRecallEnabled
      : DEFAULT_ENERGY_RECALL_ENABLED,
    onsetElevationDb: clampFinite(
      energyOnsetElevationDb,
      DEFAULT_ENERGY_ONSET_ELEVATION_DB,
      10,
      60,
    ),
    onsetSustainMs: clampInteger(energyOnsetSustainMs, DEFAULT_ENERGY_ONSET_SUSTAIN_MS, 100, 5_000),
    continuationElevationDb: clampFinite(
      energyContinuationElevationDb,
      DEFAULT_ENERGY_CONTINUATION_ELEVATION_DB,
      0,
      30,
    ),
    cooldownMs: clampInteger(energyCooldownMs, DEFAULT_ENERGY_COOLDOWN_MS, 0, 10_000),
    maxUncorroboratedContinuationSec: clampFinite(
      energyMaxContinuationSec,
      DEFAULT_ENERGY_MAX_CONTINUATION_SEC,
      5,
      60,
    ),
  };
}

/** Mirrors shared/EnergyEvidence.swift; processor state is per recording. */
export class EnergyEvidenceProcessor {
  constructor(configuration = {}, { requiresEndpointOnsetAcceptance = false } = {}) {
    this.configuration = normalizeEnergyEvidenceConfig(configuration);
    this.requiresEndpointOnsetAcceptance = Boolean(requiresEndpointOnsetAcceptance);
    this.elapsedMilliseconds = 0;
    this.consecutiveOnsetMilliseconds = 0;
    this.energyOriginatedUtteranceIsActive = false;
    this.awaitingEndpointOnsetAcceptance = false;
    // Starts only after endpoint acceptance; onset sustain and pending dwell are excluded.
    this.uncorroboratedContinuationTimerIsActive = false;
    this.uncorroboratedContinuationMilliseconds = 0;
    this.forceFinalizeRequested = false;
    this.cooldownDeadlineMilliseconds = null;
  }

  process(frameDb, floorDb, frameDurationMs, sileroCorroborated = false) {
    const elapsedFrameMilliseconds = Number.isFinite(frameDurationMs)
      ? Math.max(0, frameDurationMs)
      : 0;
    this.elapsedMilliseconds += elapsedFrameMilliseconds;
    this.forceFinalizeRequested = false;

    if (!this.configuration.enabled) return noEvidence();
    if (!Number.isFinite(frameDb) || !Number.isFinite(floorDb)) {
      this.consecutiveOnsetMilliseconds = 0;
      return noEvidence();
    }

    if (this.energyOriginatedUtteranceIsActive) {
      if (this.awaitingEndpointOnsetAcceptance) {
        // Energy has met its dwell; keep strong through the endpoint's own onset window.
        return { suppliesStrong: true, suppliesContinuing: false };
      }
      this.consecutiveOnsetMilliseconds = 0;
      if (this.uncorroboratedContinuationTimerIsActive) {
        if (sileroCorroborated) {
          this.uncorroboratedContinuationMilliseconds = 0;
        } else {
          this.uncorroboratedContinuationMilliseconds += elapsedFrameMilliseconds;
        }
        this.forceFinalizeRequested = this.uncorroboratedContinuationMilliseconds
          >= this.configuration.maxUncorroboratedContinuationSec * 1000;
      }
      return {
        suppliesStrong: false,
        suppliesContinuing: frameDb >= floorDb + this.configuration.continuationElevationDb,
      };
    }

    if (frameDb >= floorDb + this.configuration.onsetElevationDb) {
      this.consecutiveOnsetMilliseconds = Math.min(
        this.configuration.onsetSustainMs,
        this.consecutiveOnsetMilliseconds + elapsedFrameMilliseconds,
      );
    } else {
      this.consecutiveOnsetMilliseconds = 0;
    }

    const cooldownHasElapsed = this.cooldownDeadlineMilliseconds === null
      || this.elapsedMilliseconds >= this.cooldownDeadlineMilliseconds;
    if (this.consecutiveOnsetMilliseconds < this.configuration.onsetSustainMs || !cooldownHasElapsed) {
      return noEvidence();
    }

    this.energyOriginatedUtteranceIsActive = true;
    this.awaitingEndpointOnsetAcceptance = this.requiresEndpointOnsetAcceptance;
    this.uncorroboratedContinuationTimerIsActive = !this.requiresEndpointOnsetAcceptance;
    this.uncorroboratedContinuationMilliseconds = 0;
    this.consecutiveOnsetMilliseconds = 0;
    return { suppliesStrong: true, suppliesContinuing: false };
  }

  noteEnergyOriginatedOnsetAccepted() {
    if (!this.configuration.enabled) return;
    this.awaitingEndpointOnsetAcceptance = false;
    this.uncorroboratedContinuationTimerIsActive = true;
    this.uncorroboratedContinuationMilliseconds = 0;
  }

  takeForceFinalizeRequest() {
    const requested = this.forceFinalizeRequested;
    this.forceFinalizeRequested = false;
    return requested;
  }

  noteEnergyOriginatedEmission() {
    if (!this.configuration.enabled) return;
    this.cooldownDeadlineMilliseconds = this.elapsedMilliseconds + this.configuration.cooldownMs;
  }

  noteUtteranceEnded() {
    this.energyOriginatedUtteranceIsActive = false;
    this.awaitingEndpointOnsetAcceptance = false;
    this.uncorroboratedContinuationTimerIsActive = false;
    this.uncorroboratedContinuationMilliseconds = 0;
    this.forceFinalizeRequested = false;
    this.consecutiveOnsetMilliseconds = 0;
  }
}

function noEvidence() {
  return { suppliesStrong: false, suppliesContinuing: false };
}
