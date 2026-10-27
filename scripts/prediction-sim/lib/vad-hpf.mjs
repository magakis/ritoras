// Pure-logic JS mirror of shared/VADHighPassFilter.swift. The filter is used
// only before VAD RMS calculation; uploaded PCM remains the original samples.

export const STREAM_VAD_HPF_CUTOFF_HZ = 100.0;
export const STREAM_VAD_HPF_SAMPLE_RATE_HZ = 16000.0;

export class VADHighPassFilter {
  constructor({
    cutoffHz = STREAM_VAD_HPF_CUTOFF_HZ,
    sampleRate = STREAM_VAD_HPF_SAMPLE_RATE_HZ,
    float32 = false,
  } = {}) {
    const cutoff = Math.max(0, cutoffHz);
    const rc = cutoff > 0 ? 1 / (2 * Math.PI * cutoff) : Number.MAX_VALUE;
    const dt = 1 / sampleRate;
    this.float32 = float32;
    const alpha = rc / (rc + dt);
    this.alpha = float32 ? Math.fround(alpha) : alpha;
    this.previousInput = null;
    this.previousOutput = float32 ? Math.fround(0) : 0;
  }

  process(samples) {
    const filtered = [];
    filtered.length = samples.length;
    for (let i = 0; i < samples.length; i++) {
      const sample = this.float32 ? Math.fround(samples[i]) : samples[i];
      if (this.previousInput === null) {
        this.previousInput = sample;
        filtered[i] = this.float32 ? Math.fround(0) : 0;
        continue;
      }

      const sum = this.float32
        ? Math.fround(this.previousOutput + sample)
        : this.previousOutput + sample;
      const difference = this.float32
        ? Math.fround(sum - this.previousInput)
        : sum - this.previousInput;
      const output = this.float32
        ? Math.fround(this.alpha * difference)
        : this.alpha * difference;
      this.previousInput = sample;
      this.previousOutput = output;
      filtered[i] = output;
    }
    return filtered;
  }

  reset() {
    this.previousInput = null;
    this.previousOutput = 0;
  }
}
