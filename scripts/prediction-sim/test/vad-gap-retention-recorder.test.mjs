import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

describe('recorder chunk-splitter retention', () => {
  it('sheds a voiceless idle gap only after it exceeds the six-second cap', () => {
    const silenceEvents = [];
    const maxNoiseSamples = 6 * 16_000;
    const silence = makeRecorderHarness({
      frameMs: 10,
      maxNoiseSamples,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => silenceEvents.push(event),
    });
    for (let index = 0; index < 600; index += 1) silence.drive(-80);
    assert.equal(silence.retentionShedCount, 0);
    silence.drive(-80);

    const shed = silenceEvents.find(event => event.r === 'noise_guard');
    assert.equal(shed.n, maxNoiseSamples + 160);
    assert.equal(silence.retentionShedCount, 1);
    assert.equal(silence.accumulatorSamples, 0);

    const voiced = makeRecorderHarness({
      frameMs: 100,
      maxNoiseSamples: 1_600,
      gateConfig: { mode: 'adaptive', adaptiveAbsoluteSpeechFloorDb: -80 },
    });
    voiced.primingComplete = true;
    voiced.gate.floorDb = -50;
    voiced.gate.coldStartConverged = true;
    voiced.gate.adaptiveRefinementComplete = true;
    voiced.gate.updateFloorTracking = () => {};
    assert.equal(voiced.drive(-43, 0.1).output.evidence, 'continuing');
    voiced.drive(-80, 0.1);

    assert.equal(voiced.retentionShedCount, 0);
    assert.equal(voiced.accumulatorSamples, 3_200);
    assert.equal(voiced.speechSamples, 1_600);
  });

  it('bridges a retained idle gap into the following chunk', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 100,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 100,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      minChunkSamples: 0,
      minSpeechSamples: 0,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });

    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);
    const firstEmission = events.find(event => event.k === 'emit');
    assert.ok(firstEmission);

    for (let index = 0; index < 50; index += 1) harness.drive(-80);
    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);

    const emissions = events.filter(event => event.k === 'emit');
    assert.equal(emissions.length, 2);
    assert.equal(emissions[1].s0, firstEmission.s1);
    assert.ok(emissions[1].s1 - emissions[1].s0 >= 800);
  });

  it('offers a zero-voice stop tail above 250 ms without speech gates', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      maxNoiseSamples: 10 * 16_000,
      minChunkSamples: 10_000,
      minSpeechSamples: 10_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 30; index += 1) harness.drive(-80);
    harness.flush();

    const emission = events.find(event => event.k === 'emit' && event.r === 'flush');
    assert.ok(emission);
    assert.equal(emission.n, 4_800);
    assert.equal(emission.sm, 0);
    assert.equal(harness.tailFloorSampleCount, 0);
  });

  it('accounts a sub-250 ms stop tail as a tail-floor drop', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      maxNoiseSamples: 10 * 16_000,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });
    for (let index = 0; index < 20; index += 1) harness.drive(-80);
    harness.flush();

    assert.equal(events.some(event => event.k === 'emit'), false);
    assert.ok(events.some(event => event.k === 'discard' && event.r === 'tail_floor'));
    assert.equal(harness.tailFloorSampleCount, 3_200);
    assert.equal(harness.emittedSampleCount
      + harness.shedSampleCount
      + harness.tailFloorSampleCount, harness.sessionElapsedSamples);
  });

  it('retains speech beyond the spill and former accumulator caps until endpoint silence', () => {
    const events = [];
    const speechFrameCount = 1_400;
    const expectedSpeechSamples = speechFrameCount * 1_600;
    const harness = makeRecorderHarness({
      frameMs: 100,
      endpointSilenceMs: 300,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 300,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      minChunkSamples: 300 * 16,
      minSpeechSamples: 300 * 16,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      recorderConfig: { postRollSamples: 0 },
      onEvent: event => events.push(event),
    });

    for (let index = 0; index < speechFrameCount; index += 1) harness.drive(-20);

    assert.ok(harness.accumulatorSamples > 2 * 1_048_576);
    assert.ok(harness.spilledSampleCount > 0);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.equal(harness.chunkCount, 0);
    assert.equal(events.some(event => event.k === 'emit' || event.k === 'split'), false);

    for (let index = 0; index < 20 && harness.chunkCount === 0; index += 1) {
      harness.drive(-80);
    }

    const emissions = events.filter(event => event.k === 'emit');
    assert.equal(emissions.length, 1);
    assert.equal(emissions[0].r, 'endpoint');
    assert.equal(emissions[0].n, expectedSpeechSamples);
    assert.equal(harness.emittedSampleCount, expectedSpeechSamples);
    assert.equal(harness.spilledSampleCount, 0);
    assert.equal(harness.spillOccurred, true);
    assert.deepEqual([
      harness.sessionConfig.maxChunkMs,
      harness.sessionConfig.splitSearchWindowMs,
      harness.sessionConfig.minSilenceAtSplitMs,
    ], [0, 0, 0]);
  });
});
