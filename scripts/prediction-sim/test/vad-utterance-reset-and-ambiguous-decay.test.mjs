import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  StreamingEndpoint,
  StreamingEndpointEvidence as E,
} from '../lib/streaming-endpoint.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const FRAME_MS = 10;
const FRAME_SAMPLES = 160;
const SAMPLE_RATE = 16_000;
const RESET_CONFIGURATION = {
  utteranceResetMarginDb: 12,
  utteranceEstablishMs: 500,
  utteranceLevelDescentDbPerSec: 1,
  utteranceLevelDescentCapDb: 8,
  utteranceLevelRaiseSustainMs: 300,
  ambiguousDecayGraceMs: 800,
  ambiguousDecayRate: 0.75,
};

function makeStaticHarness({
  endpointSilenceMs = 2_000,
  staticRms = 0.01,
  featureEnabled = true,
  endpointMachineEnabled = true,
  ambiguousDecayRate = RESET_CONFIGURATION.ambiguousDecayRate,
  ambiguousDecayGraceMs = RESET_CONFIGURATION.ambiguousDecayGraceMs,
  recorderConfig = {},
  onFrame,
  onEvent,
} = {}) {
  return makeRecorderHarness({
    frameMs: FRAME_MS,
    endpointSilenceMs,
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs,
      resumeMs: 120,
      ambiguousRescueMs: 320,
      ambiguousDecayGraceMs,
      ambiguousDecayRate,
    },
    endpointMachineEnabled,
    utteranceRelativeResetEnabled: featureEnabled,
    minChunkSamples: 0,
    minSpeechSamples: 0,
    gateConfig: { mode: 'static', staticRms },
    recorderConfig: { ...RESET_CONFIGURATION, ...recorderConfig },
    onFrame,
    onEvent,
  });
}

function driveFor(harness, frameDb, durationMs) {
  let latestFrame = null;
  let remainingMs = durationMs;
  while (remainingMs > 0) {
    const currentFrameMs = Math.min(FRAME_MS, remainingMs);
    latestFrame = harness.drive(frameDb, currentFrameMs / 1_000);
    remainingMs -= currentFrameMs;
  }
  return latestFrame;
}

function establishStaticSpeech(harness, frameDb = -25) {
  driveFor(harness, frameDb, 500);
  assert.equal(harness.endpoint.state, 'speechActive');
  assert.equal(harness.utteranceReferenceEstablished, true);
  return harness.utteranceLevelReferenceDb;
}

function makeDecayEndpoint({
  endpointSilenceMs = 700,
  ambiguousDecayGraceMs = 800,
  ambiguousDecayRate = 0.75,
  ambiguousRescueMs = 320,
  endEvidenceMs = 100,
} = {}) {
  const endpoint = new StreamingEndpoint({
    onsetMs: 70,
    endEvidenceMs,
    endpointSilenceMs,
    resumeMs: 120,
    ambiguousRescueMs,
    ambiguousDecayEnabled: true,
    ambiguousDecayGraceMs,
    ambiguousDecayRate,
  });
  for (let index = 0; index < 7; index += 1) endpoint.process(E.strong, FRAME_SAMPLES);
  assert.equal(endpoint.state, 'speechActive');
  return endpoint;
}

function makeAdaptiveHarness() {
  const harness = makeRecorderHarness({
    frameMs: FRAME_MS,
    endpointSilenceMs: 2_000,
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs: 2_000,
      resumeMs: 120,
      ambiguousRescueMs: 320,
      ambiguousDecayGraceMs: 800,
      ambiguousDecayRate: 0.75,
    },
    utteranceRelativeResetEnabled: true,
    recorderConfig: RESET_CONFIGURATION,
    minChunkSamples: 0,
    minSpeechSamples: 0,
    gateConfig: {
      mode: 'adaptive',
      adaptiveDeltaDb: 7,
      adaptiveContinuationDeltaDb: 4,
      adaptiveAbsoluteSpeechFloorDb: -50,
    },
  });
  harness.gate.floorDb = -45;
  harness.gate.coldStartConverged = true;
  harness.gate.adaptiveRefinementComplete = true;
  harness.gate.adaptivePrimed = true;
  harness.primingComplete = true;
  for (let index = 0; index < 100; index += 1) harness.drive(-45);
  return harness;
}

function establishAdaptiveSpeech(harness) {
  driveFor(harness, -10, 500);
  assert.equal(harness.endpoint.state, 'speechActive');
  assert.equal(harness.utteranceReferenceEstablished, true);
  assert.equal(harness.utteranceLevelReferenceDb, -10);
}

function switchOffFrameProjection(frames) {
  return frames.map(frame => [
    frame.e,
    frame.sp,
    frame.ps,
    frame.es,
    frame.d,
    frame.ss,
    frame.us,
    frame.uq,
    frame.ar,
    frame.ac,
    frame.wc,
    frame.ts,
  ]);
}

describe('utterance-relative reset qualification', () => {
  it('seeds startup reference from 300ms-supported speech levels, not a 100ms crest', () => {
    const harness = makeRecorderHarness({
      frameMs: FRAME_MS,
      endpointSilenceMs: 2_000,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs: 2_000,
        resumeMs: 120,
        ambiguousRescueMs: 320,
        ambiguousDecayGraceMs: 800,
        ambiguousDecayRate: 0.75,
      },
      utteranceRelativeResetEnabled: true,
      recorderConfig: RESET_CONFIGURATION,
      minChunkSamples: 0,
      minSpeechSamples: 0,
      gateConfig: {
        mode: 'adaptive',
        adaptiveDeltaDb: 7,
        adaptiveContinuationDeltaDb: 4,
        adaptiveAbsoluteSpeechFloorDb: -50,
      },
    });
    harness.gate.floorDb = -65;
    harness.gate.coldStartConverged = true;
    harness.gate.adaptiveRefinementComplete = true;
    harness.gate.adaptivePrimed = true;
    harness.primingComplete = true;
    for (let index = 0; index < 100; index += 1) harness.drive(-65);
    harness.gate.updateFloorTracking = () => {};

    driveFor(harness, -30, 100);
    driveFor(harness, -8, 100);
    for (let index = 0; index < 30; index += 1) {
      harness.drive(index % 2 === 0 ? -38 : -32);
    }

    assert.equal(harness.utteranceReferenceEstablished, true);
    assert.equal(harness.utteranceLevelReferenceDb, -32);
    assert.equal(harness.endpoint.state, 'speechActive');

    let finalizations = 0;
    let strippedSpeechFrames = 0;
    for (let index = 0; index < 750; index += 1) {
      const frame = harness.drive(index % 2 === 0 ? -38 : -32);
      if (frame.decision.type === 'finalizeUtterance') finalizations += 1;
      if (frame.frameRecord.uq === 'stripped') strippedSpeechFrames += 1;
    }
    assert.equal(finalizations, 0);
    assert.equal(strippedSpeechFrames, 0);
    assert.equal(harness.endpoint.state, 'speechActive');
  });

  it('keeps a continuous 15 dB quiet fade alive through the descent cap', () => {
    const harness = makeStaticHarness();
    establishStaticSpeech(harness);

    let finalizations = 0;
    let referenceAfterThreeSeconds = null;
    for (let index = 0; index < 600; index += 1) {
      const frameDb = -25 - (14.9 * index) / 599;
      const frame = harness.drive(frameDb);
      if (frame.decision.type === 'finalizeUtterance') finalizations += 1;
      if (index === 299) referenceAfterThreeSeconds = harness.utteranceLevelReferenceDb;
    }

    assert.equal(finalizations, 0);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.ok(referenceAfterThreeSeconds <= -27.9);
    assert.ok(harness.utteranceLevelReferenceDb > -33);
    assert.equal(harness.chunkCount, 0);
  });

  it('finalizes 3.47s after a newly established 18 dB pause and retains re-onset audio', () => {
    const events = [];
    const harness = makeStaticHarness({ onEvent: event => events.push(event) });
    establishStaticSpeech(harness, -25);
    const pauseStartSeconds = harness.sessionElapsedSamples / SAMPLE_RATE;
    let finalizer = null;

    for (let index = 0; index < 500; index += 1) {
      const frame = harness.drive(-43);
      if (frame.decision.type === 'finalizeUtterance') {
        finalizer = frame;
        break;
      }
    }

    assert.ok(finalizer);
    const pauseDurationSeconds = harness.sessionElapsedSamples / SAMPLE_RATE - pauseStartSeconds;
    assert.ok(Math.abs(pauseDurationSeconds - 3.47) <= 0.01);
    assert.equal(finalizer.endpointEvidence, 'ambiguous');
    const firstEmission = events.find(event => event.k === 'emit' && event.r === 'endpoint');
    assert.ok(firstEmission);
    assert.ok(firstEmission.sourceEndSample / SAMPLE_RATE > pauseStartSeconds);

    driveFor(harness, -43, 100);
    const firstSpeechReturnSample = harness.sessionElapsedSamples;
    driveFor(harness, -25, 500);
    assert.ok(firstEmission.sourceEndSample < firstSpeechReturnSample);
    let secondFinalized = false;
    for (let index = 0; index < 250; index += 1) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        secondFinalized = true;
        break;
      }
    }
    const emissions = events.filter(event => event.k === 'emit');
    assert.equal(secondFinalized, true);
    assert.ok(emissions.length >= 2);
    assert.equal(emissions[1].sourceStartSample, firstEmission.sourceEndSample);
  });

  it('ignores a 100–200ms loud outlier but accepts a 300ms sustained level raise', () => {
    const harness = makeStaticHarness();
    const initialReferenceDb = establishStaticSpeech(harness);

    for (let index = 0; index < 15; index += 1) {
      const frame = harness.drive(-10);
      assert.notEqual(frame.frameRecord.uq, 'stripped');
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }
    const outlierReferenceDb = harness.utteranceLevelReferenceDb;
    assert.ok(outlierReferenceDb <= initialReferenceDb);
    assert.ok(outlierReferenceDb >= initialReferenceDb - 0.2);

    for (let index = 0; index < 15; index += 1) harness.drive(-10);
    assert.ok(harness.utteranceLevelReferenceDb >= -10);
    assert.equal(harness.endpoint.state, 'speechActive');
  });

  it('continues to reset for a user 11 dB below a TV-established reference after TV stops', () => {
    const harness = makeStaticHarness();
    establishStaticSpeech(harness, -15);

    for (let index = 0; index < 600; index += 1) {
      const frame = harness.drive(-26);
      assert.equal(frame.endpointEvidence, 'strong');
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }

    assert.equal(harness.endpoint.state, 'speechActive');
    assert.ok(harness.utteranceLevelReferenceDb > -27);
  });

  it('retains sub-ct residual audio through weighted decay despite source ambiguity', () => {
    // Sub-ct speech cannot be source-separated from the established TV level;
    // the guarantee is bounded finalization plus retention, not a speech label.
    const events = [];
    const harness = makeAdaptiveHarness();
    harness.gate.floorDb = -38;
    harness.gate.updateFloorTracking = () => {};
    harness.emitEvent = event => events.push(event);
    establishAdaptiveSpeech(harness);
    const pauseStartSample = harness.sessionElapsedSamples;
    let sawStrippedPromotion = false;
    let firstAmbiguousStartSample = null;
    let accumulatorAtFirstAmbiguousSamples = 0;
    let finalizer = null;
    for (let index = 0; index < 500; index += 1) {
      const frameDb = [-50, -46, -43, -46][index % 4];
      const frameStartSample = harness.sessionElapsedSamples;
      const accumulatedSilenceBeforeFrame = harness.endpoint.accumulatedSilenceSamples;
      const frame = harness.drive(frameDb);
      if (firstAmbiguousStartSample === null && frame.endpointEvidence === 'ambiguous') {
        firstAmbiguousStartSample = frameStartSample;
        accumulatorAtFirstAmbiguousSamples = accumulatedSilenceBeforeFrame;
      }
      sawStrippedPromotion ||= frame.output.speechShaped
        && frame.endpointEvidence === 'ambiguous';
      if (frame.decision.type === 'finalizeUtterance') {
        finalizer = frame;
        break;
      }
    }

    assert.equal(sawStrippedPromotion, true);
    assert.ok(finalizer);
    assert.notEqual(firstAmbiguousStartSample, null);
    const expectedFinalizeSample = firstAmbiguousStartSample
      + harness.endpoint.configuration.ambiguousDecayGraceSamples
      + (harness.endpoint.configuration.endpointSilenceSamples - accumulatorAtFirstAmbiguousSamples)
        / 0.75;
    assert.ok(Math.abs(harness.sessionElapsedSamples - expectedFinalizeSample) <= FRAME_SAMPLES);
    const emission = events.find(event => event.k === 'emit' && event.r === 'endpoint');
    assert.ok(emission);
    assert.ok(emission.sourceStartSample <= pauseStartSample);
    assert.equal(emission.sourceEndSample, harness.sessionElapsedSamples);
    assert.equal(emission.n, emission.sourceEndSample - emission.sourceStartSample);
  });

  it('establishes from intermittent classified evidence totaling 500ms, not wall time', () => {
    const harness = makeStaticHarness();
    driveFor(harness, -25, 200);
    assert.equal(harness.utteranceEstablishEvidenceSamples, 200 * 16);
    driveFor(harness, -44.5, 100);
    assert.equal(harness.utteranceEstablishEvidenceSamples, 200 * 16);
    driveFor(harness, -25, 150);
    assert.equal(harness.utteranceEstablishEvidenceSamples, 350 * 16);
    driveFor(harness, -80, 100);
    assert.equal(harness.utteranceEstablishEvidenceSamples, 350 * 16);
    driveFor(harness, -25, 150);

    assert.equal(harness.utteranceEstablishEvidenceSamples, 500 * 16);
    assert.equal(harness.utteranceReferenceEstablished, true);
    assert.equal(harness.utteranceLevelReferenceDb, -25);
  });
});

describe('ambiguous decay accounting', () => {
  it('preserves ambiguity across silence/rescue hops without double-credit', () => {
    const endpoint = makeDecayEndpoint();
    const milliseconds = value => value * 16;

    endpoint.process(E.silence, milliseconds(100));
    endpoint.process(E.ambiguous, milliseconds(200));
    endpoint.process(E.silence, milliseconds(100));
    assert.equal(endpoint.ambiguousRunSamples, milliseconds(200));
    assert.equal(endpoint.accumulatedSilenceSamples, milliseconds(200));
    endpoint.process(E.ambiguous, milliseconds(120));
    assert.equal(endpoint.state, 'speechActive');
    assert.equal(endpoint.ambiguousRunSamples, milliseconds(320));
    assert.equal(endpoint.accumulatedSilenceSamples, milliseconds(200));

    endpoint.process(E.silence, milliseconds(100));
    endpoint.process(E.ambiguous, milliseconds(400));
    endpoint.process(E.silence, milliseconds(100));
    endpoint.process(E.ambiguous, milliseconds(80));
    endpoint.process(E.silence, milliseconds(100));
    endpoint.process(E.ambiguous, milliseconds(100));
    endpoint.process(E.silence, milliseconds(100));
    assert.equal(endpoint.ambiguousRunSamples, milliseconds(900));
    assert.equal(endpoint.accumulatedSilenceSamples, milliseconds(675));

    const finalize = endpoint.process(E.ambiguous, milliseconds(34));
    assert.equal(finalize.type, 'finalizeUtterance');
    assert.equal(endpoint.lastDecisionSilenceSamples, milliseconds(700.5));
    // Run 934ms − 800ms grace = 134ms; 134 × 0.75 = 100.5ms (1608 samples).
    assert.equal(endpoint.lastDecisionAmbiguousCreditSamples, milliseconds(100.5));
    assert.equal(endpoint.lastDecisionAmbiguousFrameCreditSamples, milliseconds(25.5));
    assert.equal(endpoint.lastDecisionAmbiguousRunSamples, milliseconds(934));
  });

  it('matches 10ms/100ms decay crossings and avoids fractional accumulation drift', () => {
    const finalizeAfterAmbiguity = frameSamples => {
      const endpoint = makeDecayEndpoint({
        endpointSilenceMs: 600,
        ambiguousDecayGraceMs: 100,
        ambiguousRescueMs: 100,
      });
      let elapsedSamples = 0;
      for (let index = 0; index < 1_000; index += 1) {
        elapsedSamples += frameSamples;
        const decision = endpoint.process(E.ambiguous, frameSamples);
        if (decision.type === 'finalizeUtterance') {
          return { endpoint, elapsedMs: elapsedSamples / 16 };
        }
      }
      assert.fail('ambiguous run should finalize at its analytic credit threshold');
    };

    for (const frameSamples of [160, 1_600]) {
      const { endpoint, elapsedMs } = finalizeAfterAmbiguity(frameSamples);
      const expectedElapsedMs = 100 + (600 / 0.75);
      assert.ok(Math.abs(elapsedMs - expectedElapsedMs) <= frameSamples / 16);
      assert.equal(endpoint.lastDecisionSilenceSamples, 600 * 16);
    }

    const longRun = makeDecayEndpoint({
      endpointSilenceMs: 1_000_000_000,
      ambiguousDecayGraceMs: 100,
      ambiguousRescueMs: 100,
      endEvidenceMs: 1_000_000_000,
    });
    const frameSamples = 1_365;
    const frameCount = 10_000;
    for (let index = 0; index < frameCount; index += 1) {
      longRun.process(E.ambiguous, frameSamples);
    }
    const analyticCreditSamples = (frameCount * frameSamples - 100 * 16) * 0.75;
    assert.equal(longRun.accumulatedSilenceSamples, analyticCreditSamples);
  });

  it('clears active credit immediately and holds pending credit through 120ms resume', () => {
    const active = makeDecayEndpoint({ endpointSilenceMs: 700 });
    const thresholdSamples = active.configuration.endpointSilenceSamples;
    active.accumulatedSilenceSamples = thresholdSamples - 0.5;
    active.accumulatedAmbiguousCreditSamples = thresholdSamples - 0.5;
    active.ambiguousRunSamples = 500;
    active.process(E.strong, FRAME_SAMPLES);
    assert.equal(active.state, 'speechActive');
    assert.equal(active.accumulatedSilenceSamples, 0);
    assert.equal(active.ambiguousRunSamples, 0);

    const ending = makeDecayEndpoint({ endpointSilenceMs: 700 });
    ending.process(E.silence, 100 * 16);
    ending.accumulatedSilenceSamples = ending.configuration.endpointSilenceSamples - 0.5;
    ending.accumulatedAmbiguousCreditSamples = 4_000;
    ending.ambiguousRunSamples = 500;
    ending.process(E.continuing, 119 * 16);
    assert.equal(ending.state, 'endPending');
    assert.equal(ending.resumeEvidenceSamples, 119 * 16);
    assert.equal(ending.accumulatedSilenceSamples, thresholdSamples - 0.5);
    assert.equal(ending.ambiguousRunSamples, 0);
    ending.process(E.strong, 1 * 16);
    assert.equal(ending.state, 'speechActive');
    assert.equal(ending.accumulatedSilenceSamples, 0);
    assert.equal(ending.accumulatedAmbiguousCreditSamples, 0);
  });

  it('keeps strict margin equality and the guarded 120s -22 dB floor refusal intact', () => {
    for (const { label, db, stripped } of [
      { label: 'below', db: -21.999, stripped: false },
      { label: 'equal', db: -22, stripped: false },
      { label: 'above', db: -22.001, stripped: true },
    ]) {
      const harness = makeAdaptiveHarness();
      establishAdaptiveSpeech(harness);
      const frame = harness.drive(db);
      assert.ok(['strong', 'continuing'].includes(frame.output.evidence), label);
      if (stripped) {
        assert.equal(frame.endpointEvidence, 'ambiguous', label);
        assert.equal(frame.frameRecord.uq, 'stripped', label);
      } else {
        assert.equal(frame.endpointEvidence, frame.output.evidence, label);
        assert.notEqual(frame.frameRecord.uq, 'stripped', label);
      }
    }

    const harness = makeAdaptiveHarness();
    establishAdaptiveSpeech(harness);
    const maximumReanchorFloor = -20 - harness.gate.effectiveAdaptiveDeltaDb;
    for (let index = 0; index < 12_000; index += 1) {
      const frame = harness.drive(-22);
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
      assert.ok(['strong', 'continuing'].includes(frame.endpointEvidence));
      assert.ok(harness.gate.snapshot.floorDb <= maximumReanchorFloor);
    }
    assert.equal(harness.gate.snapshot.floorDb, -45);
    assert.equal(harness.reanchorEventCount, 0);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.ok(Math.abs(harness.utteranceLevelReferenceDb - -18) < 0.02);
  });

  it('keeps master-off traces equivalent and treats a zero decay rate independently', () => {
    const traces = [
      [...Array(60).fill(-25), ...Array(100).fill(-43), ...Array(220).fill(-80)],
      [
        ...Array(60).fill(-25),
        ...Array(12).fill(-80),
        ...Array(35).fill(-25),
        ...Array(220).fill(-80),
      ],
    ];
    const runTrace = trace => {
      const frames = [];
      const events = [];
      const options = {
        frameMs: FRAME_MS,
        endpointSilenceMs: 2_000,
        endpointConfig: {
          onsetMs: 70,
          endEvidenceMs: 100,
          endpointSilenceMs: 2_000,
          resumeMs: 120,
          ambiguousRescueMs: 320,
          ambiguousDecayGraceMs: 800,
          ambiguousDecayRate: 0.75,
        },
        minChunkSamples: 0,
        minSpeechSamples: 0,
        utteranceRelativeResetEnabled: false,
        gateConfig: { mode: 'static', staticRms: 0.01 },
        onFrame: frame => frames.push(frame),
        onEvent: event => events.push(event),
      };
      const harness = makeRecorderHarness(options);
      for (const frameDb of trace) harness.drive(frameDb);
      harness.flush();
      return { frames, events };
    };
    for (const trace of traces) {
      const offRun = runTrace(trace);
      const repeatedOffRun = runTrace(trace);
      assert.deepEqual(
        switchOffFrameProjection(offRun.frames),
        switchOffFrameProjection(repeatedOffRun.frames),
      );
      assert.deepEqual(
        offRun.events.filter(event => event.k === 'emit' || event.k === 'stop_flush'),
        repeatedOffRun.events.filter(event => event.k === 'emit' || event.k === 'stop_flush'),
      );
    }

    const zeroRate = makeStaticHarness({ ambiguousDecayRate: 0 });
    establishStaticSpeech(zeroRate, -15);
    let stripped = false;
    for (let index = 0; index < 1_200; index += 1) {
      const frame = zeroRate.drive(-43);
      stripped ||= frame.frameRecord.uq === 'stripped';
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.equal(stripped, true);
    assert.equal(zeroRate.endpoint.accumulatedSilenceSamples, 0);
    assert.equal(zeroRate.endpoint.ambiguousRunSamples, 1_200 * FRAME_SAMPLES);

    // The 8 dB cap leaves these −43 dB classified frames 20 dB below reference.
    let silenceFinalizer = null;
    for (let index = 0; index < 200; index += 1) {
      const frame = zeroRate.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        silenceFinalizer = frame;
        break;
      }
    }
    assert.ok(silenceFinalizer);
    // 2,000ms / 10ms per frame × 160 samples per frame = 32,000 samples.
    assert.equal(
      zeroRate.endpoint.lastDecisionSilenceSamples,
      (2_000 / FRAME_MS) * FRAME_SAMPLES,
    );
    assert.equal(zeroRate.endpoint.lastDecisionAmbiguousCreditSamples, 0);
    assert.equal(zeroRate.endpoint.lastDecisionAmbiguousRunSamples, 1_200 * FRAME_SAMPLES);
  });

  it('is a no-op when the legacy endpoint machine is disabled', () => {
    const harness = makeStaticHarness({ endpointMachineEnabled: false, featureEnabled: true });
    const frame = harness.drive(-25);

    assert.equal(harness.utteranceRelativeResetEnabled, false);
    assert.equal(harness.endpoint.configuration.ambiguousDecayEnabled, false);
    assert.equal(harness.endpoint.state, 'idle');
    assert.equal(frame.frameRecord.uq, 'disabled');
    assert.equal(frame.frameRecord.e, frame.output.evidence);
    assert.equal(frame.frameRecord.d, 'none');
  });
});
