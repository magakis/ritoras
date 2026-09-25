// Pure-logic JS mirror of VADMode, VADGateConfig, VADGateOutput, and
// VADThresholdGate in shared/VADGate.swift, plus AudioMath in
// shared/AudioMath.swift. Kept in sync per AGENTS.md → Test policy.

const VAD_CONTINUATION_DELTA_DB = 6.0;
export const VAD_STATIC_CONTINUATION_OFFSET_DB = 4.0;
export const VAD_STATIC_SILENCE_OFFSET_DB = 6.0;
export const VAD_ELEVATED_RISE_DB_PER_SECOND = 12.0;
export const VAD_SPEECH_CEILING_MARGIN_DB = 2.0;
export const VAD_SUSTAINED_CONTINUING_ONSET_S = 1.0;
export const VAD_ADAPTIVE_MIN_REFINEMENT_DURATION_S = 1.0;
export const VAD_ADAPTIVE_COLD_START_GRACE_S = 0.4;
export const VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S = 0.4;
export const VAD_ADAPTIVE_ROLLING_WINDOW_DURATION_S = 3.0;
export const VAD_ADAPTIVE_ROLLING_WINDOW_CAPACITY = 256;
export const VAD_FLOOR_MIN_DB = -80;
export const VAD_FLOOR_MAX_DB = -20;
export const CALIBRATION_QUARTILE = 0.25;
export const QUIET_BAND_DB = 6.0;
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
export const CALIBRATION_LEADING_TRIM_DB = 12.0;
const CALIBRATION_COMPLETION_EPSILON_S = 1e-9;

function clamp(value, lower, upper) {
  return Math.min(Math.max(value, lower), upper);
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
    calibrationMs: 1500,
    calibratedOffsetDb: 10.0,
    adaptiveDeltaDb: 10.0,
    adaptiveContinuationDeltaDb: 6.0,
    adaptiveAbsoluteSpeechFloorDb: VAD_ABSOLUTE_SPEECH_FLOOR_DB,
    adaptiveRiseSpeedMultiplier: 1.0,
    adaptiveSilenceDeltaDb: 3.0,
    adaptiveStaleFloorSeconds: 1.5,
    adaptiveFallTauSeconds: 0.5,
    adaptiveDynamicsEnabled: true,
    adaptiveDynamicsSpreadDb: 9.0,
    adaptiveFlatSpreadDb: 5.0,
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
    this.calibrationFinished = false;
    this.calibrationElapsed = 0;
    this.calibrationFrames = [];
    this.adaptiveRefinementElapsed = 0;
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
    this.usedFallback = false;
    this.pendingRetroactiveSpeechMs = 0;
    this.pendingTrailingSilenceMs = null;
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
    this.lastKnownMachineIsIdle = true;
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
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
      calibrating: this.config.mode === 'calibrated',
      usedFallback: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
      dynamicsSpreadDb: null,
      shortSpreadDb: null,
    };
  }

  process(frameDb, frameDuration) {
    switch (this.behaviorMode) {
      case 'static':
        return this.processStatic(frameDb);
      case 'calibrated':
        if (!this.calibrationFinished) {
          return this.processCalibration(frameDb, frameDuration);
        }
        return this.processCalibrated(frameDb);
      case 'adaptive':
        return this.processAdaptive(frameDb, frameDuration);
      default:
        return this.processStatic(frameDb);
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

  noteUtteranceEnded(quietestStrongDb) {
    if (this.behaviorMode !== 'adaptive') return;
    if (this.floorDb !== null
      && quietestStrongDb !== null
      && quietestStrongDb !== undefined
      && quietestStrongDb >= this.floorDb
        + this.effectiveAdaptiveDeltaDb
        + VAD_SPEECH_CEILING_MARGIN_DB) {
      this.speechCeilingDb = quietestStrongDb;
    }
    this.resetAdaptiveRollingWindow();
  }

  processStatic(frameDb) {
    const levels = this.classify(
      frameDb,
      this.thresholdDb,
      this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
    );
    return this.emit({
      ...levels,
      isSpeech: levels.evidence === 'strong',
      thresholdDb: levels.strongThresholdDb,
      floorDb: null,
      calibrating: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
    });
  }

  processCalibration(frameDb, frameDuration) {
    this.calibrationFrames.push({ db: frameDb, duration: frameDuration });
    this.calibrationElapsed += frameDuration;
    if (this.calibrationElapsed + CALIBRATION_COMPLETION_EPSILON_S >= this.config.calibrationMs / 1000) {
      this.finishCalibration();
    }

    const thresholdDb = this.calibrationThresholdDb();
    return this.emit({
      evidence: 'silence',
      isSpeech: false,
      strongThresholdDb: thresholdDb,
      continuationThresholdDb: thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      thresholdDb,
      floorDb: null,
      calibrating: true,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
    });
  }

  finishCalibration() {
    const q1 = this.calibrationQ1();
    const referenceThreshold = q1 + this.config.calibratedOffsetDb;
    const quietCount = this.calibrationFrames.filter(
      frame => frame.db <= q1 + QUIET_BAND_DB,
    ).length;

    const retroactiveSpeechSeconds = this.calibrationFrames
      .filter(frame => frame.db >= referenceThreshold)
      .reduce((total, frame) => total + frame.duration, 0);

    let trailingSilenceSeconds = 0;
    for (let i = this.calibrationFrames.length - 1; i >= 0; i--) {
      const frame = this.calibrationFrames[i];
      if (frame.db >= referenceThreshold) break;
      trailingSilenceSeconds += frame.duration;
    }
    this.pendingRetroactiveSpeechMs = retroactiveSpeechSeconds * 1000;
    this.pendingTrailingSilenceMs = trailingSilenceSeconds * 1000;

    const minimumQuietFrames = Math.max(3, Math.floor(this.calibrationFrames.length / 3));
    if (quietCount >= minimumQuietFrames) {
      this.thresholdDb = referenceThreshold;
      this.floorDb = null;
      this.behaviorMode = 'calibrated';
    } else {
      const seededFloor = this.clampFloor(q1);
      this.floorDb = seededFloor;
      this.thresholdDb = this.adaptiveThresholds(seededFloor).strongThresholdDb;
      this.adaptiveRefinementElapsed = 0;
      this.adaptiveRefinementComplete = true;
      this.coldStartConverged = true;
      this.behaviorMode = 'adaptive';
      this.usedFallback = true;
    }
    this.calibrationFinished = true;
  }

  processCalibrated(frameDb) {
    const levels = this.classify(
      frameDb,
      this.thresholdDb,
      this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
    );
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      ...levels,
      isSpeech: levels.evidence === 'strong',
      thresholdDb: levels.strongThresholdDb,
      floorDb: null,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
    });
  }

  processAdaptive(frameDb, frameDuration) {
    this.appendAdaptiveRollingFrame(frameDb, frameDuration);
    const rollingPercentile = this.adaptiveRollingPercentile();
    const windowMax = this.adaptiveRollingMaxDb(VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S);
    const dispersionDb = (windowMax ?? frameDb) - (rollingPercentile ?? frameDb);
    const shortSpreadDb = this.config.adaptiveDynamicsEnabled
      ? (windowMax ?? frameDb)
        - (this.adaptiveRollingMinDb(VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S) ?? frameDb)
      : null;
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
    );
    if (levels.evidence === 'silence') {
      this.elapsedSinceSilenceEvidence = 0;
    } else {
      this.elapsedSinceSilenceEvidence += Math.max(0, frameDuration);
      const elapsedSinceSilenceEvidence = this.elapsedSinceSilenceEvidence
        + CALIBRATION_COMPLETION_EPSILON_S;
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
            }
            this.hasRefusedReanchorSinceLastAcceptance = false;
            const thresholds = this.adaptiveThresholds(reanchoredFloor);
            levels = this.classify(
              frameDb,
              thresholds.strongThresholdDb,
              thresholds.continuationThresholdDb,
              thresholds.silenceThresholdDb,
            );
          } else {
            this.hasRefusedReanchorSinceLastAcceptance = true;
            if (!this.hasLoggedReanchorRefusal) this.hasLoggedReanchorRefusal = true;
          }
        }
      }
    }
    const evidence = this.dynamicsGatedEvidence(levels.evidence, dispersionDb);
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      ...levels,
      evidence,
      isSpeech: evidence === 'strong' || evidence === 'continuing',
      thresholdDb: levels.strongThresholdDb,
      floorDb: this.floorDb,
      floorConverged: this.coldStartConverged,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
      dynamicsSpreadDb: this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
      shortSpreadDb,
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
      + CALIBRATION_COMPLETION_EPSILON_S
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
    const levels = this.classify(
      frameDb,
      thresholds.strongThresholdDb,
      thresholds.continuationThresholdDb,
      thresholds.silenceThresholdDb,
    );
    const evidence = this.dynamicsGatedEvidence(
      levels.evidence,
      shortSpreadDb ?? dispersionDb,
    );
    const isSpeech = evidence === 'strong' || evidence === 'continuing';
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      ...levels,
      evidence,
      isSpeech,
      thresholdDb: levels.strongThresholdDb,
      continuationThresholdDb: levels.continuationThresholdDb,
      silenceThresholdDb: levels.silenceThresholdDb,
      floorDb: currentFloor,
      floorConverged: this.coldStartConverged,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
      dynamicsSpreadDb: this.config.adaptiveDynamicsEnabled ? dispersionDb : null,
      shortSpreadDb,
    });
  }

  dynamicsGatedEvidence(evidence, dispersionDb) {
    if (this.config.adaptiveDynamicsEnabled
      && evidence === 'strong'
      && dispersionDb < this.effectiveDynamicsSpreadDb) {
      return 'continuing';
    }
    return evidence;
  }

  updateFloorTracking(frameDb, duration, machineIsIdle = true, machineIsEnding = false) {
    this.lastKnownMachineIsIdle = machineIsIdle;
    if (this.behaviorMode !== 'adaptive') return;
    if (this.floorDb === null) return;
    if (!this.adaptiveRefinementComplete) return;
    let riseCap;
    switch (this.lastOutput.evidence) {
      case 'strong':
        riseCap = 0;
        break;
      case 'continuing':
        riseCap = machineIsIdle
          ? VAD_ELEVATED_RISE_DB_PER_SECOND * this.effectiveRiseSpeedMultiplier
          : 0;
        break;
      case 'ambiguous':
      case 'silence':
        riseCap = machineIsIdle
          ? VAD_ELEVATED_RISE_DB_PER_SECOND * this.effectiveRiseSpeedMultiplier
          : 0;
        break;
      default:
        riseCap = machineIsIdle
          ? VAD_ELEVATED_RISE_DB_PER_SECOND * this.effectiveRiseSpeedMultiplier
          : 0;
        break;
    }
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

  recalibrateFloor() {
    if (this.config.mode === 'static') return;
    if (this.config.mode === 'adaptive') {
      this.behaviorMode = 'adaptive';
      this.adaptiveRefinementElapsed = 0;
      this.adaptiveRefinementComplete = false;
      this.coldStartSpeechShapedNow = false;
      this.coldStartConverged = false;
      this.floorDb = VAD_FLOOR_MIN_DB;
    } else {
      this.behaviorMode = 'calibrated';
      this.calibrationFinished = false;
      this.calibrationElapsed = 0;
      this.calibrationFrames.length = 0;
      this.pendingRetroactiveSpeechMs = 0;
      this.pendingTrailingSilenceMs = null;
      this.floorDb = null;
      this.adaptiveRefinementElapsed = 0;
      this.adaptiveRefinementComplete = false;
    }
    const resetAdaptiveThresholds = this.config.mode === 'adaptive'
      ? this.adaptiveThresholds(VAD_FLOOR_MIN_DB)
      : null;
    this.thresholdDb = resetAdaptiveThresholds?.strongThresholdDb
      ?? dbFromRms(this.config.staticRms);
    this.elapsedSinceSilenceEvidence = 0;
    this.pendingReanchorEvent = false;
    this.hasRefusedReanchorSinceLastAcceptance = false;
    this.speechCeilingDb = null;
    this.resetAdaptiveRollingWindow();
    this.usedFallback = false;
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
      thresholdDb: this.thresholdDb,
      continuationThresholdDb: resetAdaptiveThresholds?.continuationThresholdDb
        ?? this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: resetAdaptiveThresholds?.silenceThresholdDb
        ?? this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      floorDb: this.floorDb,
      floorConverged: false,
      calibrating: this.config.mode === 'calibrated',
      usedFallback: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
      dynamicsSpreadDb: null,
      shortSpreadDb: null,
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
      usedFallback: this.usedFallback,
      dynamicsSpreadDb: this.lastOutput.dynamicsSpreadDb,
      shortSpreadDb: this.lastOutput.shortSpreadDb,
    };
  }

  adaptiveThresholds(floorDb) {
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

  classify(frameDb, strongThresholdDb, continuationThresholdDb, silenceThresholdDb) {
    let evidence;
    if (frameDb >= strongThresholdDb) {
      evidence = 'strong';
    } else if (frameDb >= continuationThresholdDb) {
      evidence = 'continuing';
    } else if (frameDb < silenceThresholdDb) {
      evidence = 'silence';
    } else {
      evidence = 'ambiguous';
    }
    return {
      evidence,
      strongThresholdDb,
      continuationThresholdDb,
      silenceThresholdDb,
    };
  }

  calibrationQ1() {
    const dbs = this.calibrationFrames.map(frame => frame.db);
    const sortedDbs = [...dbs].sort((a, b) => a - b);
    const medianDb = this.percentile(sortedDbs, 0.5);
    let leadingTrimCount = 0;
    while (leadingTrimCount < dbs.length
      && dbs[leadingTrimCount] < medianDb - CALIBRATION_LEADING_TRIM_DB) {
      leadingTrimCount += 1;
    }
    const q1Dbs = dbs.length - leadingTrimCount >= 3
      ? dbs.slice(leadingTrimCount)
      : dbs;
    const sortedQ1Dbs = [...q1Dbs].sort((a, b) => a - b);
    const index = Math.floor(CALIBRATION_QUARTILE * (sortedQ1Dbs.length - 1));
    return sortedQ1Dbs[index];
  }

  calibrationThresholdDb() {
    if (this.calibrationFrames.length === 0) return this.thresholdDb;
    return this.calibrationQ1() + this.config.calibratedOffsetDb;
  }

  clampFloor(floor) {
    return Math.min(Math.max(floor, VAD_FLOOR_MIN_DB), VAD_FLOOR_MAX_DB);
  }

  takeRetroactiveCredit() {
    const credit = [this.pendingRetroactiveSpeechMs, this.pendingTrailingSilenceMs];
    this.pendingRetroactiveSpeechMs = 0;
    this.pendingTrailingSilenceMs = null;
    return credit;
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
    calibrating,
    retroactiveSpeechMs,
    trailingSilenceMs,
    dynamicsSpreadDb = null,
    shortSpreadDb = null,
  }) {
    this.lastOutput = {
      isSpeech,
      evidence,
      thresholdDb: thresholdDb ?? strongThresholdDb,
      continuationThresholdDb,
      silenceThresholdDb,
      floorDb,
      floorConverged,
      calibrating,
      usedFallback: this.usedFallback,
      retroactiveSpeechMs,
      trailingSilenceMs,
      dynamicsSpreadDb,
      shortSpreadDb,
    };
    return { ...this.lastOutput };
  }
}
