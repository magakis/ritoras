import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const FRAME_MS = 10;
const FRAME_DURATION_S = FRAME_MS / 1000;
const SAMPLES_PER_MS = 16;
const EPSILON_MS = FRAME_MS * 2;
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

function makeScenario({
  endpointSilenceMs = USER_ENDPOINT_SILENCE_MS,
  minSpeechSamples = USER_MIN_SAMPLES,
  minChunkSamples = USER_MIN_SAMPLES,
  gateConfig = USER_GATE_CONFIG,
  headBufferSamples,
} = {}) {
  const timeline = [];
  const events = [];
  let elapsedSeconds = 0;
  const harness = makeRecorderHarness({
    endpointSilenceMs,
    minSpeechSamples,
    minChunkSamples,
    headBufferSamples,
    gateConfig,
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

function runSeconds(scenario, seconds, frameDbAt) {
  const frameCount = Math.round(seconds * 1000 / FRAME_MS);
  for (let index = 0; index < frameCount; index += 1) {
    scenario.harness.drive(frameDbAt(index, index * FRAME_DURATION_S));
  }
}

function runDbTimeline(scenario, segments) {
  for (const segment of segments) {
    runSeconds(scenario, segment.seconds, () => segment.db);
  }
}

function eventsOf(scenario, kind) {
  return scenario.events.filter(event => event.k === kind);
}

describe('session-start head buffer', () => {
  it('preserves quiet speech hidden during calibrated VAD startup', () => {
    const scenario = makeScenario({
      // This test preserves the historical >2.5 s retention behavior, not the new default.
      headBufferSamples: 6000 * SAMPLES_PER_MS,
      gateConfig: {
        ...USER_GATE_CONFIG,
        mode: 'calibrated',
        calibrationMs: 1500,
        calibratedOffsetDb: 10,
      },
    });
    runDbTimeline(scenario, [
      { seconds: 0.5, db: -54 },
      { seconds: 2.5, db: -50 },
      { seconds: 1.5, db: -35 },
      { seconds: 3.5, db: -54 },
    ]);

    const starts = eventsOf(scenario, 'start_utterance');
    const emits = eventsOf(scenario, 'emit');
    assert.strictEqual(emits.length, 1);
    assert.strictEqual(starts.length, 1);
    // With 10 ms frames, calibration is 50 ambient + 100 quiet-speech frames:
    // Q1 is -54 dB, so the successful calibration threshold is -44 dB.
    assert.strictEqual(scenario.harness.gate.usedFallback, false);
    assert.strictEqual(scenario.harness.gate.thresholdDb, -44);
    // Real-world immediate speech during calibration can drag Q1 to speech
    // level, placing the threshold above it. Here the quiet segment falls below
    // the strong/continuing bands (at the exact silence boundary), so only loud
    // speech onsets; the session head preserves the otherwise-lost first sentence.
    const startTimeMs = starts[0].timeSeconds * 1000;
    assert.ok(Math.abs(startTimeMs - 3070) <= EPSILON_MS);
    assert.ok(
      Math.abs(
        scenario.harness.headPrependedAtOnset / SAMPLES_PER_MS - (startTimeMs - 500),
      ) <= EPSILON_MS,
    );
    assert.ok(
      scenario.harness.headPrependedAtOnset
        >= 1500 * SAMPLES_PER_MS - EPSILON_MS * SAMPLES_PER_MS,
    );
    const emittedMs = emits[0].n / SAMPLES_PER_MS;
    const utteranceFromLoudOnsetMs = (emits[0].timeSeconds - 3.0) * 1000;
    assert.ok(emittedMs >= startTimeMs - EPSILON_MS);
    assert.ok(emittedMs >= 3000 - EPSILON_MS);
    assert.ok(
      emittedMs >= scenario.harness.headPrependedAtOnset / SAMPLES_PER_MS
        + (emits[0].timeSeconds - starts[0].timeSeconds) * 1000
        - EPSILON_MS,
    );
    assert.ok(emittedMs <= 3000 + utteranceFromLoudOnsetMs + EPSILON_MS);
    // Without the head, the chunk would begin at onset - 500 ms, losing the
    // quiet sentence that did not start an utterance.
  });

  it('holds the three-second hesitation until post-speech endpoint silence', () => {
    const scenario = makeScenario({
      // This exercises retaining the full three-second hesitation, not the new 2.5 s default.
      headBufferSamples: 6000 * SAMPLES_PER_MS,
    });
    runSeconds(scenario, 3, () => -54);
    runSeconds(scenario, 1.2, () => -40);
    assert.strictEqual(eventsOf(scenario, 'emit').length, 0);

    runSeconds(scenario, 2.9, () => -54);
    assert.strictEqual(eventsOf(scenario, 'emit').length, 0);
    runSeconds(scenario, 0.2, () => -54);

    const emits = eventsOf(scenario, 'emit');
    assert.strictEqual(emits.length, 1);
    assert.ok(scenario.harness.headPrependedAtOnset >= 500 * SAMPLES_PER_MS);
    const emittedMs = emits[0].n / SAMPLES_PER_MS;
    assert.ok(emittedMs >= 500 + 1200 - EPSILON_MS);
    assert.ok(
      emittedMs <= scenario.harness.headPrependedAtOnset / SAMPLES_PER_MS
        + 1.2 * 1000
        + USER_ENDPOINT_SILENCE_MS
        + EPSILON_MS,
    );
    assert.ok(emits[0].timeSeconds >= 7.2 - EPSILON_MS / 1000);
  });

  it('keeps a live, exactly filled head buffer when an empty flush is discarded', () => {
    const scenario = makeScenario();
    runSeconds(scenario, 5, () => -54);
    scenario.harness.flush();

    assert.strictEqual(scenario.harness.chunkCount, 0);
    assert.strictEqual(eventsOf(scenario, 'emit').length, 0);
    assert.ok(scenario.events.some(event => event.k === 'stop_flush' && event.r === 'empty'));
    assert.strictEqual(scenario.harness.headLive, true);
    assert.strictEqual(scenario.harness.headSamples, 2500 * SAMPLES_PER_MS);
    assert.strictEqual(scenario.harness.sessionConfig.sessionHeadBufferMs, 2500);
  });

  it('uses pre-roll rather than the head for the second emitted chunk', () => {
    const scenario = makeScenario();
    runSeconds(scenario, 2, () => -54);
    // Constant tones get strong→continuing downgraded by the flat-signal dynamics path, so modulate.
    runSeconds(scenario, 1.3, i => (i % 5 === 0 ? -25 : -35));
    scenario.harness.flush();
    assert.strictEqual(eventsOf(scenario, 'emit').length, 1);
    assert.strictEqual(scenario.harness.headLive, false);

    const secondUtteranceDurationMs = 1500;
    runSeconds(
      scenario,
      secondUtteranceDurationMs / 1000,
      i => (i % 5 === 0 ? -25 : -35),
    );
    scenario.harness.flush();

    const emits = eventsOf(scenario, 'emit');
    assert.strictEqual(emits.length, 2);
    assert.ok(
      emits[1].n / SAMPLES_PER_MS
        <= 500 + secondUtteranceDurationMs + EPSILON_MS,
    );
    assert.strictEqual(scenario.harness.headLive, false);
  });

  it('caps the head at the newest 2.5 seconds before onset by default', () => {
    const scenario = makeScenario();
    runSeconds(scenario, 8, () => -54);
    runSeconds(scenario, 1.2, () => -35);

    assert.strictEqual(scenario.harness.headSamples, 40000);
    assert.strictEqual(scenario.harness.headPrependedAtOnset, 8000);
    scenario.harness.flush();

    const emits = eventsOf(scenario, 'emit');
    assert.strictEqual(emits.length, 1);
    const emittedMs = emits[0].n / SAMPLES_PER_MS;
    assert.ok(emittedMs >= 500);
    assert.ok(emittedMs <= 500 + 1200 + EPSILON_MS);
  });

  it('retains the head across a below-minimums discard until a later emit', () => {
    const scenario = makeScenario({
      endpointSilenceMs: 700,
      minSpeechSamples: 2000 * SAMPLES_PER_MS,
      // Retention across a rejected first utterance is the subject here; preserve the old capacity.
      headBufferSamples: 6000 * SAMPLES_PER_MS,
    });
    runSeconds(scenario, 1.5, () => -54);
    runSeconds(scenario, 1.2, () => -35);
    runSeconds(scenario, 0.8, () => -54);

    const discard = scenario.events.find(
      event => event.k === 'discard' && event.r === 'below_minimums',
    );
    assert.ok(discard !== undefined);
    assert.strictEqual(scenario.harness.headLive, true);

    runSeconds(scenario, 0.3, () => -54);
    runSeconds(scenario, 2.5, () => -35);
    const secondStart = eventsOf(scenario, 'start_utterance').at(-1);
    assert.ok(secondStart !== undefined);
    assert.strictEqual(scenario.harness.headLive, true);
    scenario.harness.flush();

    const emits = eventsOf(scenario, 'emit');
    assert.strictEqual(emits.length, 1);
    assert.ok(
      emits[0].n / SAMPLES_PER_MS
        >= secondStart.timeSeconds * 1000 - EPSILON_MS,
    );
    assert.ok(discard.timeSeconds < emits[0].timeSeconds);
    assert.strictEqual(scenario.harness.headLive, false);
  });

  it('trims quiet head audio before a late onset but retains the final 500 ms', () => {
    const scenario = makeScenario({ endpointSilenceMs: 700 });
    runSeconds(scenario, 4, () => -54);
    runSeconds(scenario, 1.2, i => (i % 5 === 0 ? -25 : -35));
    assert.strictEqual(scenario.harness.headSamples, 2500 * SAMPLES_PER_MS);
    assert.strictEqual(scenario.harness.headPrependedAtOnset, 500 * SAMPLES_PER_MS);
    scenario.harness.flush();

    const emit = eventsOf(scenario, 'emit')[0];
    assert.ok(emit !== undefined);
    assert.ok(emit.n / SAMPLES_PER_MS < 500 + 1200 + 700 + EPSILON_MS);
  });

  it('uses the gate-emitted higher silence threshold in a loud room', () => {
    const scenario = makeScenario({ endpointSilenceMs: 700 });
    runSeconds(scenario, 4, () => -35);
    runSeconds(scenario, 1.2, i => (i % 5 === 0 ? -10 : -20));
    scenario.harness.flush();

    const headFrames = scenario.harness.headSlices;
    assert.ok(headFrames.length > 0);
    assert.ok(headFrames[0].silenceThresholdDb > -60);
    assert.strictEqual(scenario.harness.headPrependedAtOnset, 500 * SAMPLES_PER_MS);
  });

  it('stops trimming at speech that begins one second into the retained head', () => {
    const scenario = makeScenario({
      endpointSilenceMs: 700,
      gateConfig: {
        ...USER_GATE_CONFIG,
        mode: 'calibrated',
        calibrationMs: 1500,
        calibratedOffsetDb: 10,
      },
    });
    runSeconds(scenario, 2.5, () => -54);
    runSeconds(scenario, 0.3, () => -50);
    runSeconds(scenario, 1.2, () => -54);
    runSeconds(scenario, 1.2, i => (i % 5 === 0 ? -25 : -35));
    scenario.harness.flush();

    // At onset near 4.07 s, the 2.5 s ring begins near 1.57 s. Speech at 2.5 s
    // starts about 930 ms into that ring, leaving about 1570 ms after trim stops there.
    assert.ok(scenario.harness.headPrependedAtOnset >= 1500 * SAMPLES_PER_MS);
    assert.ok(scenario.harness.headPrependedAtOnset <= 1600 * SAMPLES_PER_MS);
  });

  it('trims static-mode head audio using its gate-emitted silence threshold', () => {
    const scenario = makeScenario({
      endpointSilenceMs: 700,
      gateConfig: { mode: 'static', staticRms: 0.025 },
    });
    runSeconds(scenario, 4, () => -54);
    runSeconds(scenario, 1.2, () => -25);
    assert.strictEqual(scenario.harness.headSamples, 2500 * SAMPLES_PER_MS);
    assert.strictEqual(scenario.harness.headPrependedAtOnset, 500 * SAMPLES_PER_MS);
    assert.ok(scenario.harness.headSlices.every(slice => Number.isFinite(slice.silenceThresholdDb)));
    scenario.harness.flush();

    assert.strictEqual(scenario.harness.sessionConfig.mode, 'static');
  });

  it('does not trim a head shorter than 500 ms', () => {
    const scenario = makeScenario({
      endpointSilenceMs: 700,
      gateConfig: { mode: 'static', staticRms: 0.025 },
    });
    runSeconds(scenario, 0.3, () => -54);
    runSeconds(scenario, 1.2, () => -25);
    // The endpoint needs 70 ms of consecutive strong frames, so 300 + 70 = 370 ms
    // have entered the head by onset; all 370 ms are retained (less than the 500 ms guard).
    // The 370 ms head at onset is below the 500 ms guard, so nothing is trimmed.
    assert.ok(scenario.harness.headPrependedAtOnset < 500 * SAMPLES_PER_MS);
    assert.strictEqual(scenario.harness.headPrependedAtOnset, 370 * SAMPLES_PER_MS);
    const start = eventsOf(scenario, 'start_utterance')[0];
    assert.strictEqual(start.n, scenario.harness.headPrependedAtOnset);
    scenario.harness.flush();

    const emitted = eventsOf(scenario, 'emit')[0];
    assert.strictEqual(emitted.s1, scenario.harness.sessionElapsedSamples / 16);
    assert.strictEqual(emitted.s1 - emitted.s0, emitted.n / SAMPLES_PER_MS);
  });
});
