import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  normalizeConfig,
  parseSession,
  replaySession,
  SHIPPING_SESSION_CONFIG,
} from '../bin/replay-vad.mjs';

const fixtureDirectory = new URL(
  '../fixtures/vad-telemetry/20261030-091944/',
  import.meta.url,
);
const fixtureSession = parseSession(fs.readFileSync(
  new URL('client_telemetry.json', fixtureDirectory),
  'utf8',
));

const qualifiedConfig = enabled => normalizeConfig({
  ...fixtureSession.config,
  utteranceRelativeResetEnabled: enabled,
  utteranceResetMarginDb: 12,
  utteranceEstablishMs: 500,
  utteranceLevelDescentDbPerSec: 1,
  utteranceLevelDescentCapDb: 8,
  utteranceLevelRaiseSustainMs: 300,
  ambiguousDecayGraceMs: 800,
  ambiguousDecayRate: 0.75,
}).config;

function legacyFrameProjection(frames) {
  return frames.map(frame => ({
    q: frame.q,
    e: frame.e,
    ps: frame.ps,
    sp: frame.sp,
    es: frame.es,
    d: frame.d,
    ss: frame.ss,
    us: frame.us,
  }));
}

function legacyEmissionProjection(events) {
  return events
    .filter(event => event.k === 'emit' || event.k === 'stop_flush')
    .map(event => ({
      k: event.k,
      r: event.r,
      n: event.n,
      sm: event.sm,
      tm: event.tm,
      es: event.es,
      sourceStartSample: event.sourceStartSample,
      sourceEndSample: event.sourceEndSample,
      s0: event.s0,
      s1: event.s1,
    }));
}

describe('2026-10-30 distant-TV pause replay', () => {
  it('finalizes at the characterized pause only with the reset/decay master enabled', () => {
    assert.equal(fixtureSession.frames.length, 674);
    assert.equal(fixtureSession.config.endpointSilenceMs, 2_000);
    assert.equal(SHIPPING_SESSION_CONFIG.utteranceRelativeResetEnabled, true);

    const enabled = replaySession(
      fixtureSession,
      qualifiedConfig(true),
      { compare: false },
    );
    assert.equal(enabled.config.utteranceRelativeResetEnabled, true);
    const firstOnsetPendingFrameIndex = enabled.frames.findIndex(frame => (
      frame.ps === 'idle' && ['strong', 'continuing'].includes(frame.e)
    ));
    assert.ok(firstOnsetPendingFrameIndex >= 0);
    const firstOnsetPendingFrame = enabled.frames[firstOnsetPendingFrameIndex];
    const onsetPendingStartSeconds = firstOnsetPendingFrame.time - firstOnsetPendingFrame.dt;
    let classifiedOnsetSamples = 0;
    let establishmentThresholdTime = null;
    for (const frame of enabled.frames.slice(firstOnsetPendingFrameIndex)) {
      if (!['strong', 'continuing'].includes(frame.e)) continue;
      const frameSamples = Math.round(frame.dt * 16_000);
      const remainingSamples = 500 * 16 - classifiedOnsetSamples;
      if (frameSamples >= remainingSamples) {
        establishmentThresholdTime = frame.time - frame.dt + remainingSamples / 16_000;
        break;
      }
      classifiedOnsetSamples += frameSamples;
    }
    assert.ok(Math.abs(onsetPendingStartSeconds - 0.4943125) <= 1e-6);
    assert.ok(Math.abs(establishmentThresholdTime - 0.9943125) <= 1e-6);
    const firstReferenceFrame = enabled.frames.find(frame => Number.isFinite(frame.ur));
    assert.ok(firstReferenceFrame);
    assert.equal(firstReferenceFrame.q, 10);
    assert.ok(Math.abs(firstReferenceFrame.time - 1.0969375) <= 1e-6);
    assert.ok(Math.abs(firstReferenceFrame.ur - -34.4536) <= 0.01);
    const finalizers = enabled.frames.filter(frame => frame.d === 'finalize_endpoint');
    assert.ok(finalizers.length >= 1);
    const firstFinalize = finalizers[0];
    // Pure-ambiguous contract is 27.1566s; mixed evidence observes 26.896375s,
    // 260.225ms earlier, inside this one-frame-scale characterization window.
    assert.ok(Math.abs(firstFinalize.time - 27.1566) <= 0.3);
    assert.equal(firstFinalize.es, 'idle');

    const pauseFrame = enabled.frames.find(frame => frame.q === 237);
    const pauseOnsetSeconds = pauseFrame.time - pauseFrame.dt;
    assert.ok(Math.abs(pauseOnsetSeconds - 23.6899) <= 0.01);
    const postRaiseClassifiedFrames = enabled.frames.filter(frame => (
      frame.q > 14
        && frame.time <= firstFinalize.time
        && ['strong', 'continuing'].includes(frame.e)
    ));
    const postRaiseClassifiedSeconds = postRaiseClassifiedFrames.reduce(
      (seconds, frame) => seconds + frame.dt,
      0,
    );
    assert.equal(postRaiseClassifiedFrames.length, 168);
    assert.ok(Math.abs(postRaiseClassifiedSeconds - 16.8508125) <= 1e-6);
    const prePauseClassifiedFrames = postRaiseClassifiedFrames.filter(frame => (
      frame.time <= pauseOnsetSeconds
    ));
    assert.equal(prePauseClassifiedFrames.length, 166);
    assert.ok(Math.abs(
      prePauseClassifiedFrames.reduce((seconds, frame) => seconds + frame.dt, 0) - 16.6575,
    ) <= 1e-6);
    const pauseClassifiedFrames = postRaiseClassifiedFrames.filter(frame => (
      frame.time - frame.dt >= pauseOnsetSeconds
    ));
    assert.deepEqual(pauseClassifiedFrames.map(frame => frame.q), [238, 254]);
    assert.ok(Math.abs(
      pauseClassifiedFrames.reduce((seconds, frame) => seconds + frame.dt, 0) - 0.1933125,
    ) <= 1e-6);
    // Classified duration exceeds the 8 dB cap; lower sustained raises stay below q13's max.
    const referenceFloorDb = -21.2964 - Math.min(8, postRaiseClassifiedSeconds);
    assert.ok(Math.abs(firstFinalize.ur - referenceFloorDb) <= 0.01);
    const lowerRaiseFrame = enabled.frames.find(frame => frame.q === 127);
    const recappedFrame = enabled.frames.find(frame => frame.q === 188);
    assert.ok(Math.abs(lowerRaiseFrame.ur - -25.1994) <= 0.01);
    assert.ok(Math.abs(recappedFrame.ur - referenceFloorDb) <= 0.01);
    const tvResetCandidates = enabled.frames.filter(frame => (
      frame.time >= pauseOnsetSeconds
        && frame.time <= firstFinalize.time
        && ['strong', 'continuing'].includes(frame.e)
    ));
    assert.ok(tvResetCandidates.length > 0);
    assert.equal(tvResetCandidates.every(frame => frame.uq === 'stripped'), true);
    const loudestStrippedTvFrame = tvResetCandidates.reduce((loudest, frame) => (
      frame.db > loudest.db ? frame : loudest
    ));
    assert.equal(loudestStrippedTvFrame.q, 236);
    assert.ok(Math.abs(loudestStrippedTvFrame.time - pauseOnsetSeconds) <= 1e-9);
    assert.equal(loudestStrippedTvFrame.e, 'continuing');
    assert.equal(loudestStrippedTvFrame.uq, 'stripped');
    assert.ok(Math.abs(loudestStrippedTvFrame.ur - referenceFloorDb) <= 0.01);
    assert.ok(Math.abs(loudestStrippedTvFrame.db - -45.8114) <= 0.01);
    const loudestPauseStripMargin = referenceFloorDb - loudestStrippedTvFrame.db;
    assert.ok(Math.abs(loudestPauseStripMargin - 16.515) <= 0.01);

    const q401 = fixtureSession.frames.find(frame => frame.q === 401);
    const q401ReplayFrame = enabled.frames.find(frame => frame.q === 401);
    const q401StartSeconds = fixtureSession.frames
      .filter(frame => frame.q < 401)
      .reduce((seconds, frame) => seconds + frame.dt, 0);
    assert.equal(q401.e, 'strong');
    assert.equal(q401.sh, true);
    assert.equal(q401.ps, 'speechActive');
    assert.ok(Math.abs(q401StartSeconds - 40.09) <= 0.1);
    assert.ok(q401StartSeconds > firstFinalize.time);
    assert.ok(q401ReplayFrame);
    assert.notEqual(q401ReplayFrame.ur, referenceFloorDb);
    assert.notEqual(q401ReplayFrame.uq, 'stripped');
    assert.equal(tvResetCandidates.some(frame => frame.q === 401), false);

    const endpointEmission = enabled.events.find(event => (
      event.k === 'emit' && event.r === 'endpoint'
    ));
    assert.ok(endpointEmission, 'the pause finalizer must emit a chunk');
    assert.ok(endpointEmission.sourceEndSample / 16_000 > pauseOnsetSeconds);
    assert.ok(endpointEmission.sourceEndSample / 16_000 < 41.5926);
    const firstRecoveredSpeech = enabled.frames.find(frame => (
      frame.time > firstFinalize.time
        && frame.db >= -40
        && ['strong', 'continuing'].includes(frame.e)
        && frame.uq !== 'stripped'
    ));
    assert.ok(firstRecoveredSpeech);
    assert.ok(Math.abs(firstRecoveredSpeech.time - firstRecoveredSpeech.dt - 41.5926) <= 0.2);
    const firstRecoveredReference = enabled.frames.find(frame => (
      frame.time >= firstRecoveredSpeech.time && Number.isFinite(frame.ur)
    ));
    assert.ok(Number.isFinite(firstRecoveredReference?.ur));
    assert.notEqual(firstRecoveredReference.ur, firstFinalize.ur);

    const disabled = replaySession(
      fixtureSession,
      qualifiedConfig(false),
      { compare: false },
    );
    assert.equal(disabled.config.utteranceRelativeResetEnabled, false);
    assert.equal(disabled.frames.some(frame => frame.d === 'finalize_endpoint'), false);
    assert.deepEqual(
      legacyFrameProjection(disabled.frames),
      legacyFrameProjection(fixtureSession.frames),
    );
    assert.deepEqual(
      legacyEmissionProjection(disabled.events),
      legacyEmissionProjection(fixtureSession.events),
    );
    assert.equal(disabled.events.some(event => event.k === 'stop_flush'), true);
    assert.equal(
      disabled.events.some(event => event.k === 'emit' && event.r === 'endpoint'),
      false,
    );
  });
});
