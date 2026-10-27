import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  highBandRatioDb,
  rmsFromDb,
  VADHighBandRatioAnalyzer,
  VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT,
} from '../lib/vad-gate.mjs';
import { loadVadFixtures } from '../lib/vad-fixtures.mjs';
import {
  classifyEndPendingEvidence,
  makeRecorderHarness,
} from '../lib/recorder-sim.mjs';
import {
  compareDecisionParity,
  decodeWav,
  framesFromWav,
  parseArgs,
  parseSession,
  replaySession,
  selectSample,
  SHIPPING_SESSION_CONFIG,
} from '../bin/replay-vad.mjs';

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

function makePcm16Wav(samples) {
  const pcm = Buffer.alloc(samples.length * 2);
  samples.forEach((sample, index) => pcm.writeInt16LE(Math.round(sample * 32768), index * 2));
  const format = Buffer.alloc(16);
  format.writeUInt16LE(1, 0);
  format.writeUInt16LE(1, 2);
  format.writeUInt32LE(sampleRate, 4);
  format.writeUInt32LE(sampleRate * 2, 8);
  format.writeUInt16LE(2, 12);
  format.writeUInt16LE(16, 14);
  const header = Buffer.alloc(12);
  header.write('RIFF', 0, 4, 'ascii');
  header.write('WAVE', 8, 4, 'ascii');
  const formatHeader = Buffer.alloc(8);
  formatHeader.write('fmt ', 0, 4, 'ascii');
  formatHeader.writeUInt32LE(format.length, 4);
  const dataHeader = Buffer.alloc(8);
  dataHeader.write('data', 0, 4, 'ascii');
  dataHeader.writeUInt32LE(pcm.length, 4);
  const wav = Buffer.concat([header, formatHeader, format, dataHeader, pcm]);
  wav.writeUInt32LE(wav.length - 8, 4);
  return wav;
}

function replayFixtureCase(fixture, overrides = {}) {
  const warmup = fixture.metadata.warmup;
  const config = {
    ...SHIPPING_SESSION_CONFIG,
    absoluteSpeechFloorDb: warmup.absolute_speech_floor_db,
    endpointSilenceMs: warmup.endpoint_silence_ms,
    silenceMs: warmup.endpoint_silence_ms,
    minSpeechMs: warmup.min_speech_ms,
    minChunkMs: warmup.min_chunk_ms,
    analysisHpfEnabled: warmup.analysis_hpf_enabled,
    analysisHpfCutoffHz: warmup.analysis_hpf_cutoff_hz,
    ...overrides,
  };
  const wav = decodeWav(fs.readFileSync(fixture.wavPath));
  const session = { frames: [], events: [], config, configIsTelemetry: false };
  return replaySession(session, config, {
    fromWav: wav,
    sourceSampleOffset: fixture.metadata.source_start_sample,
    warmup,
    compare: false,
  });
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

describe('VAD telemetry replay and fixtures', () => {
  const phaseOneFixtures = loadVadFixtures();

  it('loads checked-in Phase-1 fixtures when available', {
    skip: phaseOneFixtures.length === 0 ? 'Phase-1 fixtures are absent in this checkout' : false,
  }, () => {
    assert.equal(phaseOneFixtures.length, 12);
    assert.ok(phaseOneFixtures.some(fixture => fixture.metadata.kind === 'failure'));
    assert.ok(phaseOneFixtures.some(fixture => fixture.metadata.kind === 'guard'));
    for (const fixture of phaseOneFixtures) {
      const wav = decodeWav(fs.readFileSync(fixture.wavPath));
      assert.equal(wav.sampleRate, sampleRate, fixture.caseId);
      assert.equal(wav.channels, 1, fixture.caseId);
      assert.equal(wav.audioFormat, 1, fixture.caseId);
      assert.equal(wav.bitsPerSample, 16, fixture.caseId);
    }
  });

  const shedFixture = phaseOneFixtures.find(fixture => fixture.caseId === '20261027-000217-shed');
  it('retains the speech-evident 000217 gap instead of noise_guard shedding it', {
    skip: shedFixture ? false : '20261027-000217-shed fixture is absent in this checkout',
  }, () => {
    const replay = replayFixtureCase(shedFixture);
    const coreStartSample = 478_040;
    const coreEndSample = 670_303;
    const coreFrames = replay.frames.filter(frame => frame.sourceStartSample < coreEndSample
      && frame.sourceEndSample > coreStartSample);
    const shedCore = replay.events.filter(event => event.k === 'discard'
      && event.r === 'noise_guard'
      && event.sourceStartSample < coreEndSample
      && event.sourceEndSample > coreStartSample);

    assert.ok(coreFrames.some(frame => frame.sp));
    assert.deepEqual(shedCore, []);
    assert.ok(replay.events.some(event => event.k === 'emit'
      && event.sourceStartSample <= coreStartSample
      && event.sourceEndSample >= coreEndSample));
  });

  const idleGapFixture = phaseOneFixtures.find(
    fixture => fixture.caseId === '20261027-003838-idle-gap',
  );
  it('KD-2 documents the idle-only 003838 retained-context divergence', {
    skip: idleGapFixture ? false : '20261027-003838-idle-gap fixture is absent in this checkout',
  }, () => {
    const coreStartSample = 366_155;
    const coreEndSample = 462_361;
    const replay = replayFixtureCase(idleGapFixture);
    // KD-2: the device shed a retained gap after prior speech; this clip starts at the post-emission
    // boundary with no retained gap. Recheck shed attribution on-device with Phase-2 sample-true telemetry.
    const replayStartSample = idleGapFixture.metadata.source_start_sample
      + idleGapFixture.metadata.warmup.prefix_samples;
    const coreFrames = replay.frames.filter(frame => frame.sourceStartSample < coreEndSample
      && frame.sourceEndSample > coreStartSample);
    const shedCore = replay.events.filter(event => event.k === 'discard'
      && event.r === 'noise_guard'
      && event.sourceStartSample < coreEndSample
      && event.sourceEndSample > coreStartSample);

    assert.equal(coreFrames.some(frame => frame.sp), false);
    assert.equal(replay.events.some(event => event.k === 'start_utterance'
      && replayStartSample + Math.round(event.time * sampleRate)
        >= coreStartSample
      && replayStartSample + Math.round(event.time * sampleRate)
        < coreEndSample), false);
    assert.deepEqual(shedCore, []);
  });

  const noisePulseFixture = phaseOneFixtures.find(
    fixture => fixture.caseId === '20261027-000217-noise-pulse',
  );
  it('does not change noise-pulse VAD decisions through the retained-gap cap', {
    skip: noisePulseFixture ? false : '20261027-000217-noise-pulse fixture is absent in this checkout',
  }, () => {
    const coreStartSample = 870_182;
    const coreEndSample = 914_936;
    const sixSecondReplay = replayFixtureCase(noisePulseFixture);
    const longerCapReplay = replayFixtureCase(
      noisePulseFixture,
      { maxNoiseSec: 10 },
    );
    const decisions = replay => replay.frames
      .filter(frame => frame.sourceStartSample < coreEndSample
        && frame.sourceEndSample > coreStartSample)
      .map(frame => [frame.sp, frame.e, frame.es, frame.d]);

    assert.deepEqual(decisions(sixSecondReplay), decisions(longerCapReplay));
    assert.equal(sixSecondReplay.events.some(event => event.k === 'discard'
      && event.r === 'noise_guard'), false);
  });

  it('recomputes the whisper high-band witness from WAV samples', () => {
    const samples = Array.from({ length: 3 * frameSamples }, (_, index) => (
      rmsFromDb(-60) * Math.sqrt(2)
        * Math.sin((2 * Math.PI * 3_500 * index) / sampleRate)
    ));
    const wav = decodeWav(makePcm16Wav(samples));
    const frames = framesFromWav(wav);
    const replay = replaySession({
      frames: [],
      events: [],
      config: {},
      configIsTelemetry: false,
    }, undefined, { fromWav: wav, compare: false });

    assert.ok(frames.every(frame => frame.hbr >= VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT));
    assert.ok(replay.frames.some(frame => frame.hbr >= VAD_WHISPER_HIGH_BAND_RATIO_DB_DEFAULT));
    assert.deepEqual(
      replay.frames.map(frame => frame.sourceStartSample),
      [0, frameSamples, 2 * frameSamples],
    );
  });

  it('accepts current JSONL and uploaded payload telemetry shapes', () => {
    const oldJsonl = parseSession([
      JSON.stringify({ t: 'ev', k: 'session_start', c: { mode: 'adaptive' } }),
      JSON.stringify({ t: 'f', q: 0, dt: 0.01, db: -60, e: 'silence' }),
    ].join('\n'));
    const uploaded = parseSession(JSON.stringify({
      schema_version: 2,
      vad_config: { mode: 'adaptive', absoluteSpeechFloorDb: -70 },
      summary: { retention: { historical_dropped: 0 } },
      events: [{ k: 'emit', id: 1, sourceStartSample: 0, sourceEndSample: 160 }],
      frames: [{
        q: 0,
        dt: 0.01,
        db: -60,
        sh: true,
        sdy: 4,
        hbr: -3,
        sourceStartSample: 0,
        sourceEndSample: 160,
      }],
    }));

    assert.equal(oldJsonl.frames[0].q, 0);
    assert.equal(oldJsonl.configIsTelemetry, true);
    assert.equal(uploaded.config.absoluteSpeechFloorDb, -70);
    assert.equal(uploaded.frames[0].sh, true);
    assert.equal(uploaded.frames[0].sdy, 4);
    assert.equal(uploaded.frames[0].hbr, -3);
    assert.equal(uploaded.events[0].sourceEndSample, 160);
    assert.equal(parseArgs(['client.json', 'full.wav', '--from-wav']).sessionPath, 'client.json');
    assert.equal(parseArgs(['full.wav', 'client.json', '--from-wav']).wavPath, 'full.wav');
  });

  it('checks recorded decisions within one frame and labels legacy coordinate gaps', () => {
    const recorded = [
      { k: 'emit', r: 'endpoint', sourceStartSample: 0, sourceEndSample: 320 },
      { k: 'discard', r: 'noise_guard', sourceStartSample: 400, sourceEndSample: 560 },
    ];
    const withinTolerance = [
      { k: 'emit', r: 'endpoint', sourceStartSample: 100, sourceEndSample: 420 },
      { k: 'discard', r: 'noise_guard', sourceStartSample: 500, sourceEndSample: 660 },
    ];
    const matched = compareDecisionParity(recorded, withinTolerance, [{ dt: 0.01 }]);
    const outsideTolerance = compareDecisionParity(recorded, [
      { k: 'emit', r: 'endpoint', sourceStartSample: 161, sourceEndSample: 481 },
      { k: 'discard', r: 'noise_guard', sourceStartSample: 500, sourceEndSample: 660 },
    ], [{ dt: 0.01 }]);
    const legacy = compareDecisionParity([
      { k: 'discard', r: 'noise_guard', n: 160 },
    ], [{ k: 'discard', r: 'noise_guard', n: 160, sourceStartSample: 0, sourceEndSample: 160 }]);

    assert.equal(matched.status, 'matched');
    assert.equal(matched.matchedCount, 2);
    assert.equal(matched.toleranceSamples, frameSamples);
    assert.equal(outsideTolerance.status, 'mismatch');
    assert.equal(legacy.status, 'known_divergence');
    assert.match(legacy.knownDivergences[0].reason, /lacks source sample coordinates/);
  });

  it('supports deterministic fixture sampling and all replay selection flags', () => {
    const options = parseArgs([
      '--only-fixtures', '--sample', '2', '--seed', '19', '--stop-on-first-fail',
    ]);
    const fixtures = ['case-a', 'case-b', 'case-c', 'case-d'].map(caseId => ({ caseId }));

    assert.equal(options.onlyFixtures, true);
    assert.equal(options.sample, 2);
    assert.equal(options.seed, 19);
    assert.equal(options.stopOnFirstFail, true);
    assert.deepEqual(selectSample(fixtures, 2, 19), selectSample(fixtures, 2, 19));
    assert.equal(selectSample(fixtures, 2, 19).length, 2);
    assert.throws(() => parseArgs(['--only-fixtures', '--from-wav']), /cannot be combined/);
  });

  it('treats a missing fixture directory as empty and loads valid case metadata', () => {
    const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'vad-cases-'));
    const missingDirectory = path.join(temporaryDirectory, 'not-yet-copied');
    const emptyDirectory = path.join(temporaryDirectory, 'empty');
    const caseId = 'sample-case';
    const caseDirectory = path.join(temporaryDirectory, caseId);
    try {
      assert.deepEqual(loadVadFixtures(missingDirectory), []);
      fs.mkdirSync(emptyDirectory);
      assert.deepEqual(loadVadFixtures(emptyDirectory), []);
      fs.mkdirSync(caseDirectory);
      fs.writeFileSync(path.join(caseDirectory, 'clip.wav'), makePcm16Wav([0, 0]));
      fs.writeFileSync(path.join(caseDirectory, 'meta.json'), JSON.stringify({
        case_id: caseId,
        session: 'session-1',
        kind: 'failure',
        mechanism: 'never_emitted',
        source_start_sample: 100,
        source_end_sample: 102,
        sample_rate: sampleRate,
        evidence: ['waveform_alignment'],
        limitations: ['short clip'],
      }));

      const fixtures = loadVadFixtures(temporaryDirectory);
      assert.equal(fixtures.length, 1);
      assert.equal(fixtures[0].caseId, caseId);
      assert.equal(fixtures[0].metadata.kind, 'failure');
    } finally {
      fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  });

});
