import { makeRecorderHarness } from './recorder-sim.mjs';

export function expandLevelSegments(segments) {
  const frames = [];
  for (const segment of segments) {
    const count = Math.round(segment.durationMs / 10);
    for (let index = 0; index < count; index += 1) {
      frames.push({ dt: 0.01, db: segment.db });
    }
  }
  return frames;
}

export function makeFaultTraceHarness({
  slowOnsetEnabled = false,
  // Keep the -38 dB warm-up below the cold-start strong threshold.
  absoluteSpeechFloorDb = -35,
  slowOnsetDeltaDb = 7,
  slowOnsetEvidenceMs = 300,
  slowOnsetWindowSeconds = 1.5,
  adaptiveDynamicsEnabled = false,
  onEvent,
  onSlowOnsetDiagnostic,
} = {}) {
  return makeRecorderHarness({
    frameMs: 10,
    minChunkSamples: 0,
    minSpeechSamples: 0,
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs: 700,
      preRollMs: 500,
    },
    gateConfig: {
      mode: 'adaptive',
      adaptiveDeltaDb: 10,
      adaptiveAbsoluteSpeechFloorDb: absoluteSpeechFloorDb,
      adaptiveDynamicsEnabled,
      adaptiveRiseSpeedMultiplier: 1,
    },
    recorderConfig: {
      slowOnsetEnabled,
      slowOnsetDeltaDb,
      slowOnsetEvidenceMs,
      slowOnsetWindowSeconds,
    },
    onEvent,
    onSlowOnsetDiagnostic,
  });
}
