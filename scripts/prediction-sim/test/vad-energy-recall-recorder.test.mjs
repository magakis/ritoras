import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';
import { loadVadFixtures } from '../lib/vad-fixtures.mjs';
import {
  decodeWav,
  framesFromWav,
  normalizeConfig,
  SHIPPING_SESSION_CONFIG,
} from '../bin/replay-vad.mjs';

const fixture = JSON.parse(fs.readFileSync(
  new URL('../fixtures/vad-energy-recorder.json', import.meta.url),
  'utf8',
));
const retainedGapEvidenceDb = 6;
const energyRetentionCapSamples = 60 * 16_000;

function expandTrace(trace) {
  return trace.frames.flatMap(frame => Array.from({ length: frame.repeat ?? 1 }, () => ({
    frameDb: frame.frameDb,
    sileroProbability: frame.sileroProbability,
    frameDurationMs: frame.frameDurationMs,
  })));
}

function makeSileroRecorder({
  energyRecallEnabled = true,
  frameMs = 100,
  endpointOnsetMs = 70,
  endpointSilenceMs = 700,
  maxNoiseSamples = 6 * 16_000,
  recorderConfig = {},
  onFrame,
} = {}) {
  const events = [];
  const frames = [];
  const harness = makeRecorderHarness({
    frameMs,
    endpointSilenceMs,
    endpointConfig: {
      onsetMs: endpointOnsetMs,
      endEvidenceMs: 100,
      endpointSilenceMs,
      resumeMs: 120,
      ambiguousRescueMs: 320,
    },
    minChunkSamples: 0,
    minSpeechSamples: 0,
    maxNoiseSamples,
    recorderConfig: {
      vadSource: 'silero',
      energyRecallEnabled,
      ...recorderConfig,
    },
    onFrame: frame => {
      frames.push(frame);
      onFrame?.(frame);
    },
    onEvent: event => events.push(event),
  });
  harness.gate.floorDb = -70;
  harness.gate.adaptiveRefinementComplete = true;
  harness.gate.coldStartConverged = true;
  harness.gate.adaptivePrimed = true;
  harness.primingComplete = true;
  const forceFinalizeRequests = [];
  const processor = harness.energyEvidenceProcessor;
  const takeForceFinalizeRequest = processor.takeForceFinalizeRequest.bind(processor);
  processor.takeForceFinalizeRequest = () => {
    const requested = takeForceFinalizeRequest();
    if (requested) forceFinalizeRequests.push(harness.sessionElapsedSamples);
    return requested;
  };
  return { harness, events, frames, forceFinalizeRequests };
}

function driveTrace(harness, trace) {
  return expandTrace(trace).map(frame => {
    if (Number.isFinite(trace.pinnedFloorDb)) {
      harness.gate.floorDb = trace.pinnedFloorDb;
    }
    return harness.drive(
      frame.frameDb,
      frame.frameDurationMs / 1_000,
      { sileroProbability: frame.sileroProbability },
    );
  });
}

function emissionSignature(events) {
  return events.filter(event => event.k === 'emit').map(event => ({
    id: event.id,
    reason: event.r,
    sourceStartSample: event.sourceStartSample,
    sourceEndSample: event.sourceEndSample,
    samples: event.n,
  }));
}

function emissionsCoverRange(events, startSample, endSample) {
  const ranges = events
    .filter(event => event.k === 'emit'
      && Number.isInteger(event.sourceStartSample)
      && Number.isInteger(event.sourceEndSample))
    .map(event => ({ start: event.sourceStartSample, end: event.sourceEndSample }))
    .sort((left, right) => left.start - right.start);
  let coveredThrough = startSample;
  for (const range of ranges) {
    if (range.end <= coveredThrough) continue;
    if (range.start > coveredThrough) return false;
    coveredThrough = Math.max(coveredThrough, range.end);
    if (coveredThrough >= endSample) return true;
  }
  return false;
}

describe('Silero energy recall recorder integration', () => {
  it('emits whisper-class speech live after the pure-Silero baseline noise-guard sheds it', () => {
    assert.equal(fixture.syntheticOnly, true);
    const trace = fixture.traces.whisperClassLostBySilero;
    const baseline = makeSileroRecorder({ energyRecallEnabled: false });
    const hybrid = makeSileroRecorder();
    const baselineResults = driveTrace(baseline.harness, trace);
    const hybridResults = driveTrace(hybrid.harness, trace);
    const speechEndSample = 120 * 1_600;

    assert.equal(baselineResults.some(result => result.decision.type === 'startUtterance'), false);
    assert.ok(baseline.events.some(event => event.k === 'discard'
      && event.r === 'noise_guard'
      && event.sourceStartSample < speechEndSample
      && event.sourceEndSample > 0));
    assert.equal(baseline.events.some(event => event.k === 'emit'), false);
    assert.ok(hybridResults.some(result => result.energyOpinion?.suppliesStrong));
    assert.ok(hybrid.events.some(event => event.k === 'start_utterance'));
    const belowContinuationFrames = hybridResults.slice(0, 120).filter(result => (
      result.output.floorDb !== null
      && -35 - result.output.floorDb < 10
    ));
    assert.ok(belowContinuationFrames.length * 100 > 700);

    const liveEmissions = hybrid.events.filter(event => event.k === 'emit');
    assert.ok(liveEmissions.some(event => event.r === 'endpoint'));

    // The parallel adaptive floor can end an energy-held chunk before the constant
    // input phrase ends. Endpoint post-roll is carried into the idle gap and flushed
    // at stop, so continuity is established by the union of emitted source ranges.
    hybrid.harness.flush();
    assert.ok(hybrid.events.some(event => event.k === 'emit' && event.r === 'flush'));
    assert.ok(emissionsCoverRange(hybrid.events, 0, speechEndSample));
  });

  it('does not open or emit live for short breath and junk transients', () => {
    const { harness, events } = makeSileroRecorder();
    const results = driveTrace(harness, fixture.traces.shortBreathsAndJunk);

    assert.equal(results.some(result => result.energyOpinion?.suppliesStrong), false);
    assert.equal(results.some(result => result.decision.type === 'startUtterance'), false);
    assert.equal(events.some(event => event.k === 'emit'), false);
  });

  it('holds energy strong until recorder onset acceptance for 85 ms frames at 120 and 500 ms onset', () => {
    for (const endpointOnsetMs of [120, 500]) {
      const { harness, events } = makeSileroRecorder({
        frameMs: 85,
        endpointOnsetMs,
      });
      const results = driveTrace(harness, fixture.traces.shortFrameEnergyOnset);
      const firstEnergyStrong = results.findIndex(result => result.energyOpinion?.suppliesStrong);
      const startIndex = results.findIndex(result => result.decision.type === 'startUtterance');

      assert.ok(firstEnergyStrong >= 0);
      assert.ok(startIndex > firstEnergyStrong);
      assert.ok(results.slice(firstEnergyStrong, startIndex + 1)
        .every(result => result.energyOpinion?.suppliesStrong));
      assert.ok(events.some(event => event.k === 'start_utterance'));
      assert.ok(events.some(event => event.k === 'emit' && event.r === 'endpoint'));
    }
  });

  it('matches baseline capture and junk decisions across the 700–2000 ms endpoint-silence sweep', () => {
    const endpointSilenceValues = [700, 900, 1_100, 1_300, 1_500, 2_000];
    for (const endpointSilenceMs of endpointSilenceValues) {
      const baselineSpeech = makeSileroRecorder({
        energyRecallEnabled: false,
        endpointSilenceMs,
      });
      const hybridSpeech = makeSileroRecorder({ endpointSilenceMs });
      driveTrace(baselineSpeech.harness, fixture.traces.ordinarySileroSpeech);
      driveTrace(hybridSpeech.harness, fixture.traces.ordinarySileroSpeech);
      assert.deepEqual(
        hybridSpeech.frames,
        baselineSpeech.frames,
        `Silero evidence was downgraded or altered at ${endpointSilenceMs} ms`,
      );
      assert.deepEqual(
        emissionSignature(hybridSpeech.events),
        emissionSignature(baselineSpeech.events),
        `Silero speech changed at ${endpointSilenceMs} ms`,
      );

      const baselineJunk = makeSileroRecorder({
        energyRecallEnabled: false,
        endpointSilenceMs,
      });
      const hybridJunk = makeSileroRecorder({ endpointSilenceMs });
      driveTrace(baselineJunk.harness, fixture.traces.shortBreathsAndJunk);
      driveTrace(hybridJunk.harness, fixture.traces.shortBreathsAndJunk);
      assert.deepEqual(emissionSignature(hybridJunk.events), []);
      assert.deepEqual(
        emissionSignature(hybridJunk.events),
        emissionSignature(baselineJunk.events),
        `junk capture changed at ${endpointSilenceMs} ms`,
      );
    }
  });

  it('has zero noise_guard sheds overlapping energy-bearing idle frames', () => {
    const { harness, events } = makeSileroRecorder();
    const energyBearingRanges = [];
    for (const frame of expandTrace(fixture.traces.retainedEnergyOverCap)) {
      const startSample = harness.sessionElapsedSamples;
      const result = harness.drive(
        frame.frameDb,
        frame.frameDurationMs / 1_000,
        { sileroProbability: frame.sileroProbability },
      );
      if (result.output.floorDb !== null
        && frame.frameDb - result.output.floorDb >= retainedGapEvidenceDb) {
        energyBearingRanges.push({
          start: startSample,
          end: harness.sessionElapsedSamples,
        });
      }
    }

    const overlappingEnergySheds = events.filter(event => event.k === 'discard'
      && event.r === 'noise_guard'
      && energyBearingRanges.some(range => event.sourceStartSample < range.end
        && event.sourceEndSample > range.start));
    assert.deepEqual(overlappingEnergySheds, []);
  });

  it('flushes an energy-bearing retained buffer at stop even when no onset occurred', () => {
    const { harness, events } = makeSileroRecorder();
    const results = driveTrace(harness, fixture.traces.retainedEnergyTailWithoutOnset);

    assert.equal(results.some(result => result.energyOpinion?.suppliesStrong), false);
    assert.equal(harness.endpoint.state, 'idle');
    assert.equal(events.some(event => event.k === 'emit'), false);

    harness.flush();

    const emission = events.find(event => event.k === 'emit' && event.r === 'flush');
    assert.ok(emission);
    assert.equal(emission.n, 1_600);
    assert.equal(harness.tailFloorSampleCount, 0);
  });

  it('caps retained idle audio at 60 seconds and promotes over-cap energy to the accumulator', () => {
    const { harness } = makeSileroRecorder();
    for (const frame of expandTrace(fixture.traces.retainedEnergyOverCap)) {
      harness.drive(
        frame.frameDb,
        frame.frameDurationMs / 1_000,
        { sileroProbability: frame.sileroProbability },
      );
      assert.ok(harness.retainedGapSamples <= energyRetentionCapSamples);
    }

    assert.ok(harness.accumulatorSamples > 0);
    assert.ok(harness.accumulatorSamples > energyRetentionCapSamples);
    assert.equal(harness.retentionShedCount, 0);
    assert.equal(
      harness.accumulatorSamples + harness.retainedGapSamples,
      harness.sessionElapsedSamples,
    );
  });

  it('preserves an over-cap post-roll tail through endpoint emission and stop flush', () => {
    const { harness, events } = makeSileroRecorder({
      endpointSilenceMs: 2_000,
      recorderConfig: {
        energyRetentionCapSec: 1,
        sileroSmoothingSteps: 1,
      },
    });
    driveTrace(harness, fixture.traces.energyBearingEndpointTailOverCap);

    const endpointEmission = events.find(event => event.k === 'emit' && event.r === 'endpoint');
    assert.ok(endpointEmission);
    assert.equal(endpointEmission.n, 14_400);
    assert.equal(harness.accumulatorSamples, 25_600);
    assert.equal(harness.retainedGapSamples, 0);

    harness.flush();

    const flushEmission = events.find(event => event.k === 'emit' && event.r === 'flush');
    assert.ok(flushEmission);
    assert.equal(flushEmission.n, 25_600);
    assert.equal(harness.emittedSampleCount, 40_000);
    assert.ok(emissionsCoverRange(events, 0, 40_000));
  });

  it('force-splits noise-held energy at 12 seconds and flushes the complete remaining span', () => {
    const { harness, events, forceFinalizeRequests } = makeSileroRecorder();
    driveTrace(harness, fixture.traces.energyOnlyNoiseContinuationCap);

    const capEmission = events.find(event => event.k === 'emit' && event.r === 'endpoint');
    assert.ok(capEmission);
    assert.deepEqual(forceFinalizeRequests, [13 * 16_000]);
    assert.equal(capEmission.sourceEndSample, 13 * 16_000);
    assert.ok(capEmission.sourceEndSample < harness.sessionElapsedSamples);
    assert.equal(events.filter(event => event.k === 'start_utterance').length, 1);
    assert.equal(events.some(event => event.r === 'noise_guard'), false);

    const sessionEndSample = harness.sessionElapsedSamples;
    harness.flush();

    assert.ok(events.some(event => event.k === 'emit' && event.r === 'flush'));
    assert.ok(emissionsCoverRange(events, 0, sessionEndSample));
    assert.equal(harness.emittedSampleCount, sessionEndSample);
  });

  it('does not force-split a long energy-originated utterance with recurring Silero corroboration', () => {
    const { harness, events } = makeSileroRecorder({ endpointSilenceMs: 2_500 });
    driveTrace(harness, fixture.traces.sileroCorroboratedLongEnergySpeech);

    const endpointEmissions = events.filter(event => event.k === 'emit' && event.r === 'endpoint');
    assert.equal(events.filter(event => event.k === 'start_utterance').length, 1);
    assert.equal(endpointEmissions.length, 1);
    assert.ok(endpointEmissions[0].sourceEndSample > 30 * 16_000);
  });

  it('does not re-open on post-split ambient noise but accepts a later real onset after cooldown', () => {
    const { harness, events } = makeSileroRecorder();
    const trace = fixture.traces.energyCapAmbientThenRealOnset;

    driveTrace(harness, { frames: trace.frames.slice(0, 2) });
    assert.equal(events.filter(event => event.k === 'start_utterance').length, 1);
    assert.equal(events.filter(event => event.k === 'emit' && event.r === 'endpoint').length, 1);

    const realOnsetResults = driveTrace(harness, { frames: [trace.frames[2]] });
    assert.ok(realOnsetResults.some(result => result.energyOpinion?.suppliesStrong));
    assert.equal(events.filter(event => event.k === 'start_utterance').length, 2);

    driveTrace(harness, { frames: [trace.frames[3]] });
    assert.equal(events.filter(event => event.k === 'emit' && event.r === 'endpoint').length, 2);
    const sessionEndSample = harness.sessionElapsedSamples;
    harness.flush();
    assert.ok(emissionsCoverRange(events, 0, sessionEndSample));
  });

  it('resets the continuation cap at 11.9 seconds when Silero reaches the stop threshold', () => {
    const { harness, events, frames, forceFinalizeRequests } = makeSileroRecorder();
    const trace = fixture.traces.energyCapSileroCorroborationReset;

    driveTrace(harness, { ...trace, frames: trace.frames.slice(0, 2) });
    driveTrace(harness, {
      ...trace,
      frames: [{ ...trace.frames[2], repeat: 4 }],
    });
    assert.ok(frames.at(-1).pm < 0.30);
    assert.equal(harness.sessionElapsedSamples, 206_400);
    assert.equal(
      harness.energyEvidenceProcessor.uncorroboratedContinuationMilliseconds,
      11_900,
    );
    assert.deepEqual(forceFinalizeRequests, []);

    driveTrace(harness, {
      ...trace,
      frames: [{ ...trace.frames[2], repeat: 1 }],
    });
    assert.equal(frames.at(-1).pm, 0.30);
    assert.equal(harness.sessionElapsedSamples, 208_000);
    assert.equal(harness.energyEvidenceProcessor.uncorroboratedContinuationMilliseconds, 0);
    assert.deepEqual(forceFinalizeRequests, []);
    assert.equal(events.some(event => event.k === 'emit'), false);

    driveTrace(harness, { ...trace, frames: [trace.frames[3]] });
    assert.deepEqual(forceFinalizeRequests, [25 * 16_000]);
    const endpointEmission = events.find(event => event.k === 'emit' && event.r === 'endpoint');
    assert.ok(endpointEmission);
    assert.equal(endpointEmission.sourceEndSample, 25 * 16_000);
    assert.equal(events.filter(event => event.k === 'emit' && event.r === 'endpoint').length, 1);
  });

  it('keeps all vad-cases fixture frames and DSP-fallback events byte-identical to DSP', {
    skip: loadVadFixtures().length === 0 ? 'vad-cases fixtures are absent in this checkout' : false,
  }, () => {
    const fixtures = loadVadFixtures();
    assert.equal(fixtures.length, 12);

    for (const fixtureCase of fixtures) {
      const warmup = fixtureCase.metadata.warmup;
      const fixtureConfig = {
        ...SHIPPING_SESSION_CONFIG,
        ...(warmup ? {
          absoluteSpeechFloorDb: warmup.absolute_speech_floor_db,
          endpointSilenceMs: warmup.endpoint_silence_ms,
          silenceMs: warmup.endpoint_silence_ms,
          minSpeechMs: warmup.min_speech_ms,
          minChunkMs: warmup.min_chunk_ms,
          analysisHpfEnabled: warmup.analysis_hpf_enabled,
          analysisHpfCutoffHz: warmup.analysis_hpf_cutoff_hz,
        } : {}),
      };
      const normalized = normalizeConfig(fixtureConfig);
      const wav = decodeWav(fs.readFileSync(fixtureCase.wavPath));
      const frames = framesFromWav(wav, [], normalized.config);
      const runFixture = recorderConfig => {
        const frameRecords = [];
        const events = [];
        const harness = makeRecorderHarness({
          frameMs: 10,
          endpointSilenceMs: normalized.config.endpointSilenceMs,
          endpointConfig: normalized.endpoint.configuration,
          minChunkSamples: normalized.minChunkSamples,
          minSpeechSamples: normalized.minSpeechSamples,
          maxNoiseSamples: normalized.maxNoiseSamples,
          endpointMachineEnabled: normalized.config.endpointMachineEnabled,
          utteranceRelativeResetEnabled: normalized.config.utteranceRelativeResetEnabled,
          gateConfig: normalized.gateConfig,
          recorderConfig,
          onFrame: frame => frameRecords.push(frame),
          onEvent: event => events.push(event),
        });
        for (const frame of frames) {
          harness.drive(frame.db, frame.dt, { highBandRatioDb: frame.hbr });
        }
        harness.flush();
        harness.end();
        return {
          frameRecords,
          events: events.filter(event => event.k !== 'session_start'),
        };
      };
      const dsp = runFixture({ ...normalized.recorderConfig, vadSource: 'dsp' });
      const fallback = runFixture({
        ...normalized.recorderConfig,
        vadSource: 'silero',
        effectiveVADSource: 'silero_fallback_dsp',
      });

      assert.deepEqual(fallback.frameRecords, dsp.frameRecords, fixtureCase.caseId);
      assert.deepEqual(fallback.events, dsp.events, fixtureCase.caseId);
    }
  });

  it('reproduces the pure-Silero baseline byte-for-byte with energy recall switched off', () => {
    const { harness, events, frames } = makeSileroRecorder({ energyRecallEnabled: false });
    for (let index = 0; index < 71; index += 1) {
      const result = harness.drive(-45, 0.1, { sileroProbability: 0 });
      assert.equal(result.energyOpinion, null);
      assert.equal(result.output.floorDb, null);
    }

    const actualBaselineFrames = frames.map(frame => ({ ...frame }));
    const expectedBaselineFrames = Array.from({ length: 71 }, (_, index) => {
      const frameNumber = index + 1;
      const isNoiseGuardBoundary = frameNumber % 61 === 0;
      const samplesSinceLastShed = isNoiseGuardBoundary
        ? 0
        : (frameNumber % 61) * 1_600;
      return {
        t: 'f',
        q: index,
        sourceStartSample: index * 1_600,
        sourceEndSample: frameNumber * 1_600,
        dt: 0.1,
        db: -45,
        e: 'silence',
        sp: false,
        ps: 'idle',
        es: 'idle',
        d: 'none',
        ss: 0,
        us: 0,
        ar: 0,
        ac: 0,
        wc: 0,
        ts: samplesSinceLastShed,
        pr: 0,
        pm: 0,
      };
    });
    assert.deepEqual(actualBaselineFrames, expectedBaselineFrames);
    assert.deepEqual(events.filter(event => event.r === 'noise_guard'), [{
      t: 'ev',
      k: 'discard',
      n: 97_600,
      r: 'noise_guard',
      timestampMs: 6_100,
      sourceStartSample: 0,
      sourceEndSample: 97_600,
    }]);
    assert.equal(harness.accumulatorSamples, 0);
    assert.equal(harness.retainedGapSamples, 16_000);
  });

  it('does not apply the energy continuation cap when the kill switch is off', () => {
    const { harness, events } = makeSileroRecorder({ energyRecallEnabled: false });
    const results = driveTrace(harness, fixture.traces.energyOnlyNoiseContinuationCap);

    assert.equal(results.some(result => result.energyOpinion !== null), false);
    assert.equal(results.some(result => result.decision.type === 'startUtterance'), false);
    assert.equal(events.some(event => event.k === 'emit'), false);
    assert.equal(harness.endpoint.state, 'idle');
  });
});
