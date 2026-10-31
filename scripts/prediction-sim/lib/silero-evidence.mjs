export const DEFAULT_SILERO_START_THRESHOLD = 0.45;
export const DEFAULT_SILERO_STOP_THRESHOLD = 0.30;
export const DEFAULT_SILERO_SMOOTHING_STEPS = 5;

function clampFinite(value, fallback, minimum, maximum) {
  const finiteValue = Number.isFinite(value) ? value : fallback;
  return Math.min(maximum, Math.max(minimum, finiteValue));
}

function clampInteger(value, fallback, minimum, maximum) {
  const finiteValue = Number.isFinite(value) ? value : fallback;
  return Math.trunc(Math.min(maximum, Math.max(minimum, finiteValue)));
}

export function normalizeSileroEvidenceConfig({
  sileroStartThreshold = DEFAULT_SILERO_START_THRESHOLD,
  sileroStopThreshold = DEFAULT_SILERO_STOP_THRESHOLD,
  sileroSmoothingSteps = DEFAULT_SILERO_SMOOTHING_STEPS,
} = {}) {
  const startThreshold = clampFinite(sileroStartThreshold, DEFAULT_SILERO_START_THRESHOLD, 0.10, 0.90);
  return {
    startThreshold,
    stopThreshold: Math.min(
      clampFinite(sileroStopThreshold, DEFAULT_SILERO_STOP_THRESHOLD, 0.10, 0.90),
      startThreshold,
    ),
    smoothingSteps: clampInteger(sileroSmoothingSteps, DEFAULT_SILERO_SMOOTHING_STEPS, 1, 15),
  };
}

export class SileroEvidenceProcessor {
  constructor(configuration = {}) {
    this.configuration = normalizeSileroEvidenceConfig(configuration);
    this.recentProbabilities = [];
    this.latestDecision = null;
  }

  consume(probability) {
    const rawProbability = Number.isFinite(probability)
      ? Math.min(1, Math.max(0, probability))
      : 0;
    this.recentProbabilities.push(rawProbability);
    if (this.recentProbabilities.length > this.configuration.smoothingSteps) {
      this.recentProbabilities.splice(
        0,
        this.recentProbabilities.length - this.configuration.smoothingSteps,
      );
    }

    const smoothedProbability = this.recentProbabilities.reduce((sum, value) => sum + value, 0)
      / this.recentProbabilities.length;
    const evidence = smoothedProbability >= this.configuration.startThreshold
      ? 'strong'
      : smoothedProbability >= this.configuration.stopThreshold
        ? 'continuing'
        : 'silence';
    this.latestDecision = { rawProbability, smoothedProbability, evidence };
    return this.latestDecision;
  }

  consumeMany(probabilities) {
    let latestDecision = this.latestDecision;
    for (const probability of probabilities) {
      latestDecision = this.consume(probability);
    }
    return latestDecision;
  }

  reset() {
    this.recentProbabilities.length = 0;
    this.latestDecision = null;
  }
}
