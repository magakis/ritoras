// Pure-logic JS mirror of shared/StreamingEndpoint.swift. This module owns
// timing decisions only; the recorder owns audio buffers and pre-roll storage.

export const STREAM_ENDPOINT_SILENCE_MS = 700;

export const STREAM_ENDPOINT_ONSET_SAMPLES = 1120;
export const STREAM_ENDPOINT_END_EVIDENCE_SAMPLES = 1600;
export const STREAM_ENDPOINT_RESUME_SAMPLES = 1920;
export const STREAM_ENDPOINT_AMBIGUOUS_RESCUE_SAMPLES = 5120;
export const STREAM_ENDPOINT_PREROLL_SAMPLES = 8000;

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
    preRollSamples: STREAM_ENDPOINT_PREROLL_SAMPLES,
    ...(partial ?? {}),
  };
  if (partial?.endpointSilenceMs !== undefined) {
    config.endpointSilenceSamples = partial.endpointSilenceMs * 16;
  }
  return config;
}

export class StreamingEndpoint {
  constructor(config = {}) {
    this.configuration = makeStreamingEndpointConfig(config);
    this.state = StreamingEndpointState.idle;
    this.utteranceDurationSamples = 0;
    this.accumulatedSilenceSamples = 0;
    this.resumeEvidenceSamples = 0;
    this.ambiguousEvidenceSamples = 0;
    this.onsetEvidenceSamples = 0;
  }

  process(evidence, durationSamples) {
    const samples = Math.max(0, durationSamples);
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
    this.ambiguousEvidenceSamples = 0;
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
    this.utteranceDurationSamples = this.configuration.preRollSamples + this.onsetEvidenceSamples;
    this.accumulatedSilenceSamples = 0;
    this.resumeEvidenceSamples = 0;
    this.ambiguousEvidenceSamples = 0;
    return {
      type: 'startUtterance',
      withPreRollSamples: this.configuration.preRollSamples,
    };
  }

  processActive(evidence, durationSamples) {
    this.utteranceDurationSamples += durationSamples;
    switch (evidence) {
      case StreamingEndpointEvidence.strong:
      case StreamingEndpointEvidence.continuing:
        this.accumulatedSilenceSamples = 0;
        return this.continue();
      case StreamingEndpointEvidence.ambiguous:
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
        this.ambiguousEvidenceSamples += durationSamples;
        if (this.ambiguousEvidenceSamples < this.configuration.ambiguousRescueSamples) {
          return this.continue();
        }
        this.state = StreamingEndpointState.speechActive;
        this.accumulatedSilenceSamples = 0;
        this.resumeEvidenceSamples = 0;
        this.ambiguousEvidenceSamples = 0;
        return this.continue();
      case StreamingEndpointEvidence.silence:
        this.ambiguousEvidenceSamples = 0;
        this.accumulatedSilenceSamples += durationSamples;
        this.resumeEvidenceSamples = 0;
        if (this.accumulatedSilenceSamples < this.configuration.endpointSilenceSamples) {
          return this.continue();
        }
        this.reset();
        return this.finalize(StreamingEndpointFinalizeKind.endpoint);
      case StreamingEndpointEvidence.strong:
      case StreamingEndpointEvidence.continuing:
        // Resume evidence pauses the silence timer but cannot cancel the
        // pending end until the resume threshold is reached.
        this.ambiguousEvidenceSamples = 0;
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
