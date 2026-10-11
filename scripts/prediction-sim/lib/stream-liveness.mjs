// Pure-logic JS mirror of WhisperStreamClient.StreamLivenessEvaluator.

import {
  STREAM_HEALTH_CHECK_INTERVAL_SECONDS,
  STREAM_MAX_MISSED_PONGS,
} from './transcription-timeouts.mjs';

export const STREAM_UPLOAD_WINDOW_MINIMUM_BYTES = 1_000_000;
export const STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS = 30;

export class StreamLivenessEvaluator {
  #lastActivityAt = Number.NEGATIVE_INFINITY;
  #lastPongAt = Number.NEGATIVE_INFINITY;
  #lastFinalAt = null;
  #endSentAt = null;
  #receivedFinal = false;
  #uploadWindowOpenedAt = null;
  // A lapse cannot be renewed by sends alone; tier-appropriate evidence clears this.
  #uploadWindowReopenBlocked = false;
  // Cumulative pause credit and the portion already preceding current evidence.
  #completedUploadPauseSeconds = 0;
  #uploadPauseCreditAtEvidence = 0;

  markConnected({ at }) {
    this.#lastActivityAt = at;
    this.#uploadPauseCreditAtEvidence = this.#completedUploadPauseSeconds;
  }

  frameEnqueued({
    bytes,
    at,
    minimumBytes = STREAM_UPLOAD_WINDOW_MINIMUM_BYTES,
    maxAge = STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS,
  }) {
    const events = this.#expireUploadWindowIfNeeded({ at, maxAge });
    if (bytes >= minimumBytes
        && this.#uploadWindowOpenedAt === null
        && !this.#uploadWindowReopenBlocked
        && !this.#receivedFinal) {
      this.#uploadWindowOpenedAt = at;
      events.opened = true;
    }
    return events;
  }

  markEndSent({ at, maxAge = STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS }) {
    const events = this.#expireUploadWindowIfNeeded({ at, maxAge });
    if (this.#endSentAt === null) {
      this.#endSentAt = at;
      this.#uploadPauseCreditAtEvidence = this.#completedUploadPauseSeconds;
    }
    return events;
  }

  partialReceived({ at, maxAge = STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS }) {
    const events = this.#expireUploadWindowIfNeeded({ at, maxAge });
    const closesWindow = this.#endSentAt === null
      && this.#closeUploadWindow({ at, maxAge });
    this.#lastActivityAt = at;
    if (this.#endSentAt === null) {
      this.#uploadPauseCreditAtEvidence = this.#completedUploadPauseSeconds;
      this.#uploadWindowReopenBlocked = false;
      events.closed = closesWindow;
    }
    return events;
  }

  pongReceived({ at, maxAge = STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS }) {
    const events = this.#expireUploadWindowIfNeeded({ at, maxAge });
    events.closed = this.#closeUploadWindow({ at, maxAge });
    this.#lastPongAt = at;
    this.#lastActivityAt = at;
    this.#uploadPauseCreditAtEvidence = this.#completedUploadPauseSeconds;
    this.#uploadWindowReopenBlocked = false;
    return events;
  }

  finalReceived({ at, maxAge = STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS }) {
    const events = this.#expireUploadWindowIfNeeded({ at, maxAge });
    this.#receivedFinal = true;
    if (this.#endSentAt !== null) {
      events.closed = this.#closeUploadWindow({ at, maxAge });
      this.#uploadWindowReopenBlocked = false;
    }
    this.#lastFinalAt = at;
    this.#uploadPauseCreditAtEvidence = this.#completedUploadPauseSeconds;
    return events;
  }

  evaluate({
    at,
    interval = STREAM_HEALTH_CHECK_INTERVAL_SECONDS,
    maxMissedPongs = STREAM_MAX_MISSED_PONGS,
    maxUploadWindowAge = STREAM_UPLOAD_WINDOW_MAX_AGE_SECONDS,
  }) {
    const windowEvents = this.#expireUploadWindowIfNeeded({ at, maxAge: maxUploadWindowAge });
    const evidenceAt = this.#currentEvidenceAt();
    const currentUploadPauseSeconds = this.#currentUploadPauseSeconds({
      at,
      evidenceAt,
      maxAge: maxUploadWindowAge,
    });
    const secondsSinceEvidence = Math.max(
      0,
      at - evidenceAt
        - (this.#completedUploadPauseSeconds - this.#uploadPauseCreditAtEvidence)
        - currentUploadPauseSeconds,
    );

    return {
      endSent: this.#endSentAt !== null,
      receivedFinal: this.#receivedFinal,
      secondsSinceEvidence,
      shouldTimeout: !this.#receivedFinal
        && secondsSinceEvidence >= interval * maxMissedPongs,
      windowOpen: this.#uploadWindowOpenedAt !== null,
      windowEvents,
    };
  }

  #currentEvidenceAt() {
    return this.#endSentAt === null
      ? this.#lastActivityAt
      : Math.max(this.#endSentAt, this.#lastPongAt, this.#lastFinalAt ?? Number.NEGATIVE_INFINITY);
  }

  #closeUploadWindow({ at, maxAge }) {
    if (this.#uploadWindowOpenedAt === null) return false;

    const pausedUntil = Math.min(at, this.#uploadWindowOpenedAt + maxAge);
    const pausedFrom = Math.max(this.#uploadWindowOpenedAt, this.#currentEvidenceAt());
    if (pausedUntil > pausedFrom) {
      this.#completedUploadPauseSeconds += pausedUntil - pausedFrom;
    }
    this.#uploadWindowOpenedAt = null;
    return true;
  }

  #expireUploadWindowIfNeeded({ at, maxAge }) {
    const events = { opened: false, closed: false, lapsed: false };
    if (this.#uploadWindowOpenedAt === null) return events;

    const deadline = this.#uploadWindowOpenedAt + maxAge;
    if (at < deadline) return events;

    const pausedFrom = Math.max(this.#uploadWindowOpenedAt, this.#currentEvidenceAt());
    if (deadline > pausedFrom) {
      this.#completedUploadPauseSeconds += deadline - pausedFrom;
    }
    this.#uploadWindowOpenedAt = null;
    this.#uploadWindowReopenBlocked = true;
    events.lapsed = true;
    return events;
  }

  #currentUploadPauseSeconds({ at, evidenceAt, maxAge }) {
    if (this.#uploadWindowOpenedAt === null) return 0;

    const pausedFrom = Math.max(this.#uploadWindowOpenedAt, evidenceAt);
    const pausedUntil = Math.min(at, this.#uploadWindowOpenedAt + maxAge);
    return Math.max(0, pausedUntil - pausedFrom);
  }
}
