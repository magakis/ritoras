export const DEFAULT_ENERGY_RECALL_ENABLED = true;
export const DEFAULT_ENERGY_ONSET_ELEVATION_DB = 30;
export const DEFAULT_ENERGY_ONSET_SUSTAIN_MS = 1_000;
export const DEFAULT_ENERGY_CONTINUATION_ELEVATION_DB = 10;
export const DEFAULT_ENERGY_COOLDOWN_MS = 2_000;

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
    this.cooldownDeadlineMilliseconds = null;
  }

  process(frameDb, floorDb, frameDurationMs) {
    const elapsedFrameMilliseconds = Number.isFinite(frameDurationMs)
      ? Math.max(0, frameDurationMs)
      : 0;
    this.elapsedMilliseconds += elapsedFrameMilliseconds;

    if (!this.configuration.enabled) return noEvidence();
    if (!Number.isFinite(frameDb) || !Number.isFinite(floorDb)) {
      this.consecutiveOnsetMilliseconds = 0;
      return noEvidence();
    }

    if (this.energyOriginatedUtteranceIsActive) {
      if (this.awaitingEndpointOnsetAcceptance) {
        return { suppliesStrong: true, suppliesContinuing: false };
      }
      this.consecutiveOnsetMilliseconds = 0;
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
    this.consecutiveOnsetMilliseconds = 0;
    return { suppliesStrong: true, suppliesContinuing: false };
  }

  noteEnergyOriginatedOnsetAccepted() {
    if (!this.configuration.enabled) return;
    this.awaitingEndpointOnsetAcceptance = false;
  }

  noteEnergyOriginatedEmission() {
    if (!this.configuration.enabled) return;
    this.cooldownDeadlineMilliseconds = this.elapsedMilliseconds + this.configuration.cooldownMs;
  }

  noteUtteranceEnded() {
    this.energyOriginatedUtteranceIsActive = false;
    this.awaitingEndpointOnsetAcceptance = false;
    this.consecutiveOnsetMilliseconds = 0;
  }
}

function noEvidence() {
  return { suppliesStrong: false, suppliesContinuing: false };
}
