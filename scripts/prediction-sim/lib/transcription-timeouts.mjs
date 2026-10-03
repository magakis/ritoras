// Pure-logic JS port of SharedConfig.AsyncTranscription and WhisperError retry rules.
// Kept in sync per AGENTS.md -> Test policy.

export const DEFAULT_TIMEOUT_SECONDS = 20;
export const TOTAL_POLL_DEADLINE_SECONDS = 600;
export const SUBMIT_TIMEOUT_PER_RECORDING_SECOND = 0.1;
export const POLL_DEADLINE_PER_RECORDING_SECOND = 2.0;
export const SUBMIT_TIMEOUT_RETRY_COUNT = 2;
export const SUBMIT_TIMEOUT_RETRY_BACKOFF_SECONDS = 1;
export const SERVER_PROBE_TIMEOUT_SECONDS = 3;
export const TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS = 5;

const RETRYABLE_URL_ERROR_CODES = new Set([
  'cannotConnectToHost',
  'cannotFindHost',
  'dnsLookupFailed',
  'networkConnectionLost',
  'notConnectedToInternet',
  'timedOut',
]);

export function submitTimeout({
  baseTimeoutSeconds = DEFAULT_TIMEOUT_SECONDS,
  recordingDurationSeconds,
}) {
  return Math.max(
    baseTimeoutSeconds,
    nonnegativeRecordingDuration(recordingDurationSeconds)
      * SUBMIT_TIMEOUT_PER_RECORDING_SECOND,
  );
}

export function pollDeadline(recordingDurationSeconds) {
  return Math.max(
    TOTAL_POLL_DEADLINE_SECONDS,
    nonnegativeRecordingDuration(recordingDurationSeconds)
      * POLL_DEADLINE_PER_RECORDING_SECOND,
  );
}

export function syncRequestTimeout({
  baseTimeoutSeconds = DEFAULT_TIMEOUT_SECONDS,
  recordingDurationSeconds,
}) {
  return Math.max(baseTimeoutSeconds, pollDeadline(recordingDurationSeconds));
}

export function submitTimeoutRetryDelay(retryNumber) {
  return SUBMIT_TIMEOUT_RETRY_BACKOFF_SECONDS * 2 ** (retryNumber - 1);
}

export function routeTranscriptionTimeoutBudget({
  baseTimeoutSeconds = DEFAULT_TIMEOUT_SECONDS,
  recordingDurationSeconds,
}) {
  const currentSubmitTimeout = submitTimeout({ baseTimeoutSeconds, recordingDurationSeconds });
  const pollBudget = currentSubmitTimeout + pollDeadline(recordingDurationSeconds);

  let retryBackoffBudget = 0;
  for (let retryNumber = 1; retryNumber <= SUBMIT_TIMEOUT_RETRY_COUNT; retryNumber += 1) {
    retryBackoffBudget += submitTimeoutRetryDelay(retryNumber);
  }

  const syncFallbackBudget = currentSubmitTimeout * (SUBMIT_TIMEOUT_RETRY_COUNT + 1)
    + retryBackoffBudget
    + syncRequestTimeout({ baseTimeoutSeconds, recordingDurationSeconds });
  const serverSelectionBudget = SERVER_PROBE_TIMEOUT_SECONDS * 2;

  return Math.max(pollBudget, syncFallbackBudget) + serverSelectionBudget;
}

export function isRetryableConnectionFailure(error) {
  switch (error?.kind) {
    case 'timeout':
    case 'allServersFailed':
      return true;
    case 'networkError':
      return RETRYABLE_URL_ERROR_CODES.has(error.urlErrorCode);
    default:
      return false;
  }
}

export function retryElapsedWindow({
  error,
  baseTimeoutSeconds = DEFAULT_TIMEOUT_SECONDS,
  recordingDurationSeconds,
}) {
  if (error?.kind !== 'timeout') return TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS;

  return Math.max(
    TRANSCRIPTION_FAST_FAIL_WINDOW_SECONDS,
    routeTranscriptionTimeoutBudget({ baseTimeoutSeconds, recordingDurationSeconds }),
  );
}

export function shouldAutoRetry({
  error,
  attemptElapsedSeconds,
  attemptsRemain,
  isCancelled = false,
  baseTimeoutSeconds = DEFAULT_TIMEOUT_SECONDS,
  recordingDurationSeconds,
}) {
  if (isCancelled || !isRetryableConnectionFailure(error) || !attemptsRemain) return false;

  return attemptElapsedSeconds < retryElapsedWindow({
    error,
    baseTimeoutSeconds,
    recordingDurationSeconds,
  });
}

function nonnegativeRecordingDuration(duration) {
  return Number.isFinite(duration) ? Math.max(0, duration) : 0;
}
