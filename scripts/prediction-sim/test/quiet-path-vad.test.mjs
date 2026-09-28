import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import { VADThresholdGate, makeVadGateConfig } from '../lib/vad-gate.mjs';
import { parseSession, replaySession } from '../bin/replay-vad.mjs';

const DEFAULT_QUIET_CONFIG = {
  quietLatchMs: 1000,
  quietLatchWitnessDb: 3,
  quietLatchWitnessEnabled: false,
  quietLatchDutyCycle: 1,
  quietLatchAmbiguousEnabled: false,
  quietContinuationRiseCapDbPerSec: 12,
  softOnsetPreRollMs: 500,
  softOnsetPreRollEnabled: false,
};

function fixture(filename) {
  return fs.readFileSync(new URL(`../fixtures/vad-telemetry/${filename}`, import.meta.url), 'utf8');
}

function quietHarness({ dutyCycle, frameMs = 100 } = {}) {
  const events = [];
  const frames = [];
  const harness = makeRecorderHarness({
    frameMs,
    endpointSilenceMs: 2000,
    gateConfig: { loudRegimeEnabled: false },
    recorderConfig: {
      quietLatchMs: 1000,
      quietLatchWitnessDb: 3,
      quietLatchWitnessEnabled: true,
      quietLatchDutyCycle: dutyCycle ?? 0.6,
      quietLatchAmbiguousEnabled: false,
    },
    onEvent: event => events.push(event),
    onFrame: frame => frames.push(frame),
  });
  for (let index = 0; index < (frameMs === 100 ? 30 : 300); index += 1) {
    harness.drive(-52, frameMs / 1000);
  }
  harness.gate.floorDb = -52;
  harness.gate.isLoudRegime = false;
  harness.gate.updateFloorTracking = () => {};
  return { harness, events, frames };
}

describe('quiet-path VAD mirror knobs', () => {
  it('keeps the quiet continuation rise cap at the former 12 dB/s default', () => {
    const defaults = new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
    assert.equal(defaults.config.quietContinuationRiseCapDbPerSec, 12);

    const capped = new VADThresholdGate(makeVadGateConfig({
      mode: 'adaptive',
      loudRegimeEnabled: false,
      quietContinuationRiseCapDbPerSec: 3,
    }));
    capped.floorDb = -50;
    capped.adaptiveRefinementComplete = true;
    capped.adaptiveRollingPercentileCache = -10;
    capped.lastOutput = { ...capped.lastOutput, evidence: 'continuing' };
    capped.updateFloorTracking(-10, 1, true);
    assert.equal(capped.snapshot.floorDb, -47);
  });

  it('keeps default-off decisions and emissions invariant across telemetry fixtures', () => {
    const filenames = [
      'E31F3FEF-15A6-467B-AF05-7C7D7D9ACD06-vad.jsonl',
      'EF51BED5-74A4-4D34-A643-D270191219DB-vad.jsonl',
      '0091E171-E047-4908-8E6A-1AA5400785C3-vad.jsonl',
    ];
    for (const filename of filenames) {
      const session = parseSession(fixture(filename));
      const baseline = replaySession(session, session.config, { compare: false });
      const configured = replaySession(session, {
        ...session.config,
        ...DEFAULT_QUIET_CONFIG,
      }, { compare: false });
      assert.deepEqual(configured.frames, baseline.frames, filename);
      assert.deepEqual(configured.events.filter(event => event.k !== 'session_start'),
        baseline.events.filter(event => event.k !== 'session_start'), filename);
    }
  });

  it('recovers the Tele1 whisper gap with quiet witness and capped floor rise', () => {
    const session = parseSession(fixture('EF51BED5-74A4-4D34-A643-D270191219DB-vad.jsonl'));
    const replay = replaySession(session, {
      ...session.config,
      quietLatchWitnessEnabled: true,
      quietLatchMs: 400,
      quietLatchWitnessDb: 3,
      quietLatchDutyCycle: 0.6,
      quietContinuationRiseCapDbPerSec: 2,
      softOnsetPreRollEnabled: true,
      softOnsetPreRollMs: 500,
    }, { compare: false });
    const recovered = replay.events.find(event => (
      event.k === 'emit' && event.s0 <= 13_900 && event.s1 >= 14_500
    ));
    assert.ok(recovered, JSON.stringify(replay.events.filter(event => event.k === 'emit')));
  });

  it('bridges one 108 ms breath hiccup at duty 0.6 but not duty 1.0', () => {
    function driveBreathBridge(dutyCycle) {
      const { harness, events } = quietHarness({ dutyCycle });
      for (let index = 0; index < 8; index += 1) harness.drive(-42.5, 0.1);
      harness.drive(-80, 0.108);
      for (let index = 0; index < 2; index += 1) harness.drive(-42.5, 0.1);
      return events.some(event => event.k === 'start_utterance' && event.softOnset === true);
    }

    assert.equal(driveBreathBridge(0.6), true);
    assert.equal(driveBreathBridge(1.0), false);
  });

  it('rejects sparse continuing bursts below the configured duty cycle', () => {
    const { harness, frames } = quietHarness({ dutyCycle: 0.6 });
    let frameIndex = 0;
    for (let cycle = 0; cycle < 20; cycle += 1) {
      const continuing = harness.drive(-42.5, 0.1);
      assert.equal(continuing.output.evidence, 'continuing');
      frameIndex += 1;
      for (let silence = 0; silence < 4; silence += 1) {
        harness.drive(-80, 0.1);
        frameIndex += 1;
      }
    }
    assert.equal(frames.some(frame => frame.ll), false);
    assert.equal(harness.endpoint.state, 'idle');
    assert.ok(frameIndex > 0);
  });

  it('uses the soft-onset pre-roll only for quiet latch-mediated starts', () => {
    function startSampleCount(enabled) {
      const events = [];
      const harness = makeRecorderHarness({
        frameMs: 100,
        endpointSilenceMs: 2000,
        endpointConfig: { onsetMs: 70, preRollMs: 100 },
        gateConfig: { loudRegimeEnabled: false },
        recorderConfig: {
          loudPreRollMs: 100,
          quietLatchWitnessEnabled: true,
          quietLatchMs: 1000,
          quietLatchDutyCycle: 0.6,
          softOnsetPreRollMs: 900,
          softOnsetPreRollEnabled: enabled,
        },
        onEvent: event => events.push(event),
      });
      for (let index = 0; index < 30; index += 1) harness.drive(-52, 0.1);
      harness.headLive = false;
      harness.gate.floorDb = -52;
      harness.gate.isLoudRegime = false;
      harness.gate.updateFloorTracking = () => {};
      for (let index = 0; index < 20; index += 1) harness.drive(-42.5, 0.1);
      const start = events.find(event => event.k === 'start_utterance');
      return { samples: start?.n, softOnset: start?.softOnset === true };
    }

    const normal = startSampleCount(false);
    const soft = startSampleCount(true);
    assert.equal(normal.softOnset, true);
    assert.equal(soft.softOnset, true);
    assert.ok(soft.samples > normal.samples + 5000);
  });
});
