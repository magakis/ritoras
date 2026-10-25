import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

describe('recorder chunk-slicer retention', () => {
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

  it('holds a below-minimum finalize and carries its audio into the next emission', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 100,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      minSpeechSamples: 4_800,
      minChunkSamples: 4_800,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });

    for (let index = 0; index < 10; index += 1) harness.drive(-20);
    for (let index = 0; index < 11; index += 1) harness.drive(-80);

    assert.equal(events.some(event => event.k === 'emit'), false);
    assert.ok(events.some(event => event.k === 'outcome' && event.r === 'below_minimums_held'));
    assert.equal(harness.accumulatorSamples, 210 * 16);

    for (let index = 0; index < 25; index += 1) harness.drive(-20);
    for (let index = 0; index < 11; index += 1) harness.drive(-80);

    const emission = events.find(event => event.k === 'emit');
    assert.equal(emission.r, 'endpoint');
    assert.equal(emission.s0, 0);
    assert.equal(emission.n, 570 * 16);
    assert.equal(harness.accumulatorSamples, 0);
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

  it('splits at a silence gap, carries that suffix, and conserves every sample', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 10_000,
      minChunkSamples: 0,
      minSpeechSamples: 0,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      recorderConfig: {
        maxChunkSamples: 3_200,
        splitSearchSamples: 3_200,
        minimumSplitSilenceSamples: 160,
      },
      onEvent: event => events.push(event),
    });

    for (const db of [
      ...Array(10).fill(-20),
      ...Array(5).fill(-80),
      ...Array(25).fill(-20),
    ]) harness.drive(db);
    harness.flush();

    const splits = events.filter(event => event.k === 'split');
    assert.equal(splits.length, 2);
    assert.equal(splits[0].r, 'split_gap');
    assert.equal(splits[0].gapSamples, 800);
    assert.deepEqual([splits[0].s0, splits[0].s1], [0, 150]);
    assert.equal(splits[1].r, 'split_hardcut');
    assert.deepEqual([splits[1].s0, splits[1].s1], [150, 350]);
    assert.equal(harness.emittedSampleCount
      + harness.shedSampleCount
      + harness.tailFloorSampleCount, harness.sessionElapsedSamples);
  });
});
