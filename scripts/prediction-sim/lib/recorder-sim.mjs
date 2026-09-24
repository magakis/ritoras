import {
  makeVadGateConfig,
  VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB,
  VAD_LOUD_FLOOR_REGIME_DB,
  VAD_SUSTAINED_CONTINUING_ONSET_S,
  VADThresholdGate,
} from './vad-gate.mjs';
import { StreamingEndpoint } from './streaming-endpoint.mjs';

const DEFAULT_FRAME_MS = 10;
const DEFAULT_ENDPOINT_SILENCE_MS = 3000;
const DEFAULT_MAX_NOISE_SAMPLES = 6 * 16000;
const DEFAULT_HEAD_BUFFER_SAMPLES = 6000 * 16;

function makeGate(partial = {}) {
  return new VADThresholdGate(makeVadGateConfig({
    mode: 'adaptive',
    ...partial,
  }));
}

function makeEndpoint(endpointSilenceMs = DEFAULT_ENDPOINT_SILENCE_MS, partial = {}) {
  return new StreamingEndpoint({ endpointSilenceMs, ...partial });
}

function decisionLabel(decision) {
  if (decision.type === 'finalizeUtterance') return `finalize_${decision.kind}`;
  return decision.type;
}

function makeSessionConfig(harness) {
  const gate = harness.gate;
  const endpoint = harness.endpoint.configuration;
  const config = {
    mode: gate.config.mode,
    strongDeltaDb: gate.effectiveAdaptiveDeltaDb,
    continuationDeltaDb: gate.effectiveAdaptiveContinuationDeltaDb,
    silenceDeltaDb: gate.effectiveSilenceDeltaDb,
    dynamicsSpreadDb: gate.effectiveDynamicsSpreadDb,
    flatSpreadDb: gate.effectiveFlatSpreadDb,
    dynamicsEnabled: gate.config.adaptiveDynamicsEnabled,
    staleFloorSeconds: gate.effectiveStaleFloorSeconds,
    fallTauSeconds: gate.effectiveFallTauSeconds,
    riseMultiplier: gate.effectiveRiseSpeedMultiplier,
    endpointMachineEnabled: harness.endpointMachineEnabled,
    endpointOnsetMs: endpoint.onsetSamples / 16,
    endpointEndEvidenceMs: endpoint.endEvidenceSamples / 16,
    endpointSilenceMs: endpoint.endpointSilenceSamples / 16,
    endpointResumeMs: endpoint.resumeSamples / 16,
    endpointAmbiguousRescueMs: endpoint.ambiguousRescueSamples / 16,
    endpointPreRollMs: endpoint.preRollSamples / 16,
    sessionHeadBufferMs: harness.headBufferSamples / 16,
    silenceMs: harness.silenceThresholdSamples / 16,
    minSpeechMs: harness.minSpeechSamples / 16,
    minChunkMs: harness.minChunkSamples / 16,
    maxNoiseSec: harness.maxNoiseSamples / 16000,
    analysisHpfEnabled: false,
    analysisHpfCutoffHz: 100,
  };
  return config;
}

function copyOptional(target, key, value) {
  if (value !== null && value !== undefined) target[key] = value;
}

export function makeRecorderHarness({
  frameMs = DEFAULT_FRAME_MS,
  endpointSilenceMs = DEFAULT_ENDPOINT_SILENCE_MS,
  endpointConfig = {},
  minChunkSamples = 0,
  minSpeechSamples = 0,
  headBufferSamples = DEFAULT_HEAD_BUFFER_SAMPLES,
  maxNoiseSamples = DEFAULT_MAX_NOISE_SAMPLES,
  endpointMachineEnabled = true,
  gateConfig = {},
  onFrame,
  onEvent,
} = {}) {
  const recorderFrameDuration = frameMs / 1000;
  const endpoint = makeEndpoint(endpointSilenceMs, endpointConfig);
  const harness = {
    gate: makeGate(gateConfig),
    endpoint,
    endpointMachineEnabled,
    silenceThresholdSamples: endpoint.configuration.endpointSilenceSamples,
    minChunkSamples,
    minSpeechSamples,
    headBufferSamples,
    maxNoiseSamples,
    chunkCount: 0,
    nextChunkId: 0,
    frameSequence: 0,
    reanchorEventCount: 0,
    utteranceQuietestStrongDb: null,
    accumulatorSamples: 0,
    // Each harness models a fresh session; Swift re-arms headBuffer in setTelemetrySink at session begin.
    headSamples: 0,
    headLive: true,
    headPrependedAtOnset: null,
    speechSamples: 0,
    silenceSamples: 0,
    emittedTotalMs: null,
    noteUtteranceEndedValues: [],
    sustainedContinuingMs: 0,
    streakStartFloorDb: null,
    streakPeakDb: null,
    sustainedContinuingOnsetLatched: false,
    sawReanchorDuringUtterance: false,
    sessionConfig: null,

    emitEvent(event) {
      if (typeof onEvent === 'function') onEvent(event);
    },

    recordFrame(output, previousState, decision, decisionSilenceSamples, frameDb, frameDuration) {
      const record = {
        t: 'f',
        q: this.frameSequence,
        dt: frameDuration,
        db: frameDb,
        e: output.evidence,
        sp: output.isSpeech,
        th: output.thresholdDb,
        ct: output.continuationThresholdDb,
        st: output.silenceThresholdDb,
        ps: previousState,
        es: this.endpoint.state,
        d: decisionLabel(decision),
        ss: decisionSilenceSamples,
        us: this.endpoint.utteranceDurationSamples,
        ls: this.sustainedContinuingMs,
        ll: this.sustainedContinuingOnsetLatched,
      };
      copyOptional(record, 'fl', output.floorDb);
      record.fc = output.floorConverged;
      copyOptional(record, 'dy', output.dynamicsSpreadDb);
      this.frameSequence += 1;
      if (typeof onFrame === 'function') onFrame(record);
      return record;
    },

    drive(frameDb, frameDuration = recorderFrameDuration) {
      const frameSamples = Math.round(frameDuration * 16000);
      // The legacy accumulator already captures from session start; the head is endpoint-machine-only.
      if (this.endpointMachineEnabled && this.headLive) {
        this.headSamples = Math.min(
          this.headSamples + frameSamples,
          this.headBufferSamples,
        );
      }
      const output = this.gate.process(frameDb, frameDuration);
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
        if (this.sustainedContinuingMs === 0) {
          this.streakStartFloorDb = this.gate.snapshot.floorDb;
          this.streakPeakDb = frameDb;
        } else {
          this.streakPeakDb = Math.max(this.streakPeakDb ?? frameDb, frameDb);
        }
        this.sustainedContinuingMs += frameDuration * 1000;
      } else if (!this.sustainedContinuingOnsetLatched) {
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
      }

      const quietRegimeEvidence = output.floorDb !== null
        && output.floorDb < VAD_LOUD_FLOOR_REGIME_DB
        && ((output.dynamicsSpreadDb ?? 0) >= this.gate.effectiveFlatSpreadDb
          || frameDb >= output.continuationThresholdDb + 3);
      const quietRegimeFloorStable = output.floorDb !== null
        && this.streakStartFloorDb !== null
        && output.floorDb - this.streakStartFloorDb <= 2;
      const loudRegimeEvidence = output.floorDb !== null
        && (this.streakPeakDb ?? -Infinity)
          >= output.floorDb + this.gate.effectiveAdaptiveDeltaDb;
      if (adaptivePath
        && output.floorConverged
        && output.evidence === 'continuing'
        && endpointWasIdle
        && ((quietRegimeEvidence
          && quietRegimeFloorStable
          && this.sustainedContinuingMs >= VAD_SUSTAINED_CONTINUING_ONSET_S * 1000)
          || (loudRegimeEvidence
            && this.sustainedContinuingMs >= 1.5 * VAD_SUSTAINED_CONTINUING_ONSET_S * 1000))) {
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
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
      }
      const latchedContinuingOnset = this.sustainedContinuingOnsetLatched
        && output.evidence === 'continuing'
        && endpointInOnsetLimb;
      let endpointEvidence = adaptivePath
        && latchedContinuingOnset
        ? 'strong'
        : output.evidence;
      if (previousState === 'endPending'
        && output.shortSpreadDb !== null
        && output.dynamicsSpreadDb !== null
        && output.shortSpreadDb < this.gate.effectiveFlatSpreadDb
        && output.dynamicsSpreadDb < VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
        && (endpointEvidence === 'continuing' || endpointEvidence === 'ambiguous')) {
        endpointEvidence = 'silence';
      }
      if (output.retroactiveSpeechMs > 0) {
        this.speechSamples += output.retroactiveSpeechMs * 16;
      }
      if (output.isSpeech) this.speechSamples += frameSamples;

      let decision = { type: 'none' };
      let discarded = false;
      let decisionSilenceSamples = this.silenceSamples;
      if (this.endpointMachineEnabled) {
        decision = this.endpoint.process(endpointEvidence, frameSamples);
        decisionSilenceSamples = this.endpoint.accumulatedSilenceSamples;
        this.gate.updateFloorTracking(
          frameDb,
          frameDuration,
          previousState === 'idle' && this.endpoint.state === 'idle',
          previousState === 'endPending' || this.endpoint.state === 'endPending',
        );

        if (decision.type === 'startUtterance') {
          this.utteranceQuietestStrongDb = null;
          if (this.headLive) {
            this.accumulatorSamples = this.headSamples + frameSamples;
            this.headPrependedAtOnset = this.headSamples;
          } else {
            // The simplified pre-roll assumes its ring is full; unlike headSamples, it does not track fill.
            this.accumulatorSamples = this.endpoint.configuration.preRollSamples + frameSamples;
          }
          this.sustainedContinuingMs = 0;
          this.streakStartFloorDb = null;
          this.streakPeakDb = null;
          this.sustainedContinuingOnsetLatched = false;
          this.silenceSamples = 0;
        } else if (decision.type === 'continueUtterance'
          || decision.type === 'finalizeUtterance') {
          this.accumulatorSamples += frameSamples;
        }
        if (adaptivePath && output.evidence === 'strong' && this.endpoint.state !== 'idle') {
          this.utteranceQuietestStrongDb = Math.min(
            this.utteranceQuietestStrongDb ?? frameDb,
            frameDb,
          );
        }
      } else {
        this.gate.updateFloorTracking(
          frameDb,
          frameDuration,
          this.accumulatorSamples === 0,
        );
        this.accumulatorSamples += frameSamples;
        if (output.isSpeech) {
          this.silenceSamples = 0;
        } else {
          this.silenceSamples += frameSamples;
        }
        decisionSilenceSamples = this.silenceSamples;
        if (this.silenceSamples >= this.silenceThresholdSamples
          && this.accumulatorSamples >= this.minChunkSamples
          && this.speechSamples >= this.minSpeechSamples) {
          decision = { type: 'finalizeUtterance', kind: 'pause' };
        } else if (this.speechSamples < 1600 && this.accumulatorSamples > this.maxNoiseSamples) {
          discarded = true;
          this.emitEvent({
            t: 'ev',
            k: 'discard',
            n: this.accumulatorSamples,
            r: 'noise_guard',
          });
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          this.silenceSamples = 0;
        }
      }

      const frameRecord = this.recordFrame(
        output,
        previousState,
        this.endpointMachineEnabled ? decision : { type: 'none' },
        decisionSilenceSamples,
        frameDb,
        frameDuration,
      );

      if (decision.type === 'startUtterance') {
        this.emitEvent({
          t: 'ev',
          k: 'start_utterance',
          n: this.accumulatorSamples,
        });
      }

      if (decision.type === 'finalizeUtterance') {
        this.emittedTotalMs = this.accumulatorSamples / 16;
        const totalSamples = this.accumulatorSamples;
        const speechMs = this.speechSamples / 16;
        if (this.accumulatorSamples < this.minChunkSamples
          || this.speechSamples < this.minSpeechSamples) {
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          this.silenceSamples = 0;
          this.sawReanchorDuringUtterance = false;
          discarded = true;
          this.emitEvent({
            t: 'ev',
            k: 'discard',
            n: totalSamples,
            r: 'below_minimums',
          });
        } else {
          const reason = decision.kind;
          const chunkId = this.nextChunkId;
          this.nextChunkId += 1;
          this.chunkCount += 1;
          this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
          this.gate.noteUtteranceEnded(this.utteranceQuietestStrongDb);
          this.emitEvent({
            t: 'ev',
            k: 'emit',
            id: chunkId,
            n: totalSamples,
            r: reason,
            sm: speechMs,
            tm: this.emittedTotalMs,
          });
          this.headLive = false;
          this.headSamples = 0;
          this.utteranceQuietestStrongDb = null;
          this.accumulatorSamples = 0;
          this.speechSamples = 0;
          this.silenceSamples = 0;
          this.sawReanchorDuringUtterance = false;
          this.sustainedContinuingMs = 0;
          this.streakStartFloorDb = null;
          this.streakPeakDb = null;
          this.sustainedContinuingOnsetLatched = false;
        }
      }

      return {
        output,
        decision,
        endpointEvidence,
        reanchorEvent,
        discarded,
        latchedContinuingOnset,
        frameRecord,
      };
    },

    flush() {
      const sampleCount = this.accumulatorSamples;
      const speechMs = this.speechSamples / 16;
      const reason = sampleCount === 0
        ? 'empty'
        : this.speechSamples < this.minSpeechSamples ? 'below_minimums' : 'flush';
      if (this.endpointMachineEnabled) this.endpoint.forceFinalize('stop');
      this.emitEvent({
        t: 'ev',
        k: 'stop_flush',
        n: sampleCount,
        r: reason,
        sm: speechMs,
        tm: sampleCount / 16,
      });
      if (sampleCount === 0) return { type: 'none' };
      if (this.speechSamples < this.minSpeechSamples) {
        this.accumulatorSamples = 0;
        this.speechSamples = 0;
        this.silenceSamples = 0;
        return { type: 'none' };
      }
      const chunkId = this.nextChunkId;
      this.nextChunkId += 1;
      this.chunkCount += 1;
      this.emittedTotalMs = sampleCount / 16;
      this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
      this.gate.noteUtteranceEnded(this.utteranceQuietestStrongDb);
      this.emitEvent({
        t: 'ev',
        k: 'emit',
        id: chunkId,
        n: sampleCount,
        r: 'flush',
        sm: speechMs,
        tm: sampleCount / 16,
      });
      this.headLive = false;
      this.headSamples = 0;
      this.accumulatorSamples = 0;
      this.speechSamples = 0;
      this.silenceSamples = 0;
      this.utteranceQuietestStrongDb = null;
      this.sustainedContinuingMs = 0;
      this.streakStartFloorDb = null;
      this.streakPeakDb = null;
      this.sustainedContinuingOnsetLatched = false;
      return { type: 'finalizeUtterance', kind: 'stop' };
    },

    end({ flush = false } = {}) {
      if (flush) this.flush();
      this.emitEvent({ t: 'ev', k: 'session_end' });
    },
  };
  harness.sessionConfig = makeSessionConfig(harness);
  harness.emitEvent({ t: 'ev', k: 'session_start', c: harness.sessionConfig });
  return harness;
}
