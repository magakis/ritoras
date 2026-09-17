// Pure-logic JS mirror of VADMode, VADGateConfig, VADGateOutput, and
// VADThresholdGate in shared/VADGate.swift, plus AudioMath in
// shared/AudioMath.swift. Kept in sync per AGENTS.md → Test policy.

export const VAD_TAU_FALL_S = 0.5;
export const VAD_TAU_RISE_S = 7.0;
const VAD_CONTINUATION_DELTA_DB = 6.0;
export const VAD_SILENCE_DELTA_DB = 3.0;
export const VAD_STATIC_CONTINUATION_OFFSET_DB = 4.0;
export const VAD_STATIC_SILENCE_OFFSET_DB = 6.0;
export const VAD_MAX_RISE_DB_PER_SECOND = 1.5;
export const VAD_STABLE_SILENCE_FOR_ADAPTATION_S = 0.3;
export const VAD_FLOOR_MIN_DB = -80;
export const VAD_FLOOR_MAX_DB = -20;
export const CALIBRATION_QUARTILE = 0.25;
export const QUIET_BAND_DB = 6.0;
export const ADAPTIVE_SEED_FRAMES = 6;
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
    this.adaptiveSeedDbs = [];
    this.adaptiveSeedComplete = this.config.mode !== 'adaptive';
    this.adaptiveSeedLocked = false;
    this.floorDb = null;
    this.thresholdDb = dbFromRms(this.config.staticRms);
    this.usedFallback = false;
    this.pendingRetroactiveSpeechMs = 0;
    this.pendingTrailingSilenceMs = null;
    this.idleSilenceElapsed = 0;
    this.requiresStableSilence = false;
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
      thresholdDb: this.thresholdDb,
      continuationThresholdDb: this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      floorDb: null,
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
      this.adaptiveSeedDbs.length = 0;
      this.adaptiveSeedComplete = true;
      this.adaptiveSeedLocked = false;
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
    if (!this.adaptiveSeedComplete) {
      return this.processAdaptiveSeed(frameDb);
    }

    if (this.floorDb === null) {
      this.adaptiveSeedComplete = false;
      return this.processAdaptiveSeed(frameDb);
    }

    const levels = this.classify(
      frameDb,
      this.floorDb + this.config.adaptiveDeltaDb,
      this.floorDb + this.config.adaptiveContinuationDeltaDb,
      this.floorDb + VAD_SILENCE_DELTA_DB,
    );
    this.noteEvidence(levels.evidence);
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

  processAdaptiveSeed(frameDb) {
    this.adaptiveSeedDbs.push(frameDb);
    const runningMinimum = Math.min(...this.adaptiveSeedDbs);
    const runningFloor = this.clampFloor(runningMinimum);
    const levels = this.classify(
      frameDb,
      runningMinimum + this.config.adaptiveDeltaDb,
      runningMinimum + this.config.adaptiveContinuationDeltaDb,
      runningMinimum + VAD_SILENCE_DELTA_DB,
    );
    if (!this.adaptiveSeedLocked) this.floorDb = runningFloor;
    this.noteEvidence(levels.evidence);
    if (levels.evidence === 'strong' || levels.evidence === 'continuing') {
      this.adaptiveSeedLocked = true;
    }

    if (this.adaptiveSeedDbs.length >= ADAPTIVE_SEED_FRAMES) {
      this.adaptiveSeedComplete = true;
      this.adaptiveSeedDbs.length = 0;
    }

    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      ...levels,
      isSpeech: levels.evidence === 'strong' || levels.evidence === 'continuing',
      thresholdDb: (this.floorDb ?? runningFloor) + this.config.adaptiveDeltaDb,
      continuationThresholdDb: (this.floorDb ?? runningFloor) + this.config.adaptiveContinuationDeltaDb,
      silenceThresholdDb: (this.floorDb ?? runningFloor) + VAD_SILENCE_DELTA_DB,
      floorDb: this.floorDb ?? runningFloor,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
    });
  }

  updateFloorIfIdle(frameDb, duration) {
    if (this.behaviorMode !== 'adaptive' || this.floorDb === null) return;
    const levels = this.classify(
      frameDb,
      this.floorDb + this.config.adaptiveDeltaDb,
      this.floorDb + this.config.adaptiveContinuationDeltaDb,
      this.floorDb + VAD_SILENCE_DELTA_DB,
    );
    if (levels.evidence !== 'silence') {
      this.idleSilenceElapsed = 0;
      return;
    }

    this.idleSilenceElapsed += duration;
    if (this.requiresStableSilence && this.idleSilenceElapsed + CALIBRATION_COMPLETION_EPSILON_S < VAD_STABLE_SILENCE_FOR_ADAPTATION_S) {
      return;
    }
    this.updateFloor(frameDb, duration);
    this.refreshAdaptiveOutput();
  }

  recalibrateFloor() {
    if (this.config.mode === 'static') return;
    if (this.config.mode === 'adaptive') {
      this.behaviorMode = 'adaptive';
      this.adaptiveSeedDbs.length = 0;
      this.adaptiveSeedComplete = false;
      this.adaptiveSeedLocked = false;
      this.floorDb = null;
    } else {
      this.behaviorMode = 'calibrated';
      this.calibrationFinished = false;
      this.calibrationElapsed = 0;
      this.calibrationFrames.length = 0;
      this.pendingRetroactiveSpeechMs = 0;
      this.pendingTrailingSilenceMs = null;
      this.floorDb = null;
      this.adaptiveSeedDbs.length = 0;
      this.adaptiveSeedComplete = false;
      this.adaptiveSeedLocked = false;
    }
    this.thresholdDb = dbFromRms(this.config.staticRms);
    this.idleSilenceElapsed = 0;
    this.requiresStableSilence = false;
    this.usedFallback = false;
    this.lastOutput = {
      isSpeech: false,
      evidence: 'silence',
      thresholdDb: this.thresholdDb,
      continuationThresholdDb: this.thresholdDb - VAD_STATIC_CONTINUATION_OFFSET_DB,
      silenceThresholdDb: this.thresholdDb - VAD_STATIC_SILENCE_OFFSET_DB,
      floorDb: null,
      calibrating: this.config.mode === 'calibrated',
      usedFallback: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
    };
  }

  updateFloor(frameDb, frameDuration) {
    const tau = frameDb < this.floorDb ? VAD_TAU_FALL_S : VAD_TAU_RISE_S;
    const alpha = 1 - Math.exp(-frameDuration / tau);
    const proposed = this.floorDb + alpha * (frameDb - this.floorDb);
    const next = proposed > this.floorDb
      ? Math.min(proposed, this.floorDb + VAD_MAX_RISE_DB_PER_SECOND * frameDuration)
      : proposed;
    this.floorDb = this.clampFloor(next);
  }

  noteEvidence(evidence) {
    if (evidence === 'strong' || evidence === 'continuing') {
      this.requiresStableSilence = true;
      this.idleSilenceElapsed = 0;
    }
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
