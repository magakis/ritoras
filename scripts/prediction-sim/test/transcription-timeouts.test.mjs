import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_TIMEOUT_SECONDS,
  STREAM_FINAL_TIMEOUT_SECONDS,
  STREAM_HEALTH_CHECK_INTERVAL_SECONDS,
  STREAM_LIVENESS_SILENCE_WINDOW_SECONDS,
  STREAM_MAX_MISSED_PONGS,
  STREAM_WS_CONNECT_TIMEOUT_SECONDS,
  SUBMIT_TIMEOUT_RETRY_COUNT,
  TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS,
  isRetryableConnectionFailure,
  pollDeadline,
  retryElapsedWindow,
  routeTranscriptionTimeoutBudget,
  shouldAutoRetry,
  submitTimeout,
  submitTimeoutRetryDelay,
  syncRequestTimeout,
} from '../lib/transcription-timeouts.mjs';

describe('duration-scaled transcription timeouts', () => {
  it('keeps the configured submit and poll floors for short recordings', () => {
    assert.strictEqual(submitTimeout({ recordingDurationSeconds: 30 }), DEFAULT_TIMEOUT_SECONDS);
    assert.strictEqual(submitTimeout({ baseTimeoutSeconds: 30, recordingDurationSeconds: 30 }), 30);
    assert.strictEqual(pollDeadline(30), 600);
  });

  it('scales a 20-minute recording to a 120-second submit and 2400-second poll deadline', () => {
    assert.strictEqual(submitTimeout({ recordingDurationSeconds: 20 * 60 }), 120);
    assert.strictEqual(pollDeadline(20 * 60), 2400);
  });

  it('sets the sync timeout to at least the scaled poll deadline', () => {
    assert.strictEqual(syncRequestTimeout({ recordingDurationSeconds: 20 * 60 }), 2400);
    assert.strictEqual(syncRequestTimeout({
      baseTimeoutSeconds: 3600,
      recordingDurationSeconds: 20 * 60,
    }), 3600);
  });

  it('uses exponential submit-timeout resubmission backoff', () => {
    assert.strictEqual(SUBMIT_TIMEOUT_RETRY_COUNT, 2);
    assert.deepStrictEqual(
      Array.from({ length: SUBMIT_TIMEOUT_RETRY_COUNT }, (_, index) => submitTimeoutRetryDelay(index + 1)),
      [1, 2],
    );
  });

  it('composes route budget from polling, sync fallback, retry delays, and server probes', () => {
    assert.strictEqual(routeTranscriptionTimeoutBudget({ recordingDurationSeconds: 30 }), 669);
    assert.strictEqual(routeTranscriptionTimeoutBudget({ recordingDurationSeconds: 20 * 60 }), 2769);
  });

  it('clamps negative and non-finite recording durations to zero', () => {
    for (const recordingDurationSeconds of [-1, Number.NaN, Number.POSITIVE_INFINITY]) {
      assert.strictEqual(submitTimeout({ recordingDurationSeconds }), DEFAULT_TIMEOUT_SECONDS);
      assert.strictEqual(pollDeadline(recordingDurationSeconds), 600);
    }
  });
});

describe('streaming transcription timeouts', () => {
  it('uses 32-second WebSocket connect and 120-second final/drain waits', () => {
    assert.strictEqual(STREAM_WS_CONNECT_TIMEOUT_SECONDS, 32);
    assert.strictEqual(STREAM_FINAL_TIMEOUT_SECONDS, 120);
  });

  it('derives the 60-second liveness window from the ping cadence and missed intervals', () => {
    assert.strictEqual(STREAM_HEALTH_CHECK_INTERVAL_SECONDS, 5);
    assert.strictEqual(STREAM_MAX_MISSED_PONGS, 12);
    assert.strictEqual(
      STREAM_LIVENESS_SILENCE_WINDOW_SECONDS,
      STREAM_HEALTH_CHECK_INTERVAL_SECONDS * STREAM_MAX_MISSED_PONGS,
    );
    assert.strictEqual(STREAM_LIVENESS_SILENCE_WINDOW_SECONDS, 60);
  });
});

describe('transcription auto-retry policy', () => {
  it('admits a timeout attempt within its route budget and rejects attempts beyond it', () => {
    const options = {
      error: { kind: 'timeout' },
      attemptsRemain: true,
      recordingDurationSeconds: 20 * 60,
    };
    const routeBudget = routeTranscriptionTimeoutBudget(options);

    assert.strictEqual(retryElapsedWindow(options), routeBudget);
    assert.strictEqual(shouldAutoRetry({ ...options, attemptElapsedSeconds: routeBudget - 1 }), true);
    assert.strictEqual(shouldAutoRetry({ ...options, attemptElapsedSeconds: routeBudget }), false);
    assert.strictEqual(shouldAutoRetry({ ...options, attemptElapsedSeconds: routeBudget + 1 }), false);
  });

  it('keeps ordinary retryable errors on the five-second fast-fail window', () => {
    const error = { kind: 'allServersFailed' };
    const options = {
      error,
      attemptsRemain: true,
      attemptElapsedSeconds: TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS - 0.001,
      recordingDurationSeconds: 20 * 60,
    };

    assert.strictEqual(retryElapsedWindow(options), TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS);
    assert.strictEqual(shouldAutoRetry(options), true);
    assert.strictEqual(shouldAutoRetry({
      ...options,
      attemptElapsedSeconds: TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS,
    }), false);
  });

  it('classifies timeout as retryable and serverUnreachable as non-retryable', () => {
    assert.strictEqual(isRetryableConnectionFailure({ kind: 'timeout' }), true);
    assert.strictEqual(isRetryableConnectionFailure({ kind: 'serverUnreachable' }), false);
  });

  it('mirrors the retryable URL error code allowlist', () => {
    for (const urlErrorCode of [
      'cannotConnectToHost',
      'cannotFindHost',
      'dnsLookupFailed',
      'networkConnectionLost',
      'notConnectedToInternet',
      'timedOut',
    ]) {
      assert.strictEqual(isRetryableConnectionFailure({ kind: 'networkError', urlErrorCode }), true);
    }
    assert.strictEqual(isRetryableConnectionFailure({
      kind: 'networkError',
      urlErrorCode: 'cancelled',
    }), false);
  });
});
