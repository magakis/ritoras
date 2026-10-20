import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

function makeHarness(events, options = {}) {
  return makeRecorderHarness({
    frameMs: 10,
    minChunkSamples: 0,
    minSpeechSamples: 4_800,
    onEvent: event => events.push(event),
    ...options,
  });
}

describe('VAD stop-flush minimum speech evidence', () => {
  it('emits a stop tail with 100 ms of speech evidence', () => {
    const events = [];
    const harness = makeHarness(events);
    for (let i = 0; i < 50; i++) harness.drive(-80);
    for (let i = 0; i < 10; i++) harness.drive(-20);
    for (let i = 0; i < 80; i++) harness.drive(-80);

    harness.flush();

    assert.ok(events.some(event => event.k === 'emit' && event.r === 'flush'));
    assert.equal(events.find(event => event.k === 'stop_flush')?.r, 'flush');
  });

  it('drops a stop tail with zero speech evidence', () => {
    const events = [];
    const harness = makeHarness(events);
    for (let i = 0; i < 50; i++) harness.drive(-80);
    for (let i = 0; i < 80; i++) harness.drive(-80);

    harness.flush();

    assert.equal(events.find(event => event.k === 'stop_flush')?.r, 'empty');
    assert.equal(events.some(event => event.k === 'emit' && event.r === 'flush'), false);
  });

  it('keeps the 300 ms minimum for endpoint emission', () => {
    const events = [];
    const harness = makeHarness(events, { endpointSilenceMs: 100 });
    for (let i = 0; i < 50; i++) harness.drive(-80);
    for (let i = 0; i < 10; i++) harness.drive(-20);
    for (let i = 0; i < 20; i++) harness.drive(-80);

    assert.equal(events.some(event => event.k === 'emit'), false);
    assert.ok(events.some(event => event.k === 'discard' && event.r === 'below_minimums'));
  });
});
