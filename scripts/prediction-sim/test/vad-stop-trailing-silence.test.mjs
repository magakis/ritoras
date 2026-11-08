import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const FRAME_MS = 10;
const POST_ROLL_SAMPLES = 400 * 16;
const VAD_PROFILES = ['dsp', 'silero'];
const DISK_PATHS = [false, true];
const TOGGLE_STATES = [false, true];

function makeHarness({
  profile,
  diskRecovery,
  trimTrailingSilenceOnStopEnabled,
  endpointSilenceMs = 1_000,
  maxNoiseSamples = 6 * 16_000,
  diskWriteFailureAfterSamples = null,
  onEvent,
}) {
  return makeRecorderHarness({
    frameMs: FRAME_MS,
    endpointSilenceMs,
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs,
      resumeMs: 120,
      ambiguousRescueMs: 320,
    },
    minChunkSamples: 0,
    minSpeechSamples: 0,
    maxNoiseSamples,
    gateConfig: { mode: 'static', staticRms: 0.025 },
    recorderConfig: {
      vadSource: profile,
      sileroStartThreshold: 0.45,
      sileroStopThreshold: 0.30,
      sileroSmoothingSteps: 1,
      postRollSamples: POST_ROLL_SAMPLES,
      trimTrailingSilenceOnStopEnabled,
    },
    diskRecovery,
    diskWriteFailureAfterSamples,
    onEvent,
  });
}

function driveFrames(harness, profile, kind, count) {
  const frameDb = kind === 'speech' ? -20 : -80;
  const sileroProbability = kind === 'speech' ? 0.9 : 0.1;
  for (let index = 0; index < count; index += 1) {
    if (profile === 'silero') {
      harness.drive(frameDb, FRAME_MS / 1_000, { sileroProbability });
    } else {
      harness.drive(frameDb, FRAME_MS / 1_000);
    }
  }
}

function emitEvents(events) {
  return events.filter(event => event.k === 'emit');
}

function endpointEmissions(events) {
  return emitEvents(events).filter(event => event.r === 'endpoint');
}

function stopHarness(harness, events) {
  const firstStopEventIndex = events.length;
  harness.end({ flush: true });
  return events.slice(firstStopEventIndex);
}

function driveSpeechUntilEndpoint(harness, events, profile) {
  const previousEndpointCount = endpointEmissions(events).length;
  driveFrames(harness, profile, 'speech', 80);
  let silenceFrames = 0;
  while (endpointEmissions(events).length === previousEndpointCount && silenceFrames < 250) {
    driveFrames(harness, profile, 'silence', 1);
    silenceFrames += 1;
  }
  const endpointEmission = endpointEmissions(events)[previousEndpointCount];
  assert.ok(endpointEmission, `${profile} endpoint must emit before stop`);
  return endpointEmission;
}

describe('manual stop trailing-silence rule', () => {
  for (const profile of VAD_PROFILES) {
    for (const diskRecovery of DISK_PATHS) {
      for (const trimTrailingSilenceOnStopEnabled of TOGGLE_STATES) {
        for (const tailMs of [200, 2_000]) {
          it(
            `case 1: ${profile}, ${diskRecovery ? 'disk' : 'memory'}, toggle ${trimTrailingSilenceOnStopEnabled ? 'on' : 'off'}, ${tailMs} ms`,
            () => {
              const events = [];
              const harness = makeHarness({
                profile,
                diskRecovery,
                trimTrailingSilenceOnStopEnabled,
                onEvent: event => events.push(event),
              });
              const endpointEmission = driveSpeechUntilEndpoint(harness, events, profile);
              const emissionsBeforeStop = emitEvents(events).length;
              driveFrames(harness, profile, 'silence', tailMs / FRAME_MS);
              const stopEndSample = harness.sessionElapsedSamples;
              const pendingSilenceSamples = stopEndSample - endpointEmission.sourceEndSample;

              const stopEvents = stopHarness(harness, events);
              const stopEmissions = stopEvents.filter(event => event.k === 'emit');
              assert.ok(stopEvents.some(event => event.k === 'session_end'));

              assert.equal(harness.sessionConfig.trimTrailingSilenceOnStopEnabled,
                trimTrailingSilenceOnStopEnabled);
              if (trimTrailingSilenceOnStopEnabled) {
                assert.equal(stopEmissions.length, 0,
                  'silence-only pending audio must not be emitted');
                assert.deepEqual(harness.lastStopTailDecision, {
                  action: 'suppress',
                  trimmedSamples: 0,
                  suppressedSamples: pendingSilenceSamples,
                });
              } else {
                assert.equal(harness.lastStopTailDecision.action, 'passthrough');
                assert.equal(stopEmissions.length, 1);
                assert.equal(stopEmissions[0].n, pendingSilenceSamples);
                assert.equal(emitEvents(events).length, emissionsBeforeStop + 1);
              }
            },
          );
        }
      }
    }

    for (const diskRecovery of DISK_PATHS) {
      for (const trimTrailingSilenceOnStopEnabled of TOGGLE_STATES) {
        for (const tailMs of [0, 200, 900]) {
          it(
            `case 2: ${profile}, ${diskRecovery ? 'disk' : 'memory'}, toggle ${trimTrailingSilenceOnStopEnabled ? 'on' : 'off'}, ${tailMs} ms tail`,
            () => {
              const events = [];
              const harness = makeHarness({
                profile,
                diskRecovery,
                trimTrailingSilenceOnStopEnabled,
                endpointSilenceMs: 2_000,
                onEvent: event => events.push(event),
              });
              driveFrames(harness, profile, 'speech', 80);
              driveFrames(harness, profile, 'silence', tailMs / FRAME_MS);
              assert.equal(emitEvents(events).length, 0,
                'stop occurs before an endpoint emission');

              const stopEndSample = harness.sessionElapsedSamples;
              const tailSamples = tailMs * 16;
              const expectedTrimSamples = trimTrailingSilenceOnStopEnabled
                ? Math.max(0, tailSamples - POST_ROLL_SAMPLES)
                : 0;
              const expectedEndSample = stopEndSample - expectedTrimSamples;
              const stopEvents = stopHarness(harness, events);
              const stopEmissions = stopEvents.filter(event => event.k === 'emit');

              assert.ok(stopEvents.some(event => event.k === 'session_end'));
              assert.equal(stopEmissions.length, 1);
              assert.equal(stopEmissions[0].sourceEndSample, expectedEndSample);
              assert.equal(stopEmissions[0].n, expectedEndSample);
              assert.deepEqual(harness.lastStopTailDecision, {
                action: trimTrailingSilenceOnStopEnabled ? 'trim' : 'passthrough',
                trimmedSamples: expectedTrimSamples,
                suppressedSamples: 0,
              });
            },
          );
        }
      }
    }
  }

  for (const profile of VAD_PROFILES) {
    for (const diskRecovery of DISK_PATHS) {
      it(`case 2 preserves a burst just before stop (${profile}, ${diskRecovery ? 'disk' : 'memory'})`, () => {
        const events = [];
        const harness = makeHarness({
          profile,
          diskRecovery,
          trimTrailingSilenceOnStopEnabled: true,
          endpointSilenceMs: 1_500,
          onEvent: event => events.push(event),
        });
        driveFrames(harness, profile, 'speech', 30);
        driveFrames(harness, profile, 'silence', 80);
        driveFrames(harness, profile, 'speech', 5);
        assert.equal(emitEvents(events).length, 0, 'the burst remains inside the endpoint window');

        const stopEndSample = harness.sessionElapsedSamples;
        const stopEvents = stopHarness(harness, events);
        const stopEmission = stopEvents.find(event => event.k === 'emit');

        assert.ok(stopEmission);
        assert.equal(stopEmission.sourceEndSample, stopEndSample);
        assert.equal(harness.lastStopTailDecision.action, 'trim');
        assert.equal(harness.lastStopTailDecision.trimmedSamples, 0);
      });
    }
  }

  for (const profile of VAD_PROFILES) {
    it(`suppresses an over-six-second shed tail after endpoint (${profile})`, () => {
      const events = [];
      const harness = makeHarness({
        profile,
        diskRecovery: true,
        trimTrailingSilenceOnStopEnabled: true,
        onEvent: event => events.push(event),
      });
      const endpointEmission = driveSpeechUntilEndpoint(harness, events, profile);
      const emissionsBeforeStop = emitEvents(events).length;
      driveFrames(harness, profile, 'silence', 7_000 / FRAME_MS);
      assert.ok(harness.retentionShedCount > 0, 'the tail must cross the bounded retained-gap limit');
      const expectedSuppressedSamples = harness.sessionElapsedSamples - endpointEmission.sourceEndSample;

      const stopEvents = stopHarness(harness, events);

      assert.equal(stopEvents.filter(event => event.k === 'emit').length, 0);
      assert.equal(emitEvents(events).length, emissionsBeforeStop);
      assert.equal(harness.lastStopTailDecision.action, 'suppress');
      assert.equal(harness.lastStopTailDecision.suppressedSamples, expectedSuppressedSamples);
      assert.ok(stopEvents.some(event => event.k === 'session_end'));
    });
  }

  it('preserves interior recovered spans before suppressing the terminal silence remainder', () => {
    const events = [];
    const harness = makeHarness({
      profile: 'dsp',
      diskRecovery: true,
      trimTrailingSilenceOnStopEnabled: true,
      endpointSilenceMs: 100,
      maxNoiseSamples: 1_600,
      onEvent: event => events.push(event),
    });
    driveFrames(harness, 'dsp', 'speech', 15);
    driveFrames(harness, 'dsp', 'silence', 20);
    const firstEmission = emitEvents(events).find(event => event.r === 'endpoint');
    assert.ok(firstEmission);
    driveFrames(harness, 'dsp', 'silence', 300);
    driveFrames(harness, 'dsp', 'speech', 15);
    driveFrames(harness, 'dsp', 'silence', 20);
    const endpointEmissions = emitEvents(events).filter(event => event.r === 'endpoint');
    assert.equal(endpointEmissions.length, 2);
    const latestEmission = endpointEmissions[1];
    driveFrames(harness, 'dsp', 'silence', 500);

    const stopEvents = stopHarness(harness, events);
    const interiorRemainders = stopEvents.filter(event => (
      event.k === 'emit'
      && event.r === 'disk_remainder'
      && event.sourceEndSample <= latestEmission.sourceEndSample
    ));

    assert.ok(interiorRemainders.length > 0);
    assert.ok(interiorRemainders.every(event => event.sourceStartSample >= firstEmission.sourceEndSample));
    assert.ok(stopEvents.every(event => (
      event.k !== 'emit'
      || event.r !== 'disk_remainder'
      || event.sourceEndSample <= latestEmission.sourceEndSample
    )));
    assert.equal(harness.lastStopTailDecision.action, 'suppress');
    assert.ok(harness.lastStopTailDecision.suppressedSamples > 0);
  });

  it('passes case-2 disk recovery through when a WAV write failed during speech', () => {
    const events = [];
    const writtenSamplesAtFailure = 500 * 16;
    const harness = makeHarness({
      profile: 'dsp',
      diskRecovery: true,
      trimTrailingSilenceOnStopEnabled: true,
      endpointSilenceMs: 2_000,
      diskWriteFailureAfterSamples: writtenSamplesAtFailure,
      onEvent: event => events.push(event),
    });
    driveFrames(harness, 'dsp', 'speech', 120);
    driveFrames(harness, 'dsp', 'silence', 90);
    assert.equal(emitEvents(events).length, 0, 'stop is inside the endpoint window');
    assert.equal(harness.diskWrittenSampleCount, writtenSamplesAtFailure);
    assert.ok(harness.sessionElapsedSamples > harness.diskWrittenSampleCount);

    const stopEvents = stopHarness(harness, events);
    const recovered = stopEvents.filter(event => event.k === 'emit' && event.r === 'disk_remainder');

    assert.equal(recovered.length, 1);
    assert.equal(recovered[0].sourceStartSample, 0);
    assert.equal(recovered[0].sourceEndSample, writtenSamplesAtFailure);
    assert.equal(recovered[0].n, writtenSamplesAtFailure);
    assert.deepEqual(harness.lastStopTailDecision, {
      action: 'passthrough',
      trimmedSamples: 0,
      suppressedSamples: 0,
    });
  });

  it('still trims the case-2 disk remainder when WAV writes cover the full session', () => {
    const events = [];
    const harness = makeHarness({
      profile: 'dsp',
      diskRecovery: true,
      trimTrailingSilenceOnStopEnabled: true,
      endpointSilenceMs: 2_000,
      onEvent: event => events.push(event),
    });
    driveFrames(harness, 'dsp', 'speech', 120);
    driveFrames(harness, 'dsp', 'silence', 90);
    assert.equal(harness.diskWrittenSampleCount, harness.sessionElapsedSamples);
    const expectedTrimSamples = 900 * 16 - POST_ROLL_SAMPLES;
    const expectedEndSample = harness.sessionElapsedSamples - expectedTrimSamples;

    const stopEvents = stopHarness(harness, events);
    const recovered = stopEvents.filter(event => event.k === 'emit' && event.r === 'disk_remainder');

    assert.equal(recovered.length, 1);
    assert.equal(recovered[0].sourceEndSample, expectedEndSample);
    assert.equal(recovered[0].n, expectedEndSample);
    assert.deepEqual(harness.lastStopTailDecision, {
      action: 'trim',
      trimmedSamples: expectedTrimSamples,
      suppressedSamples: 0,
    });
  });

  it('trims only the terminal case-2 span after an earlier disk emission', () => {
    const events = [];
    const harness = makeHarness({
      profile: 'dsp',
      diskRecovery: true,
      trimTrailingSilenceOnStopEnabled: true,
      endpointSilenceMs: 2_000,
      maxNoiseSamples: 1_600,
      onEvent: event => events.push(event),
    });
    const firstEmission = driveSpeechUntilEndpoint(harness, events, 'dsp');
    driveFrames(harness, 'dsp', 'silence', 5_000 / FRAME_MS);
    const secondEmission = driveSpeechUntilEndpoint(harness, events, 'dsp');
    assert.ok(secondEmission.sourceEndSample > 0);
    assert.ok(harness.retentionShedCount > 0);
    driveFrames(harness, 'dsp', 'speech', 80);
    driveFrames(harness, 'dsp', 'silence', 900 / FRAME_MS);
    assert.equal(emitEvents(events).filter(event => event.r === 'endpoint').length, 2);

    const unadjustedSpans = harness.diskRecoverySpans();
    const sessionEndSample = harness.sessionElapsedSamples;
    const expectedTrimSamples = 900 * 16 - POST_ROLL_SAMPLES;
    const expectedEndSample = sessionEndSample - expectedTrimSamples;
    const expectedSpans = unadjustedSpans.flatMap(span => {
      const endSample = Math.min(span.endSample, expectedEndSample);
      return endSample > span.startSample
        ? [{ startSample: span.startSample, endSample }]
        : [];
    });
    const interiorSpans = expectedSpans.filter(span => (
      span.startSample >= firstEmission.sourceEndSample
      && span.endSample <= secondEmission.sourceStartSample
    ));
    assert.ok(interiorSpans.length > 0, 'the disk-remainder plan includes an interior gap');

    const stopEvents = stopHarness(harness, events);
    const recovered = stopEvents.filter(event => event.k === 'emit' && event.r === 'disk_remainder');

    assert.deepEqual(recovered.map(event => ({
      startSample: event.sourceStartSample,
      endSample: event.sourceEndSample,
    })), expectedSpans);
    assert.equal(recovered.at(-1)?.sourceEndSample, expectedEndSample);
    assert.deepEqual(harness.lastStopTailDecision, {
      action: 'trim',
      trimmedSamples: expectedTrimSamples,
      suppressedSamples: 0,
    });
  });

  it('keeps empty and sub-250 ms stop-flush paths unchanged with the toggle enabled', () => {
    const emptyEvents = [];
    const emptyHarness = makeHarness({
      profile: 'dsp',
      diskRecovery: false,
      trimTrailingSilenceOnStopEnabled: true,
      onEvent: event => emptyEvents.push(event),
    });
    stopHarness(emptyHarness, emptyEvents);
    assert.ok(['empty', 'priming_window'].includes(
      emptyEvents.find(event => event.k === 'stop_flush')?.r,
    ));
    assert.equal(emitEvents(emptyEvents).length, 0);
    assert.ok(emptyEvents.some(event => event.k === 'session_end'));

    const tailEvents = [];
    const tailHarness = makeHarness({
      profile: 'dsp',
      diskRecovery: false,
      trimTrailingSilenceOnStopEnabled: true,
      endpointSilenceMs: 1_000,
      onEvent: event => tailEvents.push(event),
    });
    driveFrames(tailHarness, 'dsp', 'speech', 5);
    driveFrames(tailHarness, 'dsp', 'silence', 10);
    stopHarness(tailHarness, tailEvents);
    assert.equal(tailEvents.find(event => event.k === 'stop_flush')?.r, 'tail_floor');
    assert.equal(emitEvents(tailEvents).length, 0);
    assert.ok(tailEvents.some(event => event.k === 'discard' && event.r === 'tail_floor'));
  });
});
