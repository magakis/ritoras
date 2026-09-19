// Pure-logic JS mirror of VADMode, VADGateConfig, VADGateOutput, and
// VADThresholdGate in shared/VADGate.swift, plus AudioMath in
// shared/AudioMath.swift. Kept in sync per AGENTS.md → Test policy.

export const VAD_TAU_FALL_S = 0.5;
const VAD_CONTINUATION_DELTA_DB = 6.0;
export const VAD_SILENCE_DELTA_DB = 3.0;
export const VAD_STATIC_CONTINUATION_OFFSET_DB = 4.0;
export const VAD_STATIC_SILENCE_OFFSET_DB = 6.0;
export const VAD_ELEVATED_RISE_DB_PER_SECOND = 6.0;
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
export const VAD_ADAPTIVE_STALE_FLOOR_DURATION_S = 3.0;
export const VAD_ADAPTIVE_FLOOR_MOVEMENT_EPSILON_DB = 1e-6;
const CALIBRATION_COMPLETION_EPSILON_S = 1e-9;

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
    ...(partial ?? {}),
  };
}

export class VADThresholdGate {
  constructor(config) {
    this.config = makeVadGateConfig(config);
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
      ? VAD_FLOOR_MIN_DB + this.config.adaptiveDeltaDb
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
    this.lastKnownMachineIsIdle = true;
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
      thresholdDb: this.thresholdDb,
      continuationThresholdDb: this.config.mode === 'adaptive'
        ? VAD_FLOOR_MIN_DB + this.config.adaptiveContinuationDeltaDb
        : this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: this.config.mode === 'adaptive'
        ? VAD_FLOOR_MIN_DB + VAD_SILENCE_DELTA_DB
        : this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      floorDb: this.floorDb,
      calibrating: this.config.mode === 'calibrated',
      usedFallback: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
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
        + this.config.adaptiveDeltaDb
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
      this.thresholdDb = seededFloor + this.config.adaptiveDeltaDb;
      this.adaptiveRefinementElapsed = 0;
      this.adaptiveRefinementComplete = true;
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
    if (!this.adaptiveRefinementComplete) {
      return this.processAdaptiveRefinement(frameDb, frameDuration);
    }

    if (this.floorDb === null) {
      this.floorDb = VAD_FLOOR_MIN_DB;
      this.adaptiveRefinementComplete = false;
      this.adaptiveRefinementElapsed = 0;
      this.coldStartSpeechShapedNow = false;
      this.coldStartConverged = false;
      return this.processAdaptiveRefinement(frameDb, frameDuration);
    }

    let levels = this.classify(
      frameDb,
      this.floorDb + this.config.adaptiveDeltaDb,
      this.floorDb + this.config.adaptiveContinuationDeltaDb,
      this.floorDb + VAD_SILENCE_DELTA_DB,
    );
    if (levels.evidence === 'silence') {
      this.elapsedSinceSilenceEvidence = 0;
    } else {
      this.elapsedSinceSilenceEvidence += Math.max(0, frameDuration);
      if (this.elapsedSinceSilenceEvidence + CALIBRATION_COMPLETION_EPSILON_S
        >= VAD_ADAPTIVE_STALE_FLOOR_DURATION_S
        && this.lastKnownMachineIsIdle) {
        const target = this.adaptiveRollingPercentile();
        if (target !== null) {
          this.elapsedSinceSilenceEvidence = 0;
          const reanchoredFloor = this.speechCeilingDb === null
            ? this.clampFloor(target)
            : this.clampFloor(Math.min(
              target,
              this.speechCeilingDb
                - this.config.adaptiveDeltaDb
                - VAD_SPEECH_CEILING_MARGIN_DB,
            ));
          const maximumReanchorFloor = VAD_FLOOR_MAX_DB - this.config.adaptiveDeltaDb;
          if (reanchoredFloor <= maximumReanchorFloor) {
            const floorMoved = Math.abs(reanchoredFloor - this.floorDb)
              > VAD_ADAPTIVE_FLOOR_MOVEMENT_EPSILON_DB;
            this.floorDb = reanchoredFloor;
            if (floorMoved && !this.hasRefusedReanchorSinceLastAcceptance) {
              this.pendingReanchorEvent = true;
            }
            this.hasRefusedReanchorSinceLastAcceptance = false;
            levels = this.classify(
              frameDb,
              reanchoredFloor + this.config.adaptiveDeltaDb,
              reanchoredFloor + this.config.adaptiveContinuationDeltaDb,
              reanchoredFloor + VAD_SILENCE_DELTA_DB,
            );
          } else {
            this.hasRefusedReanchorSinceLastAcceptance = true;
            if (!this.hasLoggedReanchorRefusal) this.hasLoggedReanchorRefusal = true;
          }
        }
      }
    }
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      ...levels,
      isSpeech: levels.evidence === 'strong' || levels.evidence === 'continuing',
      thresholdDb: levels.strongThresholdDb,
      floorDb: this.floorDb,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
    });
  }

  processAdaptiveRefinement(frameDb, frameDuration) {
    this.adaptiveRefinementElapsed += Math.max(0, frameDuration);
    if (this.floorDb === null) {
      this.floorDb = VAD_FLOOR_MIN_DB;
    }

    const rollingPercentile = this.adaptiveRollingPercentile();
    const windowMax = this.adaptiveRollingMaxDb(VAD_ADAPTIVE_COLD_START_DISPERSION_WINDOW_S);
    const dispersionDb = (windowMax ?? frameDb) - (rollingPercentile ?? frameDb);
    this.coldStartSpeechShapedNow = dispersionDb
      >= this.config.adaptiveDeltaDb + VAD_SPEECH_CEILING_MARGIN_DB;

    if (!this.coldStartSpeechShapedNow
      && this.adaptiveRefinementElapsed >= VAD_ADAPTIVE_COLD_START_GRACE_S
      && rollingPercentile !== null) {
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
    // Cold-start refinement is capped at twice the minimum duration so it cannot
    // defer convergence without bound. This protects the idle case; sustained
    // dispersive ambient that onsets during refinement can still complete while
    // unconverged and pin the -80 dB floor, a documented limitation.
    if (this.coldStartConverged
      || this.adaptiveRefinementElapsed + CALIBRATION_COMPLETION_EPSILON_S
        >= 2 * VAD_ADAPTIVE_MIN_REFINEMENT_DURATION_S) {
      this.adaptiveRefinementComplete = true;
    }

    const currentFloor = this.floorDb ?? VAD_FLOOR_MIN_DB;
    const levels = this.classify(
      frameDb,
      currentFloor + this.config.adaptiveDeltaDb,
      currentFloor + this.config.adaptiveContinuationDeltaDb,
      currentFloor + VAD_SILENCE_DELTA_DB,
    );
    const isDeferredOnset = !this.coldStartConverged
      && !this.coldStartSpeechShapedNow
      && levels.evidence === 'strong';
    const evidence = isDeferredOnset ? 'ambiguous' : levels.evidence;
    const isSpeech = isDeferredOnset
      ? false
      : levels.evidence === 'strong' || levels.evidence === 'continuing';
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      ...levels,
      evidence,
      isSpeech,
      thresholdDb: levels.strongThresholdDb,
      continuationThresholdDb: levels.continuationThresholdDb,
      silenceThresholdDb: levels.silenceThresholdDb,
      floorDb: currentFloor,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
    });
  }

  updateFloorTracking(frameDb, duration, machineIsIdle = true) {
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
        riseCap = machineIsIdle ? VAD_ELEVATED_RISE_DB_PER_SECOND : 0;
        break;
      case 'ambiguous':
      case 'silence':
        riseCap = machineIsIdle ? VAD_ELEVATED_RISE_DB_PER_SECOND : 0;
        break;
      default:
        riseCap = machineIsIdle ? VAD_ELEVATED_RISE_DB_PER_SECOND : 0;
        break;
    }
    if (machineIsIdle && this.speechCeilingDb !== null) {
      const decayedCeilingDb = this.speechCeilingDb
        + VAD_ELEVATED_RISE_DB_PER_SECOND * Math.max(0, duration);
      const clampBound = decayedCeilingDb
        - this.config.adaptiveDeltaDb
        - VAD_SPEECH_CEILING_MARGIN_DB;
      this.speechCeilingDb = clampBound > VAD_FLOOR_MAX_DB - this.config.adaptiveDeltaDb
        ? null
        : decayedCeilingDb;
    }
    if (riseCap === 0 && this.adaptiveRollingPercentileAtLeast(this.floorDb)) return;
    const target = this.adaptiveRollingPercentile();
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
    this.thresholdDb = this.config.mode === 'adaptive'
      ? VAD_FLOOR_MIN_DB + this.config.adaptiveDeltaDb
      : dbFromRms(this.config.staticRms);
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
      continuationThresholdDb: this.config.mode === 'adaptive'
        ? VAD_FLOOR_MIN_DB + this.config.adaptiveContinuationDeltaDb
        : this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: this.config.mode === 'adaptive'
        ? VAD_FLOOR_MIN_DB + VAD_SILENCE_DELTA_DB
        : this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      floorDb: this.floorDb,
      calibrating: this.config.mode === 'calibrated',
      usedFallback: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
    };
  }

  updateFloor(targetDb, frameDuration, maximumRiseDbPerSecond) {
    let floor = this.floorDb;
    if (targetDb > floor) {
      floor = Math.min(targetDb, floor + maximumRiseDbPerSecond * frameDuration);
    } else {
      floor += (1 - Math.exp(-frameDuration / VAD_TAU_FALL_S))
        * (targetDb - floor);
    }
    if (this.speechCeilingDb !== null) {
      floor = Math.min(
        floor,
        this.speechCeilingDb - this.config.adaptiveDeltaDb - VAD_SPEECH_CEILING_MARGIN_DB,
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
    this.lastOutput = {
      ...this.lastOutput,
      thresholdDb: this.floorDb + this.config.adaptiveDeltaDb,
      continuationThresholdDb: this.floorDb + this.config.adaptiveContinuationDeltaDb,
      silenceThresholdDb: this.floorDb + VAD_SILENCE_DELTA_DB,
      floorDb: this.floorDb,
      usedFallback: this.usedFallback,
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
    const sortedDbs = this.calibrationFrames.map(frame => frame.db).sort((a, b) => a - b);
    const index = Math.floor(CALIBRATION_QUARTILE * (sortedDbs.length - 1));
    return sortedDbs[index];
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
    calibrating,
    retroactiveSpeechMs,
    trailingSilenceMs,
  }) {
    this.lastOutput = {
      isSpeech,
      evidence,
      thresholdDb: thresholdDb ?? strongThresholdDb,
      continuationThresholdDb,
      silenceThresholdDb,
      floorDb,
      calibrating,
      usedFallback: this.usedFallback,
      retroactiveSpeechMs,
      trailingSilenceMs,
    };
    return { ...this.lastOutput };
  }
}
