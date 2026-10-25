import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

function makeHarness(events) {
  return makeRecorderHarness({
    frameMs: 10,
    minChunkSamples: 0,
    minSpeechSamples: 0,
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs: 700,
    },
    gateConfig: {
      mode: 'adaptive',
      adaptiveDeltaDb: 10,
      adaptiveContinuationDeltaDb: 6,
      adaptiveAbsoluteSpeechFloorDb: -80,
      adaptiveDynamicsEnabled: false,
    },
    onEvent: event => events.push(event),
  });
}

function drive(harness, levelDb, frameCount) {
  for (let index = 0; index < frameCount; index += 1) harness.drive(levelDb, 0.01);
}

function idleGapEvents(events) {
  return events.filter(event => event.k === 'discard' && event.r === 'idle_gap');
}

describe('never-onset idle-gap telemetry', () => {
  it('reports one elevated sub-onset idle run when the next utterance starts', () => {
    const events = [];
    const harness = makeHarness(events);
    drive(harness, -80, 50);
    drive(harness, -72, 250);
    drive(harness, -20, 10);

    const reported = idleGapEvents(events);

    assert.equal(reported.length, 1);
    assert.ok(reported[0].durationMs >= 2_000);
    assert.equal(reported[0].peakLevelDbFS, -72);
    assert.ok(reported[0].floorDbFSAtPeak <= -75);
    assert.equal(typeof reported[0].strongThresholdDbFSAtPeak, 'number');
    assert.equal(typeof reported[0].continuationThresholdDbFSAtPeak, 'number');
    assert.ok(reported[0].evidenceAboveFloor5Ms > 0);
  });

  it('does not report a pure-silence idle run', () => {
    const events = [];
    const harness = makeHarness(events);
    drive(harness, -80, 300);

    harness.flush();

    assert.equal(idleGapEvents(events).length, 0);
  });

  it('does not report an elevated idle run shorter than two seconds', () => {
    const events = [];
    const harness = makeHarness(events);
    drive(harness, -80, 50);
    drive(harness, -72, 130);
    drive(harness, -20, 10);

    assert.equal(idleGapEvents(events).length, 0);
  });

  it('flushes a qualifying elevated idle run at session stop', () => {
    const events = [];
    const harness = makeHarness(events);
    drive(harness, -80, 50);
    drive(harness, -72, 250);

    harness.flush();

    const reported = idleGapEvents(events);
    assert.equal(reported.length, 1);
    assert.equal(reported[0].r, 'idle_gap');
    assert.ok(reported[0].durationMs >= 2_000);
  });
});
