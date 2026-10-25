import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { GapRetentionPolicy } from '../lib/gap-retention-policy.mjs';

function appendFrame(policy, startSample, endSample, {
  db = -80,
  evidence = 'silence',
  silenceThresholdDb = -75,
  decision = 'none',
  endpointState = 'idle',
} = {}) {
  return policy.processFrame({
    startSample,
    endSample,
    db,
    evidence,
    silenceThresholdDb,
    decision,
    endpointState,
  });
}

describe('gap-retention boundary policy', () => {
  it('sheds the whole pending buffer only above the cap and below 100 ms of voice', () => {
    const policy = new GapRetentionPolicy({
      maxNoiseSamples: 100,
      minVoiceEvidenceSamples: 1_600,
      minSpeechSamples: 10,
      minChunkSamples: 10,
    });
    appendFrame(policy, 0, 100);
    assert.equal(policy.shedSlabs.length, 0);
    appendFrame(policy, 100, 101);

    assert.deepEqual(policy.shedSlabs, [{
      startSample: 0,
      endSample: 101,
      voiceSamples: 0,
    }]);
    assert.equal(policy.snapshot().pending.sampleCount, 0);

    const retainedVoice = new GapRetentionPolicy({
      maxNoiseSamples: 100,
      minVoiceEvidenceSamples: 1_600,
    });
    appendFrame(retainedVoice, 0, 1_600, {
      db: -40,
      evidence: 'continuing',
      endpointState: 'idle',
    });
    appendFrame(retainedVoice, 1_600, 1_601);
    assert.equal(retainedVoice.shedSlabs.length, 0);
  });

  it('bridges the pending gap into the next endpoint emission', () => {
    const policy = new GapRetentionPolicy({
      maxNoiseSamples: 100_000,
      minSpeechSamples: 1_600,
      minChunkSamples: 1_600,
    });
    appendFrame(policy, 0, 1_600, {
      db: -20,
      evidence: 'strong',
      decision: 'start_utterance',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 1_600, 3_200, {
      decision: 'finalize_endpoint',
      endpointState: 'idle',
    });
    appendFrame(policy, 3_200, 32_000);
    appendFrame(policy, 32_000, 33_600, {
      db: -20,
      evidence: 'strong',
      decision: 'start_utterance',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 33_600, 35_200, {
      db: -20,
      evidence: 'continuing',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 35_200, 36_800, {
      decision: 'finalize_endpoint',
      endpointState: 'idle',
    });

    assert.deepEqual(policy.chunks.map(chunk => [chunk.startSample, chunk.endSample]), [
      [0, 3_200],
      [3_200, 36_800],
    ]);
    assert.equal(policy.chunks[1].onsetSample, 33_600);
  });

  it('emits the complete endpoint block without trimming post-roll', () => {
    const policy = new GapRetentionPolicy({
      minSpeechSamples: 1_600,
      minChunkSamples: 1_600,
    });
    appendFrame(policy, 0, 1_600, {
      db: -20,
      evidence: 'strong',
      decision: 'start_utterance',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 1_600, 12_800, {
      decision: 'finalize_endpoint',
      endpointState: 'idle',
    });

    assert.equal(policy.chunks.length, 1);
    assert.equal(policy.chunks[0].startSample, 0);
    assert.equal(policy.chunks[0].endSample, 12_800);
    assert.equal(policy.chunks[0].finalizeSample, 12_800);
  });

  it('flush-offers-idle-pending: emits sub-minimum soft-onset audio without gates', () => {
    const policy = new GapRetentionPolicy();
    appendFrame(policy, 0, 2_400, {
      db: -70,
      evidence: 'continuing',
      endpointState: 'idle',
    });
    appendFrame(policy, 2_400, 8_000, { endpointState: 'idle' });

    assert.equal(policy.active, false);
    const outcome = policy.flush();

    assert.equal(outcome.offered, true);
    assert.equal(outcome.emitted, true);
    assert.equal(outcome.voiceSamples, 2_400);
    assert.equal(policy.chunks.length, 1);
    assert.equal(policy.chunks[0].reason, 'stop-flush');
    assert.equal(policy.chunks[0].startSample, 0);
    assert.equal(policy.chunks[0].endSample, 8_000);
  });

  it('flush emits the 001159 zero-voice pending audio without gates', () => {
    const policy = new GapRetentionPolicy();
    appendFrame(policy, 0, 75_040, { endpointState: 'idle' });

    const outcome = policy.flush();

    assert.equal(outcome.offered, true);
    assert.equal(outcome.emitted, true);
    assert.equal(outcome.voiceSamples, 0);
    assert.equal(policy.chunks.length, 1);
    assert.equal(policy.chunks[0].startSample, 0);
    assert.equal(policy.chunks[0].endSample, 75_040);
    assert.equal(policy.chunks[0].reason, 'stop-flush');
  });

  it('accounts a sub-250ms flush tail as a tail-floor drop', () => {
    const policy = new GapRetentionPolicy();
    appendFrame(policy, 0, 354, {
      db: -70,
      evidence: 'continuing',
      endpointState: 'idle',
    });

    const outcome = policy.flush();

    assert.equal(outcome.offered, true);
    assert.equal(outcome.emitted, false);
    assert.deepEqual(policy.tailFloorDrops, [{
      startSample: 0,
      endSample: 354,
      durationSamples: 354,
      durationMs: 22.125,
      voiceSamples: 354,
      voiceMs: 22.125,
      reason: 'tail-floor',
    }]);
    assert.equal(policy.chunks.length, 0);
    assert.equal(policy.snapshot().pending.sampleCount, 0);
  });

  it('emits a 300ms quiet flush tail even with zero voice evidence', () => {
    const policy = new GapRetentionPolicy();
    appendFrame(policy, 0, 4_800, { endpointState: 'idle' });

    const outcome = policy.flush();

    assert.equal(outcome.offered, true);
    assert.equal(outcome.emitted, true);
    assert.equal(outcome.voiceSamples, 0);
    assert.equal(policy.chunks.length, 1);
    assert.equal(policy.chunks[0].startSample, 0);
    assert.equal(policy.chunks[0].endSample, 4_800);
    assert.equal(policy.tailFloorDrops.length, 0);
  });

  it('holds below-minimum endpoint audio for the next eligible emission', () => {
    const policy = new GapRetentionPolicy();
    appendFrame(policy, 0, 2_400, {
      db: -70,
      evidence: 'continuing',
      decision: 'start_utterance',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 2_400, 3_200, {
      decision: 'finalize_endpoint',
      endpointState: 'idle',
    });

    assert.equal(policy.chunks.length, 0);
    assert.deepEqual(policy.events.find(event => event.type === 'endpoint-finalize-held'), {
      type: 'endpoint-finalize-held',
      endpoint_finalize_index: 1,
      start_sample: 0,
      end_sample: 3_200,
      duration_samples: 3_200,
      duration_ms: 200,
      voice_samples: 2_400,
      voice_ms: 150,
      reason: 'min-gates',
      emitted: false,
      split: false,
    });

    appendFrame(policy, 3_200, 10_000, { endpointState: 'idle' });
    appendFrame(policy, 10_000, 13_200, {
      db: -20,
      evidence: 'strong',
      decision: 'start_utterance',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 13_200, 17_000, {
      db: -20,
      evidence: 'continuing',
      endpointState: 'speechActive',
    });
    appendFrame(policy, 17_000, 18_000, {
      decision: 'finalize_endpoint',
      endpointState: 'idle',
    });

    assert.equal(policy.chunks.length, 1);
    assert.equal(policy.chunks[0].endpointFinalizeIndex, 2);
    assert.equal(policy.chunks[0].startSample, 0);
    assert.equal(policy.chunks[0].endSample, 18_000);
    assert.equal(policy.chunks[0].voiceSamples, 9_400);
  });

  it('flush emits a 379.875ms zero-voice remainder after a shed slab', () => {
    const policy = new GapRetentionPolicy({
      maxNoiseSamples: 96_000,
    });
    appendFrame(policy, 0, 96_160);
    appendFrame(policy, 96_160, 102_238);

    const outcome = policy.flush();

    assert.equal(outcome.offered, true);
    assert.equal(outcome.emitted, true);
    assert.deepEqual(
      policy.shedSlabs.map(slab => [slab.startSample, slab.endSample]),
      [[0, 96_160]],
    );
    assert.deepEqual(
      policy.chunks.map(chunk => [chunk.startSample, chunk.endSample]),
      [[96_160, 102_238]],
    );
    assert.equal(policy.chunks[0].voiceSamples, 0);
    assert.equal(policy.chunks[0].reason, 'stop-flush');
    assert.equal(
      policy.shedSlabs[0].endSample - policy.shedSlabs[0].startSample
        + policy.chunks[0].endSample - policy.chunks[0].startSample,
      102_238,
    );
  });

  it('retains a long active utterance until endpoint finalization', () => {
    const policy = new GapRetentionPolicy({
      minSpeechSamples: 300 * 16,
      minChunkSamples: 300 * 16,
    });
    const speechEndSample = 40 * 16_000;
    for (let startSample = 0; startSample < speechEndSample; startSample += 1_600) {
      appendFrame(policy, startSample, startSample + 1_600, {
        db: -20,
        evidence: startSample === 0 ? 'strong' : 'continuing',
        decision: startSample === 0 ? 'start_utterance' : 'none',
        endpointState: 'speechActive',
      });
    }

    assert.equal(policy.chunks.length, 0);
    assert.equal(policy.snapshot().pending.sampleCount, speechEndSample);

    appendFrame(policy, speechEndSample, speechEndSample + 1_600, {
      decision: 'finalize_endpoint',
      endpointState: 'idle',
    });

    assert.equal(policy.chunks.length, 1);
    assert.deepEqual(
      [policy.chunks[0].startSample, policy.chunks[0].endSample],
      [0, speechEndSample + 1_600],
    );
  });
});
