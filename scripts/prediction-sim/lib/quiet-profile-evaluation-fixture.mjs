import { adaptClientTelemetry } from './client-telemetry.mjs';
import { DEFAULT_SESSION_CONFIG } from '../bin/replay-vad.mjs';
import { quietProfileConfig } from '../bin/vad-never-onset-study.mjs';

export function createQuietProfileEvaluationFixture() {
  const baselineConfig = {
    ...DEFAULT_SESSION_CONFIG,
    mode: 'adaptive',
    // The -54 dB guard blocks cold-start ambient, then sits below converged -50/-53 dB thresholds.
    absoluteSpeechFloorDb: -54,
    dynamicsEnabled: false,
    strongDeltaDb: 10,
    continuationDeltaDb: 6,
    loudRegimeEnterDb: -35,
    loudStrongDeltaDb: 7,
    loudContinuationDeltaDb: 3,
    minSpeechMs: 300,
    minChunkMs: 300,
    endpointOnsetMs: 70,
  };
  const session = adaptClientTelemetry({
    vad_config: baselineConfig,
    frames: [
      ...Array(100).fill({ dt: 0.01, db: -60 }),
      ...Array(100).fill({ dt: 0.01, db: -52.5 }),
      ...Array(100).fill({ dt: 0.01, db: -60 }),
    ],
    events: [{ k: 'stop_flush', r: 'flush' }],
  }, 'quiet-profile-delta-override');
  const evaluationConfig = quietProfileConfig(session.config);
  return { session, baselineConfig: session.config, evaluationConfig };
}
