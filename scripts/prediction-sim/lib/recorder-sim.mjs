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
const DEFAULT_HEAD_BUFFER_SAMPLES = 2500 * 16;

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
  if (decision.type === 'startUtterance') return 'start_utterance';
  if (decision.type === 'continueUtterance') return 'continue_utterance';
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
    loudRegimeEnabled: gate.config.loudRegimeEnabled,
    loudRegimeEnterDb: gate.config.loudRegimeEnterDb,
    loudRegimeExitDb: gate.config.loudRegimeExitDb,
    loudRegimeEnterMs: gate.config.loudRegimeEnterMs,
    loudRegimeExitMs: gate.config.loudRegimeExitMs,
    loudStrongDeltaDb: gate.config.loudStrongDeltaDb,
    loudContinuationDeltaDb: gate.config.loudContinuationDeltaDb,
    loudSilenceDeltaDb: gate.config.loudSilenceDeltaDb,
    loudDynamicsSpreadDb: gate.config.loudDynamicsSpreadDb,
    loudRiseDbPerSec: gate.config.loudRiseDbPerSec,
    quietContinuationRiseCapDbPerSec: gate.config.quietContinuationRiseCapDbPerSec,
    loudLatchMs: harness.loudLatchMs,
    loudLatchAmbiguousEnabled: harness.loudLatchAmbiguousEnabled,
    loudLatchWitnessDb: harness.loudLatchWitnessDb,
    loudFlatTerminateEnabled: harness.loudFlatTerminateEnabled,
    loudFlatSpreadDb: harness.loudFlatSpreadDb,
    loudFlatTerminateSeconds: harness.loudFlatTerminateSeconds,
    loudFlatStreakMs: harness.flatFrameStreakMs,
    loudFlatTerminatorActive: harness.flatTerminatorActive,
    loudPreRollMs: harness.loudPreRollMs,
    quietLatchMs: harness.quietLatchMs,
    quietLatchWitnessDb: harness.quietLatchWitnessDb,
    quietLatchWitnessEnabled: harness.quietLatchWitnessEnabled,
    quietLatchDutyCycle: harness.quietLatchDutyCycle,
    quietLatchAmbiguousEnabled: harness.quietLatchAmbiguousEnabled,
    softOnsetPreRollMs: harness.softOnsetPreRollMs,
    softOnsetPreRollEnabled: harness.softOnsetPreRollEnabled,
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
  recorderConfig = {},
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
    postHeadPreRollSamples: 0,
    loudPreRollMs: recorderConfig.loudPreRollMs ?? endpoint.configuration.preRollSamples / 16,
    softOnsetPreRollMs: recorderConfig.softOnsetPreRollMs ?? 500,
    softOnsetPreRollEnabled: recorderConfig.softOnsetPreRollEnabled ?? false,
    loudLatchMs: recorderConfig.loudLatchMs ?? 400,
    loudLatchAmbiguousEnabled: recorderConfig.loudLatchAmbiguousEnabled ?? false,
    loudLatchWitnessDb: recorderConfig.loudLatchWitnessDb ?? 3,
    quietLatchMs: recorderConfig.quietLatchMs ?? 1000,
    quietLatchWitnessDb: recorderConfig.quietLatchWitnessDb ?? 3,
    quietLatchWitnessEnabled: recorderConfig.quietLatchWitnessEnabled ?? false,
    quietLatchDutyCycle: recorderConfig.quietLatchDutyCycle ?? 1,
    quietLatchAmbiguousEnabled: recorderConfig.quietLatchAmbiguousEnabled ?? false,
    loudFlatTerminateEnabled: recorderConfig.loudFlatTerminateEnabled ?? false,
    loudFlatSpreadDb: recorderConfig.loudFlatSpreadDb ?? 2.5,
    loudFlatTerminateSeconds: recorderConfig.loudFlatTerminateSeconds ?? 3,
    flatFrameStreakMs: 0,
    flatFrameStreakStartTime: null,
    flatTerminatorActive: false,
    terminatorActivationCount: 0,
    latchMissingDynamicsWitnessCount: 0,
    maxNoiseSamples,
    chunkCount: 0,
    nextChunkId: 0,
    frameSequence: 0,
    reanchorEventCount: 0,
    utteranceQuietestStrongDb: null,
    accumulatorSamples: 0,
    chunkStartSessionSamples: null,
    sessionElapsedSamples: 0,
    // Each harness models a fresh session; Swift re-arms headBuffer in setTelemetrySink at session begin.
    headSamples: 0,
    headLive: true,
    headPrependedAtOnset: null,
    headSlices: [],
    speechSamples: 0,
    silenceSamples: 0,
    emittedTotalMs: null,
    noteUtteranceEndedValues: [],
    sustainedContinuingMs: 0,
    streakStartFloorDb: null,
    streakPeakDb: null,
    sustainedContinuingOnsetLatched: false,
    streakSawDynamics: false,
    latchWitnessRejectionCounted: false,
    quietLatchHistory: [],
    quietLatchCandidateStartTime: null,
    quietLatchStartFloorDb: null,
    quietLatchCoverageMs: 0,
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
      if (output.isLoudRegime) record.lr = true;
      this.frameSequence += 1;
      if (typeof onFrame === 'function') onFrame(record);
      return record;
    },

    drive(frameDb, frameDuration = recorderFrameDuration) {
      const frameSamples = Math.round(frameDuration * 16000);
      this.sessionElapsedSamples += frameSamples;
      const output = this.gate.process(frameDb, frameDuration);
      if (this.endpointMachineEnabled && this.headLive) {
        this.headSamples = Math.min(
          this.headSamples + frameSamples,
          this.headBufferSamples,
        );
        this.headSlices.push({
          sampleCount: frameSamples,
          frameDb,
          silenceThresholdDb: output.silenceThresholdDb,
        });
        let excessSamples = this.headSlices.reduce((total, slice) => total + slice.sampleCount, 0)
          - this.headSamples;
        while (excessSamples > 0 && this.headSlices.length > 0) {
          if (this.headSlices[0].sampleCount <= excessSamples) {
            excessSamples -= this.headSlices.shift().sampleCount;
          } else {
            this.headSlices[0].sampleCount -= excessSamples;
            excessSamples = 0;
          }
        }
      }
      const reanchorEvent = this.gate.takePendingReanchorEvent();
      const previousState = this.endpoint.state;
      const endpointWasIdle = previousState === 'idle';
      if (reanchorEvent) this.reanchorEventCount += 1;

      if (reanchorEvent
        && (previousState === 'speechActive' || previousState === 'endPending')) {
        this.sawReanchorDuringUtterance = true;
      }

      const adaptivePath = output.floorDb !== null;
      const quietWitnessMode = this.quietLatchWitnessEnabled && !output.isLoudRegime;
      if (this.quietLatchWitnessEnabled && !quietWitnessMode) this.resetQuietLatchWindow();
      const eligibleStreak = output.evidence === 'continuing'
        || (this.loudLatchAmbiguousEnabled && output.evidence === 'ambiguous');
      if (quietWitnessMode) {
        this.updateQuietWitnessStreak(output, frameDb, frameDuration, endpointWasIdle);
      } else if (adaptivePath && eligibleStreak && endpointWasIdle) {
        if (this.sustainedContinuingMs === 0) {
          this.streakStartFloorDb = this.gate.snapshot.floorDb;
          this.streakPeakDb = frameDb;
          this.latchWitnessRejectionCounted = false;
        } else {
          this.streakPeakDb = Math.max(this.streakPeakDb ?? frameDb, frameDb);
        }
        this.sustainedContinuingMs += frameDuration * 1000;
        if ((output.dynamicsSpreadDb ?? 0) >= this.loudLatchWitnessDb) {
          this.streakSawDynamics = true;
        }
      } else if (!this.sustainedContinuingOnsetLatched) {
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
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
      const legacyLoudBranch = !this.gate.config.loudRegimeEnabled
        && output.floorDb >= VAD_LOUD_FLOOR_REGIME_DB;
      const quietLatchQualified = quietWitnessMode
        ? this.quietLatchStreakQualified(
          output,
          quietRegimeEvidence,
          quietRegimeFloorStable,
        )
        : quietRegimeEvidence
          && quietRegimeFloorStable
          && this.sustainedContinuingMs >= VAD_SUSTAINED_CONTINUING_ONSET_S * 1000;
      const legacyLoudLatchQualified = legacyLoudBranch
        && loudRegimeEvidence
        && this.sustainedContinuingMs >= 1.5 * VAD_SUSTAINED_CONTINUING_ONSET_S * 1000;
      const loudLatchQualified = output.isLoudRegime
        && this.sustainedContinuingMs >= this.loudLatchMs
        && this.streakSawDynamics;
      if (adaptivePath
        && output.floorConverged
        && (output.evidence === 'continuing'
          || (output.isLoudRegime
            ? this.loudLatchAmbiguousEnabled
            : this.quietLatchWitnessEnabled && this.quietLatchAmbiguousEnabled)
            && output.evidence === 'ambiguous')
        && endpointWasIdle
        && (quietLatchQualified || legacyLoudLatchQualified || loudLatchQualified)) {
        this.sustainedContinuingOnsetLatched = true;
      }
      if (output.isLoudRegime
        && this.sustainedContinuingMs >= this.loudLatchMs
        && !this.streakSawDynamics
        && !this.latchWitnessRejectionCounted) {
        this.latchMissingDynamicsWitnessCount += 1;
        this.latchWitnessRejectionCounted = true;
      }
      const endpointInOnsetLimb = endpointWasIdle || previousState === 'onsetPending';
      if (this.sustainedContinuingOnsetLatched
        && (!adaptivePath
          || !endpointInOnsetLimb
          || (output.evidence === 'ambiguous'
            && !(output.isLoudRegime
              ? this.loudLatchAmbiguousEnabled
              : this.quietLatchWitnessEnabled && this.quietLatchAmbiguousEnabled))
          || output.evidence === 'silence')) {
        this.sustainedContinuingOnsetLatched = false;
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
      }
      const latchedContinuingOnset = this.sustainedContinuingOnsetLatched
        && (output.evidence === 'continuing'
          || (output.isLoudRegime
            ? this.loudLatchAmbiguousEnabled
            : this.quietLatchWitnessEnabled && this.quietLatchAmbiguousEnabled)
            && output.evidence === 'ambiguous')
        && endpointInOnsetLimb;
      let endpointEvidence = adaptivePath
        && latchedContinuingOnset
        ? 'strong'
        : output.evidence;
      const flatTerminatorStateEligible = previousState === 'speechActive'
        || (this.flatTerminatorActive && previousState === 'endPending');
      const flat = this.loudFlatTerminateEnabled
        && output.isLoudRegime
        && flatTerminatorStateEligible
        && output.dynamicsSpreadDb !== null
          && output.shortSpreadDb !== null
          && output.dynamicsSpreadDb < this.loudFlatSpreadDb
          && output.shortSpreadDb < this.loudFlatSpreadDb;
      if (flat) {
        if (!this.flatTerminatorActive) {
          this.flatFrameStreakStartTime ??= (this.sessionElapsedSamples - frameSamples) / 16000;
          this.flatFrameStreakMs += frameDuration * 1000;
          if (this.flatFrameStreakMs >= this.loudFlatTerminateSeconds * 1000) {
            this.flatTerminatorActive = true;
            if (endpointEvidence !== 'silence') {
              this.terminatorActivationCount += 1;
              this.emitEvent({
                t: 'ev',
                k: 'flat_terminate',
                n: Math.round(this.flatFrameStreakMs * 16),
                r: 'flat_spread',
                startTime: this.flatFrameStreakStartTime,
                time: this.sessionElapsedSamples / 16000,
              });
            }
          }
        }
        if (this.flatTerminatorActive) endpointEvidence = 'silence';
      } else {
        this.flatFrameStreakMs = 0;
        this.flatFrameStreakStartTime = null;
        this.flatTerminatorActive = false;
      }
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
        if (this.flatTerminatorActive && this.endpoint.state === 'idle') {
          this.flatFrameStreakMs = 0;
          this.flatFrameStreakStartTime = null;
          this.flatTerminatorActive = false;
        }
        decisionSilenceSamples = this.endpoint.accumulatedSilenceSamples;
        this.gate.updateFloorTracking(
          frameDb,
          frameDuration,
          previousState === 'idle' && this.endpoint.state === 'idle',
          previousState === 'endPending' || this.endpoint.state === 'endPending',
          this.quietLatchWitnessDb,
        );

        if (decision.type === 'startUtterance') {
          this.utteranceQuietestStrongDb = null;
          const softOnset = this.quietLatchWitnessEnabled
            && latchedContinuingOnset
            && !output.isLoudRegime;
          if (this.headLive) {
            const trimmedSamples = this.headTrimSamples();
            this.accumulatorSamples = this.headSamples - trimmedSamples;
            this.headPrependedAtOnset = this.headSamples - trimmedSamples;
            this.chunkStartSessionSamples = this.sessionElapsedSamples
              - this.headSamples + trimmedSamples;
          } else {
            let requestedPreRollMs = output.isLoudRegime
              ? Math.max(this.endpoint.configuration.preRollSamples / 16, this.loudPreRollMs)
              : this.endpoint.configuration.preRollSamples / 16;
            if (softOnset && this.softOnsetPreRollEnabled) {
              requestedPreRollMs = Math.max(requestedPreRollMs, this.softOnsetPreRollMs);
            }
            const requestedPreRollSamples = Math.round(requestedPreRollMs * 16);
            const preRollSamples = Math.min(requestedPreRollSamples, this.postHeadPreRollSamples);
            this.accumulatorSamples = preRollSamples + frameSamples;
            this.chunkStartSessionSamples = this.sessionElapsedSamples
              - frameSamples - preRollSamples;
            this.postHeadPreRollSamples = 0;
          }
          this.sustainedContinuingMs = 0;
          this.streakStartFloorDb = null;
          this.streakPeakDb = null;
          this.streakSawDynamics = false;
          this.sustainedContinuingOnsetLatched = false;
          this.resetQuietLatchWindow();
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
          false,
          this.quietLatchWitnessDb,
        );
        if (this.accumulatorSamples === 0) {
          this.chunkStartSessionSamples = this.sessionElapsedSamples - frameSamples;
        }
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
          this.chunkStartSessionSamples = null;
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
          ...(this.quietLatchWitnessEnabled
            && latchedContinuingOnset
            && !output.isLoudRegime ? { softOnset: true } : {}),
        });
      }

      if (decision.type === 'finalizeUtterance') {
        this.emittedTotalMs = this.accumulatorSamples / 16;
        const totalSamples = this.accumulatorSamples;
        const speechMs = this.speechSamples / 16;
        if (this.accumulatorSamples < this.minChunkSamples
          || this.speechSamples < this.minSpeechSamples) {
          this.accumulatorSamples = 0;
          this.chunkStartSessionSamples = null;
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
            s0: this.chunkStartSessionSamples / 16,
            s1: (this.chunkStartSessionSamples + totalSamples) / 16,
            es: previousState,
          });
          this.headLive = false;
          this.headSamples = 0;
          this.postHeadPreRollSamples = 0;
          this.utteranceQuietestStrongDb = null;
          this.accumulatorSamples = 0;
          this.chunkStartSessionSamples = null;
          this.speechSamples = 0;
          this.silenceSamples = 0;
          this.sawReanchorDuringUtterance = false;
          this.sustainedContinuingMs = 0;
          this.streakStartFloorDb = null;
           this.streakPeakDb = null;
           this.streakSawDynamics = false;
          this.sustainedContinuingOnsetLatched = false;
          this.resetQuietLatchWindow();
        }
      }

      if (!this.headLive && decision.type !== 'startUtterance') {
        if (decision.type === 'finalizeUtterance' || discarded) {
          this.postHeadPreRollSamples = 0;
        } else if (previousState === 'idle' || previousState === 'onsetPending') {
          const capacity = Math.max(
            this.endpoint.configuration.preRollSamples,
            Math.round(this.loudPreRollMs * 16),
            Math.round(this.softOnsetPreRollMs * 16),
          );
          this.postHeadPreRollSamples = Math.min(
            capacity,
            this.postHeadPreRollSamples + frameSamples,
          );
        } else {
          this.postHeadPreRollSamples = 0;
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

    resetQuietLatchWindow() {
      this.quietLatchHistory.length = 0;
      this.quietLatchCandidateStartTime = null;
      this.quietLatchStartFloorDb = null;
      this.quietLatchCoverageMs = 0;
    },

    updateQuietWitnessStreak(output, frameDb, frameDuration, endpointWasIdle) {
      const eligible = output.evidence === 'continuing'
        || (this.quietLatchAmbiguousEnabled && output.evidence === 'ambiguous');
      if (!endpointWasIdle || output.floorDb === null) {
        if (!this.sustainedContinuingOnsetLatched) this.resetQuietLatchWindow();
        return;
      }

      const end = this.sessionElapsedSamples / 16000;
      const start = end - frameDuration;
      if (this.quietLatchCandidateStartTime === null && eligible) {
        this.quietLatchCandidateStartTime = start;
        this.quietLatchStartFloorDb = output.floorDb;
      }
      if (this.quietLatchCandidateStartTime === null) {
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
        return;
      }

      this.quietLatchHistory.push({
        start,
        end,
        eligible,
        frameDb,
        floorDb: output.floorDb,
        dynamicsSpreadDb: output.dynamicsSpreadDb,
      });
      const windowSeconds = Math.max(0, this.quietLatchMs) / 1000;
      const cutoff = end - windowSeconds;
      while (this.quietLatchHistory.length > 0
        && this.quietLatchHistory[0].end <= cutoff) {
        this.quietLatchHistory.shift();
      }
      if (this.quietLatchHistory.length > 0
        && this.quietLatchHistory[0].start < cutoff) {
        this.quietLatchHistory[0].start = cutoff;
      }

      const eligibleFrames = this.quietLatchHistory.filter(frame => frame.eligible);
      if (eligibleFrames.length === 0) {
        this.resetQuietLatchWindow();
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
        return;
      }
      if (output.floorDb - this.quietLatchStartFloorDb > 2) {
        this.resetQuietLatchWindow();
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
        if (eligible) this.updateQuietWitnessStreak(output, frameDb, frameDuration, endpointWasIdle);
        return;
      }

      this.quietLatchCoverageMs = eligibleFrames.reduce(
        (total, frame) => total + (frame.end - frame.start) * 1000,
        0,
      );
      this.sustainedContinuingMs = Math.min(
        Math.max(0, this.quietLatchMs),
        (end - this.quietLatchCandidateStartTime) * 1000,
      );
      this.streakStartFloorDb = this.quietLatchStartFloorDb;
      this.streakPeakDb = Math.max(...eligibleFrames.map(frame => frame.frameDb));
      this.streakSawDynamics = eligibleFrames.some(frame => (
        (frame.dynamicsSpreadDb ?? 0) >= this.quietLatchWitnessDb
      ));
    },

    quietLatchStreakQualified(output, legacyEvidence, floorStable) {
      const windowMs = Math.max(0, this.quietLatchMs);
      const dutyCycle = Math.min(1, Math.max(0, this.quietLatchDutyCycle));
      const eligible = output.evidence === 'continuing'
        || (this.quietLatchAmbiguousEnabled && output.evidence === 'ambiguous');
      return eligible
        && output.floorConverged
        && !output.isLoudRegime
        && floorStable
        && this.sustainedContinuingMs >= windowMs
        && this.quietLatchCoverageMs >= dutyCycle * windowMs
        && (legacyEvidence || this.streakSawDynamics);
    },

    headTrimSamples() {
      const protectedSamples = 500 * 16;
      const maximumTrimSamples = Math.max(0, this.headSamples - protectedSamples);
      let trimmedSamples = 0;
      for (const slice of this.headSlices) {
        if (trimmedSamples + slice.sampleCount > maximumTrimSamples
          || slice.silenceThresholdDb === null
          || slice.silenceThresholdDb === undefined
          || slice.frameDb >= slice.silenceThresholdDb) break;
        trimmedSamples += slice.sampleCount;
      }
      return trimmedSamples;
    },

    flush() {
      const sampleCount = this.accumulatorSamples;
      const speechMs = this.speechSamples / 16;
      const decisionTimeEndpointState = this.endpoint.state;
      const startMs = (this.chunkStartSessionSamples
        ?? (this.sessionElapsedSamples - sampleCount)) / 16;
      const endMs = startMs + sampleCount / 16;
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
        ...(sampleCount > 0 ? { s0: startMs } : {}),
        s1: endMs,
        es: decisionTimeEndpointState,
      });
      if (sampleCount === 0) return { type: 'none' };
      if (this.speechSamples < this.minSpeechSamples) {
        this.accumulatorSamples = 0;
        this.chunkStartSessionSamples = null;
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
        s0: startMs,
        s1: endMs,
        es: decisionTimeEndpointState,
      });
      this.headLive = false;
      this.headSamples = 0;
      this.accumulatorSamples = 0;
      this.chunkStartSessionSamples = null;
      this.speechSamples = 0;
      this.silenceSamples = 0;
      this.utteranceQuietestStrongDb = null;
      this.sustainedContinuingMs = 0;
      this.streakStartFloorDb = null;
      this.streakPeakDb = null;
      this.sustainedContinuingOnsetLatched = false;
      this.streakSawDynamics = false;
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
