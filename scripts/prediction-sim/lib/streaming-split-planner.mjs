// Pure-logic JS mirror of shared/StreamingSplitPlanner.swift. It tracks only
// sample offsets; the recorder owns audio storage and forced-split replay.

export const STREAM_VAD_MAX_UTTERANCE_SAMPLES = 20 * 16000;
export const STREAM_VAD_USABLE_PAUSE_SAMPLES = 300 * 16;
export const STREAM_VAD_MIN_SPLIT_UTTERANCE_SAMPLES = 1000 * 16;

export class StreamingSplitPlanner {
  constructor({
    maxUtteranceSamples = STREAM_VAD_MAX_UTTERANCE_SAMPLES,
    usablePauseSamples = STREAM_VAD_USABLE_PAUSE_SAMPLES,
    minimumUtteranceSamples = STREAM_VAD_MIN_SPLIT_UTTERANCE_SAMPLES,
    overlapSamples = 0,
  } = {}) {
    this.maxUtteranceSamples = Math.max(0, maxUtteranceSamples);
    this.usablePauseSamples = Math.max(0, usablePauseSamples);
    this.minimumUtteranceSamples = Math.max(0, minimumUtteranceSamples);
    this.overlapSamples = Math.max(0, overlapSamples);
    this.reset();
  }

  begin(initialSamples) {
    this.totalSamples = Math.max(0, initialSamples);
    this.silenceRunSamples = 0;
    this.latestUsablePauseEndSamples = null;
  }

  append(evidence, durationSamples) {
    const samples = Math.max(0, durationSamples);
    if (samples === 0) return;

    if (evidence === 'silence') {
      this.silenceRunSamples += samples;
    } else {
      this.silenceRunSamples = 0;
    }

    const nextTotal = this.totalSamples + samples;
    if (
      evidence === 'silence'
      && this.silenceRunSamples >= this.usablePauseSamples
      && nextTotal >= this.minimumUtteranceSamples
    ) {
      this.latestUsablePauseEndSamples = nextTotal;
    }
    this.totalSamples = nextTotal;
  }

  splitPoint() {
    if (this.totalSamples < this.maxUtteranceSamples || this.maxUtteranceSamples === 0) {
      return null;
    }
    if (this.latestUsablePauseEndSamples !== null) {
      const offset = Math.max(1, this.latestUsablePauseEndSamples - this.overlapSamples);
      return {
        offsetSamples: Math.min(offset, this.maxUtteranceSamples),
        reason: 'pause',
      };
    }
    return { offsetSamples: this.maxUtteranceSamples, reason: 'cap' };
  }

  reset() {
    this.totalSamples = 0;
    this.silenceRunSamples = 0;
    this.latestUsablePauseEndSamples = null;
  }
}
