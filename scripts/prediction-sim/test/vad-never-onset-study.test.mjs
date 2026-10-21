import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { adaptClientTelemetry, recordedEmissionMap } from '../lib/client-telemetry.mjs';
import { findIdleGapTriggers } from '../lib/vad-idle-gap.mjs';
import { calculateSlowOnsetThreshold } from '../lib/recorder-sim.mjs';
import { expandLevelSegments, makeFaultTraceHarness } from '../lib/vad-never-onset-fault-trace.mjs';
import { replaySession } from '../bin/replay-vad.mjs';
import {
  compareEmissionMaps,
  findFirstFrameDivergence,
  isKnownLegacyStopFlushDivergence,
} from '../bin/vad-never-onset-study.mjs';

const fixtureRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../fixtures/vad-never-onset');

function readFixture(name) {
  return JSON.parse(fs.readFileSync(path.join(fixtureRoot, name), 'utf8'));
}

function runTrace(frames, {
  slowOnsetEnabled = false,
  absoluteSpeechFloorDb = -35,
  slowOnsetDeltaDb = 7,
  slowOnsetEvidenceMs = 300,
  slowOnsetWindowSeconds = 1.5,
  adaptiveDynamicsEnabled = false,
} = {}) {
  const events = [];
  const harness = makeFaultTraceHarness({
    slowOnsetEnabled,
    absoluteSpeechFloorDb,
    slowOnsetDeltaDb,
    slowOnsetEvidenceMs,
    slowOnsetWindowSeconds,
    adaptiveDynamicsEnabled,
    onEvent: event => events.push(event),
  });
  let elapsed = 0;
  for (const frame of frames) {
    elapsed += frame.dt;
    harness.drive(frame.db, frame.dt);
    for (let index = events.length - 1; index >= 0 && events[index].time === undefined; index -= 1) {
      events[index].time = elapsed;
    }
  }
  harness.flush();
  harness.end();
  return { events, starts: events.filter(event => event.k === 'start_utterance') };
}

function framesForTrace(fixture) {
  return expandLevelSegments(fixture.segments).map(frame => ({ db: frame.db, dt: frame.dt }));
}

describe('never-onset slow-path validation', () => {
  it('replays only client db/dt and extracts recorded emission boundaries', () => {
    const payload = {
      vad_config: { absoluteSpeechFloorDb: -70, mode: 'adaptive' },
      frames: [
        { q: 0, dt: 0.01, db: -40, e: 'corrupt', th: 0 },
        { q: 1, dt: 0.02, db: -30, e: 'strong', th: -99 },
      ],
      events: [{ k: 'emit', id: 1, s0: 120, s1: 760, tm: 640 }],
    };
    const adapted = adaptClientTelemetry(payload, 'fixture-session');
    const replay = replaySession(adapted, { ...adapted.config, endpointMachineEnabled: false });

    assert.deepEqual(adapted.frames, [
      { t: 'f', q: 0, dt: 0.01, db: -40 },
      { t: 'f', q: 1, dt: 0.02, db: -30 },
    ]);
    assert.deepEqual(adapted.recordedFrames[1], { q: 1, e: 'strong', es: undefined, d: undefined });
    assert.equal(replay.frames.length, 2);
    assert.equal(recordedEmissionMap(adapted)[0].start, 0.12);
    assert.equal(recordedEmissionMap(adapted)[0].end, 0.76);
  });

  it('reports frame index/time and classifies the known legacy stop-flush mismatch', () => {
    const session = {
      id: '20261021-192953',
      recordedFrames: [
        { e: 'continuing', es: 'idle', d: 'none' },
        { e: 'continuing', es: 'idle', d: 'none' },
      ],
      events: [{
        k: 'stop_flush',
        r: 'below_minimums',
        sm: 278.625,
        s0: 14497.25,
        s1: 16782.4375,
      }],
      config: { minSpeechMs: 300 },
    };
    const replay = {
      frames: [
        { e: 'continuing', es: 'idle', d: 'none', time: 0.01 },
        { e: 'strong', es: 'speechActive', d: 'start_utterance', time: 0.02 },
      ],
    };
    const divergence = findFirstFrameDivergence(session, replay);
    const exception = isKnownLegacyStopFlushDivergence(session, [], [{
      start: 14.49725,
      end: 16.7824375,
    }]);

    assert.equal(divergence.frameIndex, 1);
    assert.equal(divergence.timeSeconds, 0.02);
    assert.equal(exception.classification, 'known-version-divergence');
    assert.equal(exception.excludedFromFidelity, true);
    assert.equal(isKnownLegacyStopFlushDivergence({ ...session, id: 'other-session' }, [], []), null);
    assert.equal(compareEmissionMaps(
      [{ start: null, end: null }],
      [{ start: 0.1, end: 0.2 }],
    ).pass, false);
  });

  it('recovers the sustained floor+7.6 dB incident signature only when enabled', () => {
    const fixture = readFixture('incident-signature.json');
    const frames = framesForTrace(fixture);
    const softSegment = fixture.segments[1];
    const peakAboveFloorDb = softSegment.db - fixture.floorDb;
    const baseline = runTrace(frames);
    const candidate = runTrace(frames, { slowOnsetEnabled: true });

    assert.ok(peakAboveFloorDb >= 7.3 && peakAboveFloorDb <= 8.5);
    assert.ok(softSegment.durationMs >= 1200 && softSegment.durationMs <= 3000);
    assert.equal(baseline.starts.length, 0);
    assert.equal(candidate.starts.length, 1);
    assert.ok(candidate.events.some(event => event.k === 'slow_onset'));
    assert.ok(candidate.starts[0].time >= 0.9 && candidate.starts[0].time <= 2.4);
  });

  it('does not trigger on separated 100 ms transient spikes', () => {
    const fixture = readFixture('transient-spikes.json');
    const baseline = runTrace(framesForTrace(fixture));
    const candidate = runTrace(framesForTrace(fixture), { slowOnsetEnabled: true });

    assert.equal(baseline.starts.length, 0);
    assert.equal(candidate.starts.length, 0);
    assert.equal(candidate.events.some(event => event.k === 'slow_onset'), false);
  });

  it('keeps synthetic quiet-room whisper onset behavior unchanged under the -65 dB guard', () => {
    const fixture = readFixture('quiet-room-whisper.json');
    const frames = [];
    for (const segment of fixture.trace) {
      for (let elapsed = 0; elapsed < segment.durationMs; elapsed += 10) {
        frames.push({ db: segment.db, dt: 0.01 });
      }
    }
    const baseline = runTrace(frames, {
      absoluteSpeechFloorDb: -65,
      adaptiveDynamicsEnabled: false,
    });
    const candidate = runTrace(frames, {
      absoluteSpeechFloorDb: -65,
      slowOnsetEnabled: true,
      slowOnsetDeltaDb: 5,
      slowOnsetEvidenceMs: 300,
      adaptiveDynamicsEnabled: false,
    });

    assert.ok(baseline.starts.length > 0);
    assert.deepEqual(candidate.starts.map(event => event.time), baseline.starts.map(event => event.time));
    assert.equal(candidate.events.some(event => event.k === 'slow_onset'), false);
    assert.equal(calculateSlowOnsetThreshold(-75, 5, -65), Math.max(-75 + 10, -65));
  });

  it('finds only continuous idle evidence above floor+6 and the absolute guard', () => {
    const makeFrames = levels => levels.map(db => ({
      dt: 0.01,
      db,
      fl: -38,
      ps: 'idle',
      es: 'idle',
    }));

    const trigger = findIdleGapTriggers(makeFrames(Array(30).fill(-31)), { guardDb: -50 });
    const transient = findIdleGapTriggers(makeFrames([
      ...Array(15).fill(-31), ...Array(5).fill(-38), ...Array(15).fill(-31),
    ]), { guardDb: -50 });
    const belowGuard = findIdleGapTriggers(Array.from({ length: 40 }, () => ({
      dt: 0.01,
      db: -66,
      fl: -72,
      ps: 'idle',
      es: 'idle',
    })), {
      guardDb: -65,
      deltaDb: 6,
    });

    assert.equal(trigger.length, 1);
    assert.equal(transient.length, 0);
    assert.equal(belowGuard.length, 0);
  });
});
