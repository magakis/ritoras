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

function makeEndpoint(endpointSilenceMs = 3000) {
  return new StreamingEndpoint({ endpointSilenceMs });
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

function driveIdleFrame(gate, endpoint, frameDb, trackingDuration = frameDuration) {
  const output = gate.process(frameDb, frameDuration);
  const reanchorEvent = gate.takePendingReanchorEvent();
  const decision = endpoint.process(output.evidence, frameSamples);
  gate.updateFloorTracking(frameDb, trackingDuration, true);
  return { output, decision, reanchorEvent };
}

function makeRecorderHarness({
  frameMs = frameDurationMs,
  endpointSilenceMs = 3000,
  minChunkSamples = 0,
  minSpeechSamples = 0,
} = {}) {
  const recorderFrameDuration = frameMs / 1000;
  const recorderFrameSamples = frameMs * 16;
  const harness = {
    gate: makeGate(),
    endpoint: makeEndpoint(endpointSilenceMs),
    minChunkSamples,
    minSpeechSamples,
    chunkCount: 0,
    reanchorEventCount: 0,
    utteranceQuietestStrongDb: null,
    accumulatorSamples: 0,
    speechSamples: 0,
    emittedTotalMs: null,
    noteUtteranceEndedValues: [],
    sustainedContinuingMs: 0,
    sustainedContinuingOnsetLatched: false,
    sawReanchorDuringUtterance: false,

    drive(frameDb) {
      const output = this.gate.process(frameDb, recorderFrameDuration);
      const reanchorEvent = this.gate.takePendingReanchorEvent();
      const previousState = this.endpoint.state;
      const endpointWasIdle = previousState === 'idle';
      if (reanchorEvent) this.reanchorEventCount += 1;

      if (reanchorEvent
        && (previousState === 'speechActive' || previousState === 'endPending')) {
        this.sawReanchorDuringUtterance = true;
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
        this.emittedTotalMs = this.accumulatorSamples / 16;
        if (this.accumulatorSamples < this.minChunkSamples
          || this.speechSamples < this.minSpeechSamples) {
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          this.sawReanchorDuringUtterance = false;
          discarded = true;
        } else {
          this.chunkCount += 1;
          this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
          this.gate.noteUtteranceEnded(this.utteranceQuietestStrongDb);
          this.utteranceQuietestStrongDb = null;
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          this.sawReanchorDuringUtterance = false;
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
  it('reaches the ambient floor without endpoint onset', () => {
    const gate = makeGate();
    let firstSilenceMs = null;

    for (let i = 0; i < 700; i++) {
      const output = gate.process(-65, frameDuration);
      gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, frameDuration, true);
      const elapsedMs = (i + 1) * frameDurationMs;
      if (output.evidence === 'silence' && firstSilenceMs === null) {
        firstSilenceMs = elapsedMs;
      }
    }

    assert.ok(firstSilenceMs !== null && firstSilenceMs <= 4100);
    assert.strictEqual(gate.snapshot.floorDb, -65);
  });

  it('N1/N6: continuous speech stays one chunk until a real pause', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    const monologueMs = 60_000;
    let initialFloor = null;
    let previousAccumulatorSamples = 0;

    for (let i = 0; i < monologueMs / frameDurationMs; i++) {
      const frame = harness.drive(-21);
      assert.strictEqual(frame.output.evidence, 'strong');
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.strictEqual(frame.discarded, false);
      initialFloor ??= harness.gate.snapshot.floorDb;
      assert.ok(Math.abs(harness.gate.snapshot.floorDb - initialFloor) <= 1e-9);
      assert.ok(harness.accumulatorSamples >= previousAccumulatorSamples);
      previousAccumulatorSamples = harness.accumulatorSamples;
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.ok(harness.accumulatorSamples > 0);

    let pauseMs = 0;
    let finalizeCount = 0;
    let finalized = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-80);
      pauseMs += frameDurationMs;
      if (frame.decision.type === 'finalizeUtterance') {
        finalizeCount += 1;
        finalized = frame;
        break;
      }
    }

    assert.ok(pauseMs >= 700);
    assert.strictEqual(finalizeCount, 1);
    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.ok(Math.abs(harness.emittedTotalMs - (monologueMs + pauseMs)) <= 300);
  });

  it('ends talk-then-real-silence after endpoint silence', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    let finalizedAtMs = null;

    for (let i = 0; i < 1000; i++) {
      const { decision } = driveFrame(gate, endpoint, -21);
      assert.notStrictEqual(decision.type, 'finalizeUtterance');
    }

    for (let i = 0; i < 720; i++) {
      const { decision } = driveFrame(gate, endpoint, -80);
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

    for (let i = 0; i < 500; i++) {
      gate.process(-65, frameDuration);
      gate.takePendingReanchorEvent();
      gate.updateFloorTracking(-65, frameDuration, true);
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

  it('N4: re-anchors idle ambiguous ambient without opening the endpoint', () => {
    const gate = makeGate();
    const endpoint = makeEndpoint();
    gate.floorDb = -70;
    let reanchorEventCount = 0;
    let sawSilence = false;

    for (let i = 0; i < 400; i++) {
      const { output, decision, reanchorEvent } = driveIdleFrame(gate, endpoint, -65, 0);
      if (reanchorEvent) reanchorEventCount += 1;
      if (output.evidence === 'silence') sawSilence = true;
      assert.strictEqual(decision.type, 'none');
    }

    assert.strictEqual(reanchorEventCount, 1);
    assert.strictEqual(gate.snapshot.floorDb, -65);
    assert.strictEqual(sawSilence, true);
    assert.strictEqual(endpoint.state, 'idle');
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

  it('N3: continuous non-idle ambient never re-anchors or ends', () => {
    const harness = makeRecorderHarness();
    for (let i = 0; i < 6000; i++) {
      const frame = harness.drive(-65);
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      assert.strictEqual(frame.reanchorEvent, false);
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.gate.snapshot.floorDb, -80);
    assert.strictEqual(harness.endpoint.state, 'speechActive');
  });

  it('N7: stale time is retained until the machine becomes idle', () => {
    const gate = makeGate();
    gate.floorDb = -70;

    for (let i = 0; i < 500; i++) {
      gate.process(-65, frameDuration);
      assert.strictEqual(gate.takePendingReanchorEvent(), false);
      gate.updateFloorTracking(-65, frameDuration, false);
    }

    gate.process(-65, frameDuration);
    assert.strictEqual(gate.takePendingReanchorEvent(), false);
    gate.updateFloorTracking(-65, 0, true);

    gate.process(-65, frameDuration);
    assert.strictEqual(gate.takePendingReanchorEvent(), true);
    assert.strictEqual(gate.snapshot.floorDb, -65);
  });

  it('keeps an utterance when real speech follows continuous ambient', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-65);
    for (let i = 0; i < 30; i++) harness.drive(-21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(finalized, true);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
  });

  it('noisy pause after real speech does not discard the utterance', () => {
    const harness = makeRecorderHarness();
    const quietestStrongDb = -35;
    let sawReanchor = false;

    for (let i = 0; i < 220; i++) harness.drive(quietestStrongDb);

    // Ambiguous evidence keeps the active utterance alive, but cannot move the
    // floor or trigger a stale re-anchor while the endpoint is non-idle.
    for (let i = 0; i < 320; i++) {
      const floorDb = harness.gate.snapshot.floorDb;
      const frameDb = floorDb + (i % 10 < 2 ? 4 : 6);
      const frame = harness.drive(frameDb);
      sawReanchor ||= frame.reanchorEvent;
    }

    let finalized = null;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.strictEqual(sawReanchor, false);
    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.strictEqual(harness.noteUtteranceEndedValues.at(-1), quietestStrongDb);
  });

  it('R2: emits a continuing-only fallback onset without a mid-utterance re-anchor', () => {
    const harness = makeRecorderHarness();
    let sawFallbackOnset = false;
    let finalized = null;

    for (let i = 0; i < 200; i++) {
      const frameDb = harness.gate.snapshot.floorDb + 7;
      const frame = harness.drive(frameDb);
      assert.notStrictEqual(frame.output.evidence, 'strong');
      if (frame.output.evidence === 'continuing' && frame.endpointEvidence === 'strong') {
        sawFallbackOnset = true;
      }
    }

    assert.strictEqual(sawFallbackOnset, true);
    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.utteranceQuietestStrongDb, null);
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('N5: headroom guards preserve a valid ceiling and prevent the ambient wedge', () => {
    const gate = makeGate();
    gate.floorDb = -50;

    gate.noteUtteranceEnded(-40);
    assert.strictEqual(gate.speechCeilingDb, null);
    gate.noteUtteranceEnded(-38);
    assert.strictEqual(gate.speechCeilingDb, -38);
    gate.noteUtteranceEnded(null);
    assert.strictEqual(gate.speechCeilingDb, -38);

    const harness = makeRecorderHarness();
    harness.gate.speechCeilingDb = -35;
    let ambientDb = null;
    let ambientFinalized = null;

    for (let i = 0; i < 200; i++) {
      const frameDb = harness.gate.snapshot.floorDb + 7;
      const frame = harness.drive(frameDb);
      if (frame.decision.type === 'startUtterance') {
        ambientDb = frameDb;
        break;
      }
    }
    assert.ok(ambientDb !== null);

    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        ambientFinalized = frame;
        break;
      }
    }
    assert.ok(ambientFinalized !== null);
    assert.strictEqual(ambientFinalized.discarded, false);
    assert.strictEqual(harness.gate.speechCeilingDb, -35);

    const floorBeforeIdleAmbient = harness.gate.snapshot.floorDb;
    let reonset = false;
    for (let i = 0; i < 200; i++) {
      const frame = harness.drive(ambientDb);
      if (frame.decision.type === 'startUtterance') reonset = true;
    }
    assert.strictEqual(reonset, false);
    assert.strictEqual(harness.endpoint.state, 'idle');
    assert.ok(harness.gate.snapshot.floorDb > floorBeforeIdleAmbient);
  });

  it('R3: kept utterances still respect the min-chunk/min-speech gates', () => {
    const quietestStrongDb = -35;
    const harness = makeRecorderHarness({
      minChunkSamples: 1,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
    });

    for (let i = 0; i < 220; i++) harness.drive(quietestStrongDb);
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
    assert.strictEqual(harness.sawReanchorDuringUtterance, false);
    assert.strictEqual(harness.accumulatorSamples, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('still discards an utterance below both minimum gates', () => {
    const harness = makeRecorderHarness({
      endpointSilenceMs: 800,
      minChunkSamples: Number.MAX_SAFE_INTEGER,
      minSpeechSamples: Number.MAX_SAFE_INTEGER,
    });

    for (let i = 0; i < 100; i++) harness.drive(-21);

    let finalized = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, true);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'idle');
  });

  it('does not discard speech that starts on the first frame', () => {
    const harness = makeRecorderHarness();

    for (let i = 0; i < 400; i++) harness.drive(-21);

    let finalized = false;
    for (let i = 0; i < 600; i++) {
      const frame = harness.drive(-80);
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

  it('N2/R1: flat monotone speech stays active for 60 seconds and resumes after pause', () => {
    const harness = makeRecorderHarness({ endpointSilenceMs: 700 });
    const monologueMs = 60_000;
    let initialFloor = null;

    for (let i = 0; i < monologueMs / frameDurationMs; i++) {
      const frame = harness.drive(-40 + (i % 2));
      assert.strictEqual(frame.output.evidence, 'strong');
      assert.notStrictEqual(frame.decision.type, 'finalizeUtterance');
      initialFloor ??= harness.gate.snapshot.floorDb;
      assert.ok(Math.abs(harness.gate.snapshot.floorDb - initialFloor) <= 1e-9);
    }

    assert.strictEqual(harness.reanchorEventCount, 0);
    assert.strictEqual(harness.chunkCount, 0);
    assert.strictEqual(harness.endpoint.state, 'speechActive');

    let finalized = null;
    for (let i = 0; i < 100; i++) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = frame;
        break;
      }
    }

    assert.ok(finalized !== null);
    assert.strictEqual(finalized.discarded, false);
    assert.strictEqual(harness.chunkCount, 1);
    assert.strictEqual(harness.endpoint.state, 'idle');

    for (let i = 0; i < 6; i++) {
      const frame = harness.drive(-40);
      assert.notStrictEqual(frame.decision.type, 'startUtterance');
    }
    assert.strictEqual(harness.drive(-40).decision.type, 'startUtterance');
    assert.strictEqual(harness.endpoint.state, 'speechActive');
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
      assert.strictEqual(gate.snapshot.floorDb, -40);
    }
    assert.strictEqual(gate.snapshot.floorDb, -40);

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
      gate.updateFloorTracking(frameDb, 0, true);
    }

    assert.strictEqual(reanchorEvent, true);
    assert.ok(Math.abs(gate.snapshot.floorDb - ceilingFloor) < 0.001);
    assert.strictEqual(gate.speechCeilingDb, -25);
  });
});
