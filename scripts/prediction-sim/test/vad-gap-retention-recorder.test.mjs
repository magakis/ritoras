import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

function makeSilenceFilteringHarness({
  enabled = true,
  preRollMs = 200,
  postRollMs = 0,
  diskRecovery = false,
  endpointMachineEnabled = true,
  onEvent,
} = {}) {
  return makeRecorderHarness({
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
    endpointMachineEnabled,
    gateConfig: { mode: 'static', staticRms: 0.025 },
    recorderConfig: {
      postRollSamples: postRollMs * 16,
      trimTrailingSilenceOnStopEnabled: false,
      vadSilenceFilteringEnabled: enabled,
      vadSilenceFilteringPreRollMs: preRollMs,
    },
    diskRecovery,
    onEvent,
  });
}

function driveSpeechSegment(harness) {
  for (let index = 0; index < 15; index += 1) harness.drive(-20);
  for (let index = 0; index < 20; index += 1) harness.drive(-80);
}

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

  it('retains a six-second idle gap while a VAD-accepted endpoint accumulator is held', () => {
    const events = [];
    const maxNoiseSamples = 6 * 16_000;
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
      minChunkSamples: 300 * 16,
      minSpeechSamples: 300 * 16,
      maxNoiseSamples,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      onEvent: event => events.push(event),
    });

    for (let index = 0; index < 20; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);
    assert.equal(harness.endpoint.state, 'idle');
    assert.ok(events.some(event => event.k === 'outcome' && event.r === 'below_minimums_held'));
    assert.ok(harness.accumulatorHasSpeechEvidence);

    for (let index = 0; index < 601; index += 1) harness.drive(-80);

    assert.equal(harness.retentionShedCount, 0);
    assert.ok(harness.accumulatorSamples > maxNoiseSamples);
    assert.equal(events.some(event => event.k === 'discard' && event.r === 'noise_guard'), false);

    harness.flush();

    assert.ok(events.some(event => event.k === 'emit' && event.r === 'flush'));
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
      recorderConfig: { vadSilenceFilteringEnabled: false },
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

  it('drops the quiet gap except for the configured pre-roll', () => {
    const events = [];
    let harness;
    const utteranceStarts = [];
    harness = makeSilenceFilteringHarness({
      preRollMs: 200,
      onEvent: event => {
        events.push(event);
        if (event.k === 'start_utterance') {
          utteranceStarts.push(harness.sessionElapsedSamples);
        }
      },
    });

    driveSpeechSegment(harness);
    const firstEmission = events.find(event => event.k === 'emit');
    for (let index = 0; index < 50; index += 1) harness.drive(-80);
    driveSpeechSegment(harness);

    const emissions = events.filter(event => event.k === 'emit');
    assert.equal(emissions.length, 2);
    assert.ok(utteranceStarts[1] - firstEmission.sourceEndSample > 200 * 16);
    assert.equal(emissions[1].sourceStartSample, utteranceStarts[1] - 200 * 16);
  });

  it('keeps emitted source spans disjoint across filtered gaps', () => {
    const events = [];
    const harness = makeSilenceFilteringHarness({ onEvent: event => events.push(event) });
    driveSpeechSegment(harness);
    for (let index = 0; index < 70; index += 1) harness.drive(-80);
    driveSpeechSegment(harness);
    for (let index = 0; index < 90; index += 1) harness.drive(-80);
    driveSpeechSegment(harness);

    const emissions = events.filter(event => event.k === 'emit');
    assert.equal(emissions.length, 3);
    for (let index = 1; index < emissions.length; index += 1) {
      assert.ok(
        emissions[index].sourceStartSample >= emissions[index - 1].sourceEndSample,
        'a later chunk must not reuse source samples already emitted',
      );
    }
  });

  it('preserves short intra-chunk pauses while filtering is enabled', () => {
    const events = [];
    const harness = makeSilenceFilteringHarness({ onEvent: event => events.push(event) });
    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    const pauseStartSample = harness.sessionElapsedSamples;
    for (let index = 0; index < 5; index += 1) harness.drive(-80);
    const pauseEndSample = harness.sessionElapsedSamples;
    for (let index = 0; index < 15; index += 1) harness.drive(-20);
    for (let index = 0; index < 20; index += 1) harness.drive(-80);

    assert.ok(events.some(event => event.k === 'emit'));
    assert.ok(harness.emittedSourceSpans.some(span => (
      span.startSample <= pauseStartSample && span.endSample >= pauseEndSample
    )));
  });

  it('keeps speech-evident gap spans in addition to the configured pre-roll', () => {
    const harness = makeSilenceFilteringHarness({ preRollMs: 100 });
    harness.appendRetainedGap(3_200, 0, 'silence', -80, null);
    harness.appendRetainedGap(1_600, 3_200, 'continuing', -43, -50);
    harness.appendRetainedGap(3_200, 4_800, 'silence', -80, null);

    harness.moveRetainedGapToAccumulator();

    assert.deepEqual(harness.accumulatorSourceSpans, [
      { startSample: 3_200, endSample: 4_800 },
      { startSample: 6_400, endSample: 8_000 },
    ]);
    assert.deepEqual(harness.filteredSourceSpans, [
      { startSample: 0, endSample: 3_200 },
      { startSample: 4_800, endSample: 6_400 },
    ]);
  });

  it('excludes filtered gaps and speechless terminal audio from disk recovery', () => {
    const events = [];
    const harness = makeSilenceFilteringHarness({
      preRollMs: 200,
      diskRecovery: true,
      onEvent: event => events.push(event),
    });
    const firstSpan = { startSample: 0, endSample: 1_600 };
    harness.recordEmission({ t: 'ev', k: 'emit', id: 0, n: 1_600 }, [firstSpan]);
    harness.appendRetainedGap(8_000, 1_600, 'silence', -80, null);
    harness.moveRetainedGapToAccumulator();
    const secondSpans = harness.accumulatorSourceSpans.map(span => ({ ...span }));
    const secondSamples = secondSpans.reduce(
      (total, span) => total + span.endSample - span.startSample,
      0,
    );
    harness.recordEmission({ t: 'ev', k: 'emit', id: 1, n: secondSamples }, secondSpans);
    harness.clearDiskFlushAccumulator();
    harness.appendRetainedGap(5_000, 9_600, 'silence', -80, null);
    harness.sessionElapsedSamples = 14_600;
    harness.diskWrittenSampleCount = 14_600;

    assert.deepEqual(harness.diskRecoverySpans(), [
      { startSample: 9_600, endSample: 14_600 },
    ]);
    harness.flush();

    assert.equal(events.some(event => event.k === 'emit' && event.r === 'disk_remainder'), false);
    assert.equal(harness.lastStopTailDecision.action, 'suppress');
  });

  it('leaves endpoint-machine-disabled output unchanged when filtering is enabled', () => {
    for (const diskRecovery of [false, true]) {
      const outputBySetting = [];
      for (const enabled of [false, true]) {
        const events = [];
        const harness = makeSilenceFilteringHarness({
          enabled,
          // Preserve legacy silence chunks so the OFF/ON emissions are comparable.
          postRollMs: 400,
          endpointMachineEnabled: false,
          diskRecovery,
          onEvent: event => events.push(event),
        });
        for (let index = 0; index < 30; index += 1) harness.drive(-80);

        harness.flush();

        const emissions = events
          .filter(event => event.k === 'emit')
          .map(({ n, sourceStartSample, sourceEndSample }) => ({
            n,
            sourceStartSample,
            sourceEndSample,
          }));
        assert.equal(
          emissions.reduce((total, event) => total + event.n, 0),
          4_800,
        );
        assert.equal(harness.lastStopTailDecision.action, 'passthrough');
        outputBySetting.push(emissions);
      }
      assert.deepEqual(outputBySetting[1], outputBySetting[0]);
    }
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
