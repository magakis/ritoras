// Pure-logic JS mirror of VADMode, VADGateConfig, VADGateOutput, and
// VADThresholdGate in shared/VADGate.swift, plus AudioMath in
// shared/AudioMath.swift. Kept in sync per AGENTS.md → Test policy.

const VAD_CONTINUATION_DELTA_DB = 6.0;
export const VAD_STATIC_CONTINUATION_OFFSET_DB = 4.0;
export const VAD_STATIC_SILENCE_OFFSET_DB = 6.0;
export const VAD_ELEVATED_RISE_DB_PER_SECOND = 12.0;
export const VAD_SPEECH_CEILING_MARGIN_DB = 2.0;
// Keep the end-floor correction bounded until the residual post-finalize bump decays.
const VAD_UTTERANCE_END_FLOOR_RESEED_MAX_DROP_DB = 4.0;
const VAD_UTTERANCE_END_FLOOR_RISE_HOLD_S = 1.2;
export const VAD_ADAPTIVE_MIN_REFINEMENT_DURATION_S = 1.0;
export const VAD_ADAPTIVE_COLD_START_GRACE_S = 0.4;
export const VAD_ADAPTIVE_PRIMING_MAX_S = 0.45;
export const VAD_ADAPTIVE_PRIMING_QUIET_S = 0.10;
export const VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S = 0.4;
const VAD_SPEECH_SHAPE_WINDOW_S = 0.1;
export const VAD_ADAPTIVE_ROLLING_WINDOW_DURATION_S = 3.0;
export const VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY = 256;
export const VAD_FLOOR_MIN_DB = -80;
export const VAD_FLOOR_MAX_DB = -20;
export const VAD_ADAPTIVE_ROLLING_PERCENTILE = 0.1;
export const VAD_ADAPTIVE_FLOOR_MOVEMENT_EPSILON_DB = 1e-6;
export const VAD_ABSOLUTE_SPEECH_FLOOR_DB = -50;
export const VAD_LOUD_FLOOR_REGIME_DB = -35;
export const VAD_ADAPTIVE_RISE_MULTIPLIER_MIN = 0.5;
export const VAD_ADAPTIVE_RISE_MULTIPLIER_MAX = 4.0;
export const VAD_ADAPTIVE_STRONG_DELTA_DB_MIN = 3.0;
export const VAD_ADAPTIVE_STRONG_DELTA_DB_MAX = 24.0;
export const VAD_ADAPTIVE_CONTINUATION_DELTA_DB_MIN = 2.0;
export const VAD_ADAPTIVE_SILENCE_DELTA_DB_MIN = 1.0;
export const VAD_ADAPTIVE_SILENCE_DELTA_DB_MAX = 5.0;
export const VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MIN = 0.5;
export const VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MAX = 10.0;
export const VAD_ADAPTIVE_FALL_TAU_SECONDS_MIN = 0.2;
export const VAD_ADAPTIVE_FALL_TAU_SECONDS_MAX = 2.0;
export const VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MIN = 6.0;
export const VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MAX = 24.0;
export const VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB = 6.0;
export const VAD_ADAPTIVE_FLAT_SPREAD_DB_MIN = 3.0;
export const VAD_ADAPTIVE_FLAT_SPREAD_DB_MAX = 8.0;
export const VAD_ADAPTIVE_IMPLAUSIBLE_SPEECH_S = 8.0;
const TIME_BOUNDARY_EPSILON_S = 1e-9;

function clamp(value, lower, upper) {
  return Math.min(Math.max(value, lower), upper);
}

// Gradual spread is speech-shaped; abrupt spread remains eligible as a gust.
export function isSpeechShaped({
  dynamicsSpreadDb,
  shortSpreadDb,
  flatSpreadDb,
  adjacentStepDb = 0,
  allowWindBoundaryStep = false,
}) {
  // Quiet frames keep the strict wind boundary; other evidence accepts exactly 6 dB.
  const stepIsWithinSpeechBoundary = allowWindBoundaryStep
    ? adjacentStepDb <= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
    : adjacentStepDb < VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB;
  return Number.isFinite(dynamicsSpreadDb)
    && Number.isFinite(shortSpreadDb)
    && Number.isFinite(adjacentStepDb)
    && stepIsWithinSpeechBoundary
    && (dynamicsSpreadDb >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
      || shortSpreadDb >= flatSpreadDb);
}

export function dbFromRms(rms) {
  const result = 20 * Math.log10(Math.max(rms, 1e-10));
  return Math.max(result, -100);
}

export function rmsFromDb(db) {
  return 10 ** (db / 20);
}

export function makeVadGateConfig(partial = {}) {
  return {
    mode: 'static',
    staticRms: 0.025,
    adaptiveDeltaDb: 7.0,
    adaptiveContinuationDeltaDb: 4.0,
    adaptiveAbsoluteSpeechFloorDb: VAD_ABSOLUTE_SPEECH_FLOOR_DB,
    adaptiveRiseSpeedMultiplier: 1.0,
    adaptiveSilenceDeltaDb: 3.0,
    adaptiveStaleFloorSeconds: 1.5,
    adaptiveFallTauSeconds: 0.5,
    adaptiveDynamicsEnabled: true,
    adaptiveDynamicsSpreadDb: 9.0,
    adaptiveFlatSpreadDb: 5.0,
    loudRegimeEnabled: true,
    loudRegimeEnterDb: -35,
    loudRegimeExitDb: -38,
    loudRegimeEnterMs: 300,
    loudRegimeExitMs: 1000,
    loudStrongDeltaDb: 7,
    loudContinuationDeltaDb: 3,
    loudSilenceDeltaDb: 2,
    loudDynamicsSpreadDb: 9,
    loudRiseDbPerSec: 12,
    primingMaximumSeconds: VAD_ADAPTIVE_PRIMING_MAX_S,
    primingQuietSeedSeconds: VAD_ADAPTIVE_PRIMING_QUIET_S,
    quietContinuationRiseCapDbPerSec: 12,
    ...(partial ?? {}),
  };
}

export class VADThresholdGate {
  constructor(config) {
    this.config = makeVadGateConfig(config);
    this.effectiveAdaptiveDeltaDb = clamp(
      this.config.adaptiveDeltaDb,
      VAD_ADAPTIVE_STRONG_DELTA_DB_MIN,
      VAD_ADAPTIVE_STRONG_DELTA_DB_MAX,
    );
    this.effectiveAdaptiveContinuationDeltaDb = clamp(
      this.config.adaptiveContinuationDeltaDb,
      VAD_ADAPTIVE_CONTINUATION_DELTA_DB_MIN,
      this.effectiveAdaptiveDeltaDb - 1,
    );
    this.effectiveAbsoluteSpeechFloorDb = clamp(
      this.config.adaptiveAbsoluteSpeechFloorDb,
      VAD_FLOOR_MIN_DB,
      -30,
    );
    this.effectiveSilenceDeltaDb = clamp(
      this.config.adaptiveSilenceDeltaDb,
      VAD_ADAPTIVE_SILENCE_DELTA_DB_MIN,
      Math.min(5, this.effectiveAdaptiveContinuationDeltaDb - 1),
    );
    this.effectiveRiseSpeedMultiplier = clamp(
      this.config.adaptiveRiseSpeedMultiplier,
      VAD_ADAPTIVE_RISE_MULTIPLIER_MIN,
      VAD_ADAPTIVE_RISE_MULTIPLIER_MAX,
    );
    this.effectiveStaleFloorSeconds = clamp(
      this.config.adaptiveStaleFloorSeconds,
      VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MIN,
      VAD_ADAPTIVE_STALE_FLOOR_SECONDS_MAX,
    ) / this.effectiveRiseSpeedMultiplier;
    this.effectiveFallTauSeconds = clamp(
      this.config.adaptiveFallTauSeconds,
      VAD_ADAPTIVE_FALL_TAU_SECONDS_MIN,
      VAD_ADAPTIVE_FALL_TAU_SECONDS_MAX,
    );
    this.effectiveDynamicsSpreadDb = clamp(
      this.config.adaptiveDynamicsSpreadDb,
      VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MIN,
      VAD_ADAPTIVE_DYNAMICS_SPREAD_DB_MAX,
    );
    this.effectiveFlatSpreadDb = clamp(
      this.config.adaptiveFlatSpreadDb,
      VAD_ADAPTIVE_FLAT_SPREAD_DB_MIN,
      VAD_ADAPTIVE_FLAT_SPREAD_DB_MAX,
    );
    this.behaviorMode = this.config.mode;
    this.adaptiveRefinementElapsed = 0;
    this.adaptivePrimingElapsed = 0;
    this.adaptivePrimingQuietElapsed = 0;
    this.adaptivePrimed = this.config.mode !== 'adaptive';
    this.adaptiveRefinementComplete = this.config.mode !== 'adaptive';
    this.coldStartSpeechShapedNow = false;
    this.coldStartConverged = false;
    this.floorDb = this.config.mode === 'adaptive' ? VAD_FLOOR_MIN_DB : null;
    this.thresholdDb = this.config.mode === 'adaptive'
      ? Math.max(
        VAD_FLOOR_MIN_DB + this.effectiveAdaptiveDeltaDb,
        this.effectiveAbsoluteSpeechFloorDb,
      )
      : dbFromRms(this.config.staticRms);
    this.pendingReanchorEvent = false;
    this.hasLoggedReanchorRefusal = false;
    this.hasRefusedReanchorSinceLastAcceptance = false;
    this.elapsedSinceSilenceEvidence = 0;
    this.speechCeilingDb = null;
    this.adaptiveRollingDbs = Array(VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY).fill(0);
    this.adaptiveRollingDurations = Array(VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY).fill(0);
    this.adaptiveRollingWriteIndex = 0;
    this.adaptiveRollingCount = 0;
    this.adaptiveRollingElapsed = 0;
    this.adaptiveRollingPercentileCache = null;
    this.floorRiseSuppressionRemainingSeconds = 0;
    this.lastKnownMachineIsIdle = true;
    this.isLoudRegime = false;
    this.loudEnterElapsed = 0;
    this.loudExitElapsed = 0;
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
      speechShaped: false,
      thresholdDb: this.thresholdDb,
      continuationThresholdDb: this.config.mode === 'adaptive'
        ? Math.max(
          VAD_FLOOR_MIN_DB + this.effectiveAdaptiveContinuationDeltaDb,
          this.effectiveAbsoluteSpeechFloorDb,
        )
        : this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: this.config.mode === 'adaptive'
        ? VAD_FLOOR_MIN_DB + this.effectiveSilenceDeltaDb
        : this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      floorDb: this.floorDb,
      floorConverged: false,
      dynamicsSpreadDb: null,
      shortSpreadDb: null,
      isLoudRegime: false,
      didReanchor: false,
      didCompletePriming: false,
      primingDurationSeconds: 0,
      primingEndedAtCap: false,
    };
  }

  process(frameDb, frameDuration) {
    switch (this.behaviorMode) {
      case 'static':
        return this.processStatic(frameDb, frameDuration);
      case 'adaptive':
        return this.processAdaptive(frameDb, frameDuration);
      default:
        return this.processStatic(frameDb, frameDuration);
    }
  }

  get snapshot() {
    return { ...this.lastOutput };
  }

  get secondsSinceSilenceEvidence() {
    return this.elapsedSinceSilenceEvidence;
  }

  takePendingReanchorEvent() {
    const event = this.pendingReanchorEvent;
    this.pendingReanchorEvent = false;
    return event;
  }

  noteUtteranceEnded(quietestStrongDb, trailingSilenceDb = null) {
    if (this.behaviorMode !== 'adaptive') return;
    if (this.floorDb !== null
      && quietestStrongDb !== null
      && quietestStrongDb !== undefined
      && quietestStrongDb >= this.floorDb
        + this.effectiveAdaptiveDeltaDb
        + VAD_SPEECH_CEILING_MARGIN_DB) {
      this.speechCeilingDb = quietestStrongDb;
    }
    if (this.floorDb !== null && Number.isFinite(trailingSilenceDb)) {
      if (this.speechCeilingDb === null) {
        const lowestAllowedFloor = Math.max(
          VAD_FLOOR_MIN_DB,
          this.floorDb - VAD_UTTERANCE_END_FLOOR_RESEED_MAX_DROP_DB,
        );
        const reseededFloor = Math.min(
          this.floorDb,
          Math.max(lowestAllowedFloor, this.clampFloor(trailingSilenceDb)),
        );
        if (reseededFloor < this.floorDb) {
          this.floorDb = reseededFloor;
          this.floorRiseSuppressionRemainingSeconds = VAD_UTTERANCE_END_FLOOR_RISE_HOLD_S;
        } else {
          this.floorRiseSuppressionRemainingSeconds = 0;
        }
      } else {
        // Preserve headroom: a deeper floor could promote ambient evidence to strong.
        this.floorRiseSuppressionRemainingSeconds = 0;
      }
    } else {
      this.floorRiseSuppressionRemainingSeconds = 0;
    }
    this.resetAdaptiveRollingWindow();
  }

  processStatic(frameDb, frameDuration) {
    this.appendAdaptiveRollingFrame(frameDb, frameDuration);
    const levels = this.classify(
      frameDb,
      this.thresholdDb,
      this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
    );
    return this.emit({
      ...levels,
      isSpeech: levels.evidence === 'strong',
      speechShaped: levels.speechShaped,
      thresholdDb: levels.strongThresholdDb,
      floorDb: null,
    });
  }

  processAdaptive(frameDb, frameDuration) {
    let didReanchor = false;
    this.appendAdaptiveRollingFrame(frameDb, frameDuration);
    const rollingPercentile = this.adaptiveRollingPercentile();
    const windowMax = this.adaptiveRollingMaxDb(VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S);
    const dispersionDb = (windowMax ?? frameDb) - (rollingPercentile ?? frameDb);
    const shortSpreadDb = this.config.adaptiveDynamicsEnabled
      ? (windowMax ?? frameDb)
        - (this.adaptiveRollingMinDb(VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S) ?? frameDb)
      : null;
    const adjacentStepDb = this.adaptiveRollingAdjacentStepDb();
    this.adaptiveRollingPercentileCache = rollingPercentile;
    if (!this.adaptiveRefinementComplete) {
      return this.processAdaptiveRefinement(
        frameDb,
        frameDuration,
        rollingPercentile,
        dispersionDb,
        shortSpreadDb,
      );
    }

    if (this.floorDb === null) {
      this.floorDb = VAD_FLOOR_MIN_DB;
      this.adaptiveRefinementComplete = false;
      this.adaptiveRefinementElapsed = 0;
      this.coldStartSpeechShapedNow = false;
      this.coldStartConverged = false;
      return this.processAdaptiveRefinement(
        frameDb,
        frameDuration,
        rollingPercentile,
        dispersionDb,
        shortSpreadDb,
      );
    }

    const thresholds = this.adaptiveThresholds(this.floorDb);
    let levels = this.classify(
      frameDb,
      thresholds.strongThresholdDb,
      thresholds.continuationThresholdDb,
      thresholds.silenceThresholdDb,
      this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
      shortSpreadDb,
      adjacentStepDb,
    );
    if (levels.evidence === 'silence') {
      this.elapsedSinceSilenceEvidence = 0;
    } else {
      this.elapsedSinceSilenceEvidence += Math.max(0, frameDuration);
      const elapsedSinceSilenceEvidence = this.elapsedSinceSilenceEvidence
        + TIME_BOUNDARY_EPSILON_S;
      const viaIdle = this.lastKnownMachineIsIdle
        && elapsedSinceSilenceEvidence >= this.effectiveStaleFloorSeconds;
      const flatSignal = dispersionDb < this.effectiveFlatSpreadDb
        && (shortSpreadDb === null || shortSpreadDb < this.effectiveFlatSpreadDb);
      const viaStuckRun = !this.lastKnownMachineIsIdle
        && elapsedSinceSilenceEvidence >= VAD_ADAPTIVE_IMPLAUSIBLE_SPEECH_S
        && flatSignal;
      const floorAtInitClamp = this.floorDb <= VAD_FLOOR_MIN_DB
        + VAD_ADAPTIVE_FLOOR_MOVEMENT_EPSILON_DB;
      if (floorAtInitClamp || viaIdle || viaStuckRun) {
        const target = rollingPercentile;
        if (target !== null) {
          this.elapsedSinceSilenceEvidence = 0;
          const reanchoredFloor = this.speechCeilingDb === null
            ? this.clampFloor(target)
            : this.clampFloor(Math.min(
              target,
              this.speechCeilingDb
                - this.effectiveAdaptiveDeltaDb
                - VAD_SPEECH_CEILING_MARGIN_DB,
            ));
          const maximumReanchorFloor = VAD_FLOOR_MAX_DB - this.effectiveAdaptiveDeltaDb;
          if (reanchoredFloor <= maximumReanchorFloor) {
            const floorMoved = Math.abs(reanchoredFloor - this.floorDb)
              > VAD_ADAPTIVE_FLOOR_MOVEMENT_EPSILON_DB;
            this.floorDb = reanchoredFloor;
            if (floorMoved && !this.hasRefusedReanchorSinceLastAcceptance) {
              this.pendingReanchorEvent = true;
              didReanchor = true;
            }
            this.hasRefusedReanchorSinceLastAcceptance = false;
            const thresholds = this.adaptiveThresholds(reanchoredFloor);
            levels = this.classify(
              frameDb,
              thresholds.strongThresholdDb,
              thresholds.continuationThresholdDb,
              thresholds.silenceThresholdDb,
              this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
              shortSpreadDb,
              adjacentStepDb,
            );
          } else {
            this.hasRefusedReanchorSinceLastAcceptance = true;
            if (!this.hasLoggedReanchorRefusal) this.hasLoggedReanchorRefusal = true;
          }
        }
      }
    }
    const evidence = this.dynamicsGatedEvidence(levels.evidence, dispersionDb);
    const { didCompletePriming, primingEndedAtCap } = this.updatePriming(
      frameDb,
      levels.strongThresholdDb,
      frameDuration,
    );
    return this.emit({
      ...levels,
      evidence,
      isSpeech: evidence === 'strong' || evidence === 'continuing',
      speechShaped: levels.speechShaped,
      thresholdDb: levels.strongThresholdDb,
      floorDb: this.floorDb,
      floorConverged: this.coldStartConverged,
      dynamicsSpreadDb: this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
      shortSpreadDb,
      didReanchor,
      didCompletePriming,
      primingDurationSeconds: this.adaptivePrimingElapsed,
      primingEndedAtCap: didCompletePriming
        && this.adaptivePrimingQuietElapsed < this.config.primingQuietSeedSeconds,
    });
  }

  processAdaptiveRefinement(frameDb, frameDuration, rollingPercentile, dispersionDb, shortSpreadDb) {
    this.adaptiveRefinementElapsed += Math.max(0, frameDuration);
    if (this.floorDb === null) {
      this.floorDb = VAD_FLOOR_MIN_DB;
    }

    const shapedThresholdDb = this.config.adaptiveDynamicsEnabled
      ? this.effectiveDynamicsSpreadDb
      : this.effectiveAdaptiveDeltaDb + VAD_SPEECH_CEILING_MARGIN_DB;
    this.coldStartSpeechShapedNow = dispersionDb >= shapedThresholdDb;

    if (this.adaptiveRefinementElapsed >= VAD_ADAPTIVE_COLD_START_GRACE_S
      && rollingPercentile !== null) {
      // Do not cap this seed at the absolute speech floor: loud-room ambient
      // would be pinned artificially low and recreate the original failure.
      this.floorDb = this.clampFloor(rollingPercentile);
      if (!this.coldStartConverged) {
        this.coldStartConverged = true;
      }
    } else if (!this.coldStartConverged) {
      if (this.floorDb !== null) {
        this.floorDb = Math.min(this.floorDb, this.clampFloor(frameDb));
      } else {
        this.floorDb = VAD_FLOOR_MIN_DB;
      }
    }
    const refinementCapReached = this.adaptiveRefinementElapsed
      + TIME_BOUNDARY_EPSILON_S
      >= 2 * VAD_ADAPTIVE_MIN_REFINEMENT_DURATION_S;
    if (refinementCapReached && !this.coldStartConverged) {
      const forcedSeedDb = rollingPercentile
        ?? this.adaptiveRollingMinDb(VAD_ADAPTIVE_ROLLING_WINDOW_DURATION_S)
        ?? frameDb;
      this.floorDb = this.clampFloor(forcedSeedDb);
      this.coldStartConverged = true;
    }
    if (this.coldStartConverged || refinementCapReached) {
      this.adaptiveRefinementComplete = true;
    }

    const currentFloor = this.floorDb ?? VAD_FLOOR_MIN_DB;
    const thresholds = this.adaptiveThresholds(currentFloor);
    const adjacentStepDb = this.adaptiveRollingAdjacentStepDb();
    const levels = this.classify(
      frameDb,
      thresholds.strongThresholdDb,
      thresholds.continuationThresholdDb,
      thresholds.silenceThresholdDb,
      this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
      shortSpreadDb,
      adjacentStepDb,
    );
    const evidence = this.dynamicsGatedEvidence(
      levels.evidence,
      shortSpreadDb ?? dispersionDb,
    );
    const isSpeech = evidence === 'strong' || evidence === 'continuing';
    const { didCompletePriming, primingEndedAtCap } = this.updatePriming(
      frameDb,
      levels.strongThresholdDb,
      frameDuration,
    );
    return this.emit({
      ...levels,
      evidence,
      isSpeech,
      speechShaped: levels.speechShaped,
      thresholdDb: levels.strongThresholdDb,
      continuationThresholdDb: levels.continuationThresholdDb,
      silenceThresholdDb: levels.silenceThresholdDb,
      floorDb: currentFloor,
      floorConverged: this.coldStartConverged,
      dynamicsSpreadDb: this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
      shortSpreadDb,
      didCompletePriming,
      primingDurationSeconds: this.adaptivePrimingElapsed,
      primingEndedAtCap,
    });
  }

  updatePriming(frameDb, strongThresholdDb, frameDuration) {
    if (this.behaviorMode !== 'adaptive' || this.adaptivePrimed) {
      return { didCompletePriming: false, primingEndedAtCap: false };
    }
    const duration = Math.max(0, frameDuration);
    this.adaptivePrimingElapsed = Math.min(
      this.config.primingMaximumSeconds,
      this.adaptivePrimingElapsed + duration,
    );
    if (this.coldStartConverged && frameDb < strongThresholdDb) {
      this.adaptivePrimingQuietElapsed += duration;
    } else {
      this.adaptivePrimingQuietElapsed = 0;
    }
    const endedAtCap = this.adaptivePrimingElapsed + TIME_BOUNDARY_EPSILON_S
      >= this.config.primingMaximumSeconds;
    if (this.adaptivePrimingQuietElapsed < this.config.primingQuietSeedSeconds && !endedAtCap) {
      return { didCompletePriming: false, primingEndedAtCap: false };
    }
    this.adaptivePrimed = true;
    return {
      didCompletePriming: true,
      primingEndedAtCap: endedAtCap
        && this.adaptivePrimingQuietElapsed < this.config.primingQuietSeedSeconds,
    };
  }

  dynamicsGatedEvidence(evidence, dispersionDb) {
    const spread = this.isLoudRegime
      ? Math.max(0, this.config.loudDynamicsSpreadDb)
      : this.effectiveDynamicsSpreadDb;
    if (this.config.adaptiveDynamicsEnabled
      && evidence === 'strong'
      && spread > 0
      && dispersionDb < spread) {
      return 'continuing';
    }
    return evidence;
  }

  updateFloorTracking(frameDb, duration, machineIsIdle = true, machineIsEnding = false,
    quietRiseCapAppliesToAmbiguous = false, quietRiseCapWitnessDb = 3) {
    this.lastKnownMachineIsIdle = machineIsIdle;
    if (this.config.loudRegimeEnabled && this.floorDb !== null) {
      if (this.floorDb >= this.config.loudRegimeEnterDb) {
        this.loudEnterElapsed += Math.max(0, duration);
        this.loudExitElapsed = 0;
        if (this.loudEnterElapsed * 1000 >= this.config.loudRegimeEnterMs) this.isLoudRegime = true;
      } else if (this.floorDb <= this.config.loudRegimeExitDb) {
        this.loudEnterElapsed = 0;
        if (machineIsIdle) {
          this.loudExitElapsed += Math.max(0, duration);
          if (this.loudExitElapsed * 1000 >= this.config.loudRegimeExitMs) this.isLoudRegime = false;
        } else this.loudExitElapsed = 0;
      } else {
        this.loudEnterElapsed = 0;
        this.loudExitElapsed = 0;
      }
    }
    if (this.behaviorMode !== 'adaptive') return;
    if (this.floorDb === null) return;
    if (!this.adaptiveRefinementComplete) return;
    // Match the Swift hold while the recorder is idle after an utterance ends.
    const suppressReseededFloorRise = machineIsIdle
      && this.floorRiseSuppressionRemainingSeconds > 0;
    if (suppressReseededFloorRise) {
      this.floorRiseSuppressionRemainingSeconds = Math.max(
        0,
        this.floorRiseSuppressionRemainingSeconds - Math.max(0, duration),
      );
    }
    let riseCap;
    switch (this.lastOutput.evidence) {
      case 'strong':
        riseCap = 0;
        break;
      case 'continuing':
        if (!machineIsIdle) {
          riseCap = 0;
        } else if (this.isLoudRegime) {
          riseCap = this.config.loudRiseDbPerSec * this.effectiveRiseSpeedMultiplier;
        } else if ((this.lastOutput.dynamicsSpreadDb ?? -Infinity) >= quietRiseCapWitnessDb) {
          riseCap = this.config.quietContinuationRiseCapDbPerSec
            * this.effectiveRiseSpeedMultiplier;
        } else {
          riseCap = VAD_ELEVATED_RISE_DB_PER_SECOND * this.effectiveRiseSpeedMultiplier;
        }
        break;
      case 'ambiguous':
      case 'silence':
        if (!machineIsIdle) {
          riseCap = 0;
        } else if (this.isLoudRegime) {
          riseCap = this.config.loudRiseDbPerSec * this.effectiveRiseSpeedMultiplier;
        } else if (this.lastOutput.evidence === 'ambiguous'
          && quietRiseCapAppliesToAmbiguous
          && (this.lastOutput.dynamicsSpreadDb ?? -Infinity) >= quietRiseCapWitnessDb) {
          riseCap = this.config.quietContinuationRiseCapDbPerSec
            * this.effectiveRiseSpeedMultiplier;
        } else {
          riseCap = VAD_ELEVATED_RISE_DB_PER_SECOND * this.effectiveRiseSpeedMultiplier;
        }
        break;
      default:
        riseCap = machineIsIdle
          ? VAD_ELEVATED_RISE_DB_PER_SECOND * this.effectiveRiseSpeedMultiplier
          : 0;
        break;
    }
    if (suppressReseededFloorRise) riseCap = 0;
    if (machineIsIdle && this.speechCeilingDb !== null) {
      const decayedCeilingDb = this.speechCeilingDb
        + VAD_ELEVATED_RISE_DB_PER_SECOND
          * this.effectiveRiseSpeedMultiplier
          * Math.max(0, duration);
      const clampBound = decayedCeilingDb
        - this.effectiveAdaptiveDeltaDb
        - VAD_SPEECH_CEILING_MARGIN_DB;
      this.speechCeilingDb = clampBound > VAD_FLOOR_MAX_DB - this.effectiveAdaptiveDeltaDb
        ? null
        : decayedCeilingDb;
    }
    if (machineIsEnding
      && !suppressReseededFloorRise
      && this.lastOutput.shortSpreadDb !== null
      && this.lastOutput.dynamicsSpreadDb !== null
      && this.lastOutput.shortSpreadDb < this.effectiveFlatSpreadDb
      && this.lastOutput.dynamicsSpreadDb < VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
      && this.lastOutput.evidence !== 'strong') {
      const target = Math.max(this.adaptiveRollingPercentileCache ?? frameDb, frameDb);
      const risenFloor = Math.max(
        this.floorDb,
        Math.min(
          target,
          this.floorDb + VAD_ELEVATED_RISE_DB_PER_SECOND
            * this.effectiveRiseSpeedMultiplier * duration,
        ),
      );
      this.floorDb = this.clampFloor(risenFloor);
      this.refreshAdaptiveOutput();
      return;
    }
    if (riseCap === 0 && this.adaptiveRollingPercentileAtLeast(this.floorDb)) return;
    const target = this.adaptiveRollingPercentileCache;
    if (target === null) return;
    this.updateFloor(target, duration, riseCap);
    this.refreshAdaptiveOutput();
  }

  resetFloorAfterRouteChange() {
    if (this.config.mode !== 'adaptive') return;
    this.behaviorMode = 'adaptive';
    this.adaptiveRefinementElapsed = 0;
    this.adaptivePrimingElapsed = 0;
    this.adaptivePrimingQuietElapsed = 0;
    this.adaptivePrimed = false;
    this.adaptiveRefinementComplete = false;
    this.coldStartSpeechShapedNow = false;
    this.coldStartConverged = false;
    this.floorDb = VAD_FLOOR_MIN_DB;
    const resetAdaptiveThresholds = this.adaptiveThresholds(VAD_FLOOR_MIN_DB);
    this.thresholdDb = resetAdaptiveThresholds.strongThresholdDb;
    this.elapsedSinceSilenceEvidence = 0;
    this.pendingReanchorEvent = false;
    this.hasRefusedReanchorSinceLastAcceptance = false;
    this.speechCeilingDb = null;
    this.floorRiseSuppressionRemainingSeconds = 0;
    this.resetAdaptiveRollingWindow();
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
      speechShaped: false,
      thresholdDb: this.thresholdDb,
      continuationThresholdDb: resetAdaptiveThresholds.continuationThresholdDb,
      silenceThresholdDb: resetAdaptiveThresholds.silenceThresholdDb,
      floorDb: this.floorDb,
      floorConverged: false,
      dynamicsSpreadDb: null,
      shortSpreadDb: null,
      didReanchor: false,
      didCompletePriming: false,
      primingDurationSeconds: 0,
      primingEndedAtCap: false,
    };
  }

  updateFloor(targetDb, frameDuration, maximumRiseDbPerSecond) {
    let floor = this.floorDb;
    if (targetDb > floor) {
      floor = Math.min(targetDb, floor + maximumRiseDbPerSecond * frameDuration);
    } else {
      floor += (1 - Math.exp(-frameDuration / this.effectiveFallTauSeconds))
        * (targetDb - floor);
    }
    if (this.speechCeilingDb !== null) {
      floor = Math.min(
        floor,
        this.speechCeilingDb - this.effectiveAdaptiveDeltaDb - VAD_SPEECH_CEILING_MARGIN_DB,
      );
    }
    this.floorDb = this.clampFloor(floor);
  }

  appendAdaptiveRollingFrame(db, duration) {
    if (duration <= 0) return;
    if (this.adaptiveRollingCount === VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) {
      const oldestIndex = (this.adaptiveRollingWriteIndex - this.adaptiveRollingCount
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      this.adaptiveRollingElapsed -= this.adaptiveRollingDurations[oldestIndex];
    } else {
      this.adaptiveRollingCount += 1;
    }

    this.adaptiveRollingDbs[this.adaptiveRollingWriteIndex] = db;
    this.adaptiveRollingDurations[this.adaptiveRollingWriteIndex] = duration;
    this.adaptiveRollingWriteIndex = (this.adaptiveRollingWriteIndex + 1)
      % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
    this.adaptiveRollingElapsed += duration;

    while (this.adaptiveRollingCount > 0
      && this.adaptiveRollingElapsed > VAD_ADAPTIVE_ROLLING_WINDOW_DURATION_S) {
      const oldestIndex = (this.adaptiveRollingWriteIndex - this.adaptiveRollingCount
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      this.adaptiveRollingElapsed -= this.adaptiveRollingDurations[oldestIndex];
      this.adaptiveRollingCount -= 1;
    }
  }

  resetAdaptiveRollingWindow() {
    this.adaptiveRollingWriteIndex = 0;
    this.adaptiveRollingCount = 0;
    this.adaptiveRollingElapsed = 0;
    this.adaptiveRollingPercentileCache = null;
  }

  adaptiveRollingPercentile() {
    if (this.adaptiveRollingCount === 0) return null;
    const values = [];
    for (let offset = 0; offset < this.adaptiveRollingCount; offset++) {
      const index = (this.adaptiveRollingWriteIndex - this.adaptiveRollingCount + offset
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      values.push(this.adaptiveRollingDbs[index]);
    }
    return this.percentile(values, VAD_ADAPTIVE_ROLLING_PERCENTILE);
  }

  adaptiveRollingMaxDb(coverSeconds) {
    if (this.adaptiveRollingCount === 0) return null;
    let maximum = -Infinity;
    let coveredSeconds = 0;
    for (let offset = 0; offset < this.adaptiveRollingCount; offset++) {
      const index = (this.adaptiveRollingWriteIndex - 1 - offset
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      maximum = Math.max(maximum, this.adaptiveRollingDbs[index]);
      coveredSeconds += this.adaptiveRollingDurations[index];
      if (coveredSeconds > coverSeconds) break;
    }
    return maximum;
  }

  adaptiveRollingMinDb(coverSeconds) {
    if (this.adaptiveRollingCount === 0) return null;
    let minimum = Infinity;
    let coveredSeconds = 0;
    for (let offset = 0; offset < this.adaptiveRollingCount; offset++) {
      const index = (this.adaptiveRollingWriteIndex - 1 - offset
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      minimum = Math.min(minimum, this.adaptiveRollingDbs[index]);
      coveredSeconds += this.adaptiveRollingDurations[index];
      if (coveredSeconds > coverSeconds) break;
    }
    return minimum;
  }

  adaptiveRollingAdjacentStepDb() {
    if (this.adaptiveRollingCount < 2) return null;
    const currentIndex = (this.adaptiveRollingWriteIndex - 1
      + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
    const previousIndex = (this.adaptiveRollingWriteIndex - 2
      + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
    return Math.abs(this.adaptiveRollingDbs[currentIndex] - this.adaptiveRollingDbs[previousIndex]);
  }

  adaptiveQuietShapeSpreads(silenceThresholdDb) {
    if (this.adaptiveRollingCount === 0) {
      return { dynamicsSpreadDb: null, shortSpreadDb: null, adjacentStepDb: null };
    }
    const quietValues = [];
    let adjacentStepDb = null;
    let newerFrameDb = null;
    let coveredSeconds = 0;
    for (let offset = 0; offset < this.adaptiveRollingCount; offset += 1) {
      const index = (this.adaptiveRollingWriteIndex - 1 - offset
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      const frameDb = this.adaptiveRollingDbs[index];
      if (frameDb >= silenceThresholdDb) break;
      if (newerFrameDb !== null) {
        const stepDb = Math.abs(newerFrameDb - frameDb);
        if (adjacentStepDb === null) adjacentStepDb = stepDb;
        // Do not let modulation before an abrupt transition keep settled quiet speech-shaped.
        if (stepDb >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB) break;
      }
      quietValues.push(frameDb);
      newerFrameDb = frameDb;
      coveredSeconds += this.adaptiveRollingDurations[index];
      if (coveredSeconds > VAD_SPEECH_SHAPE_WINDOW_S) break;
    }
    if (quietValues.length === 0) {
      return { dynamicsSpreadDb: null, shortSpreadDb: null, adjacentStepDb: null };
    }
    const maximum = Math.max(...quietValues);
    const minimum = Math.min(...quietValues);
    return {
      dynamicsSpreadDb: maximum - this.percentile(quietValues, VAD_ADAPTIVE_ROLLING_PERCENTILE),
      shortSpreadDb: maximum - minimum,
      adjacentStepDb,
    };
  }

  adaptiveRollingPercentileAtLeast(floorDb) {
    if (this.adaptiveRollingCount === 0) return false;

    const position = VAD_ADAPTIVE_ROLLING_PERCENTILE * (this.adaptiveRollingCount - 1);
    const lowerIndex = Math.floor(position);
    const upperIndex = Math.min(lowerIndex + 1, this.adaptiveRollingCount - 1);
    let belowCount = 0;
    let maximumBelow = -Infinity;
    let minimumAtOrAbove = Infinity;

    for (let offset = 0; offset < this.adaptiveRollingCount; offset++) {
      const index = (this.adaptiveRollingWriteIndex - this.adaptiveRollingCount + offset
        + VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY) % VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY;
      const value = this.adaptiveRollingDbs[index];
      if (value < floorDb) {
        belowCount += 1;
        maximumBelow = Math.max(maximumBelow, value);
      } else {
        minimumAtOrAbove = Math.min(minimumAtOrAbove, value);
      }
    }

    if (belowCount <= lowerIndex) return true;
    if (belowCount > upperIndex) return false;
    if (upperIndex === lowerIndex) return false;
    const fraction = position - lowerIndex;
    return maximumBelow + fraction * (minimumAtOrAbove - maximumBelow) >= floorDb;
  }

  percentile(values, percentile) {
    const sortedValues = [...values].sort((a, b) => a - b);
    if (sortedValues.length === 0) return 0;
    if (sortedValues.length === 1) return sortedValues[0];
    const position = percentile * (sortedValues.length - 1);
    const lowerIndex = Math.floor(position);
    const upperIndex = Math.min(lowerIndex + 1, sortedValues.length - 1);
    const fraction = position - lowerIndex;
    return sortedValues[lowerIndex]
      + fraction * (sortedValues[upperIndex] - sortedValues[lowerIndex]);
  }

  refreshAdaptiveOutput() {
    const thresholds = this.adaptiveThresholds(this.floorDb);
    this.lastOutput = {
      ...this.lastOutput,
      thresholdDb: thresholds.strongThresholdDb,
      continuationThresholdDb: thresholds.continuationThresholdDb,
      silenceThresholdDb: thresholds.silenceThresholdDb,
      floorDb: this.floorDb,
      floorConverged: this.coldStartConverged,
      dynamicsSpreadDb: this.lastOutput.dynamicsSpreadDb,
      shortSpreadDb: this.lastOutput.shortSpreadDb,
      isLoudRegime: this.isLoudRegime,
      didReanchor: false,
      didCompletePriming: false,
      primingDurationSeconds: this.adaptivePrimingElapsed,
      primingEndedAtCap: false,
    };
  }

  adaptiveThresholds(floorDb) {
    if (this.isLoudRegime) {
      const strongDelta = Math.min(this.effectiveAdaptiveDeltaDb, this.config.loudStrongDeltaDb);
      const continuationDelta = Math.min(
        this.effectiveAdaptiveContinuationDeltaDb,
        this.config.loudContinuationDeltaDb,
      );
      const silenceDelta = Math.min(this.effectiveSilenceDeltaDb, this.config.loudSilenceDeltaDb);
      const strongThresholdDb = Math.max(floorDb + strongDelta, this.effectiveAbsoluteSpeechFloorDb);
      const continuationThresholdDb = Math.min(
        Math.max(floorDb + continuationDelta, this.effectiveAbsoluteSpeechFloorDb),
        strongThresholdDb - 1,
      );
      return {
        strongThresholdDb,
        continuationThresholdDb,
        silenceThresholdDb: Math.min(floorDb + silenceDelta, 5, continuationThresholdDb - 1),
      };
    }
    return {
      strongThresholdDb: Math.max(
        floorDb + this.effectiveAdaptiveDeltaDb,
        this.effectiveAbsoluteSpeechFloorDb,
      ),
      continuationThresholdDb: Math.max(
        floorDb + this.effectiveAdaptiveContinuationDeltaDb,
        this.effectiveAbsoluteSpeechFloorDb,
      ),
      silenceThresholdDb: floorDb + this.effectiveSilenceDeltaDb,
    };
  }

  classify(
    frameDb,
    strongThresholdDb,
    continuationThresholdDb,
    silenceThresholdDb,
    dynamicsSpreadDb = null,
    shortSpreadDb = null,
    adjacentStepDb = null,
  ) {
    let evidence;
    let speechShaped;
    if (frameDb >= strongThresholdDb) {
      evidence = 'strong';
      speechShaped = isSpeechShaped({
        dynamicsSpreadDb,
        shortSpreadDb,
        flatSpreadDb: this.effectiveFlatSpreadDb,
        adjacentStepDb,
        allowWindBoundaryStep: true,
      });
    } else if (frameDb >= continuationThresholdDb) {
      evidence = 'continuing';
      speechShaped = isSpeechShaped({
        dynamicsSpreadDb,
        shortSpreadDb,
        flatSpreadDb: this.effectiveFlatSpreadDb,
        adjacentStepDb,
        allowWindBoundaryStep: true,
      });
    } else if (frameDb < silenceThresholdDb) {
      const quietShapeSpreads = this.adaptiveQuietShapeSpreads(silenceThresholdDb);
      speechShaped = isSpeechShaped({
        dynamicsSpreadDb: quietShapeSpreads.dynamicsSpreadDb,
        shortSpreadDb: quietShapeSpreads.shortSpreadDb,
        flatSpreadDb: this.effectiveFlatSpreadDb,
        adjacentStepDb: quietShapeSpreads.adjacentStepDb,
      });
      evidence = 'silence';
    } else {
      evidence = 'ambiguous';
      speechShaped = isSpeechShaped({
        dynamicsSpreadDb,
        shortSpreadDb,
        flatSpreadDb: this.effectiveFlatSpreadDb,
        adjacentStepDb,
        allowWindBoundaryStep: true,
      });
    }
    return {
      evidence,
      speechShaped,
      strongThresholdDb,
      continuationThresholdDb,
      silenceThresholdDb,
    };
  }

  clampFloor(floor) {
    return Math.min(Math.max(floor, VAD_FLOOR_MIN_DB), VAD_FLOOR_MAX_DB);
  }

  emit({
    evidence,
    isSpeech,
    thresholdDb,
    strongThresholdDb,
    continuationThresholdDb,
    silenceThresholdDb,
    floorDb,
    floorConverged = false,
    dynamicsSpreadDb = null,
    shortSpreadDb = null,
    speechShaped = false,
    isLoudRegime = this.isLoudRegime,
    didReanchor = false,
    didCompletePriming = false,
    primingDurationSeconds = 0,
    primingEndedAtCap = false,
  }) {
    this.lastOutput = {
      isSpeech,
      evidence,
      thresholdDb: thresholdDb ?? strongThresholdDb,
      continuationThresholdDb,
      silenceThresholdDb,
      floorDb,
      floorConverged,
      dynamicsSpreadDb,
      shortSpreadDb,
      speechShaped,
      isLoudRegime,
      didReanchor,
      didCompletePriming,
      primingDurationSeconds,
      primingEndedAtCap,
    };
    return { ...this.lastOutput };
  }
}
