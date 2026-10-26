import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  highBandRatioDb,
  rmsFromDb,
  VADHighBandRatioAnalyzer,
  VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT,
} from '../lib/vad-gate.mjs';
import {
  classifyEndPendingEvidence,
  makeRecorderHarness,
} from '../lib/recorder-sim.mjs';

const sampleRate = 16_000;
const frameSamples = 160;
const frameDuration = frameSamples / sampleRate;
const whisperLevelsDb = [-62.9, -61.4, -59.0, -60.2, -62.1];

function dcCorrectedRms(samples) {
  const mean = samples.reduce((total, sample) => total + sample, 0) / samples.length;
  const sumSquares = samples.reduce((total, sample) => total + (sample - mean) ** 2, 0);
  return Math.sqrt(sumSquares / samples.length);
}

function sineFrame(frequencyHz, rmsDb, frameIndex) {
  const amplitude = rmsFromDb(rmsDb) * Math.sqrt(2);
  const firstSample = frameIndex * frameSamples;
  return Array.from({ length: frameSamples }, (_, index) => (
    amplitude * Math.sin((2 * Math.PI * frequencyHz * (firstSample + index)) / sampleRate)
  ));
}

function hissFrame(targetRms, frameIndex) {
  let state = (frameIndex + 1) * 0x9e3779b1;
  const samples = Array.from({ length: frameSamples }, () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 0x80000000 - 1;
  });
  const rms = dcCorrectedRms(samples);
  const scale = targetRms / rms;
  return samples.map(sample => sample * scale);
}

function makeAdaptiveHarness({
  endpointSilenceMs = 900,
  maxNoiseSamples,
  gateConfig = {},
  onFrame,
} = {}) {
  return makeRecorderHarness({
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
    ...(maxNoiseSamples === undefined ? {} : { maxNoiseSamples }),
    onFrame,
    gateConfig: {
      adaptiveDeltaDb: 10,
      adaptiveContinuationDeltaDb: 6,
      adaptiveSilenceDeltaDb: 3,
      adaptiveAbsoluteSpeechFloorDb: -80,
      ...gateConfig,
    },
  });
}

function primeFloorAt(harness, floorDb = -60) {
  harness.primingComplete = true;
  harness.gate.floorDb = floorDb;
  harness.gate.coldStartConverged = true;
  harness.gate.adaptiveRefinementComplete = true;
  harness.gate.adaptivePrimed = true;
}

function prefillAmbient(harness, frameCount = 300) {
  for (let index = 0; index < frameCount; index += 1) harness.drive(-60);
}

function startSpeechAndEnterEndPending(harness) {
  prefillAmbient(harness);
  for (let index = 0; index < 20; index += 1) harness.drive(-40);
  assert.equal(harness.endpoint.state, 'speechActive');

  for (let index = 0; index < 20 && harness.endpoint.state !== 'endPending'; index += 1) {
    harness.drive(-80);
  }
  assert.equal(harness.endpoint.state, 'endPending');
}

function driveWhisperFrames(harness, frameCount, analyzer = new VADHighBandRatioAnalyzer()) {
  const results = [];
  for (let index = 0; index < frameCount; index += 1) {
    const frameDb = whisperLevelsDb[index % whisperLevelsDb.length];
    const samples = sineFrame(3_500, frameDb, index);
    const ratio = analyzer.process(samples, dcCorrectedRms(samples));
    results.push(harness.drive(frameDb, frameDuration, { highBandRatioDb: ratio }));
  }
  return results;
}

describe('spectral whisper detection and quiet-audio retention', () => {
  it('distinguishes high-band whispers from low-frequency fan energy', () => {
    const whisperAnalyzer = new VADHighBandRatioAnalyzer();
    const fanAnalyzer = new VADHighBandRatioAnalyzer();
    const whisper = sineFrame(3_500, -60, 0);
    const fan = sineFrame(180, -60, 0);
    const whisperRatio = whisperAnalyzer.process(whisper, dcCorrectedRms(whisper));
    const fanRatio = fanAnalyzer.process(fan, dcCorrectedRms(fan));

    assert.ok(whisperRatio >= VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT);
    assert.ok(fanRatio < VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT);
    assert.equal(highBandRatioDb(0, 0), -100);
  });

  it('adds speech-shape, short-spread, and high-band ratio to lean frame telemetry', () => {
    const frames = [];
    const harness = makeAdaptiveHarness({ onFrame: frame => frames.push(frame) });
    primeFloorAt(harness);
    const samples = sineFrame(3_500, -62, 0);
    const ratio = new VADHighBandRatioAnalyzer().process(samples, dcCorrectedRms(samples));

    harness.drive(-62, frameDuration, { highBandRatioDb: ratio });

    assert.equal(typeof frames[0].sh, 'boolean');
    assert.ok(Object.hasOwn(frames[0], 'hbr'));
    assert.equal(frames[0].hbr, ratio);
  });

  it('modulated low-level high-band speech resumes end-pending instead of banking silence', () => {
    const harness = makeAdaptiveHarness();
    startSpeechAndEnterEndPending(harness);

    const whisperFrames = driveWhisperFrames(harness, 80);

    assert.ok(whisperFrames.some(frame => frame.output.speechShaped));
    assert.ok(whisperFrames.some(frame => frame.endpointEvidence === 'continuing'));
    assert.ok(whisperFrames.every(frame => frame.decision.type !== 'finalizeUtterance'));
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.equal(harness.endpoint.accumulatedSilenceSamples, 0);
    assert.equal(harness.chunkCount, 0);
  });

  it('flat fan noise and unmodulated high-band hiss still bank silence and finalize', () => {
    const fanHarness = makeAdaptiveHarness({ endpointSilenceMs: 500 });
    startSpeechAndEnterEndPending(fanHarness);
    const fanAnalyzer = new VADHighBandRatioAnalyzer();
    let fanFinalized = false;
    for (let index = 0; index < 80; index += 1) {
      const samples = sineFrame(180, -60, index);
      const ratio = fanAnalyzer.process(samples, dcCorrectedRms(samples));
      const frame = fanHarness.drive(-60, frameDuration, { highBandRatioDb: ratio });
      assert.equal(frame.output.speechShaped, false);
      fanFinalized ||= frame.decision.type === 'finalizeUtterance';
      if (fanFinalized) break;
    }
    assert.ok(fanFinalized);
    assert.equal(fanHarness.chunkCount, 1);

    const hissHarness = makeAdaptiveHarness({ endpointSilenceMs: 500 });
    startSpeechAndEnterEndPending(hissHarness);
    const hissAnalyzer = new VADHighBandRatioAnalyzer();
    const targetRms = rmsFromDb(-60);
    let hissFinalized = false;
    for (let index = 0; index < 80; index += 1) {
      const samples = hissFrame(targetRms, index);
      const ratio = hissAnalyzer.process(samples, dcCorrectedRms(samples));
      assert.ok(ratio >= VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT);
      const frame = hissHarness.drive(-60, frameDuration, { highBandRatioDb: ratio });
      assert.equal(frame.output.speechShaped, false);
      hissFinalized ||= frame.decision.type === 'finalizeUtterance';
      if (hissFinalized) break;
    }
    assert.ok(hissFinalized);
    assert.equal(hissHarness.chunkCount, 1);
  });

  it('does not shed a quiet gap with a speech-level peak when evidence is under 100 ms', () => {
    const harness = makeAdaptiveHarness({
      maxNoiseSamples: 1_600,
      gateConfig: { adaptiveContinuationDeltaDb: 8 },
    });
    primeFloorAt(harness);
    for (let index = 0; index < 4; index += 1) harness.drive(-60);

    const peak = harness.drive(-52.5);
    assert.equal(peak.output.evidence, 'ambiguous');
    assert.equal(peak.output.speechShaped, false);
    // Stop at the first over-cap frame; later floor-level frames start a new gap.
    for (let index = 0; index < 6; index += 1) harness.drive(-60);

    assert.equal(harness.retentionShedCount, 0);
    assert.equal(harness.shedSampleCount, 0);
    assert.equal(harness.accumulatorSamples, harness.maxNoiseSamples + frameSamples);
    assert.equal(harness.retainedGapSamples, 0);
  });

  it('retains a preceding quiet-shaped span until a later strong onset opens', () => {
    const harness = makeAdaptiveHarness();
    primeFloorAt(harness);
    const quietFrames = driveWhisperFrames(harness, 40);
    assert.equal(harness.endpoint.state, 'idle');
    assert.ok(quietFrames.some(frame => frame.output.speechShaped));
    assert.ok(harness.retainedGapEvidenceSamples > 0);

    for (let index = 0; index < 20 && harness.endpoint.state !== 'speechActive'; index += 1) {
      harness.drive(-40);
    }

    assert.equal(harness.endpoint.state, 'speechActive');
    assert.ok(harness.headPrependedAtOnset > 0);
    assert.ok(harness.accumulatorSamples >= 40 * frameSamples);
    assert.equal(harness.retentionShedCount, 0);
  });

  it('leaves quiet-only onset idle but delivers the retained span on stop flush', () => {
    const harness = makeAdaptiveHarness();
    primeFloorAt(harness);
    const quietFrames = driveWhisperFrames(harness, 60);

    assert.ok(quietFrames.some(frame => frame.output.speechShaped));
    assert.equal(harness.endpoint.state, 'idle');
    assert.equal(harness.chunkCount, 0);
    assert.ok(harness.retainedGapSamples >= 250 * 16);

    harness.flush();

    assert.equal(harness.chunkCount, 1);
    assert.equal(harness.emittedSampleCount, 60 * frameSamples);
  });

  it('keeps raw strong evidence resumable during end-pending', () => {
    const harness = makeAdaptiveHarness();
    startSpeechAndEnterEndPending(harness);
    const strongFrame = {
      endpointState: harness.endpoint.state,
      evidence: 'strong',
      speechShaped: false,
      shortSpreadDb: 9,
      dynamicsSpreadDb: 14,
      flatSpreadDb: harness.gate.effectiveFlatSpreadDb,
      adjacentStepDb: 9,
      accumulatedSilenceSamples: harness.endpoint.accumulatedSilenceSamples,
      endpointSilenceSamples: harness.endpoint.configuration.endpointSilenceSamples,
      ambiguousRescueSamples: harness.endpoint.configuration.ambiguousRescueSamples,
      rescueAwareWindowsEnabled: false,
    };
    const gustEdge = classifyEndPendingEvidence({
      ...strongFrame,
      previousEvidence: 'silence',
    });
    const evidence = classifyEndPendingEvidence({
      ...strongFrame,
      previousEvidence: 'strong',
    });

    assert.equal(gustEdge, 'silence');
    assert.equal(evidence, 'strong');
    harness.endpoint.process(evidence, 120 * 16);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.equal(harness.endpoint.accumulatedSilenceSamples, 0);
  });
});
