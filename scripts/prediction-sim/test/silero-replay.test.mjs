import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeConfig,
  replaySession,
  SHIPPING_SESSION_CONFIG,
} from '../bin/replay-vad.mjs';

function makeSession(config, frames) {
  return {
    frames,
    events: [],
    config,
    configIsTelemetry: false,
  };
}

describe('Silero VAD replay handling', () => {
  it('skips sessions configured for Silero and preserves its replay settings', () => {
    const config = {
      ...SHIPPING_SESSION_CONFIG,
      vadSource: 'silero',
      sileroStartThreshold: 0.80,
      sileroStopThreshold: 0.70,
      sileroSmoothingSteps: 1,
    };
    const session = makeSession(config, [{ t: 'f', q: 0, dt: 0.01, db: -80 }]);
    const normalized = normalizeConfig(config);

    assert.equal(normalized.config.vadSource, 'silero');
    assert.equal(normalized.config.sileroStartThreshold, 0.80);
    assert.equal(normalized.config.sileroStopThreshold, 0.70);
    assert.equal(normalized.config.sileroSmoothingSteps, 1);
    assert.equal(normalized.recorderConfig.vadSource, 'silero');
    assert.equal(normalized.recorderConfig.sileroStartThreshold, 0.80);
    assert.equal(normalized.recorderConfig.sileroStopThreshold, 0.70);
    assert.equal(normalized.recorderConfig.sileroSmoothingSteps, 1);

    const replay = replaySession(session, config, { compare: false });

    assert.equal(replay.status, 'unsupported_skipped');
    assert.match(replay.reason, /Silero-sourced sessions/);
  });

  it('skips sessions whose frames contain Silero probability telemetry', () => {
    const session = makeSession({ ...SHIPPING_SESSION_CONFIG }, [
      { t: 'f', q: 0, dt: 0.01, db: -80, pr: 0.50, pm: 0.50 },
    ]);

    const replay = replaySession(session, session.config, { compare: false });

    assert.equal(replay.status, 'unsupported_skipped');
    assert.match(replay.reason, /Silero-sourced sessions/);
  });

  it('replays a DSP session normally', () => {
    const config = { ...SHIPPING_SESSION_CONFIG, vadSource: 'dsp' };
    const session = makeSession(config, [{ t: 'f', q: 0, dt: 0.01, db: -80 }]);

    const replay = replaySession(session, config, { compare: false });

    assert.notEqual(replay.status, 'unsupported_skipped');
    assert.equal(replay.frames.length, 1);
    assert.ok(replay.metrics);
  });
});
