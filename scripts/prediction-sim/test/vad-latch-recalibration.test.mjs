import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { adaptClientTelemetry } from '../lib/client-telemetry.mjs';
import { DEFAULT_SESSION_CONFIG, normalizeConfig, replaySession } from '../bin/replay-vad.mjs';

const fixturePath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../fixtures/vad-never-onset/flatfee-incident-preonset.json',
);

function evidenceCounts(frames) {
  const counts = { continuing: 0, ambiguous: 0, silence: 0, strong: 0 };
  for (const frame of frames) {
    const label = frame.e;
    if (Object.hasOwn(counts, label)) counts[label] += 1;
  }
  return counts;
}

function maxContinuingStreakMs(frames, isConverged) {
  let streakMs = 0;
  let maximumMs = 0;
  for (let index = 0; index < frames.length; index += 1) {
    if (isConverged(index) && frames[index].e === 'continuing') {
      streakMs += frames[index].dt * 1000;
      maximumMs = Math.max(maximumMs, streakMs);
    } else {
      streakMs = 0;
    }
  }
  return maximumMs;
}

describe('latch recalibration anchor', () => {
  it('forwards the sweep knobs to the mirror gate and recorder', () => {
    const normalized = normalizeConfig({
      ...DEFAULT_SESSION_CONFIG,
      mode: 'adaptive',
      latchAmbiguousGraceMs: 150,
      loudRegimeEnterDb: -35,
      loudLatchMs: 300,
      dynamicsWitnessDb: 7.5,
    });

    assert.equal(normalized.config.latchAmbiguousGraceMs, 150);
    assert.equal(normalized.config.loudRegimeEnterDb, -35);
    assert.equal(normalized.config.loudLatchMs, 300);
    assert.equal(normalized.config.dynamicsWitnessDb, 7.5);
    assert.equal(normalized.gateConfig.adaptiveDynamicsSpreadDb, 7.5);
    assert.equal(normalized.gateConfig.loudDynamicsSpreadDb, 7.5);
    assert.equal(normalized.recorderConfig.latchAmbiguousGraceMs, 150);
    assert.equal(normalized.recorderConfig.dynamicsWitnessDb, 7.5);
  });

  it('replays corpus-derived q0–q99 pre-onset db/dt and preserves the no-latch baseline', () => {
    const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
    const recordedEvidence = fixture.recordedEvidenceRuns.join('').split('').map(code => ({
      C: 'continuing',
      A: 'ambiguous',
      S: 'silence',
      T: 'strong',
    })[code]);
    const expectedCounts = Object.fromEntries(['continuing', 'ambiguous', 'silence', 'strong']
      .map(label => [label, fixture.expectedEvidenceCounts[label]]));
    assert.equal(fixture.frames.length, 100);
    assert.deepEqual(evidenceCounts(recordedEvidence.map(e => ({ e }))), expectedCounts);

    const session = adaptClientTelemetry({
      id: fixture.sessionId,
      vad_config: fixture.vad_config,
      frames: fixture.frames.map(([q, dt, db], index) => ({
        q,
        dt,
        db,
        e: recordedEvidence[index],
        fc: q >= fixture.floorConvergedFromQ,
        ll: false,
      })),
      events: [],
    }, fixture.sessionId);
    const replay = replaySession(session, session.config, { compare: false });
    const simulatedEvidenceCounts = evidenceCounts(replay.frames);
    const recordedEvidenceCounts = evidenceCounts(session.recordedFrames);

    assert.deepEqual(recordedEvidenceCounts, expectedCounts);
    assert.deepEqual(simulatedEvidenceCounts, expectedCounts);
    assert.ok(Math.abs(maxContinuingStreakMs(
      session.recordedFrames,
      index => session.recordedFrames[index].fc,
    ) - fixture.expectedEvidenceCounts.bestContinuingStreakMs) < 1e-6);
    assert.ok(Math.abs(maxContinuingStreakMs(
      replay.frames,
      index => replay.frames[index].fc,
    ) - fixture.expectedEvidenceCounts.bestContinuingStreakMs) < 1e-6);
    assert.equal(session.recordedFrames.some(frame => frame.ll), false);
    assert.equal(replay.frames.some(frame => frame.ll), false);
    assert.equal(replay.events.some(event => event.k === 'start_utterance'
      && event.time < fixture.firstBaselineOnsetSeconds), false);
  });
});
