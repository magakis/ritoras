import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  StreamingEndpoint,
  StreamingEndpointEvidence as E,
} from '../lib/streaming-endpoint.mjs';
import {
  VADThresholdGate,
  makeVadGateConfig,
} from '../lib/vad-gate.mjs';

const samples = milliseconds => milliseconds * 16;

function feed(endpoint, evidence, durationMs) {
  return endpoint.process(evidence, samples(durationMs));
}

function startEndpoint() {
  const endpoint = new StreamingEndpoint();
  for (let i = 0; i < 7; i++) feed(endpoint, E.strong, 10);
  assert.strictEqual(endpoint.state, 'speechActive');
  return endpoint;
}

describe('StreamingEndpoint', () => {
  it('does not clip a quiet trailing word before 700ms of real silence', () => {
    const endpoint = startEndpoint();
    feed(endpoint, E.continuing, 40);
    feed(endpoint, E.silence, 100);
    feed(endpoint, E.continuing, 10);
    feed(endpoint, E.silence, 599);
    assert.strictEqual(endpoint.state, 'endPending');
    assert.strictEqual(feed(endpoint, E.silence, 1).type, 'finalizeUtterance');
    assert.strictEqual(endpoint.state, 'idle');
  });

  it('speech frames never advance the pending-end silence timer', () => {
    const endpoint = startEndpoint();
    feed(endpoint, E.silence, 600);
    assert.strictEqual(endpoint.state, 'endPending');
    assert.strictEqual(endpoint.accumulatedSilenceSamples, samples(600));

    feed(endpoint, E.continuing, 50);
    assert.strictEqual(endpoint.accumulatedSilenceSamples, samples(600));
    assert.strictEqual(feed(endpoint, E.silence, 50).type, 'continueUtterance');
    assert.strictEqual(endpoint.accumulatedSilenceSamples, samples(650));
    assert.strictEqual(feed(endpoint, E.silence, 50).type, 'finalizeUtterance');
  });

  it('intermittent sub-threshold speech bursts do not finalize mid-burst', () => {
    const endpoint = startEndpoint();
    feed(endpoint, E.silence, 300);
    assert.strictEqual(endpoint.state, 'endPending');

    for (let i = 0; i < 8; i++) {
      const speechDecision = feed(endpoint, E.continuing, 80);
      assert.notStrictEqual(speechDecision.type, 'finalizeUtterance');
      const silenceDecision = feed(endpoint, E.silence, 40);
      assert.notStrictEqual(silenceDecision.type, 'finalizeUtterance');
    }
    assert.strictEqual(endpoint.accumulatedSilenceSamples, samples(620));

    assert.notStrictEqual(feed(endpoint, E.continuing, 80).type, 'finalizeUtterance');
    assert.strictEqual(feed(endpoint, E.silence, 80).type, 'finalizeUtterance');
  });

  it('ignores a short wind burst but cancels on 120ms of resume evidence', () => {
    const wind = startEndpoint();
    feed(wind, E.silence, 100);
    feed(wind, E.strong, 10);
    feed(wind, E.silence, 600);
    assert.strictEqual(wind.state, 'idle');

    const resumed = startEndpoint();
    feed(resumed, E.silence, 100);
    feed(resumed, E.strong, 10);
    const decision = feed(resumed, E.continuing, 110);
    assert.strictEqual(decision.type, 'continueUtterance');
    assert.strictEqual(resumed.state, 'speechActive');
    assert.strictEqual(resumed.accumulatedSilenceSamples, 0);
  });

  it('never opens an utterance for repeated sub-70ms wind impulses', () => {
    const endpoint = new StreamingEndpoint();
    for (let i = 0; i < 20; i++) {
      feed(endpoint, E.strong, 20);
      feed(endpoint, E.silence, 20);
      assert.notStrictEqual(endpoint.state, 'speechActive');
    }
    assert.strictEqual(endpoint.state, 'idle');
  });

  it('restarts silence timing after resumed speech cancels end-pending', () => {
    const endpoint = startEndpoint();
    feed(endpoint, E.silence, 100);
    feed(endpoint, E.continuing, 120);
    assert.strictEqual(endpoint.state, 'speechActive');
    feed(endpoint, E.silence, 100);
    feed(endpoint, E.silence, 599);
    assert.strictEqual(endpoint.state, 'endPending');
    assert.strictEqual(feed(endpoint, E.silence, 1).type, 'finalizeUtterance');
  });

  it('pauses rather than resets the silence counter for ambiguous frames', () => {
    const endpoint = startEndpoint();
    feed(endpoint, E.silence, 100);
    feed(endpoint, E.ambiguous, 500);
    feed(endpoint, E.silence, 599);
    assert.strictEqual(endpoint.state, 'endPending');
    assert.strictEqual(feed(endpoint, E.silence, 1).type, 'finalizeUtterance');
  });

  it('stabilizes gradually rising background noise before endpoint classification', () => {
    const gate = new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
    const initialFloor = gate.snapshot.floorDb;
    for (let i = 0; i < 50; i++) {
      const frameDb = -70 + i * 0.1;
      gate.process(frameDb, 0.1);
      gate.updateFloorIfIdle(frameDb, 0.1);
    }

    const ambientDb = -65.1;
    assert.ok(gate.snapshot.floorDb > initialFloor);
    assert.ok(Math.abs(gate.snapshot.floorDb - ambientDb) <= 3);
    const stabilized = gate.process(ambientDb, 0.1);
    assert.ok([E.silence, E.ambiguous].includes(stabilized.evidence));

    const endpoint = new StreamingEndpoint();
    assert.strictEqual(endpoint.process(stabilized.evidence, samples(100)).type, 'none');
    assert.strictEqual(endpoint.state, 'idle');
  });

  it('keeps the floor fixed through active and end-pending states', () => {
    const gate = new VADThresholdGate(makeVadGateConfig({ mode: 'adaptive' }));
    const endpoint = new StreamingEndpoint();
    for (let i = 0; i < 50; i++) {
      gate.process(-50, 0.1);
      gate.updateFloorIfIdle(-50, 0.1, true);
    }
    for (let i = 0; i < 7; i++) {
      const output = gate.process(-30, 0.01);
      endpoint.process(output.evidence, samples(10));
    }
    const initialFloor = gate.snapshot.floorDb;
    const quiet = gate.process(-60, 0.1);
    endpoint.process(quiet.evidence, samples(100));
    assert.strictEqual(endpoint.state, 'endPending');
    assert.strictEqual(gate.snapshot.floorDb, initialFloor);
    for (let i = 0; i < 5; i++) {
      const output = gate.process(-60, 0.1);
      endpoint.process(output.evidence, samples(100));
    }
    assert.strictEqual(gate.snapshot.floorDb, initialFloor);
    const finalOutput = gate.process(-60, 0.1);
    assert.strictEqual(endpoint.process(finalOutput.evidence, samples(100)).type, 'finalizeUtterance');
    assert.strictEqual(endpoint.state, 'idle');

    for (let i = 0; i < 31; i++) {
      gate.process(-60, 0.1);
      gate.updateFloorIfIdle(-60, 0.1, true);
    }
    assert.ok(gate.snapshot.floorDb < initialFloor);
  });

  it('requires about 70ms of strong onset and requests 250ms of pre-roll', () => {
    const endpoint = new StreamingEndpoint();
    for (let i = 0; i < 6; i++) {
      assert.strictEqual(feed(endpoint, E.strong, 10).type, 'none');
    }
    const decision = feed(endpoint, E.strong, 10);
    assert.strictEqual(decision.type, 'startUtterance');
    assert.strictEqual(decision.withPreRollSamples, 4000);
  });

  it('finalizes at about 700ms of confirmed silence', () => {
    const endpoint = startEndpoint();
    feed(endpoint, E.silence, 100);
    assert.strictEqual(feed(endpoint, E.silence, 599).type, 'continueUtterance');
    assert.strictEqual(feed(endpoint, E.silence, 1).type, 'finalizeUtterance');
  });
});
