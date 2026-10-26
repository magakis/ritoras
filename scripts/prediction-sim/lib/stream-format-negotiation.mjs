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

export function configMessage(sampleRate) {
  if (!STREAM_SOURCE_SAMPLE_RATES.includes(sampleRate)) return null;
  return JSON.stringify({
    type: 'CONFIG',
    format: STREAM_AUDIO_FORMAT.AAC_M4A,
    sampleRate,
    channels: 1,
    bitrate: 64_000,
    protocol: 2,
  });
}

export function initialMode(aacEnabled) {
  return aacEnabled ? null : STREAM_AUDIO_MODE.FLOAT32_PCM;
}

export function shouldSendConfig(aacEnabled, sessionLegacyPinned) {
  return aacEnabled && !sessionLegacyPinned;
}

export function timeoutDecision() {
  return {
    kind: STREAM_NEGOTIATION_DECISION.CLOSE_CONNECTION_AND_PIN_LEGACY,
    pinsSessionLegacy: true,
  };
}

export function decisionForServerMessage(text, aacEnabled, deadlineExpired = false) {
  if (!aacEnabled) {
    return { kind: STREAM_NEGOTIATION_DECISION.SELECT, mode: STREAM_AUDIO_MODE.FLOAT32_PCM };
  }

  let message;
  try {
    message = JSON.parse(text);
  } catch {
    return deadlineExpired
      ? timeoutDecision()
      : { kind: STREAM_NEGOTIATION_DECISION.WAIT };
  }
  if (message === null || typeof message !== 'object' || Array.isArray(message)) {
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
    if (message.format !== STREAM_AUDIO_FORMAT.AAC_M4A
        || !Number.isInteger(message.protocol)
        || message.protocol !== 2) {
      return { kind: STREAM_NEGOTIATION_DECISION.WAIT };
    }
    return { kind: STREAM_NEGOTIATION_DECISION.SELECT, mode: STREAM_AUDIO_MODE.AAC_M4A };
  }

  return { kind: STREAM_NEGOTIATION_DECISION.WAIT };
}
