// Pure-logic JS mirror of VADMode, VADGateConfig, VADGateOutput, and
// VADThresholdGate in shared/VADGate.swift, plus AudioMath in
// shared/AudioMath.swift. Kept in sync per AGENTS.md → Test policy.

export const VAD_TAU_FALL_S = 0.5;
export const VAD_TAU_RISE_S = 7.0;
export const VAD_HYSTERESIS_BUMP_DB = 3.0;
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
    adaptiveHysteresisEnabled: true,
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
    this.inSpeech = false;
    this.floorDb = null;
    this.thresholdDb = dbFromRms(this.config.staticRms);
    this.usedFallback = false;
    this.pendingRetroactiveSpeechMs = 0;
    this.pendingTrailingSilenceMs = null;
    this.lastOutput = {
      isSpeech: false,
      thresholdDb: this.thresholdDb,
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
    const isSpeech = frameDb >= this.thresholdDb;
    return this.emit({
      isSpeech,
      thresholdDb: this.thresholdDb,
      floorDb: null,
      calibrating: false,
      retroactiveSpeechMs: 0,
      trailingSilenceMs: null,
    });
  }

  processCalibration(frameDb, frameDuration) {
    this.calibrationFrames.push({ db: frameDb, duration: frameDuration });
    this.calibrationElapsed += frameDuration;
    // Tolerate the representation error from summing frame durations such
    // as ten 0.1-second frames without changing the elapsed-time boundary.
    if (this.calibrationElapsed + CALIBRATION_COMPLETION_EPSILON_S >= this.config.calibrationMs / 1000) {
      this.finishCalibration();
    }

    // Every frame in the window is held as non-speech. The threshold is only
    // reported for diagnostics; the calibrated floor remains null until the
    // window has ended. The running Q1 gives an interim value after the first
    // frame, while the running minimum is the empty-window fallback.
    return this.emit({
      isSpeech: false,
      thresholdDb: this.calibrationThresholdDb(),
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
      // A contaminated window starts Adaptive from its measured Q1 rather
      // than collecting a second seed window, so calibration cannot gate
      // away speech that occurred during the first window.
      const seededFloor = this.clampFloor(q1);
      this.floorDb = seededFloor;
      this.thresholdDb = seededFloor + this.config.adaptiveDeltaDb;
      this.adaptiveSeedDbs.length = 0;
      this.adaptiveSeedComplete = true;
      this.inSpeech = false;
      this.behaviorMode = 'adaptive';
      this.usedFallback = true;
    }
    this.calibrationFinished = true;
  }

  processCalibrated(frameDb) {
    const isSpeech = frameDb >= this.thresholdDb;
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      isSpeech,
      thresholdDb: this.thresholdDb,
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
      // This is only reachable before the first adaptive seed frame. Keep
      // the interim behavior identical to the running-min seed path.
      this.adaptiveSeedComplete = false;
      return this.processAdaptiveSeed(frameDb);
    }

    const currentFloor = this.floorDb;
    const startDb = currentFloor + this.config.adaptiveDeltaDb;
    const continueDb = this.config.adaptiveHysteresisEnabled
      ? startDb + VAD_HYSTERESIS_BUMP_DB
      : startDb;
    const decisionThreshold = this.inSpeech ? continueDb : startDb;
    const isSpeech = frameDb >= decisionThreshold;
    this.inSpeech = isSpeech;

    if (!isSpeech) {
      this.updateFloor(frameDb, frameDuration);
    }

    const outputFloor = this.floorDb;
    const outputStartDb = outputFloor + this.config.adaptiveDeltaDb;
    const outputThreshold = this.inSpeech && this.config.adaptiveHysteresisEnabled
      ? outputStartDb + VAD_HYSTERESIS_BUMP_DB
      : outputStartDb;
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      isSpeech,
      thresholdDb: outputThreshold,
      floorDb: outputFloor,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
    });
  }

  processAdaptiveSeed(frameDb) {
    this.adaptiveSeedDbs.push(frameDb);
    const runningMinimum = Math.min(...this.adaptiveSeedDbs);
    const runningFloor = this.clampFloor(runningMinimum);
    // Before the sixth frame, decisions use the raw running minimum. The
    // exposed floor is clamped, and the sixth frame makes that clamped
    // value the steady-state floor.
    const startDb = runningMinimum + this.config.adaptiveDeltaDb;
    const continueDb = this.config.adaptiveHysteresisEnabled
      ? startDb + VAD_HYSTERESIS_BUMP_DB
      : startDb;
    const decisionThreshold = this.inSpeech ? continueDb : startDb;
    const isSpeech = frameDb >= decisionThreshold;
    this.inSpeech = isSpeech;
    this.floorDb = runningFloor;

    if (this.adaptiveSeedDbs.length >= ADAPTIVE_SEED_FRAMES) {
      this.adaptiveSeedComplete = true;
      this.adaptiveSeedDbs.length = 0;
    }

    const outputThreshold = this.inSpeech && this.config.adaptiveHysteresisEnabled
      ? runningFloor + this.config.adaptiveDeltaDb + VAD_HYSTERESIS_BUMP_DB
      : runningFloor + this.config.adaptiveDeltaDb;
    const [retroactiveSpeechMs, trailingSilenceMs] = this.takeRetroactiveCredit();
    return this.emit({
      isSpeech,
      thresholdDb: outputThreshold,
      floorDb: runningFloor,
      calibrating: false,
      retroactiveSpeechMs,
      trailingSilenceMs,
    });
  }

  updateFloor(frameDb, frameDuration) {
    const tau = frameDb < this.floorDb ? VAD_TAU_FALL_S : VAD_TAU_RISE_S;
    const alpha = 1 - Math.exp(-frameDuration / tau);
    this.floorDb = this.clampFloor(
      this.floorDb + alpha * (frameDb - this.floorDb),
    );
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
    isSpeech,
    thresholdDb,
    floorDb,
    calibrating,
    retroactiveSpeechMs,
    trailingSilenceMs,
  }) {
    this.lastOutput = {
      isSpeech,
      thresholdDb,
      floorDb,
      calibrating,
      usedFallback: this.usedFallback,
      retroactiveSpeechMs,
      trailingSilenceMs,
    };
    return { ...this.lastOutput };
  }
}
