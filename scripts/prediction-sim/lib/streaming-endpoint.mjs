// Pure-logic JS mirror of shared/StreamingEndpoint.swift. This module owns
// endpoint timing only; the recorder owns continuous audio retention.

export const STREAM_ENDPOINT_SILENCE_MS = 700;

export const STREAM_ENDPOINT_ONSET_SAMPLES = 1120;
export const STREAM_ENDPOINT_END_EVIDENCE_SAMPLES = 1600;
export const STREAM_ENDPOINT_RESUME_SAMPLES = 1920;
export const STREAM_ENDPOINT_AMBIGUOUS_RESCUE_SAMPLES = 5120;
export const STREAM_ENDPOINT_AMBIGUOUS_DECAY_GRACE_MS = 800;
export const STREAM_ENDPOINT_AMBIGUOUS_DECAY_RATE = 0.75;
const STREAM_ENDPOINT_MIN_SAMPLES = 160;

export const StreamingEndpointEvidence = Object.freeze({
  strong: 'strong',
  continuing: 'continuing',
  ambiguous: 'ambiguous',
  silence: 'silence',
});

export const StreamingEndpointState = Object.freeze({
  idle: 'idle',
  onsetPending: 'onsetPending',
  speechActive: 'speechActive',
  endPending: 'endPending',
});

export const StreamingEndpointFinalizeKind = Object.freeze({
  endpoint: 'endpoint',
  stop: 'stop',
});

export function makeStreamingEndpointConfig(partial = {}) {
  const config = {
    onsetSamples: STREAM_ENDPOINT_ONSET_SAMPLES,
    endEvidenceSamples: STREAM_ENDPOINT_END_EVIDENCE_SAMPLES,
    endpointSilenceSamples: STREAM_ENDPOINT_SILENCE_MS * 16,
    resumeSamples: STREAM_ENDPOINT_RESUME_SAMPLES,
    ambiguousRescueSamples: STREAM_ENDPOINT_AMBIGUOUS_RESCUE_SAMPLES,
    ambiguousDecayEnabled: false,
    ambiguousDecayGraceMs: STREAM_ENDPOINT_AMBIGUOUS_DECAY_GRACE_MS,
    ambiguousDecayRate: STREAM_ENDPOINT_AMBIGUOUS_DECAY_RATE,
    ...(partial ?? {}),
  };
  const millisecondFields = [
    ['onsetMs', 'onsetSamples'],
    ['endEvidenceMs', 'endEvidenceSamples'],
    ['endpointSilenceMs', 'endpointSilenceSamples'],
    ['ambiguousDecayGraceMs', 'ambiguousDecayGraceSamples'],
  ];
  for (const [millisecondsKey, samplesKey] of millisecondFields) {
    if (partial?.[millisecondsKey] !== undefined) {
      config[samplesKey] = partial[millisecondsKey] * 16;
    }
  }
  const proportionalFields = [
    ['resumeToEndpointSilenceRatio', 'resumeSamples'],
    ['ambiguousRescueToEndpointSilenceRatio', 'ambiguousRescueSamples'],
  ];
  for (const [ratioKey, samplesKey] of proportionalFields) {
    if (partial?.[ratioKey] !== undefined) {
      config[samplesKey] = config.endpointSilenceSamples * partial[ratioKey];
    }
  }
  // Do not impose Config.swift's current upper bounds here; Phase 4 must revisit
  // those bounds if the corpus sweep exceeds them.
  // Explicit milliseconds remain the most specific override; ratios let
  // replay sweeps scale the windows without selecting new defaults here.
  for (const [millisecondsKey, samplesKey] of [
    ['resumeMs', 'resumeSamples'],
    ['ambiguousRescueMs', 'ambiguousRescueSamples'],
  ]) {
    if (partial?.[millisecondsKey] !== undefined) {
      config[samplesKey] = partial[millisecondsKey] * 16;
    }
  }
  config.onsetSamples = Math.max(STREAM_ENDPOINT_MIN_SAMPLES, config.onsetSamples);
  config.endEvidenceSamples = Math.max(
    STREAM_ENDPOINT_MIN_SAMPLES,
    config.endEvidenceSamples,
  );
  config.endpointSilenceSamples = Math.max(
    STREAM_ENDPOINT_MIN_SAMPLES,
    config.endpointSilenceSamples,
  );
  config.endEvidenceSamples = Math.min(
    config.endEvidenceSamples,
    config.endpointSilenceSamples,
  );
  // Resume above endpoint silence is permitted but inert: evidence classes are
  // mutually exclusive, so endpoint silence wins before resume can accrue.
  config.resumeSamples = Math.max(STREAM_ENDPOINT_MIN_SAMPLES, config.resumeSamples);
  config.ambiguousRescueSamples = Math.max(
    STREAM_ENDPOINT_MIN_SAMPLES,
    config.ambiguousRescueSamples,
  );
  const rawAmbiguousDecayGraceSamples = config.ambiguousDecayGraceSamples
    ?? config.ambiguousDecayGraceMs * 16;
  const finiteAmbiguousDecayGraceSamples = Number.isFinite(rawAmbiguousDecayGraceSamples)
    ? rawAmbiguousDecayGraceSamples
    : STREAM_ENDPOINT_AMBIGUOUS_DECAY_GRACE_MS * 16;
  config.ambiguousDecayGraceSamples = Math.max(
    100 * 16,
    Math.min(2_000 * 16, finiteAmbiguousDecayGraceSamples),
    config.ambiguousRescueSamples,
  );
  config.ambiguousDecayGraceMs = config.ambiguousDecayGraceSamples / 16;
  config.ambiguousDecayEnabled = Boolean(config.ambiguousDecayEnabled);
  config.ambiguousDecayRate = Number.isFinite(config.ambiguousDecayRate)
    ? Math.min(1, Math.max(0, config.ambiguousDecayRate))
    : STREAM_ENDPOINT_AMBIGUOUS_DECAY_RATE;
  return config;
}

export class StreamingEndpoint {
  constructor(config = {}) {
    this.configuration = makeStreamingEndpointConfig(config);
    this.state = StreamingEndpointState.idle;
    this.utteranceDurationSamples = 0;
    this.accumulatedSilenceSamples = 0;
    this.resumeEvidenceSamples = 0;
    this.ambiguousRunSamples = 0;
    this.accumulatedAmbiguousCreditSamples = 0;
    this.lastFrameAmbiguousCreditSamples = 0;
    this.lastDecisionSilenceSamples = null;
    this.lastDecisionAmbiguousCreditSamples = null;
    this.lastDecisionAmbiguousRunSamples = null;
    this.lastDecisionAmbiguousFrameCreditSamples = null;
    this.onsetEvidenceSamples = 0;
  }

  process(evidence, durationSamples) {
    const samples = Math.max(0, durationSamples);
    this.lastFrameAmbiguousCreditSamples = 0;
    this.lastDecisionSilenceSamples = null;
    this.lastDecisionAmbiguousCreditSamples = null;
    this.lastDecisionAmbiguousRunSamples = null;
    this.lastDecisionAmbiguousFrameCreditSamples = null;
    if (this.configuration.ambiguousDecayEnabled) {
      return this.processWithAmbiguousDecay(evidence, samples);
    }
    switch (this.state) {
      case StreamingEndpointState.idle:
        return this.processIdle(evidence, samples);
      case StreamingEndpointState.onsetPending:
        return this.processOnset(evidence, samples);
      case StreamingEndpointState.speechActive:
        return this.processActive(evidence, samples);
      case StreamingEndpointState.endPending:
        return this.processEndPending(evidence, samples);
      default:
        return this.none();
    }
  }

  forceFinalize(kind) {
    if (this.state === StreamingEndpointState.idle) return this.none();
    if (this.state === StreamingEndpointState.onsetPending) {
      this.reset();
      return this.none();
    }
    this.reset();
    return this.finalize(kind);
  }

  reset() {
    this.state = StreamingEndpointState.idle;
    this.utteranceDurationSamples = 0;
    this.accumulatedSilenceSamples = 0;
    this.resumeEvidenceSamples = 0;
    this.ambiguousRunSamples = 0;
    this.accumulatedAmbiguousCreditSamples = 0;
    this.lastFrameAmbiguousCreditSamples = 0;
    this.lastDecisionSilenceSamples = null;
    this.lastDecisionAmbiguousCreditSamples = null;
    this.lastDecisionAmbiguousRunSamples = null;
    this.lastDecisionAmbiguousFrameCreditSamples = null;
    this.onsetEvidenceSamples = 0;
  }

  processIdle(evidence, durationSamples) {
    if (evidence !== StreamingEndpointEvidence.strong) return this.none();
    this.state = StreamingEndpointState.onsetPending;
    this.onsetEvidenceSamples = durationSamples;
    if (this.onsetEvidenceSamples >= this.configuration.onsetSamples) {
      return this.beginUtterance();
    }
    return this.none();
  }

  processOnset(evidence, durationSamples) {
    if (evidence !== StreamingEndpointEvidence.strong) {
      this.reset();
      return this.none();
    }
    this.onsetEvidenceSamples += durationSamples;
    if (this.onsetEvidenceSamples < this.configuration.onsetSamples) return this.none();
    return this.beginUtterance();
  }

  beginUtterance() {
    this.state = StreamingEndpointState.speechActive;
    this.utteranceDurationSamples = this.onsetEvidenceSamples;
    this.accumulatedSilenceSamples = 0;
    this.resumeEvidenceSamples = 0;
    this.ambiguousRunSamples = 0;
    this.accumulatedAmbiguousCreditSamples = 0;
    return { type: 'startUtterance' };
  }

  processActive(evidence, durationSamples) {
    this.utteranceDurationSamples += durationSamples;
    switch (evidence) {
      case StreamingEndpointEvidence.strong:
      case StreamingEndpointEvidence.continuing:
        this.accumulatedSilenceSamples = 0;
        return this.continue();
      case StreamingEndpointEvidence.ambiguous:
        // Match speech-like treatment: ambiguous frames must not bank silence
        // toward end evidence (StreamingEndpoint.swift:155–173).
        this.accumulatedSilenceSamples = 0;
        return this.continue();
      case StreamingEndpointEvidence.silence:
        this.accumulatedSilenceSamples += durationSamples;
        if (this.accumulatedSilenceSamples < this.configuration.endEvidenceSamples) {
          return this.continue();
        }
        this.state = StreamingEndpointState.endPending;
        return this.continue();
      default:
        return this.continue();
    }
  }

  processEndPending(evidence, durationSamples) {
    this.utteranceDurationSamples += durationSamples;
    switch (evidence) {
      case StreamingEndpointEvidence.ambiguous:
        this.ambiguousRunSamples += durationSamples;
        if (this.ambiguousRunSamples < this.configuration.ambiguousRescueSamples) {
          return this.continue();
        }
        this.state = StreamingEndpointState.speechActive;
        this.accumulatedSilenceSamples = 0;
        this.resumeEvidenceSamples = 0;
        this.ambiguousRunSamples = 0;
        return this.continue();
      case StreamingEndpointEvidence.silence:
        this.ambiguousRunSamples = 0;
        this.accumulatedSilenceSamples += durationSamples;
        this.resumeEvidenceSamples = 0;
        if (this.accumulatedSilenceSamples < this.configuration.endpointSilenceSamples) {
          return this.continue();
        }
        return this.finalizeForEndpoint();
      case StreamingEndpointEvidence.strong:
      case StreamingEndpointEvidence.continuing:
        // Resume evidence pauses the silence timer but cannot cancel the
        // pending end until the resume threshold is reached.
        this.ambiguousRunSamples = 0;
        this.resumeEvidenceSamples += durationSamples;
        if (this.resumeEvidenceSamples < this.configuration.resumeSamples) {
          return this.continue();
        }
        this.state = StreamingEndpointState.speechActive;
        this.accumulatedSilenceSamples = 0;
        this.resumeEvidenceSamples = 0;
        return this.continue();
      default:
        return this.continue();
    }
  }

  processWithAmbiguousDecay(evidence, durationSamples) {
    switch (this.state) {
      case StreamingEndpointState.idle:
        return this.processIdle(evidence, durationSamples);
      case StreamingEndpointState.onsetPending:
        return this.processOnset(evidence, durationSamples);
      case StreamingEndpointState.speechActive:
      case StreamingEndpointState.endPending:
        this.utteranceDurationSamples += durationSamples;
        break;
      default:
        return this.none();
    }

    switch (evidence) {
      case StreamingEndpointEvidence.strong:
      case StreamingEndpointEvidence.continuing:
        this.ambiguousRunSamples = 0;
        if (this.state === StreamingEndpointState.speechActive) {
          this.accumulatedSilenceSamples = 0;
          this.accumulatedAmbiguousCreditSamples = 0;
          this.resumeEvidenceSamples = 0;
          return this.continue();
        }

        this.resumeEvidenceSamples += durationSamples;
        if (this.resumeEvidenceSamples < this.configuration.resumeSamples) {
          return this.continue();
        }
        this.state = StreamingEndpointState.speechActive;
        this.accumulatedSilenceSamples = 0;
        this.accumulatedAmbiguousCreditSamples = 0;
        this.resumeEvidenceSamples = 0;
        return this.continue();

      case StreamingEndpointEvidence.ambiguous: {
        const runBeforeFrame = this.ambiguousRunSamples;
        this.ambiguousRunSamples += durationSamples;
        // Compute this frame's beyond-grace slice once, before any state hop.
        const beyondGraceSamples = Math.max(
          0,
          this.ambiguousRunSamples - Math.max(
            runBeforeFrame,
            this.configuration.ambiguousDecayGraceSamples,
          ),
        );
        const creditSamples = beyondGraceSamples * this.configuration.ambiguousDecayRate;
        this.lastFrameAmbiguousCreditSamples = creditSamples;
        this.accumulatedSilenceSamples += creditSamples;
        this.accumulatedAmbiguousCreditSamples += creditSamples;

        if (this.accumulatedSilenceSamples >= this.configuration.endpointSilenceSamples) {
          return this.finalizeForEndpoint();
        }
        if (this.state === StreamingEndpointState.speechActive
          && this.accumulatedSilenceSamples >= this.configuration.endEvidenceSamples) {
          this.state = StreamingEndpointState.endPending;
        }
        if (this.state === StreamingEndpointState.endPending
          && this.ambiguousRunSamples >= this.configuration.ambiguousRescueSamples) {
          // Rescue returns to active without discarding either endpoint counter.
          this.state = StreamingEndpointState.speechActive;
          this.resumeEvidenceSamples = 0;
        }
        return this.continue();
      }

      case StreamingEndpointEvidence.silence:
        this.accumulatedSilenceSamples += durationSamples;
        if (this.state === StreamingEndpointState.endPending) this.resumeEvidenceSamples = 0;
        if (this.accumulatedSilenceSamples >= this.configuration.endpointSilenceSamples) {
          return this.finalizeForEndpoint();
        }
        if (this.state === StreamingEndpointState.speechActive
          && this.accumulatedSilenceSamples >= this.configuration.endEvidenceSamples) {
          this.state = StreamingEndpointState.endPending;
        }
        return this.continue();

      default:
        return this.continue();
    }
  }

  finalizeForEndpoint() {
    const decisionSilenceSamples = this.accumulatedSilenceSamples;
    const decisionAmbiguousCreditSamples = this.accumulatedAmbiguousCreditSamples;
    const decisionAmbiguousRunSamples = this.ambiguousRunSamples;
    const decisionAmbiguousFrameCreditSamples = this.lastFrameAmbiguousCreditSamples;
    this.reset();
    this.lastDecisionSilenceSamples = decisionSilenceSamples;
    this.lastDecisionAmbiguousCreditSamples = decisionAmbiguousCreditSamples;
    this.lastDecisionAmbiguousRunSamples = decisionAmbiguousRunSamples;
    this.lastDecisionAmbiguousFrameCreditSamples = decisionAmbiguousFrameCreditSamples;
    return this.finalize(StreamingEndpointFinalizeKind.endpoint);
  }

  none() {
    return { type: 'none' };
  }

  continue() {
    return { type: 'continueUtterance' };
  }

  finalize(kind) {
    return { type: 'finalizeUtterance', kind };
  }
}
