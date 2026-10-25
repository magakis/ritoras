import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

function drive(harness, frames) {
  for (const frame of frames) harness.drive(frame);
}

describe('recorder chunk-splitter endpoint boundaries', () => {
  it('does not split at a long-duration boundary or a brief silence gap', () => {
    const events = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      endpointSilenceMs: 1_000,
      minChunkSamples: 300 * 16,
      minSpeechSamples: 300 * 16,
      gateConfig: { mode: 'static', staticRms: 0.025 },
      recorderConfig: { postRollSamples: 0 },
      onEvent: event => events.push(event),
    });
    const speech = Array.from({ length: 3_200 }, (_, index) => (
      index >= 2_950 && index < 2_960 ? -80 : -20
    ));
    drive(harness, speech);

    assert.ok(harness.accumulatorSamples > 30 * 16_000);
    assert.equal(harness.chunkCount, 0);
    assert.equal(events.some(event => event.k === 'emit' || event.k === 'split'), false);
    assert.equal(harness.sessionConfig.maxChunkMs, 0);

    for (let index = 0; index < 120 && harness.chunkCount === 0; index += 1) {
      harness.drive(-80);
    }

    const emissions = events.filter(event => event.k === 'emit');
    assert.equal(emissions.length, 1);
    assert.equal(emissions[0].r, 'endpoint');
    assert.equal(harness.endpoint.state, 'idle');
  });
});
