// Pure-logic JS mirror of StreamFormatNegotiation.

export const STREAM_AUDIO_FORMAT = Object.freeze({
  LEGACY_FLOAT32: 'f32le',
  AAC_M4A: 'aac-m4a',
  RESERVED_PCM16: 'pcm16',
});

export const STREAM_AUDIO_MODE = Object.freeze({
  FLOAT32_PCM: 'float32PCM',
  AAC_M4A: 'aacM4A',
});

export const STREAM_NEGOTIATION_DECISION = Object.freeze({
  WAIT: 'wait',
  SELECT: 'select',
  FALLBACK_IN_PLACE_AND_PIN_LEGACY: 'fallbackInPlaceAndPinLegacy',
  CLOSE_CONNECTION_AND_PIN_LEGACY: 'closeConnectionAndPinLegacy',
});

export const STREAM_SOURCE_SAMPLE_RATES = Object.freeze([16_000, 48_000]);

export function configMessage(sampleRate, aacEnabled, cleanupPreferences) {
  if (aacEnabled && !STREAM_SOURCE_SAMPLE_RATES.includes(sampleRate)) return null;

  const message = {
    type: 'CONFIG',
    format: aacEnabled
      ? STREAM_AUDIO_FORMAT.AAC_M4A
      : STREAM_AUDIO_FORMAT.LEGACY_FLOAT32,
  };
  if (aacEnabled) {
    message.sampleRate = sampleRate;
    message.channels = 1;
    message.bitrate = 64_000;
  }
  message.protocol = 2;
  forEachCleanupWireField(cleanupPreferences, (field, value) => {
    message[field] = value;
  });
  return JSON.stringify(message);
}

export function initialMode(configSent) {
  return configSent ? null : STREAM_AUDIO_MODE.FLOAT32_PCM;
}

export function shouldSendConfig(aacEnabled, sessionLegacyPinned, cleanupPreferences) {
  if (sessionLegacyPinned) return false;
  return aacEnabled || hasSelectedCleanupPreferences(cleanupPreferences);
}

export function timeoutDecision() {
  return {
    kind: STREAM_NEGOTIATION_DECISION.CLOSE_CONNECTION_AND_PIN_LEGACY,
    pinsSessionLegacy: true,
  };
}

export function decisionForServerMessage(text, aacEnabled, deadlineExpired = false) {
  const message = decodeServerMessage(text);
  if (!message) {
    return deadlineExpired
      ? timeoutDecision()
      : { kind: STREAM_NEGOTIATION_DECISION.WAIT };
  }

  if (message.type === 'error') {
    return {
      kind: STREAM_NEGOTIATION_DECISION.FALLBACK_IN_PLACE_AND_PIN_LEGACY,
      mode: STREAM_AUDIO_MODE.FLOAT32_PCM,
      pinsSessionLegacy: true,
    };
  }
  if (deadlineExpired) return timeoutDecision();

  if (message.type === 'CONFIG_ACK') {
    const requestedFormat = aacEnabled
      ? STREAM_AUDIO_FORMAT.AAC_M4A
      : STREAM_AUDIO_FORMAT.LEGACY_FLOAT32;
    if (message.format !== requestedFormat || message.protocol !== 2) {
      return { kind: STREAM_NEGOTIATION_DECISION.WAIT };
    }
    return {
      kind: STREAM_NEGOTIATION_DECISION.SELECT,
      mode: aacEnabled ? STREAM_AUDIO_MODE.AAC_M4A : STREAM_AUDIO_MODE.FLOAT32_PCM,
    };
  }

  return { kind: STREAM_NEGOTIATION_DECISION.WAIT };
}

function hasSelectedCleanupPreferences(cleanupPreferences) {
  let hasSelectedValue = false;
  forEachCleanupWireField(cleanupPreferences, () => {
    hasSelectedValue = true;
  });
  return hasSelectedValue;
}

function forEachCleanupWireField(cleanupPreferences, body) {
  if (cleanupPreferences.styling !== 'serverDefault') {
    body('cleanup_styling', cleanupPreferences.styling);
  }
  if (cleanupPreferences.structure !== 'serverDefault') {
    body('cleanup_structure', cleanupPreferences.structure);
  }
  if (cleanupPreferences.context !== 'serverDefault') {
    body('cleanup_context', cleanupPreferences.context);
  }
}

function decodeServerMessage(text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    return null;
  }
  if (message === null || typeof message !== 'object' || Array.isArray(message)
      || typeof message.type !== 'string'
      || !isValidOptionalString(message.format)
      || !isValidOptionalInteger(message.protocol)) {
    return null;
  }
  return message;
}

function isValidOptionalString(value) {
  return value === undefined || value === null || typeof value === 'string';
}

function isValidOptionalInteger(value) {
  return value === undefined || value === null || Number.isInteger(value);
}
