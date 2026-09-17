// Pure-logic mirror of the profile resolution in shared/Config.swift.

export const VADSensitivityProfile = Object.freeze({
  automatic: 'automatic',
  quietVoice: 'quietVoice',
  noisyEnvironment: 'noisyEnvironment',
});

export const VADPauseProfile = Object.freeze({
  fast: 'fast',
  balanced: 'balanced',
  long: 'long',
});

export const VAD_PROFILE_DEFAULTS = Object.freeze({
  sensitivity: VADSensitivityProfile.automatic,
  pause: VADPauseProfile.balanced,
  strongDeltaDb: 10,
  continuingDeltaDb: 6,
  silenceDeltaDb: 3,
  legacySilenceMs: 2000,
});

const SENSITIVITY_VALUES = Object.freeze({
  automatic: { strongDeltaDb: 10, continuingDeltaDb: 6 },
  quietVoice: { strongDeltaDb: 7, continuingDeltaDb: 4 },
  noisyEnvironment: { strongDeltaDb: 13, continuingDeltaDb: 8 },
});

const PAUSE_DURATIONS_MS = Object.freeze({
  fast: 450,
  balanced: 700,
  long: 1100,
});

function clampAdaptiveDeltaDb(value) {
  return Math.min(Math.max(value, 3), 24);
}

export function resolveSensitivity({
  profile = VAD_PROFILE_DEFAULTS.sensitivity,
  rawAdaptiveDeltaDb,
  rawOverrideExplicit = false,
} = {}) {
  const selectedProfile = SENSITIVITY_VALUES[profile]
    ? profile
    : VAD_PROFILE_DEFAULTS.sensitivity;
  const values = SENSITIVITY_VALUES[selectedProfile];
  const strongDeltaDb = Number.isFinite(rawAdaptiveDeltaDb)
    && (rawOverrideExplicit || rawAdaptiveDeltaDb !== VAD_PROFILE_DEFAULTS.strongDeltaDb)
    ? clampAdaptiveDeltaDb(rawAdaptiveDeltaDb)
    : values.strongDeltaDb;

  return {
    profile: selectedProfile,
    strongDeltaDb,
    continuingDeltaDb: values.continuingDeltaDb,
    silenceDeltaDb: VAD_PROFILE_DEFAULTS.silenceDeltaDb,
  };
}

export function legacySilenceToPauseProfile(value) {
  const clampedValue = Math.min(Math.max(value, 0), 5000);
  if (clampedValue < 575) return VADPauseProfile.fast;
  if (clampedValue <= 900) return VADPauseProfile.balanced;
  return VADPauseProfile.long;
}

export function resolvePauseProfile({
  profile,
  legacySilenceMs,
} = {}) {
  const hasProfile = Object.prototype.hasOwnProperty.call(PAUSE_DURATIONS_MS, profile);
  const selectedProfile = hasProfile
    ? profile
    : (Number.isFinite(legacySilenceMs) && legacySilenceMs !== VAD_PROFILE_DEFAULTS.legacySilenceMs
      ? legacySilenceToPauseProfile(legacySilenceMs)
      : VAD_PROFILE_DEFAULTS.pause);

  return {
    profile: selectedProfile,
    silenceMs: PAUSE_DURATIONS_MS[selectedProfile],
  };
}

export function resolveVadProfiles({
  sensitivityProfile,
  pauseProfile,
  rawAdaptiveDeltaDb,
  rawAdaptiveDeltaOverride = false,
  legacySilenceMs,
} = {}) {
  return {
    sensitivity: resolveSensitivity({
      profile: sensitivityProfile,
      rawAdaptiveDeltaDb,
      rawOverrideExplicit: rawAdaptiveDeltaOverride,
    }),
    pause: resolvePauseProfile({
      profile: pauseProfile,
      legacySilenceMs,
    }),
  };
}
