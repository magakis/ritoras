import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const FRAME_MS = 10;
const FRAME_DURATION_S = FRAME_MS / 1000;
const SAMPLES_PER_MS = 16;
const USER_MIN_DURATION_MS = 450;
const USER_ENDPOINT_SILENCE_MS = 3000;
const USER_MIN_SAMPLES = USER_MIN_DURATION_MS * SAMPLES_PER_MS;
const USER_GATE_CONFIG = Object.freeze({
  mode: 'adaptive',
  adaptiveDeltaDb: 10,
  adaptiveContinuationDeltaDb: 6,
  adaptiveSilenceDeltaDb: 5,
  adaptiveRiseSpeedMultiplier: 1,
  adaptiveFallTauSeconds: 0.5,
  adaptiveStaleFloorSeconds: 1.5,
  adaptiveDynamicsSpreadDb: 9,
  adaptiveFlatSpreadDb: 5,
  adaptiveDynamicsEnabled: true,
});

function makeScenario() {
  const timeline = [];
  const events = [];
  let elapsedSeconds = 0;
  const harness = makeRecorderHarness({
    endpointSilenceMs: USER_ENDPOINT_SILENCE_MS,
    minSpeechSamples: USER_MIN_SAMPLES,
    minChunkSamples: USER_MIN_SAMPLES,
    gateConfig: USER_GATE_CONFIG,
    onFrame: record => {
      elapsedSeconds += record.dt;
      timeline.push({ ...record, timeSeconds: elapsedSeconds });
    },
    onEvent: event => {
      events.push({ ...event, timeSeconds: elapsedSeconds });
    },
  });
  return { harness, timeline, events };
}

function runFrames(scenario, frameCount, frameDbAt) {
  for (let index = 0; index < frameCount; index += 1) {
    scenario.harness.drive(frameDbAt(index, index * FRAME_DURATION_S));
  }
}

function runSeconds(scenario, seconds, frameDbAt) {
  runFrames(scenario, Math.round(seconds * 1000 / FRAME_MS), frameDbAt);
}

function bugAmbientDb(frameIndex) {
  const nominalDb = -54.5;
  const jitterDb = [0.5, 0.75, 1, -0.25][frameIndex % 4];
  return Math.max(-54, nominalDb + jitterDb);
}

function bugScenarioFrameDb(frameIndex) {
  if (frameIndex >= 200) return bugAmbientDb(frameIndex - 200);

  const phaseFrame = frameIndex % 40;
  if (phaseFrame >= 30) return -54;
  return [-45, -47.5, -50][frameIndex % 3];
}

function runBugScenario(seconds) {
  const scenario = makeScenario();
  runSeconds(scenario, seconds, frameIndex => bugScenarioFrameDb(frameIndex));
  return scenario;
}

function runAmbientSpeechControl() {
  const scenario = makeScenario();
  runSeconds(scenario, 3, () => -54.5);
  runSeconds(scenario, 3, frameIndex => {
    if (frameIndex < 120) return frameIndex % 2 === 0 ? -45 : -48;
    return frameIndex % 20 === 0 ? -50 : (frameIndex % 2 === 0 ? -45 : -48);
  });
  runSeconds(scenario, 3.5, () => -54.5);
  return scenario;
}

function runRoomControl() {
  const scenario = makeScenario();
  runSeconds(scenario, 3, () => -40);
  runSeconds(scenario, 2, () => -30);
  runSeconds(scenario, 3.5, () => -40);
  return scenario;
}

function runFlatWhisperTradeoff() {
  const scenario = makeScenario();
  runSeconds(scenario, 3, () => -54.5);
  runSeconds(scenario, 20, frameIndex => (frameIndex % 7 === 0 ? -45 : -46));
  return scenario;
}

function sampleAt(timeline, seconds) {
  return timeline.find(frame => frame.timeSeconds >= seconds) ?? timeline.at(-1);
}

function stateTransitions(timeline) {
  const transitions = [];
  let previous = null;
  for (const frame of timeline) {
    if (frame.es !== previous) {
      transitions.push(frame.es);
      previous = frame.es;
    }
  }
  return transitions;
}

function evidenceCounts(timeline) {
  return timeline.reduce((counts, frame) => {
    counts[frame.e] = (counts[frame.e] ?? 0) + 1;
    return counts;
  }, {});
}

function printDebugReport(label, scenario, sampleTimes = []) {
  if (process.env.VAD_REPRO_DEBUG !== '1') return;

  console.log(`\n[${label}] transitions: ${stateTransitions(scenario.timeline).join(' -> ')}`);
  console.log(`[${label}] evidence: ${JSON.stringify(evidenceCounts(scenario.timeline))}`);
  if (sampleTimes.length > 0) {
    console.log('time | floor | strong | continue | silence | evidence | endpoint');
    for (const seconds of sampleTimes) {
      const frame = sampleAt(scenario.timeline, seconds);
      console.log([
        `${seconds.toFixed(1)}s`,
        frame.fl?.toFixed(1) ?? 'n/a',
        frame.th?.toFixed(1) ?? 'n/a',
        frame.ct?.toFixed(1) ?? 'n/a',
        frame.st?.toFixed(1) ?? 'n/a',
        frame.e,
        frame.es,
      ].join(' | '));
    }
  }
  console.log(`[${label}] chunks=${scenario.harness.chunkCount} finalState=${scenario.harness.endpoint.state}`);
}

describe('adaptive VAD stuck-floor verification', () => {
  it('seeds the dispersive cold start promptly and remains stable long-term', () => {
    const sixtyFiveSeconds = runBugScenario(65);
    printDebugReport(
      'A: dispersive cold start then ambient recovery (65 s)',
      sixtyFiveSeconds,
      [0.5, 1, 2, 5, 30, 65],
    );

    const firstSeedFrame = sixtyFiveSeconds.timeline.find(
      frame => frame.fl !== -80 && frame.timeSeconds <= 1,
    );
    assert.ok(firstSeedFrame !== undefined);
    assert.ok(firstSeedFrame.timeSeconds <= 1);
    assert.strictEqual(sixtyFiveSeconds.harness.gate.coldStartConverged, true);
    assert.strictEqual(sixtyFiveSeconds.harness.gate.adaptiveRefinementComplete, true);

    const firstSilenceFrame = sixtyFiveSeconds.timeline.find(
      frame => frame.timeSeconds > firstSeedFrame.timeSeconds && frame.e === 'silence',
    );
    assert.ok(firstSilenceFrame !== undefined);
    assert.ok(firstSilenceFrame.timeSeconds <= 8);

    const firstIdleAfterRecovery = sixtyFiveSeconds.timeline.find(
      frame => frame.timeSeconds >= firstSilenceFrame.timeSeconds && frame.es === 'idle',
    );
    assert.ok(firstIdleAfterRecovery !== undefined);
    assert.ok(firstIdleAfterRecovery.timeSeconds <= 12);
    // The post-seed signal stays below strong onset; the old pinned floor
    // incorrectly emitted this ambient-only session as speech.
    assert.strictEqual(sixtyFiveSeconds.harness.chunkCount, 0);
    assert.strictEqual(sixtyFiveSeconds.events.some(event => event.k === 'emit'), false);
    assert.ok(Math.abs(sixtyFiveSeconds.harness.gate.snapshot.floorDb - -54) <= 0.6);
    const finalFiveSeconds = sixtyFiveSeconds.timeline.filter(frame => frame.timeSeconds > 60);
    assert.ok(finalFiveSeconds.length > 0);
    assert.ok(finalFiveSeconds.every(frame => frame.e === 'silence' && frame.es === 'idle'));
    assert.strictEqual(sixtyFiveSeconds.harness.reanchorEventCount, 0);

    const tenMinutes = runBugScenario(600);
    printDebugReport('A: dispersive cold start then ambient recovery (10 min)', tenMinutes);
    assert.ok(Math.abs(tenMinutes.harness.gate.snapshot.floorDb - -54) <= 0.6);
    assert.strictEqual(tenMinutes.harness.endpoint.state, 'idle');
    assert.strictEqual(tenMinutes.harness.chunkCount, 0);
    assert.strictEqual(tenMinutes.harness.reanchorEventCount, 0);
  });

  it('keeps the healthy ambient-to-whisper control path usable', () => {
    const scenario = runAmbientSpeechControl();
    printDebugReport('B: ambient, whisper, silence', scenario);

    const ambientFrames = scenario.timeline.slice(0, 300);
    assert.ok(ambientFrames.every(frame => frame.es === 'idle'));
    assert.ok(ambientFrames.every(frame => frame.e !== 'strong'));
    assert.ok(Math.abs(scenario.harness.gate.snapshot.floorDb - -54.5) < 0.001);
    assert.strictEqual(scenario.harness.chunkCount, 1);
    assert.strictEqual(scenario.harness.endpoint.state, 'idle');
    assert.ok(scenario.events.some(event => event.k === 'start_utterance'));
    assert.ok(scenario.events.some(event => event.k === 'emit'));
    assert.strictEqual(
      scenario.timeline.some(frame => frame.d === 'finalize_endpoint'),
      true,
    );
  });

  it('keeps the normal-room control path usable', () => {
    const scenario = runRoomControl();
    printDebugReport('C: normal room, speech, silence', scenario);

    const ambientFrames = scenario.timeline.slice(0, 300);
    assert.ok(ambientFrames.every(frame => frame.es === 'idle'));
    assert.ok(Math.abs(scenario.harness.gate.snapshot.floorDb - -40) < 0.001);
    assert.strictEqual(scenario.harness.chunkCount, 1);
    assert.strictEqual(scenario.harness.endpoint.state, 'idle');
    assert.ok(scenario.events.some(event => event.k === 'start_utterance'));
    assert.ok(scenario.events.some(event => event.k === 'emit'));
  });

  it('documents the flat-whisper trade-off: emit audio and recover the floor', () => {
    const scenario = runFlatWhisperTradeoff();
    printDebugReport('D: converged ambient, flat whisper', scenario);

    // The whisper stays above the continuation threshold until the stuck-run re-anchor.
    assert.strictEqual(
      scenario.timeline.some(frame => frame.es === 'speechActive'),
      true,
    );
    assert.strictEqual(
      scenario.timeline.some(frame => frame.es === 'endPending'),
      true,
    );
    const emittedEvent = scenario.events.find(event => event.k === 'emit');
    assert.ok(emittedEvent !== undefined);
    assert.ok(emittedEvent.timeSeconds <= 15);
    assert.ok(scenario.harness.chunkCount >= 1);
    assert.ok(scenario.events.some(event => event.k === 'start_utterance'));
    assert.ok(scenario.harness.gate.snapshot.floorDb >= -48);
    assert.ok(scenario.harness.gate.snapshot.floorDb <= -44);
    assert.strictEqual(scenario.harness.reanchorEventCount, 1);
  });
});
