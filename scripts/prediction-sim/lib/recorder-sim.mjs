import {
  isSpeechShaped,
  makeVadGateConfig,
  VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB,
  VAD_LOUD_FLOOR_REGIME_DB,
  VAD_WHISPER_HPF_CUTOFF_HZ,
  VADThresholdGate,
} from './vad-gate.mjs';
import { StreamingEndpoint } from './streaming-endpoint.mjs';
import {
  IDLE_GAP_TELEMETRY_EVIDENCE_ABOVE_FLOOR_DB,
  IDLE_GAP_TELEMETRY_MIN_SECONDS,
  IDLE_GAP_TELEMETRY_PEAK_ABOVE_FLOOR_DB,
} from './vad-idle-gap.mjs';

// This chunk splitter segments a continuous
// audio stream into chunks for streaming ASR while retaining all audio except
// voiceless slabs over maxNoiseSec. Speech is never trimmed from chunks; do not
// add silence-stripping or aggressive speech-gating here.

const DEFAULT_FRAME_MS = 10;
const DEFAULT_ENDPOINT_SILENCE_MS = 3000;
const DEFAULT_MAX_NOISE_SAMPLES = 6 * 16000;
const DEFAULT_HEAD_BUFFER_SAMPLES = 2500 * 16;
const MINIMUM_VOICE_EVIDENCE_SAMPLES = 100 * 16;
const GAP_SPEECH_PEAK_ABOVE_FLOOR_DB = 6;
const MAX_STRONG_GUST_FRAME_DURATION_S = 0.02;
const STOP_FLUSH_MINIMUM_SAMPLES = 250 * 16;
const POST_FINALIZE_SOFT_LATCH_SUPPRESSION_SAMPLES = 700 * 16;
export const VAD_POST_ROLL_SAMPLES = 400 * 16;

export function calculateSlowOnsetThreshold(floorDb, slowLevelDeltaDb, absoluteGuardDb) {
  return Math.max(floorDb + slowLevelDeltaDb, absoluteGuardDb);
}

function makeGate(partial = {}) {
  return new VADThresholdGate(makeVadGateConfig({
    mode: 'adaptive',
    ...partial,
  }));
}

function makeEndpoint(endpointSilenceMs = DEFAULT_ENDPOINT_SILENCE_MS, partial = {}) {
  return new StreamingEndpoint({ endpointSilenceMs, ...partial });
}

function clampFinite(value, fallback, minimum, maximum) {
  const finiteValue = Number.isFinite(value) ? value : fallback;
  return Math.min(maximum, Math.max(minimum, finiteValue));
}

function clampInteger(value, fallback, minimum, maximum) {
  return Math.trunc(clampFinite(value, fallback, minimum, maximum));
}

export function classifyEndPendingEvidence({
  endpointState,
  evidence,
  previousEvidence = null,
  speechShaped,
  shortSpreadDb,
  dynamicsSpreadDb,
  flatSpreadDb,
  adjacentStepDb = 0,
  accumulatedSilenceSamples,
  endpointSilenceSamples,
  ambiguousRescueSamples,
  rescueAwareWindowsEnabled,
  frameDuration = DEFAULT_FRAME_MS / 1000,
}) {
  if (endpointState !== 'endPending'
    || shortSpreadDb === null
    || shortSpreadDb === undefined
    || dynamicsSpreadDb === null
    || dynamicsSpreadDb === undefined) {
    return evidence;
  }

  const shapedEvidence = speechShaped ?? isSpeechShaped({
    dynamicsSpreadDb,
    shortSpreadDb,
    flatSpreadDb,
    adjacentStepDb,
  });
  if (evidence === 'strong') {
    // Only an unshaped edge that starts a short strong run is treated as a gust.
    const isolatedAbruptGust = !shapedEvidence
      && previousEvidence !== 'strong'
      && adjacentStepDb >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
      && dynamicsSpreadDb >= VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
      && shortSpreadDb >= flatSpreadDb
      && frameDuration <= MAX_STRONG_GUST_FRAME_DURATION_S;
    return isolatedAbruptGust ? 'silence' : evidence;
  }
  if ((evidence !== 'continuing' && evidence !== 'ambiguous') || shapedEvidence) {
    return evidence;
  }

  // Flat soft evidence may bank silence; the shared shape predicate above keeps
  // modulated soft evidence on the speech path. Preserve the existing wind filter
  // until the remaining silence is within one rescue window; after that,
  // continuing evidence must reach the endpoint as ambiguous or the widened
  // rescue threshold can never fire. The aperture is opt-in via sweep ratios;
  // legacy millisecond settings retain the original unconditional rewrite.
  if (!rescueAwareWindowsEnabled
    || endpointSilenceSamples - accumulatedSilenceSamples > ambiguousRescueSamples) {
    return 'silence';
  }

  return evidence === 'continuing' ? 'ambiguous' : evidence;
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
    absoluteSpeechFloorDb: gate.effectiveAbsoluteSpeechFloorDb,
    continuationDeltaDb: gate.effectiveAdaptiveContinuationDeltaDb,
    silenceDeltaDb: gate.effectiveSilenceDeltaDb,
    dynamicsSpreadDb: gate.effectiveDynamicsSpreadDb,
    flatSpreadDb: gate.effectiveFlatSpreadDb,
    dynamicsEnabled: gate.config.adaptiveDynamicsEnabled,
    whisperHighPassCutoffHz: VAD_WHISPER_HPF_CUTOFF_HZ,
    whisperHighBandRatioDb: gate.effectiveWhisperHighBandRatioDb,
    whisperModulationSpreadDb: gate.config.whisperModulationSpreadDb,
    whisperContextMs: gate.config.whisperContextMs,
    gapSpeechPeakAboveFloorDb: GAP_SPEECH_PEAK_ABOVE_FLOOR_DB,
    idleGapMinSeconds: IDLE_GAP_TELEMETRY_MIN_SECONDS,
    idleGapPeakAboveFloorDb: IDLE_GAP_TELEMETRY_PEAK_ABOVE_FLOOR_DB,
    idleGapEvidenceAboveFloorDb: IDLE_GAP_TELEMETRY_EVIDENCE_ABOVE_FLOOR_DB,
    staleFloorSeconds: gate.effectiveStaleFloorSeconds,
    fallTauSeconds: gate.effectiveFallTauSeconds,
    riseMultiplier: gate.effectiveRiseSpeedMultiplier,
    endpointMachineEnabled: harness.endpointMachineEnabled,
    endpointOnsetMs: endpoint.onsetSamples / 16,
    endpointEndEvidenceMs: endpoint.endEvidenceSamples / 16,
    endpointSilenceMs: endpoint.endpointSilenceSamples / 16,
    endpointResumeMs: endpoint.resumeSamples / 16,
    endpointAmbiguousRescueMs: endpoint.ambiguousRescueSamples / 16,
    utteranceRelativeResetEnabled: harness.utteranceRelativeResetEnabled,
    utteranceResetMarginDb: harness.utteranceResetMarginDb,
    utteranceEstablishMs: harness.utteranceEstablishSamples / 16,
    utteranceLevelDescentDbPerSec: harness.utteranceLevelDescentDbPerSec,
    utteranceLevelDescentCapDb: harness.utteranceLevelDescentCapDb,
    utteranceLevelRaiseSustainMs: harness.utteranceLevelRaiseSustainSamples / 16,
    ambiguousDecayGraceMs: endpoint.ambiguousDecayGraceMs,
    ambiguousDecayRate: endpoint.ambiguousDecayRate,
    endpointPreRollMs: endpoint.preRollSamples / 16,
    sessionHeadBufferMs: harness.headBufferSamples / 16,
    silenceMs: harness.silenceThresholdSamples / 16,
    minSpeechMs: harness.minSpeechSamples / 16,
    minChunkMs: harness.minChunkSamples / 16,
    maxNoiseSec: harness.maxNoiseSamples / 16000,
    maxChunkMs: 0,
    splitSearchWindowMs: 0,
    minSilenceAtSplitMs: 0,
    postRollMs: harness.postRollSamples / 16,
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
    latchAmbiguousGraceMs: harness.latchAmbiguousGraceMs,
    dynamicsWitnessDb: harness.dynamicsWitnessDb,
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
    quietRiseCapAppliesToAmbiguous: harness.quietRiseCapAppliesToAmbiguous,
    quietRiseCapWitnessDb: harness.quietRiseCapWitnessDb,
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
  utteranceRelativeResetEnabled = true,
  recorderConfig = {},
  gateConfig = {},
  onFrame,
  onEvent,
  onSlowOnsetDiagnostic,
} = {}) {
  const recorderFrameDuration = frameMs / 1000;
  const featureEnabled = Boolean(utteranceRelativeResetEnabled && endpointMachineEnabled);
  const utteranceEstablishSamples = clampInteger(
    recorderConfig.utteranceEstablishMs,
    500,
    250,
    2_000,
  ) * 16;
  // Keep direct harness callers consistent with the replay config's effective dwell.
  const utteranceLevelRaiseSustainSamples = Math.min(
    clampInteger(recorderConfig.utteranceLevelRaiseSustainMs, 300, 100, 1_000) * 16,
    utteranceEstablishSamples,
  );
  const endpoint = makeEndpoint(endpointSilenceMs, {
    ...endpointConfig,
    ambiguousDecayEnabled: featureEnabled,
  });
  const gate = makeGate(gateConfig);
  const harness = {
    gate,
    endpoint,
    endpointMachineEnabled,
    utteranceRelativeResetEnabled: featureEnabled,
    utteranceResetMarginDb: clampFinite(recorderConfig.utteranceResetMarginDb, 12, 6, 24),
    utteranceEstablishSamples,
    utteranceLevelDescentDbPerSec: clampFinite(
      recorderConfig.utteranceLevelDescentDbPerSec,
      1,
      0,
      3,
    ),
    utteranceLevelDescentCapDb: clampFinite(
      recorderConfig.utteranceLevelDescentCapDb,
      8,
      0,
      24,
    ),
    utteranceLevelRaiseSustainSamples,
    utteranceLevelReferenceDb: null,
    utteranceLevelMaximumDb: null,
    utteranceEstablishEvidenceSamples: 0,
    utteranceEstablishmentWindowSamples: 0,
    utteranceEstablishmentLevels: [],
    utteranceReferenceEstablished: false,
    utteranceLevelRaiseEvidenceSamples: 0,
    utteranceLevelRaiseCandidateMaxDb: null,
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
    latchAmbiguousGraceMs: Math.max(0, recorderConfig.latchAmbiguousGraceMs ?? 0),
    dynamicsWitnessDb: recorderConfig.dynamicsWitnessDb ?? gate.effectiveDynamicsSpreadDb,
    latchAmbiguousGraceElapsedMs: 0,
    latchAmbiguousGraceExpired: false,
    lastLatchDynamicsWitnessTime: null,
    quietLatchMs: recorderConfig.quietLatchMs ?? 1000,
    quietLatchWitnessDb: recorderConfig.quietLatchWitnessDb ?? 3,
    quietLatchWitnessEnabled: recorderConfig.quietLatchWitnessEnabled ?? false,
    quietLatchDutyCycle: recorderConfig.quietLatchDutyCycle ?? 1,
    quietLatchAmbiguousEnabled: recorderConfig.quietLatchAmbiguousEnabled ?? false,
    slowOnsetEnabled: recorderConfig.slowOnsetEnabled ?? false,
    slowOnsetDeltaDb: recorderConfig.slowOnsetDeltaDb ?? 6,
    slowOnsetEvidenceMs: recorderConfig.slowOnsetEvidenceMs ?? 400,
    slowOnsetWindowSeconds: recorderConfig.slowOnsetWindowSeconds ?? 1.5,
    quietRiseCapAppliesToAmbiguous: recorderConfig.quietRiseCapAppliesToAmbiguous ?? false,
    quietRiseCapWitnessDb: recorderConfig.quietRiseCapWitnessDb ?? 3,
    loudFlatTerminateEnabled: recorderConfig.loudFlatTerminateEnabled ?? false,
    loudFlatSpreadDb: recorderConfig.loudFlatSpreadDb ?? 2.5,
    loudFlatTerminateSeconds: recorderConfig.loudFlatTerminateSeconds ?? 3,
    flatFrameStreakMs: 0,
    flatFrameStreakStartTime: null,
    flatTerminatorActive: false,
    terminatorActivationCount: 0,
    latchMissingDynamicsWitnessCount: 0,
    maxNoiseSamples,
    spillThresholdSamples: recorderConfig.spillThresholdSamples ?? 1_048_576,
    spilledSampleCount: 0,
    spillOccurred: false,
    postRollSamples: recorderConfig.postRollSamples ?? VAD_POST_ROLL_SAMPLES,
    contiguousTrailingSilenceSamples: 0,
    contiguousTrailingSilenceMinimumDb: null,
    contiguousTrailingSilencePeakAboveFloorDb: null,
    postFinalizeSoftLatchSuppressionSamplesRemaining: 0,
    chunkCount: 0,
    emittedSampleCount: 0,
    nextChunkId: 0,
    idleGapRunSamples: 0,
    idleGapStartSessionSamples: null,
    idleGapEndSessionSamples: null,
    idleGapPeakLevelDb: null,
    idleGapFloorDbAtPeak: null,
    idleGapStrongThresholdDbAtPeak: null,
    idleGapContinuationThresholdDbAtPeak: null,
    idleGapEvidenceAboveFloor5Samples: 0,
    frameSequence: 0,
    reanchorEventCount: 0,
    utteranceQuietestStrongDb: null,
    accumulatorSamples: 0,
    accumulatorPeakAboveFloorDb: null,
    accumulatorHasSpeechEvidence: false,
    chunkStartSessionSamples: null,
    chunkEndSessionSamples: null,
    retainedGapSamples: 0,
    retainedGapStartSessionSamples: null,
    retainedGapEvidenceSamples: 0,
    retainedGapPeakAboveFloorDb: null,
    retentionShedCount: 0,
    shedSampleCount: 0,
    tailFloorSampleCount: 0,
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
    previousProcessedFrameDb: null,
    sustainedContinuingMs: 0,
    streakStartFloorDb: null,
    streakPeakDb: null,
    sustainedContinuingOnsetLatched: false,
    streakSawDynamics: false,
    quietLatchRisingEdgeAtSessionSamples: null,
    latchWitnessRejectionCounted: false,
    quietLatchHistory: [],
    slowOnsetHistory: [],
    slowOnsetTriggerTime: null,
    quietLatchCandidateStartTime: null,
    quietLatchStartFloorDb: null,
    quietLatchCoverageMs: 0,
    sawReanchorDuringUtterance: false,
    primingComplete: gate.snapshot.floorDb === null,
    sessionConfig: null,

    emitEvent(event) {
      if (typeof onEvent === 'function') onEvent(event);
    },

    resetAfterRouteChange() {
      this.gate.resetFloorAfterRouteChange();
      this.resetUtteranceLevelReference();
      this.primingComplete = this.gate.snapshot.floorDb === null;
      this.contiguousTrailingSilenceSamples = 0;
      this.contiguousTrailingSilenceMinimumDb = null;
      this.contiguousTrailingSilencePeakAboveFloorDb = null;
      this.postFinalizeSoftLatchSuppressionSamplesRemaining = 0;
      this.previousProcessedFrameDb = null;
      this.quietLatchRisingEdgeAtSessionSamples = null;
      this.quietLatchRisingEdgeSeen = false;
    },

    resetUtteranceLevelReference() {
      this.utteranceLevelReferenceDb = null;
      this.utteranceLevelMaximumDb = null;
      this.utteranceEstablishEvidenceSamples = 0;
      this.utteranceEstablishmentWindowSamples = 0;
      this.utteranceEstablishmentLevels.length = 0;
      this.utteranceReferenceEstablished = false;
      this.utteranceLevelRaiseEvidenceSamples = 0;
      this.utteranceLevelRaiseCandidateMaxDb = null;
    },

    qualifyEndpointEvidence(
      evidence,
      classifiedEvidence,
      frameDb,
      frameSamples,
      frameDuration,
      previousState,
    ) {
      if (!this.utteranceRelativeResetEnabled) return { evidence, state: 'disabled' };

      // Keep gate-classified duration separate from endpoint remaps.
      let qualifiedEvidence = evidence;
      let qualificationState = this.utteranceReferenceEstablished ? 'established' : 'establishing';
      if ((evidence === 'strong' || evidence === 'continuing')
        && this.utteranceReferenceEstablished
        && this.utteranceLevelReferenceDb - frameDb > this.utteranceResetMarginDb) {
        qualifiedEvidence = 'ambiguous';
        qualificationState = 'stripped';
      }

      if (classifiedEvidence !== 'strong' && classifiedEvidence !== 'continuing') {
        this.utteranceLevelRaiseEvidenceSamples = 0;
        this.utteranceLevelRaiseCandidateMaxDb = null;
      }
      this.updateUtteranceLevelReference(
        classifiedEvidence,
        evidence,
        frameDb,
        frameSamples,
        frameDuration,
        previousState,
      );
      if (qualificationState !== 'stripped') {
        qualificationState = this.utteranceReferenceEstablished ? 'established' : 'establishing';
      }
      return { evidence: qualifiedEvidence, state: qualificationState };
    },

    updateUtteranceLevelReference(
      classifiedEvidence,
      endpointEvidence,
      frameDb,
      frameSamples,
      frameDuration,
      previousState,
    ) {
      if (classifiedEvidence !== 'strong' && classifiedEvidence !== 'continuing') return;

      if (!this.utteranceReferenceEstablished) {
        if (previousState === 'idle' && endpointEvidence !== 'strong') return;
        const windowSamplesToAdd = this.utteranceEstablishEvidenceSamples
          < this.utteranceEstablishSamples
          ? Math.min(
            frameSamples,
            this.utteranceEstablishSamples - this.utteranceEstablishEvidenceSamples,
          )
          : frameSamples;
        this.utteranceEstablishEvidenceSamples += frameSamples;
        if (windowSamplesToAdd > 0) {
          this.utteranceEstablishmentLevels.push({
            frameDb,
            samples: windowSamplesToAdd,
          });
          this.utteranceEstablishmentWindowSamples += windowSamplesToAdd;
          this.trimUtteranceEstablishmentWindow();
        }
        if (this.utteranceEstablishEvidenceSamples < this.utteranceEstablishSamples) return;
        const sustainedLevelDb = this.sustainedEstablishmentLevelDb();
        if (sustainedLevelDb === null) return;
        this.utteranceLevelMaximumDb = sustainedLevelDb;
        this.utteranceLevelReferenceDb = sustainedLevelDb;
        this.utteranceReferenceEstablished = true;
        this.utteranceEstablishmentWindowSamples = 0;
        this.utteranceEstablishmentLevels.length = 0;
        this.utteranceLevelRaiseEvidenceSamples = 0;
        this.utteranceLevelRaiseCandidateMaxDb = null;
        return;
      }

      const previousReferenceDb = this.utteranceLevelReferenceDb;
      // Only establishment and sustained raises can move the descent floor.
      const minimumReferenceDb = this.utteranceLevelMaximumDb - this.utteranceLevelDescentCapDb;
      const descendedReferenceDb = Math.max(
        minimumReferenceDb,
        previousReferenceDb - this.utteranceLevelDescentDbPerSec * frameDuration,
      );
      this.utteranceLevelReferenceDb = descendedReferenceDb;
      if (frameDb <= previousReferenceDb) {
        this.utteranceLevelRaiseEvidenceSamples = 0;
        this.utteranceLevelRaiseCandidateMaxDb = null;
        return;
      }

      this.utteranceLevelRaiseEvidenceSamples += frameSamples;
      this.utteranceLevelRaiseCandidateMaxDb = Math.max(
        this.utteranceLevelRaiseCandidateMaxDb ?? frameDb,
        frameDb,
      );
      if (this.utteranceLevelRaiseEvidenceSamples < this.utteranceLevelRaiseSustainSamples) return;

      const raisedReferenceDb = this.utteranceLevelRaiseCandidateMaxDb;
      this.utteranceLevelMaximumDb = Math.max(this.utteranceLevelMaximumDb, raisedReferenceDb);
      this.utteranceLevelReferenceDb = Math.max(descendedReferenceDb, raisedReferenceDb);
      this.utteranceLevelRaiseEvidenceSamples = 0;
      this.utteranceLevelRaiseCandidateMaxDb = null;
    },

    trimUtteranceEstablishmentWindow() {
      while (this.utteranceEstablishmentWindowSamples > this.utteranceEstablishSamples
        && this.utteranceEstablishmentLevels.length > 0) {
        const firstSample = this.utteranceEstablishmentLevels[0];
        const excessSamples = this.utteranceEstablishmentWindowSamples
          - this.utteranceEstablishSamples;
        if (firstSample.samples <= excessSamples) {
          this.utteranceEstablishmentWindowSamples -= firstSample.samples;
          this.utteranceEstablishmentLevels.shift();
        } else {
          firstSample.samples -= excessSamples;
          this.utteranceEstablishmentWindowSamples -= excessSamples;
        }
      }
    },

    sustainedEstablishmentLevelDb() {
      let classifiedSamples = 0;
      // A startup crest with less than the raise dwell cannot define the seed.
      const strongestLevels = [...this.utteranceEstablishmentLevels]
        .sort((left, right) => right.frameDb - left.frameDb);
      for (const sample of strongestLevels) {
        classifiedSamples += sample.samples;
        if (classifiedSamples >= this.utteranceLevelRaiseSustainSamples) {
          return sample.frameDb;
        }
      }
      return null;
    },

    recordFrame(
      output,
      previousState,
      decision,
      decisionSilenceSamples,
      frameDb,
      frameDuration,
      qualificationState,
      physicalTrailingSilenceSamples,
    ) {
      const record = {
        t: 'f',
        q: this.frameSequence,
        sourceStartSample: this.sessionElapsedSamples - Math.round(frameDuration * 16000),
        sourceEndSample: this.sessionElapsedSamples,
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
        uq: qualificationState,
        ar: this.endpoint.lastDecisionAmbiguousRunSamples
          ?? this.endpoint.ambiguousRunSamples,
        ac: this.endpoint.lastDecisionAmbiguousFrameCreditSamples
          ?? this.endpoint.lastFrameAmbiguousCreditSamples,
        wc: this.endpoint.lastDecisionAmbiguousCreditSamples
          ?? this.endpoint.accumulatedAmbiguousCreditSamples,
        ts: physicalTrailingSilenceSamples,
      };
      copyOptional(record, 'fl', output.floorDb);
      copyOptional(record, 'ur', this.utteranceLevelReferenceDb);
      record.fc = output.floorConverged;
      copyOptional(record, 'dy', output.dynamicsSpreadDb);
      record.sh = output.speechShaped;
      copyOptional(record, 'sdy', output.shortSpreadDb);
      copyOptional(record, 'hbr', output.highBandRatioDb);
      if (output.isLoudRegime) record.lr = true;
      this.frameSequence += 1;
      if (typeof onFrame === 'function') onFrame(record);
      return record;
    },

    seedChunkFromPreRoll(frameSamples, output, softOnset = false) {
      if (this.retainedGapSamples > 0) {
        const retainedGapSamples = this.retainedGapSamples;
        this.moveRetainedGapToAccumulator();
        this.headPrependedAtOnset = retainedGapSamples;
        this.postHeadPreRollSamples = 0;
        return true;
      }
      if (this.accumulatorSamples > 0) return false;

      if (this.headLive) {
        const trimmedSamples = this.headTrimSamples();
        this.accumulatorSamples = this.headSamples - trimmedSamples;
        this.headPrependedAtOnset = this.accumulatorSamples;
        this.chunkStartSessionSamples = this.sessionElapsedSamples
          - this.headSamples + trimmedSamples;
        this.chunkEndSessionSamples = this.sessionElapsedSamples;
      } else {
        let requestedPreRollMs = output.isLoudRegime
          ? Math.max(this.endpoint.configuration.preRollSamples / 16, this.loudPreRollMs)
          : this.endpoint.configuration.preRollSamples / 16;
        if (softOnset && this.softOnsetPreRollEnabled) {
          requestedPreRollMs = Math.max(requestedPreRollMs, this.softOnsetPreRollMs);
        }
        const requestedPreRollSamples = Math.round(requestedPreRollMs * 16);
        const preRollSamples = Math.min(requestedPreRollSamples, this.postHeadPreRollSamples);
        this.accumulatorSamples = preRollSamples;
        this.chunkStartSessionSamples = this.sessionElapsedSamples - frameSamples - preRollSamples;
        this.chunkEndSessionSamples = this.sessionElapsedSamples;
        this.postHeadPreRollSamples = 0;
      }
      return false;
    },

    appendRetainedGap(frameSamples, frameStartSamples, evidence, frameDb, floorDb) {
      if (this.retainedGapSamples === 0) {
        this.retainedGapStartSessionSamples = frameStartSamples;
      }
      this.retainedGapSamples += frameSamples;
      if (floorDb !== null && floorDb !== undefined) {
        const peakAboveFloorDb = frameDb - floorDb;
        if (this.retainedGapPeakAboveFloorDb === null
          || peakAboveFloorDb > this.retainedGapPeakAboveFloorDb) {
          this.retainedGapPeakAboveFloorDb = peakAboveFloorDb;
        }
      }
      if (evidence === 'strong' || evidence === 'continuing') {
        this.retainedGapEvidenceSamples += frameSamples;
      }
    },

    moveRetainedGapToAccumulator() {
      if (this.retainedGapSamples === 0) return false;
      if (this.accumulatorSamples === 0) {
        this.chunkStartSessionSamples = this.retainedGapStartSessionSamples;
      }
      this.accumulatorHasSpeechEvidence ||= this.retainedGapEvidenceSamples > 0;
      this.chunkEndSessionSamples = this.retainedGapStartSessionSamples + this.retainedGapSamples;
      this.accumulatorSamples += this.retainedGapSamples;
      this.clearRetainedGap();
      return true;
    },

    clearRetainedGap() {
      this.retainedGapSamples = 0;
      this.retainedGapStartSessionSamples = null;
      this.retainedGapEvidenceSamples = 0;
      this.retainedGapPeakAboveFloorDb = null;
    },

    retainedGapHasSpeechEvidence() {
      if (this.retainedGapEvidenceSamples > 0) return true;
      if (this.retainedGapPeakAboveFloorDb !== null
        && this.retainedGapPeakAboveFloorDb >= GAP_SPEECH_PEAK_ABOVE_FLOOR_DB) return true;
      return this.accumulatorHasSpeechEvidence;
    },

    accumulatorHasPlausibleSpeech() {
      if (this.accumulatorHasSpeechEvidence) return true;
      return this.accumulatorPeakAboveFloorDb !== null
        && this.accumulatorPeakAboveFloorDb >= GAP_SPEECH_PEAK_ABOVE_FLOOR_DB;
    },

    trackAccumulatorSpeechEvidence(output, frameDb) {
      this.accumulatorHasSpeechEvidence ||= output.evidence === 'strong'
        || output.evidence === 'continuing'
        || output.speechShaped;
      if (output.floorDb !== null && output.floorDb !== undefined) {
        const peakAboveFloorDb = frameDb - output.floorDb;
        if (this.accumulatorPeakAboveFloorDb === null
          || peakAboveFloorDb > this.accumulatorPeakAboveFloorDb) {
          this.accumulatorPeakAboveFloorDb = peakAboveFloorDb;
        }
      }
    },

    shedRetainedGap() {
      const sampleCount = this.retainedGapSamples;
      this.retentionShedCount += 1;
      this.shedSampleCount += sampleCount;
      this.emitEvent({
        t: 'ev',
        k: 'discard',
        n: sampleCount,
        r: 'noise_guard',
        timestampMs: this.sessionElapsedSamples / 16,
        sourceStartSample: this.retainedGapStartSessionSamples,
        sourceEndSample: this.retainedGapStartSessionSamples + sampleCount,
      });
      this.clearRetainedGap();
      this.headSamples = 0;
      this.headSlices.length = 0;
      this.postHeadPreRollSamples = 0;
      if (this.accumulatorSamples === 0) {
        this.chunkStartSessionSamples = null;
        this.chunkEndSessionSamples = null;
        this.accumulatorPeakAboveFloorDb = null;
        this.accumulatorHasSpeechEvidence = false;
        this.speechSamples = 0;
        this.silenceSamples = 0;
        this.contiguousTrailingSilenceSamples = 0;
        this.contiguousTrailingSilenceMinimumDb = null;
        this.contiguousTrailingSilencePeakAboveFloorDb = null;
      }
    },

    manageRetainedGapOverflow() {
      if (this.retainedGapSamples <= this.maxNoiseSamples
        || (this.endpoint.state !== 'idle' && this.endpoint.state !== 'onsetPending')) {
        return;
      }
      if (!this.retainedGapHasSpeechEvidence()) {
        this.shedRetainedGap();
      } else {
        this.moveRetainedGapToAccumulator();
      }
    },

    drive(frameDb, frameDuration = recorderFrameDuration, { highBandRatioDb = null } = {}) {
      const frameSamples = Math.round(frameDuration * 16000);
      const frameStartSamples = this.sessionElapsedSamples;
      const previousState = this.endpoint.state;
      const previousFrameDb = this.previousProcessedFrameDb;
      const previousGateEvidence = this.gate.snapshot.evidence;
      const adjacentStepDb = previousFrameDb === null
        ? null
        : Math.abs(frameDb - previousFrameDb);
      this.previousProcessedFrameDb = frameDb;
      const hasRisingEdgeWitness = previousFrameDb !== null
        && frameDb - previousFrameDb >= this.gate.effectiveFlatSpreadDb;
      this.sessionElapsedSamples += frameSamples;
      this.slowOnsetTriggerTime = null;
      const primingWasComplete = this.primingComplete;
      const output = this.gate.process(frameDb, frameDuration, {
        highBandRatioDb,
        withinUtteranceContext: previousState === 'speechActive' || previousState === 'endPending',
      });
      const completedPrimingNow = output.didCompletePriming;
      this.primingComplete ||= completedPrimingNow;
      if (completedPrimingNow) {
        this.emitEvent({
          t: 'ev',
          k: 'priming_complete',
          r: output.primingEndedAtCap ? 'duration_cap' : 'quiet_floor_seed',
          tm: output.primingDurationSeconds * 1000,
        });
      }
      if (!primingWasComplete && !this.headLive) {
        this.postHeadPreRollSamples = Math.min(
          this.endpoint.configuration.preRollSamples,
          this.postHeadPreRollSamples + frameSamples,
        );
      }
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
      const endpointWasIdle = previousState === 'idle';
      const frameWasInRetainedGap = this.endpointMachineEnabled
        && (previousState === 'idle' || previousState === 'onsetPending');
      // Cool off only fallback promotion; raw strong evidence still reaches the endpoint.
      const suppressPostFinalizeSoftLatch = this.postFinalizeSoftLatchSuppressionSamplesRemaining > 0;
      if (suppressPostFinalizeSoftLatch) {
        this.postFinalizeSoftLatchSuppressionSamplesRemaining = Math.max(
          0,
          this.postFinalizeSoftLatchSuppressionSamplesRemaining - frameSamples,
        );
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
        this.quietLatchRisingEdgeAtSessionSamples = null;
        this.quietLatchRisingEdgeSeen = false;
        this.sustainedContinuingOnsetLatched = false;
        this.latchAmbiguousGraceElapsedMs = 0;
        this.latchAmbiguousGraceExpired = false;
        this.lastLatchDynamicsWitnessTime = null;
      }
      const slowEvidenceBeforeMs = this.slowOnsetHistory.reduce(
        (total, frame) => total + frame.end - frame.start,
        0,
      ) * 1000;
      const slowThresholdFloorTermDb = output.floorDb === null
        ? null
        : output.floorDb + this.slowOnsetDeltaDb;
      const slowThresholdGuardDb = this.gate.effectiveAbsoluteSpeechFloorDb;
      const slowThresholdDb = output.floorDb === null
        ? null
        : calculateSlowOnsetThreshold(
          output.floorDb,
          this.slowOnsetDeltaDb,
          slowThresholdGuardDb,
        );
      const slowOnsetQualifies = this.slowOnsetEnabled
        && this.endpointMachineEnabled
        && this.primingComplete
        && endpointWasIdle
        && output.floorDb !== null
        && frameDb >= slowThresholdDb;
      if (reanchorEvent) this.reanchorEventCount += 1;

      if (reanchorEvent
        && (previousState === 'speechActive' || previousState === 'endPending')) {
        this.sawReanchorDuringUtterance = true;
      }

      const adaptivePath = output.floorDb !== null;
      const quietWitnessMode = this.quietLatchWitnessEnabled && !output.isLoudRegime;
      if (this.quietLatchWitnessEnabled && !quietWitnessMode) this.resetQuietLatchWindow();
      const frameTime = this.sessionElapsedSamples / 16000;
      if (endpointWasIdle
        && output.floorConverged
        && output.dynamicsSpreadDb !== null
        && output.dynamicsSpreadDb >= this.dynamicsWitnessDb) {
        this.lastLatchDynamicsWitnessTime = frameTime;
      }
      if (suppressPostFinalizeSoftLatch) this.lastLatchDynamicsWitnessTime = null;
      const hasRecentDynamicsWitness = this.lastLatchDynamicsWitnessTime !== null
        && (frameTime - this.lastLatchDynamicsWitnessTime) * 1000 <= 500;
      const ambiguousEvidence = output.evidence === 'ambiguous';
      const legacyAmbiguousStreak = this.loudLatchAmbiguousEnabled && ambiguousEvidence;
      const ambiguousGraceStreak = ambiguousEvidence
        && this.latchAmbiguousGraceMs > 0
        && output.floorConverged
        && hasRecentDynamicsWitness
        && !this.latchAmbiguousGraceExpired
        && this.latchAmbiguousGraceElapsedMs + frameDuration * 1000
          <= this.latchAmbiguousGraceMs;
      const ambiguousGraceFrame = ambiguousGraceStreak && !legacyAmbiguousStreak;
      const eligibleStreak = !suppressPostFinalizeSoftLatch
        && (output.evidence === 'continuing'
          || legacyAmbiguousStreak
          || ambiguousGraceStreak);
      if (suppressPostFinalizeSoftLatch
        || !endpointWasIdle
        || !adaptivePath
        || output.evidence === 'silence') {
        this.quietLatchRisingEdgeAtSessionSamples = null;
        this.quietLatchRisingEdgeSeen = false;
      } else if (hasRisingEdgeWitness) {
        this.quietLatchRisingEdgeAtSessionSamples = this.sessionElapsedSamples;
      }
      const quietWitnessEvidenceEligible = output.evidence === 'continuing'
        || (this.quietLatchAmbiguousEnabled && ambiguousEvidence);
      const quietLatchStreakEligible = quietWitnessMode
        ? quietWitnessEvidenceEligible
        : eligibleStreak;
      if (quietLatchStreakEligible && endpointWasIdle) {
        const startsQuietLatchStreak = quietWitnessMode
          ? this.quietLatchCandidateStartTime === null
          : this.sustainedContinuingMs === 0;
        const hadImmediateRisingEdge = this.quietLatchRisingEdgeAtSessionSamples === frameStartSamples;
        if (startsQuietLatchStreak) {
          this.quietLatchRisingEdgeSeen = hasRisingEdgeWitness || hadImmediateRisingEdge;
          this.quietLatchRisingEdgeAtSessionSamples = null;
        } else if (hasRisingEdgeWitness) {
          this.quietLatchRisingEdgeSeen = true;
          this.quietLatchRisingEdgeAtSessionSamples = null;
        }
      } else if (!quietWitnessMode && !this.sustainedContinuingOnsetLatched) {
        this.quietLatchRisingEdgeSeen = false;
      }
      if (output.evidence === 'continuing') {
        this.latchAmbiguousGraceElapsedMs = 0;
        this.latchAmbiguousGraceExpired = false;
      } else if (ambiguousEvidence && this.latchAmbiguousGraceMs > 0
        && !legacyAmbiguousStreak) {
        if (ambiguousGraceFrame) {
          this.latchAmbiguousGraceElapsedMs += frameDuration * 1000;
        } else if (this.sustainedContinuingMs > 0 || this.streakStartFloorDb !== null) {
          this.latchAmbiguousGraceElapsedMs = 0;
          this.latchAmbiguousGraceExpired = true;
        } else {
          this.latchAmbiguousGraceElapsedMs = 0;
        }
      } else if (!ambiguousEvidence) {
        this.latchAmbiguousGraceElapsedMs = 0;
        this.latchAmbiguousGraceExpired = false;
      }
      if (suppressPostFinalizeSoftLatch) {
        this.latchAmbiguousGraceElapsedMs = 0;
        this.latchAmbiguousGraceExpired = false;
      }
      if (quietWitnessMode) {
        if (suppressPostFinalizeSoftLatch) this.resetQuietLatchWindow();
        else this.updateQuietWitnessStreak(output, frameDb, frameDuration, endpointWasIdle);
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
        && output.floorDb <= this.streakStartFloorDb;
      const quietLatchQualified = quietWitnessMode
        && this.quietLatchRisingEdgeSeen
        && this.quietLatchStreakQualified(
          output,
          quietRegimeEvidence,
          quietRegimeFloorStable,
        );
      const loudLatchQualified = output.isLoudRegime
        && this.sustainedContinuingMs >= this.loudLatchMs
        && this.streakSawDynamics;
      const latchAcceptsAmbiguous = legacyAmbiguousStreak || ambiguousGraceStreak;
      const latchEligibleEvidence = !suppressPostFinalizeSoftLatch
        && (output.evidence === 'continuing'
          || (ambiguousEvidence && latchAcceptsAmbiguous));
      if (adaptivePath
        && output.floorConverged
        && latchEligibleEvidence
        && endpointWasIdle
        && (quietLatchQualified || loudLatchQualified)) {
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
          || (ambiguousEvidence && !latchAcceptsAmbiguous)
          || output.evidence === 'silence')) {
        this.sustainedContinuingOnsetLatched = false;
        this.sustainedContinuingMs = 0;
        this.streakStartFloorDb = null;
        this.streakPeakDb = null;
        this.streakSawDynamics = false;
        this.quietLatchRisingEdgeAtSessionSamples = null;
        this.quietLatchRisingEdgeSeen = false;
      }
      const latchedContinuingOnset = this.sustainedContinuingOnsetLatched
        && latchEligibleEvidence
        && endpointInOnsetLimb;
      let endpointEvidence = adaptivePath
        && latchedContinuingOnset
        ? 'strong'
        : output.evidence;
      const slowOnsetTriggered = this.updateSlowOnsetEvidence(
        frameDb,
        output.floorDb,
        frameDuration,
      );
      const slowEvidenceAfterMs = this.slowOnsetHistory.reduce(
        (total, frame) => total + frame.end - frame.start,
        0,
      ) * 1000;
      const slowOnsetAccumulatorBeforeMs = this.accumulatorSamples / 16;
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
        if (this.flatTerminatorActive
          && (previousState !== 'endPending' || output.evidence !== 'strong')) {
          endpointEvidence = 'silence';
        }
      } else {
        this.flatFrameStreakMs = 0;
        this.flatFrameStreakStartTime = null;
        this.flatTerminatorActive = false;
      }
      // Keep gate/floor evidence level-based; shape only controls the endpoint silence clock.
      if (output.speechShaped && endpointEvidence === 'silence') {
        endpointEvidence = 'continuing';
      }
      endpointEvidence = classifyEndPendingEvidence({
        endpointState: previousState,
        evidence: endpointEvidence,
        previousEvidence: previousGateEvidence,
        speechShaped: output.speechShaped,
        shortSpreadDb: output.shortSpreadDb,
        dynamicsSpreadDb: output.dynamicsSpreadDb,
        adjacentStepDb,
        flatSpreadDb: this.gate.effectiveFlatSpreadDb,
        accumulatedSilenceSamples: this.endpoint.accumulatedSilenceSamples,
        endpointSilenceSamples: this.endpoint.configuration.endpointSilenceSamples,
        ambiguousRescueSamples: this.endpoint.configuration.ambiguousRescueSamples,
        rescueAwareWindowsEnabled:
          this.endpoint.configuration.resumeToEndpointSilenceRatio !== undefined
          || this.endpoint.configuration.ambiguousRescueToEndpointSilenceRatio !== undefined,
        frameDuration,
      });
      let qualificationState = this.utteranceRelativeResetEnabled ? 'establishing' : 'disabled';
      if (this.endpointMachineEnabled) {
        const qualification = this.qualifyEndpointEvidence(
          endpointEvidence,
          output.evidence,
          frameDb,
          frameSamples,
          frameDuration,
          previousState,
        );
        endpointEvidence = qualification.evidence;
        qualificationState = qualification.state;
      }
      if (output.isSpeech) this.speechSamples += frameSamples;
      if (this.endpointMachineEnabled) {
        const isTrailingSilence = endpointEvidence === 'silence';
        this.contiguousTrailingSilenceSamples = isTrailingSilence
          ? this.contiguousTrailingSilenceSamples + frameSamples
          : 0;
        this.contiguousTrailingSilenceMinimumDb = isTrailingSilence
          ? Math.min(this.contiguousTrailingSilenceMinimumDb ?? frameDb, frameDb)
          : null;
        if (isTrailingSilence) {
          if (output.floorDb !== null && output.floorDb !== undefined) {
            const peakAboveFloorDb = frameDb - output.floorDb;
            if (this.contiguousTrailingSilencePeakAboveFloorDb === null
              || peakAboveFloorDb > this.contiguousTrailingSilencePeakAboveFloorDb) {
              this.contiguousTrailingSilencePeakAboveFloorDb = peakAboveFloorDb;
            }
          }
        } else {
          this.contiguousTrailingSilencePeakAboveFloorDb = null;
        }
      } else {
        const isTrailingSilence = !output.isSpeech;
        this.contiguousTrailingSilenceSamples = isTrailingSilence
          ? this.contiguousTrailingSilenceSamples + frameSamples
          : 0;
        this.contiguousTrailingSilenceMinimumDb = isTrailingSilence
          ? Math.min(this.contiguousTrailingSilenceMinimumDb ?? frameDb, frameDb)
          : null;
        if (isTrailingSilence) {
          if (output.floorDb !== null && output.floorDb !== undefined) {
            const peakAboveFloorDb = frameDb - output.floorDb;
            if (this.contiguousTrailingSilencePeakAboveFloorDb === null
              || peakAboveFloorDb > this.contiguousTrailingSilencePeakAboveFloorDb) {
              this.contiguousTrailingSilencePeakAboveFloorDb = peakAboveFloorDb;
            }
          }
        } else {
          this.contiguousTrailingSilencePeakAboveFloorDb = null;
        }
      }

      let decision = { type: 'none' };
      let discarded = false;
      let decisionSilenceSamples = this.silenceSamples;
      let decisionAmbiguousCreditSamples = 0;
      if (this.endpointMachineEnabled) {
        const silenceBeforeDecision = this.endpoint.accumulatedSilenceSamples;
        if (slowOnsetTriggered) {
          const remainingOnsetSamples = Math.max(
            0,
            this.endpoint.configuration.onsetSamples - this.endpoint.onsetEvidenceSamples,
          );
          decision = this.endpoint.process('strong', remainingOnsetSamples);
          this.emitEvent({
            t: 'ev',
            k: 'slow_onset',
            n: Math.round(this.slowOnsetEvidenceMs * 16),
            r: 'cumulative_level',
            time: this.slowOnsetTriggerTime,
          });
        } else {
          decision = this.endpoint.process(endpointEvidence, frameSamples);
        }
        if (this.flatTerminatorActive && this.endpoint.state === 'idle') {
          this.flatFrameStreakMs = 0;
          this.flatFrameStreakStartTime = null;
          this.flatTerminatorActive = false;
        }
        if (decision.type === 'finalizeUtterance') {
          decisionSilenceSamples = this.endpoint.lastDecisionSilenceSamples
            ?? silenceBeforeDecision + (endpointEvidence === 'silence' ? frameSamples : 0);
          decisionAmbiguousCreditSamples = this.endpoint.lastDecisionAmbiguousCreditSamples ?? 0;
        } else {
          decisionSilenceSamples = this.endpoint.accumulatedSilenceSamples;
        }
        if (frameWasInRetainedGap) {
          this.appendRetainedGap(
            frameSamples,
            frameStartSamples,
            output.isSpeech || output.speechShaped ? 'continuing' : output.evidence,
            frameDb,
            output.floorDb,
          );
          this.manageRetainedGapOverflow();
        }
        // Prevent the adaptive floor from chasing evidence held for a slow onset.
        this.gate.updateFloorTracking(
          frameDb,
          frameDuration,
          previousState === 'idle'
            && this.endpoint.state === 'idle'
            && this.slowOnsetHistory.length === 0,
          previousState === 'endPending' || this.endpoint.state === 'endPending',
          this.quietRiseCapAppliesToAmbiguous,
          this.quietRiseCapWitnessDb,
        );

        const synthesizedStartNow = completedPrimingNow
          && this.accumulatorSamples === 0
          && (this.endpoint.state !== 'idle' || decision.type === 'finalizeUtterance');
        if (synthesizedStartNow) {
          this.seedChunkFromPreRoll(frameSamples, output,
            latchedContinuingOnset && !output.isLoudRegime);
        }
        if (decision.type === 'startUtterance' && this.primingComplete) {
          this.utteranceQuietestStrongDb = null;
          if (slowOnsetTriggered) {
            this.speechSamples += Math.round(this.slowOnsetEvidenceMs * 16);
          }
          const softOnset = this.quietLatchWitnessEnabled
            && latchedContinuingOnset
            && !output.isLoudRegime;
          const seededFromGap = this.seedChunkFromPreRoll(frameSamples, output, softOnset);
          if (!this.headLive && !seededFromGap) {
            this.accumulatorSamples += frameSamples;
            this.chunkEndSessionSamples = this.sessionElapsedSamples;
          }
          this.trackAccumulatorSpeechEvidence(output, frameDb);
          this.sustainedContinuingMs = 0;
          this.streakStartFloorDb = null;
          this.streakPeakDb = null;
          this.streakSawDynamics = false;
          this.sustainedContinuingOnsetLatched = false;
          this.latchAmbiguousGraceElapsedMs = 0;
          this.latchAmbiguousGraceExpired = false;
          this.lastLatchDynamicsWitnessTime = null;
          this.resetQuietLatchWindow();
          this.silenceSamples = 0;
        } else if (this.primingComplete && (decision.type === 'continueUtterance'
          || decision.type === 'finalizeUtterance')) {
          if (!synthesizedStartNow) {
            this.accumulatorSamples += frameSamples;
            this.chunkEndSessionSamples = this.sessionElapsedSamples;
          }
          this.trackAccumulatorSpeechEvidence(output, frameDb);
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
          this.quietRiseCapAppliesToAmbiguous,
          this.quietRiseCapWitnessDb,
        );
        if (this.accumulatorSamples === 0) {
          this.chunkStartSessionSamples = this.sessionElapsedSamples - frameSamples;
        }
        this.accumulatorSamples += frameSamples;
        this.chunkEndSessionSamples = this.sessionElapsedSamples;
        this.trackAccumulatorSpeechEvidence(output, frameDb);
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
        } else if (this.speechSamples < MINIMUM_VOICE_EVIDENCE_SAMPLES
          && this.accumulatorSamples > this.maxNoiseSamples
          && !this.accumulatorHasPlausibleSpeech()) {
          discarded = true;
          this.emitEvent({
            t: 'ev',
            k: 'discard',
            n: this.accumulatorSamples,
            r: 'noise_guard',
            timestampMs: this.sessionElapsedSamples / 16,
            sourceStartSample: this.chunkStartSessionSamples,
            sourceEndSample: this.chunkEndSessionSamples,
          });
          this.accumulatorSamples = 0;
          this.accumulatorPeakAboveFloorDb = null;
          this.accumulatorHasSpeechEvidence = false;
          this.chunkStartSessionSamples = null;
          this.chunkEndSessionSamples = null;
          this.speechSamples = 0;
          this.silenceSamples = 0;
        }
      }

      const frameRecord = this.recordFrame(
        output,
        previousState,
        this.endpointMachineEnabled ? decision : { type: 'none' },
        Math.round(decisionSilenceSamples),
        frameDb,
        frameDuration,
        qualificationState,
        this.contiguousTrailingSilenceSamples,
      );
      if (decision.type === 'finalizeUtterance'
        || (previousState === 'onsetPending' && this.endpoint.state === 'idle')) {
        this.resetUtteranceLevelReference();
      }
      if (decision.type === 'startUtterance') {
        this.finishIdleGapRun();
      } else if (this.endpointMachineEnabled
        && previousState === 'idle'
        && this.endpoint.state === 'idle') {
        this.trackIdleGapFrame(frameDb, frameSamples, output);
      }
      const slowOnsetDiagnostic = {
        enabled: this.slowOnsetEnabled,
        endpointMachineEnabled: this.endpointMachineEnabled,
        floorDb: output.floorDb,
        floorThresholdDb: slowThresholdFloorTermDb,
        guardThresholdDb: slowThresholdGuardDb,
        thresholdDb: slowThresholdDb,
        qualifies: slowOnsetQualifies,
        evidenceBeforeMs: slowEvidenceBeforeMs,
        evidenceAfterMs: slowEvidenceAfterMs,
        windowOccupancyMs: slowEvidenceAfterMs,
        triggered: slowOnsetTriggered,
        triggerTime: this.slowOnsetTriggerTime,
        endpointStateBefore: previousState,
        endpointStateAfter: this.endpoint.state,
        decision: decision.type,
        accumulatorBeforeMs: slowOnsetAccumulatorBeforeMs,
        accumulatorAfterMs: this.accumulatorSamples / 16,
        reason: !this.slowOnsetEnabled
          ? 'tier_disabled'
          : !this.endpointMachineEnabled
            ? 'endpoint_machine_disabled'
            : !this.primingComplete
              ? 'priming_incomplete'
            : output.floorDb === null
              ? 'floor_unavailable'
              : !endpointWasIdle
                ? 'endpoint_not_idle'
                : slowOnsetTriggered
                  ? decision.type === 'startUtterance' ? 'trigger_accepted' : 'endpoint_ignored_trigger'
                  : !slowOnsetQualifies && slowEvidenceAfterMs < slowEvidenceBeforeMs
                    ? 'window_evicted_evidence'
                    : slowOnsetQualifies ? 'evidence_accumulating' : 'below_threshold',
      };
      if (typeof onSlowOnsetDiagnostic === 'function') {
        onSlowOnsetDiagnostic({
          frame: frameRecord,
          time: this.sessionElapsedSamples / 16000,
          db: frameDb,
          dt: frameDuration,
          diagnostic: slowOnsetDiagnostic,
        });
      }

      if (decision.type === 'startUtterance' && this.primingComplete) {
        this.emitEvent({
          t: 'ev',
          k: 'start_utterance',
          n: this.accumulatorSamples,
          ...(slowOnsetTriggered ? { time: this.slowOnsetTriggerTime } : {}),
          ...(this.quietLatchWitnessEnabled
            && latchedContinuingOnset
            && !output.isLoudRegime ? { softOnset: true } : {}),
        });
      }

      if (decision.type === 'finalizeUtterance') {
        if (decision.kind === 'endpoint') {
          this.postFinalizeSoftLatchSuppressionSamplesRemaining = POST_FINALIZE_SOFT_LATCH_SUPPRESSION_SAMPLES;
        }
        if (!this.primingComplete && this.accumulatorSamples === 0) {
          this.emitEvent({ t: 'ev', k: 'discard', r: 'priming_window' });
          this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
          this.gate.noteUtteranceEnded(
            this.utteranceQuietestStrongDb,
            this.contiguousTrailingSilenceMinimumDb,
          );
          this.utteranceQuietestStrongDb = null;
          this.speechSamples = 0;
          return { output, decision, frameRecord: null, discarded: true };
        }
        const rawTotalSamples = this.accumulatorSamples;
        this.lastUntrimmedEmitSampleCount = rawTotalSamples;
        const trailingSilenceSamples = Math.min(this.contiguousTrailingSilenceSamples, rawTotalSamples);
        const trimsPostRoll = decision.type === 'finalizeUtterance' && decision.kind !== 'stop';
        const totalSamples = trimsPostRoll
          ? rawTotalSamples - Math.max(0, trailingSilenceSamples - this.postRollSamples)
          : rawTotalSamples;
        const trimmedTailSamples = rawTotalSamples - totalSamples;
        this.emittedTotalMs = totalSamples / 16;
        const speechMs = this.speechSamples / 16;
        if (this.accumulatorSamples < this.minChunkSamples
          || this.speechSamples < this.minSpeechSamples) {
          // Swift keeps a below-minimum endpoint accumulator for later continuation or stop flush.
          this.emitEvent({
            t: 'ev',
            k: 'outcome',
            n: this.accumulatorSamples,
            r: 'below_minimums_held',
            sm: speechMs,
            tm: this.accumulatorSamples / 16,
            es: previousState,
          });
          this.sawReanchorDuringUtterance = false;
        } else {
          const reason = decision.kind;
          const chunkId = this.nextChunkId;
          const emissionStartSamples = this.chunkStartSessionSamples
            ?? (this.sessionElapsedSamples - rawTotalSamples);
          const sourceEndSamples = (this.chunkEndSessionSamples ?? this.sessionElapsedSamples)
            - trimmedTailSamples;
          this.nextChunkId += 1;
          this.chunkCount += 1;
          this.emittedSampleCount += totalSamples;
          this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
          this.gate.noteUtteranceEnded(
            this.utteranceQuietestStrongDb,
            this.contiguousTrailingSilenceMinimumDb,
          );
          this.emitEvent({
            t: 'ev',
            k: 'emit',
            id: chunkId,
            n: totalSamples,
            r: reason,
            sm: speechMs,
            tm: this.emittedTotalMs,
            s0: emissionStartSamples / 16,
            s1: (emissionStartSamples + totalSamples) / 16,
            sourceStartSample: emissionStartSamples,
            sourceEndSample: sourceEndSamples,
            es: previousState,
            weightedSilenceCreditMs: decisionAmbiguousCreditSamples / 16,
            physicalTrailingSilenceMs: this.contiguousTrailingSilenceSamples / 16,
          });
          this.clearRetainedGap();
          if (trimmedTailSamples > 0) {
            // Keep the post-roll-trimmed silence contiguous with the next chunk.
            this.retainedGapSamples = trimmedTailSamples;
            this.retainedGapStartSessionSamples = sourceEndSamples;
            this.retainedGapPeakAboveFloorDb = this.contiguousTrailingSilencePeakAboveFloorDb;
            this.manageRetainedGapOverflow();
          }
          this.headLive = false;
          this.headSamples = 0;
          this.postHeadPreRollSamples = 0;
          this.utteranceQuietestStrongDb = null;
          this.accumulatorSamples = 0;
          this.accumulatorPeakAboveFloorDb = null;
          this.accumulatorHasSpeechEvidence = false;
          this.chunkStartSessionSamples = null;
          this.chunkEndSessionSamples = null;
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

      if (primingWasComplete && !this.headLive && decision.type !== 'startUtterance') {
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

      this.spilledSampleCount = Math.max(0, this.accumulatorSamples - this.spillThresholdSamples);
      this.spillOccurred ||= this.spilledSampleCount > 0;

      return {
        output,
        decision,
        endpointEvidence,
        reanchorEvent,
        discarded,
        latchedContinuingOnset,
        frameRecord,
        slowOnsetDiagnostic,
      };
    },

    resetQuietLatchWindow() {
      this.quietLatchHistory.length = 0;
      this.quietLatchCandidateStartTime = null;
      this.quietLatchStartFloorDb = null;
      this.quietLatchCoverageMs = 0;
      this.quietLatchRisingEdgeAtSessionSamples = null;
      this.quietLatchRisingEdgeSeen = false;
    },

    trackIdleGapFrame(frameDb, frameSamples, output) {
      if (typeof onEvent !== 'function') return;
      if (this.idleGapRunSamples === 0) {
        this.idleGapStartSessionSamples = this.sessionElapsedSamples - frameSamples;
      }
      this.idleGapRunSamples += frameSamples;
      this.idleGapEndSessionSamples = this.sessionElapsedSamples;
      if (output.floorDb === null) return;
      if (frameDb >= output.floorDb + IDLE_GAP_TELEMETRY_EVIDENCE_ABOVE_FLOOR_DB) {
        this.idleGapEvidenceAboveFloor5Samples += frameSamples;
      }
      if (this.idleGapPeakLevelDb !== null && frameDb <= this.idleGapPeakLevelDb) return;
      this.idleGapPeakLevelDb = frameDb;
      this.idleGapFloorDbAtPeak = output.floorDb;
      this.idleGapStrongThresholdDbAtPeak = output.thresholdDb;
      this.idleGapContinuationThresholdDbAtPeak = output.continuationThresholdDb;
    },

    finishIdleGapRun() {
      const durationMs = this.idleGapRunSamples / 16;
      const peakAboveFloorDb = this.idleGapPeakLevelDb === null
        || this.idleGapFloorDbAtPeak === null
        ? null
        : this.idleGapPeakLevelDb - this.idleGapFloorDbAtPeak;
      if (typeof onEvent === 'function'
        && durationMs >= IDLE_GAP_TELEMETRY_MIN_SECONDS * 1000
        && peakAboveFloorDb >= IDLE_GAP_TELEMETRY_PEAK_ABOVE_FLOOR_DB) {
        this.emitEvent({
          t: 'ev',
          k: 'discard',
          r: 'idle_gap',
          timestampMs: this.sessionElapsedSamples / 16,
          sourceStartSample: this.idleGapStartSessionSamples,
          sourceEndSample: this.idleGapEndSessionSamples,
          durationMs,
          peakLevelDbFS: this.idleGapPeakLevelDb,
          floorDbFSAtPeak: this.idleGapFloorDbAtPeak,
          strongThresholdDbFSAtPeak: this.idleGapStrongThresholdDbAtPeak,
          continuationThresholdDbFSAtPeak: this.idleGapContinuationThresholdDbAtPeak,
          evidenceAboveFloor5Ms: this.idleGapEvidenceAboveFloor5Samples / 16,
        });
      }
      this.idleGapRunSamples = 0;
      this.idleGapStartSessionSamples = null;
      this.idleGapEndSessionSamples = null;
      this.idleGapPeakLevelDb = null;
      this.idleGapFloorDbAtPeak = null;
      this.idleGapStrongThresholdDbAtPeak = null;
      this.idleGapContinuationThresholdDbAtPeak = null;
      this.idleGapEvidenceAboveFloor5Samples = 0;
    },

    updateSlowOnsetEvidence(frameDb, floorDb, frameDuration) {
      if (!this.slowOnsetEnabled
        || !this.endpointMachineEnabled
        || !this.primingComplete
        || floorDb === null
        || this.endpoint.state !== 'idle') {
        this.slowOnsetHistory.length = 0;
        return false;
      }

      const end = this.sessionElapsedSamples / 16000;
      const start = end - frameDuration;
      const requiredDb = calculateSlowOnsetThreshold(
        floorDb,
        this.slowOnsetDeltaDb,
        this.gate.effectiveAbsoluteSpeechFloorDb,
      );
      if (frameDb >= requiredDb) this.slowOnsetHistory.push({ start, end });

      const cutoff = end - this.slowOnsetWindowSeconds;
      while (this.slowOnsetHistory.length > 0
        && this.slowOnsetHistory[0].end <= cutoff) {
        this.slowOnsetHistory.shift();
      }
      if (this.slowOnsetHistory.length > 0
        && this.slowOnsetHistory[0].start < cutoff) {
        this.slowOnsetHistory[0].start = cutoff;
      }

      const evidenceSeconds = this.slowOnsetHistory.reduce(
        (total, frame) => total + frame.end - frame.start,
        0,
      );
      if (evidenceSeconds * 1000 + 1e-6 < this.slowOnsetEvidenceMs) return false;
      const evidenceOvershootSeconds = Math.max(
        0,
        evidenceSeconds - this.slowOnsetEvidenceMs / 1000,
      );
      this.slowOnsetTriggerTime = end - evidenceOvershootSeconds;
      this.slowOnsetHistory.length = 0;
      return true;
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
      this.previousProcessedFrameDb = null;
      this.quietLatchRisingEdgeAtSessionSamples = null;
      this.quietLatchRisingEdgeSeen = false;
      this.moveRetainedGapToAccumulator();
      this.finishIdleGapRun();
      const stopWeightedSilenceCreditMs = this.endpoint.accumulatedAmbiguousCreditSamples / 16;
      const stopPhysicalTrailingSilenceMs = this.contiguousTrailingSilenceSamples / 16;
      const sampleCount = this.accumulatorSamples;
      const speechMs = this.speechSamples / 16;
      const decisionTimeEndpointState = this.endpoint.state;
      const startMs = (this.chunkStartSessionSamples
        ?? (this.sessionElapsedSamples - sampleCount)) / 16;
      const endMs = startMs + sampleCount / 16;
      const sourceStartSample = this.chunkStartSessionSamples
        ?? (this.sessionElapsedSamples - sampleCount);
      const sourceEndSample = this.chunkEndSessionSamples ?? this.sessionElapsedSamples;
      const reason = sampleCount === 0
        ? (this.primingComplete ? 'empty' : 'priming_window')
        : sampleCount < STOP_FLUSH_MINIMUM_SAMPLES ? 'tail_floor' : 'flush';
      if (this.endpointMachineEnabled) this.endpoint.forceFinalize('stop');
      this.resetUtteranceLevelReference();
      this.emitEvent({
        t: 'ev',
        k: 'stop_flush',
        n: sampleCount,
        r: reason,
        sm: speechMs,
        tm: sampleCount / 16,
        ...(sampleCount > 0 ? { s0: startMs } : {}),
        s1: endMs,
        timestampMs: this.sessionElapsedSamples / 16,
        ...(sampleCount > 0 ? { sourceStartSample, sourceEndSample } : {}),
        es: decisionTimeEndpointState,
      });
      if (!this.primingComplete && sampleCount === 0) return { type: 'none' };
      if (sampleCount === 0) return { type: 'none' };
      // Sub-250 ms cannot contain an intelligible word, so the tail floor
      // prevents hallucinated tokens.
      if (sampleCount < STOP_FLUSH_MINIMUM_SAMPLES) {
        this.tailFloorSampleCount += sampleCount;
        this.emitEvent({
          t: 'ev',
          k: 'discard',
          n: sampleCount,
          r: 'tail_floor',
          timestampMs: this.sessionElapsedSamples / 16,
          sourceStartSample,
          sourceEndSample,
        });
        this.accumulatorSamples = 0;
        this.accumulatorPeakAboveFloorDb = null;
        this.accumulatorHasSpeechEvidence = false;
        this.chunkStartSessionSamples = null;
        this.chunkEndSessionSamples = null;
        this.speechSamples = 0;
        this.silenceSamples = 0;
        this.contiguousTrailingSilenceSamples = 0;
        this.contiguousTrailingSilenceMinimumDb = null;
        return { type: 'none' };
      }
      const chunkId = this.nextChunkId;
      this.nextChunkId += 1;
      this.chunkCount += 1;
      this.emittedSampleCount += sampleCount;
      this.emittedTotalMs = sampleCount / 16;
      if (this.speechSamples > 0) {
        this.noteUtteranceEndedValues.push(this.utteranceQuietestStrongDb);
        this.gate.noteUtteranceEnded(
          this.utteranceQuietestStrongDb,
          this.contiguousTrailingSilenceMinimumDb,
        );
      }
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
        sourceStartSample,
        sourceEndSample,
        es: decisionTimeEndpointState,
        weightedSilenceCreditMs: stopWeightedSilenceCreditMs,
        physicalTrailingSilenceMs: stopPhysicalTrailingSilenceMs,
      });
      this.headLive = false;
      this.headSamples = 0;
      this.accumulatorSamples = 0;
      this.accumulatorPeakAboveFloorDb = null;
      this.accumulatorHasSpeechEvidence = false;
      this.chunkStartSessionSamples = null;
      this.chunkEndSessionSamples = null;
      this.speechSamples = 0;
      this.silenceSamples = 0;
      this.utteranceQuietestStrongDb = null;
      this.sustainedContinuingMs = 0;
      this.streakStartFloorDb = null;
      this.streakPeakDb = null;
      this.sustainedContinuingOnsetLatched = false;
      this.streakSawDynamics = false;
      this.quietLatchRisingEdgeAtSessionSamples = null;
      this.quietLatchRisingEdgeSeen = false;
      return { type: 'finalizeUtterance', kind: 'stop' };
    },

    end({ flush = false } = {}) {
      if (flush) this.flush();
      this.resetUtteranceLevelReference();
      this.emitEvent({ t: 'ev', k: 'session_end' });
    },
  };
  harness.sessionConfig = makeSessionConfig(harness);
  harness.emitEvent({ t: 'ev', k: 'session_start', c: harness.sessionConfig });
  return harness;
}
