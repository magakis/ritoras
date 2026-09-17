import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  VAD_PROFILE_DEFAULTS,
  VADPauseProfile,
  VADSensitivityProfile,
  resolvePauseProfile,
  resolveSensitivity,
  resolveVadProfiles,
} from '../lib/vad-profiles.mjs';

describe('VAD profile resolution', () => {
  it('maps each sensitivity profile to coordinated onset and continuation deltas', () => {
    assert.deepStrictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.automatic,
    }), {
      profile: 'automatic', strongDeltaDb: 10, continuingDeltaDb: 6, silenceDeltaDb: 3,
    });
    assert.deepStrictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.quietVoice,
    }), {
      profile: 'quietVoice', strongDeltaDb: 7, continuingDeltaDb: 4, silenceDeltaDb: 3,
    });
    assert.deepStrictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.noisyEnvironment,
    }), {
      profile: 'noisyEnvironment', strongDeltaDb: 13, continuingDeltaDb: 8, silenceDeltaDb: 3,
    });
  });

  it('uses raw onset override before profile values and defaults otherwise', () => {
    assert.strictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.quietVoice,
      rawAdaptiveDeltaDb: 18,
    }).strongDeltaDb, 18);
    assert.strictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.quietVoice,
      rawAdaptiveDeltaDb: 10,
    }).strongDeltaDb, 7);
    assert.strictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.quietVoice,
      rawAdaptiveDeltaDb: 10,
      rawOverrideExplicit: true,
    }).strongDeltaDb, 10);
    assert.strictEqual(resolveSensitivity({
      profile: VADSensitivityProfile.quietVoice,
    }).strongDeltaDb, 7);
    assert.strictEqual(resolveSensitivity().strongDeltaDb, VAD_PROFILE_DEFAULTS.strongDeltaDb);
  });

  it('clamps corrupt raw deltas without producing invalid thresholds', () => {
    assert.strictEqual(resolveSensitivity({ rawAdaptiveDeltaDb: -100 }).strongDeltaDb, 3);
    assert.strictEqual(resolveSensitivity({ rawAdaptiveDeltaDb: 100 }).strongDeltaDb, 24);
    assert.strictEqual(resolveSensitivity({ rawAdaptiveDeltaDb: Number.NaN }).strongDeltaDb, 10);
  });

  it('maps pause profiles to their endpoint silence durations', () => {
    assert.strictEqual(resolvePauseProfile({ profile: VADPauseProfile.fast }).silenceMs, 450);
    assert.strictEqual(resolvePauseProfile({ profile: VADPauseProfile.balanced }).silenceMs, 700);
    assert.strictEqual(resolvePauseProfile({ profile: VADPauseProfile.long }).silenceMs, 1100);
  });

  it('migrates legacy silence values only when no profile is stored', () => {
    assert.strictEqual(resolvePauseProfile({ legacySilenceMs: 2000 }).profile, 'balanced');
    assert.strictEqual(resolvePauseProfile({ legacySilenceMs: 500 }).profile, 'fast');
    assert.strictEqual(resolvePauseProfile({ legacySilenceMs: 700 }).profile, 'balanced');
    assert.strictEqual(resolvePauseProfile({ legacySilenceMs: 1200 }).profile, 'long');
    assert.strictEqual(resolvePauseProfile({ profile: 'long', legacySilenceMs: 500 }).profile, 'long');
  });

  it('clamps corrupt legacy silence values to a valid profile', () => {
    assert.strictEqual(resolvePauseProfile({ legacySilenceMs: -1 }).silenceMs, 450);
    assert.strictEqual(resolvePauseProfile({ legacySilenceMs: 999999 }).silenceMs, 1100);
    assert.strictEqual(resolveVadProfiles({ pauseProfile: 'invalid' }).pause.profile, 'balanced');
  });
});
