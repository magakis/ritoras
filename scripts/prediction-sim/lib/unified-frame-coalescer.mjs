// Pure-logic JS mirror of shared/UnifiedFrameCoalescer.swift.

export const UNIFIED_FRAME_SAMPLE_COUNT = 8_960;

export class UnifiedFrameCoalescer {
  #pendingSamples = [];

  append(samples) {
    const frames = [];
    let sampleIndex = 0;

    while (sampleIndex < samples.length) {
      const availableFrameSamples = UNIFIED_FRAME_SAMPLE_COUNT
        - this.#pendingSamples.length;
      const samplesToAppend = Math.min(availableFrameSamples, samples.length - sampleIndex);
      const endIndex = sampleIndex + samplesToAppend;
      for (; sampleIndex < endIndex; sampleIndex += 1) {
        this.#pendingSamples.push(samples[sampleIndex]);
      }

      if (this.#pendingSamples.length === UNIFIED_FRAME_SAMPLE_COUNT) {
        frames.push(this.#pendingSamples);
        this.#pendingSamples = [];
      }
    }
    return frames;
  }

  flush() {
    if (this.#pendingSamples.length === 0) return null;
    const remainder = this.#pendingSamples;
    this.#pendingSamples = [];
    return remainder;
  }
}
