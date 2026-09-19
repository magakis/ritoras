import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  makeVadGateConfig,
  VAD_SPEECH_CEILING_MARGIN_DB,
  VAD_SUSTAINED_CONTINUING_ONSET_S,
  VADThresholdGate,
} from '../lib/vad-gate.mjs';
import { StreamingEndpoint } from '../lib/streaming-endpoint.mjs';

const frameDurationMs = 10;
const frameDuration = frameDurationMs / 1000;
const frameSamples = frameDurationMs * 16;

function makeGate() {
  return new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
}

function makeEndpoint() {
  return new StreamingEndpoint({ endpointSilenceMs: 3000 });
}

function driveFrame(gate, endpoint, frameDb) {
  const output = gate.process(frameDb, frameDuration);
  const reanchorEvent = gate.takePendingReanchorEvent();
  const previousState = endpoint.state;
  const decision = endpoint.process(output.evidence, frameSamples);
  gate.updateFloorTracking(
    frameDb,
    frameDuration,
    previousState === 'idle' && endpoint.state === 'idle',
  );
  return { output, decision, previousState, reanchorEvent };
}

function makeRecorderHarness({
  frameMs = frameDurationMs,
  minChunkSamples = 0,
  minSpeechSamples = 0,
} = {}) {
  const recorderFrameDuration = frameMs / 1000;
  const recorderFrameSamples = frameMs * 16;
  const harness = {
    gate: makeGate(),
    endpoint: makeEndpoint(),
    minChunkSamples,
    minSpeechSamples,
    chunkCount: 0,
    reanchorEventCount: 0,
    requiresPostReanchorSpeech: false,
    utteranceQuietestStrongDb: null,
    accumulatorSamples: 0,
    speechSamples: 0,
    speechClearFloorCheckCount: 0,
    noteUtteranceEndedValues: [],
    sustainedContinuingMs: 0,
    sustainedContinuingOnsetLatched: false,

    drive(frameDb) {
      const output = this.gate.process(frameDb, recorderFrameDuration);
      const reanchorEvent = this.gate.takePendingReanchorEvent();
      const previousState = this.endpoint.state;
      const endpointWasIdle = previousState === 'idle';
      if (reanchorEvent) this.reanchorEventCount += 1;

      if (reanchorEvent
        && (previousState === 'speechActive' || previousState === 'endPending')) {
        this.requiresPostReanchorSpeech = true;
      } else if (!reanchorEvent
        && this.requiresPostReanchorSpeech
        && output.evidence === 'strong') {
        this.requiresPostReanchorSpeech = false;
      }

      const adaptivePath = output.floorDb !== null;
      if (adaptivePath && output.evidence === 'continuing' && endpointWasIdle) {
        this.sustainedContinuingMs += recorderFrameDuration * 1000;
      } else if (!this.sustainedContinuingOnsetLatched) {
        this.sustainedContinuingMs = 0;
      }

      if (adaptivePath
        && output.evidence === 'continuing'
        && endpointWasIdle
        && this.sustainedContinuingMs >= VAD_SUSTAINED_CONTINUING_ONSET_S * 1000) {
        this.sustainedContinuingOnsetLatched = true;
      }
      const endpointInOnsetLimb = endpointWasIdle || previousState === 'onsetPending';
      if (this.sustainedContinuingOnsetLatched
        && (!adaptivePath
          || !endpointInOnsetLimb
          || output.evidence === 'ambiguous'
          || output.evidence === 'silence')) {
        this.sustainedContinuingOnsetLatched = false;
        this.sustainedContinuingMs = 0;
      }
      const latchedContinuingOnset = this.sustainedContinuingOnsetLatched
        && output.evidence === 'continuing'
        && endpointInOnsetLimb;
      const endpointEvidence = adaptivePath
        && latchedContinuingOnset
        ? 'strong'
        : output.evidence;
      if (output.retroactiveSpeechMs > 0) {
        this.speechSamples += output.retroactiveSpeechMs * 16;
      }
      if (output.isSpeech) this.speechSamples += recorderFrameSamples;
      const decision = this.endpoint.process(endpointEvidence, recorderFrameSamples);
      this.gate.updateFloorTracking(
        frameDb,
        recorderFrameDuration,
        previousState === 'idle' && this.endpoint.state === 'idle',
      );

      if (decision.type === 'startUtterance') {
        this.utteranceQuietestStrongDb = null;
        this.accumulatorSamples = this.endpoint.configuration.preRollSamples + recorderFrameSamples;
        this.sustainedContinuingMs = 0;
        this.sustainedContinuingOnsetLatched = false;
      } else if (decision.type === 'continueUtterance'
        || decision.type === 'finalizeUtterance') {
        this.accumulatorSamples += recorderFrameSamples;
      }
      if (adaptivePath && output.evidence === 'strong' && this.endpoint.state !== 'idle') {
        this.utteranceQuietestStrongDb = Math.min(
          this.utteranceQuietestStrongDb ?? frameDb,
          frameDb,
        );
      }

      let discarded = false;
      if (decision.type === 'finalizeUtterance') {
        if (this.accumulatorSamples < this.minChunkSamples
          || this.speechSamples < this.minSpeechSamples) {
          this.requiresPostReanchorSpeech = false;
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          discarded = true;
        } else if (this.requiresPostReanchorSpeech) {
          this.requiresPostReanchorSpeech = false;
          let speechClearsFloor = false;
          if (this.utteranceQuietestStrongDb !== null) {
            this.speechClearFloorCheckCount += 1;
            speechClearsFloor = this.gate.speechClearsCurrentFloor(
              this.utteranceQuietestStrongDb,
            );
          }
          if (!speechClearsFloor) {
            this.accumulatorSamples = 0;
            this.speechSamples = 0;
            discarded = true;
          } else {
            this.chunkCount += 1;
            this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
            this.gate.noteUtteranceEnded(this.utteranceQuietestStrongDb);
            this.utteranceQuietestStrongDb = null;
            this.accumulatorSamples = 0;
            this.speechSamples = 0;
            this.sustainedContinuingMs = 0;
            this.sustainedContinuingOnsetLatched = false;
          }
        } else {
          this.chunkCount += 1;
          this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
          this.gate.noteUtteranceEnded(this.utteranceQuietestStrongDb);
          this.utteranceQuietestStrongDb = null;
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          this.sustainedContinuingMs = 0;
          this.sustainedContinuingOnsetLatched = false;
        }
      }
      return { output, decision, endpointEvidence, reanchorEvent, discarded };
    },
  };
  return harness;
}

describe('adaptive VAD convergence', () => {
  it('breaks the sustained ambient deadlock and reaches the endpoint', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let firstSilenceMs = null;
    let endpointMs = null;

    for (let i = 0; i < 700; i++) {
      const { output, decision } = driveFrame(gate, endpoint, -65);
      const elapsedMs = (i + 1) * frameDurationMs;
      if (output.evidence === 'silence' && firstSilenceMs === null) {
        firstSilenceMs = elapsedMs;
      }
      if (decision.type === 'finalizeUtterance') {
        endpointMs = elapsedMs;
        break;
      }
    }

    assert.ok(firstSilenceMs !== null && firstSilenceMs <= 4100);
    assert.ok(endpointMs !== null && endpointMs <= 7100);
  });

  it('keeps continuous voiced speech strong and never chases its floor', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalized = false;
    let maximumFloor = -Infinity;

    for (let i = 0; i < 6000; i++) {
      const { output, decision } = driveFrame(gate, endpoint, -21);
      assert.strictEqual(output.evidence, 'strong');
      if (i >= 6) assert.strictEqual(endpoint.state, 'speechActive');
      maximumFloor = Math.max(maximumFloor, gate.snapshot.floorDb);
      if (decision.type === 'finalizeUtterance') finalized = true;
    }

    assert.strictEqual(finalized, false);
    assert.ok(maximumFloor <= -21);
  });

  it('ends talk-then-silence after stale-floor convergence plus endpoint silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    for (let i = 0; i < 1000; i++) {
      const { decision } = driveFrame(gate, endpoint, -21);
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    for (let i = 0; i < 720; i++) {
      const { decision } = driveFrame(gate, endpoint, -65);
      if (decision.type === 'finalizeUtterance') {
        finalizedAtMs = 10_000 + (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.ok(finalizedAtMs !== null);
    assert.ok(finalizedAtMs <= 17_200);
  });

  it('reports ambient headroom at approximately three decibels', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();

    for (let i = 0; i < 500; i++) {
      driveFrame(gate, endpoint, -65);
    }

    assert.ok(Math.abs(gate.snapshot.silenceThresholdDb - -62) <= 0.5);
  });

  it('refuses re-anchor above the headroom guard and keeps the floor pinned', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let lastFrame = null;
    let endpointReached = false;

    for (let i = 0; i < 600; i++) {
      lastFrame = driveFrame(gate, endpoint, -25);
      if (lastFrame.decision.type === 'finalizeUtterance') {
        endpointReached = true;
        break;
      }
    }

    // Extreme ambient above the -30 dB headroom guard cannot converge: the
    // floor stays at its refined -80 dB seed, so silence remains undetectable.
    // This is app-target only; stop/flush still delivers the audio, with the
    // accumulator growing at the bounded input rate (about 64 KB/s).
    assert.ok(lastFrame !== null);
    assert.strictEqual(lastFrame.output.floorDb, -80);
    assert.strictEqual(gate.snapshot.floorDb, -80);
    assert.strictEqual(lastFrame.output.evidence, 'strong');
    assert.strictEqual(lastFrame.reanchorEvent, false);
    assert.strictEqual(endpointReached, false);
    assert.strictEqual(endpoint.state, 'speechActive');
  });

  it('survives the ambiguous rescue during re-anchor convergence and reaches silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let rescued = false;

    for (let i = 0; i < 450; i++) {
      driveFrame(gate, endpoint, -65);
    }

    for (let i = 0; i < 50; i++) {
      const { output, previousState } = driveFrame(gate, endpoint, -60);
      if (previousState === 'endPending'
        && endpoint.state === 'speechActive'
        && output.evidence === 'ambiguous') {
        rescued = true;
      }
    }

    let endpointReached = false;
    for (let i = 0; i < 800; i++) {
      const { decision } = driveFrame(gate, endpoint, -60);
      if (decision.type === 'finalizeUtterance') {
        endpointReached = true;
        break;
      }
    }

    assert.strictEqual(rescued, true);
    assert.strictEqual(endpointReached, true);
  });

  it('does not stale-reanchor a quick recording shorter than three seconds', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();

    for (let i = 0; i < 290; i++) {
      const { output, decision } = driveFrame(gate, endpoint, -21);
      assert.strictEqual(output.evidence, 'strong');
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    assert.strictEqual(gate.snapshot.floorDb, -80);
  });

  it('discards a pure-ambient utterance after re-anchor endpoint', () => {
    const harness = makeRecorderHarness();
    let finalized = false;
    let discarded = false;

    // Finalization depends on the 3.0 s stale timer, endpoint silence, and refinement window.
    for (let i = 0; i < 900; i++) {
      const frame = harness.drive(-65);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        discarded = frame.discarded;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 1);
    assert.strictEqual(finalized, true);
    assert.strictEqual(discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.requiresPostReanchorSpeech, false);
    assert.strictEqual(harness.accumulatorSamples, 0);
  });

  it('keeps an utterance when real speech follows ambient re-anchor', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-65);
    for (let i = 0; i < 30; i++) harness.drive(-21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-65);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 1);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('noisy pause after real speech does not discard the utterance', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;
    let sawReanchor = false;

    for (let i = 0; i < 220; i++) harness.drive(quietestStrongDb);

    // The floor is still near the cold-start floor here. Three seconds of
    // ambiguous-band ambient triggers the stale re-anchor while the utterance
    // is active, then the pause continues with shorter ambiguous bursts.
    for (let i = 0; i < 320; i++) {
      const floorDb = harness.gate.snapshot.floorDb;
      const frameDb = floorDb + (i % 10 < 2 ? 4 : 6);
      const frame = harness.drive(frameDb);
      if (frame.reanchorEvent) {
        sawReanchor = true;
        break;
      }
    }

    let finalized = null;
    let sawAmbiguousEndPending = false;
    for (let i = 0; i < 600; i++) {
      // Keep each ambiguous burst below the 320-ms bar-rescue threshold;
      // silence stretches accumulate the endpoint's three-second timer.
      const frameDb = i % 50 < 20
        ? harness.gate.snapshot.floorDb + 4
        : -80;
      const frame = harness.drive(frameDb);
      if (harness.endpoint.state === 'endPending' && frame.output.evidence === 'ambiguous') {
        sawAmbiguousEndPending = true;
      }
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.strictEqual(sawReanchor, true);
    assert.strictEqual(sawAmbiguousEndPending, true);
    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.requiresPostReanchorSpeech, false);
    assert.strictEqual(harness.noteUtteranceEndedValues.at(-1), quietestStrongDb);
  });

  it('flagged fallback-onset utterance with no strong frames discards without consulting the floor check', () => {
    const harness = makeRecorderHarness();
    let sawFallbackOnset = false;
    let sawReanchor = false;
    let finalized = null;

    for (let i = 0; i < 900; i++) {
      const frameDb = sawReanchor
        ? -80
        : harness.gate.snapshot.floorDb + 7;
      const frame = harness.drive(frameDb);
      assert.notStrictEqual(frame.output.evidence, 'strong');
      if (frame.output.evidence === 'continuing' && frame.endpointEvidence === 'strong') {
        sawFallbackOnset = true;
      }
      if (frame.reanchorEvent) sawReanchor = true;
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.strictEqual(sawFallbackOnset, true);
    assert.strictEqual(sawReanchor, true);
    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.utteranceQuietestStrongDb, null);
    assert.strictEqual(harness.speechClearFloorCheckCount, 0);
    assert.strictEqual(harness.requiresPostReanchorSpeech, false);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('uses the inclusive speech-clears-floor boundary', () => {
    const gate = makeGate();
    const config = makeVadGateConfig({ mode: 'adaptive' });
    const floorDb = -50;
    gate.floorDb = floorDb;
    const boundaryDb = floorDb + config.adaptiveDeltaDb + VAD_SPEECH_CEILING_MARGIN_DB;

    // Residual speech below 12 dB SNR is not trusted; retaining the exact
    // boundary lets a valid utterance self-heal the speech ceiling.
    assert.strictEqual(gate.speechClearsCurrentFloor(boundaryDb), true);
    assert.strictEqual(gate.speechClearsCurrentFloor(boundaryDb - 1), false);
  });

  it('kept utterances still respect the min-chunk/min-speech gates', () => {
    const quietestStrongDb = -35;
    const harness = makeRecorderHarness({
      minChunkSamples: 1,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
    });

    for (let i = 0; i < 220; i++) harness.drive(quietestStrongDb);

    let sawReanchor = false;
    for (let i = 0; i < 320; i++) {
      const floorDb = harness.gate.snapshot.floorDb;
      const frameDb = floorDb + (i % 10 < 2 ? 4 : 6);
      const frame = harness.drive(frameDb);
      if (frame.reanchorEvent) {
        sawReanchor = true;
        break;
      }
    }
    assert.strictEqual(sawReanchor, true);
    assert.strictEqual(harness.gate.speechClearsCurrentFloor(quietestStrongDb), true);

    let finalized = null;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.speechClearFloorCheckCount, 0);
    assert.strictEqual(harness.accumulatorSamples, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('does not discard speech that starts on the first frame', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-65);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('flat monotone cold-start speech endpoints mid-utterance but resumed speech re-onsets', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    for (let i = 0; i < 710; i++) {
      const { decision } = driveFrame(gate, endpoint, -40);
      if (decision.type === 'finalizeUtterance') {
        finalizedAtMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.ok(finalizedAtMs !== null);
    assert.ok(finalizedAtMs >= 5000 && finalizedAtMs <= 7100);
    assert.strictEqual(endpoint.state, 'idle');
    assert.strictEqual(gate.speechCeilingDb, null);

    gate.noteUtteranceEnded(-40);
    let onsetMs = null;
    for (let i = 0; i < 20; i++) {
      const { decision } = driveFrame(gate, endpoint, -40);
      if (decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.ok(onsetMs !== null && onsetMs < 200);
    assert.strictEqual(endpoint.state, 'speechActive');
  });

  it('post-endpoint floor does not eat speech — resumed speech re-onsets', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;
    const ceilingFloor = quietestStrongDb
      - makeVadGateConfig({ mode: 'adaptive' }).adaptiveDeltaDb
      - VAD_SPEECH_CEILING_MARGIN_DB;

    for (let i = 0; i < 100; i++) harness.drive(quietestStrongDb);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    for (let i = 0; i < 30; i++) harness.drive(-80);
    assert.strictEqual(harness.endpoint.state, 'endPending');

    let sawAmbiguousEndPending = false;
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(i % 10 === 9 ? -75 : -80);
      if (harness.endpoint.state === 'endPending' && frame.output.evidence === 'ambiguous') {
        sawAmbiguousEndPending = true;
      }
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }

    assert.strictEqual(sawAmbiguousEndPending, true);
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.gate.speechCeilingDb, quietestStrongDb);
    assert.strictEqual(harness.endpoint.state, 'idle');

    for (let i = 0; i < 200; i++) {
      harness.drive(-75);
      assert.strictEqual(harness.endpoint.state, 'idle');
      assert.ok(harness.gate.snapshot.floorDb <= ceilingFloor);
    }

    let onsetMs = null;
    for (let i = 0; i < 50; i++) {
      const frame = harness.drive(quietestStrongDb);
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }
    assert.ok(onsetMs !== null && onsetMs <= 500);
  });

  it('uniform quiet speech re-onsets despite stale re-anchor via the sustained continuing fallback', () => {
    const frameMs = 100;
    const harness = makeRecorderHarness({ frameMs });
    let onsetMs = null;
    let usedSustainedFallback = false;

    for (let i = 0; i < 150; i++) {
      const frame = harness.drive(-73);
      if (frame.endpointEvidence === 'strong' && frame.output.evidence === 'continuing') {
        usedSustainedFallback = true;
      }
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameMs;
        break;
      }
    }

    assert.strictEqual(usedSustainedFallback, true);
    assert.ok(onsetMs !== null && onsetMs <= 1500);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('fallback onset completes with small frames', () => {
    const harness = makeRecorderHarness();
    let onsetMs = null;
    let usedSustainedFallback = false;

    for (let i = 0; i < 200; i++) {
      const frameDb = harness.gate.snapshot.continuationThresholdDb + 0.1;
      const frame = harness.drive(frameDb);
      assert.strictEqual(frame.output.evidence, 'continuing');
      if (frame.endpointEvidence === 'strong') usedSustainedFallback = true;
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameDurationMs;
        break;
      }
    }

    assert.strictEqual(usedSustainedFallback, true);
    assert.ok(onsetMs !== null && onsetMs <= 2000);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('re-onsets fluctuating speech after ambiguous interruptions', () => {
    const frameMs = 100;
    const harness = makeRecorderHarness({ frameMs });
    let onsetMs = null;
    let usedSustainedFallback = false;

    for (let i = 0; i < 60; i++) {
      let frameDb;
      if (i < 10) {
        frameDb = i % 5 === 0 ? -75 : -73;
      } else {
        const continuationThreshold = harness.gate.snapshot.continuationThresholdDb;
        frameDb = continuationThreshold + (i % 2 === 0 ? 0.05 : 0.2);
      }
      const frame = harness.drive(frameDb);
      if (frame.endpointEvidence === 'strong' && frame.output.evidence === 'continuing') {
        usedSustainedFallback = true;
      }
      if (frame.decision.type === 'startUtterance') {
        onsetMs = (i + 1) * frameMs;
        break;
      }
    }

    assert.strictEqual(usedSustainedFallback, true);
    assert.ok(onsetMs !== null && onsetMs <= 2500);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('steady noise above the floor does not false-open via fallback onset', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -25;

    for (let i = 0; i < 100; i++) harness.drive(quietestStrongDb);
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.gate.speechCeilingDb, quietestStrongDb);
    assert.strictEqual(harness.endpoint.state, 'idle');

    let onset = false;
    let firstSilenceMs = null;
    let lastOutput = null;
    for (let i = 0; i < 200; i++) {
      lastOutput = harness.drive(-73);
      if (lastOutput.decision.type === 'startUtterance') onset = true;
      if (lastOutput.output.evidence === 'silence' && firstSilenceMs === null) {
        firstSilenceMs = (i + 1) * frameDurationMs;
      }
    }

    assert.strictEqual(onset, false);
    assert.ok(firstSilenceMs !== null && firstSilenceMs < 1000);
    assert.strictEqual(lastOutput.output.evidence, 'silence');
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('speech ceiling caps re-anchor and idle rise until decay releases it', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 100; i++) harness.drive(-25);
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');

    const gate = harness.gate;
    const quietestStrongDb = -25;
    const adaptiveDeltaDb = makeVadGateConfig({ mode: 'adaptive' }).adaptiveDeltaDb;
    const ceilingFloor = quietestStrongDb - adaptiveDeltaDb - VAD_SPEECH_CEILING_MARGIN_DB;
    assert.strictEqual(gate.speechCeilingDb, quietestStrongDb);
    gate.floorDb = -40;

    for (let i = 0; i < 150; i++) {
      const loudFrameDb = gate.floorDb + 5;
      gate.process(loudFrameDb, frameDuration);
      gate.updateFloorTracking(loudFrameDb, frameDuration, false);
      assert.ok(gate.snapshot.floorDb <= ceilingFloor);
    }
    assert.ok(Math.abs(gate.snapshot.floorDb - ceilingFloor) < 0.001);

    for (let i = 0; i < 150; i++) {
      const loudFrameDb = gate.floorDb + 5;
      gate.process(loudFrameDb, frameDuration);
      gate.updateFloorTracking(loudFrameDb, frameDuration, true);
    }

    assert.strictEqual(gate.speechCeilingDb, null);
    assert.ok(gate.snapshot.floorDb > ceilingFloor);
  });

  it('stale re-anchor lands on the speech ceiling cap', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 100; i++) harness.drive(-25);
    let emitted = false;
    for (let i = 0; i < 500; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        emitted = true;
        break;
      }
    }
    assert.strictEqual(emitted, true);
    assert.strictEqual(harness.gate.speechCeilingDb, -25);

    const gate = harness.gate;
    const ceilingFloor = -25 - 10 - VAD_SPEECH_CEILING_MARGIN_DB;
    gate.floorDb = -40;
    let reanchorEvent = false;
    for (let i = 0; i < 301; i++) {
      const frameDb = -22;
      gate.process(frameDb, frameDuration);
      if (gate.takePendingReanchorEvent()) reanchorEvent = true;
      gate.updateFloorTracking(frameDb, frameDuration, false);
    }

    assert.strictEqual(reanchorEvent, true);
    assert.ok(Math.abs(gate.snapshot.floorDb - ceilingFloor) < 0.001);
    assert.strictEqual(gate.speechCeilingDb, -25);
  });
});
