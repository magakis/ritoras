import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  StreamingEndpoint,
  StreamingEndpointEvidence as E,
  makeStreamingEndpointConfig,
} from '../lib/streaming-endpoint.mjs';
import { classifyEndPendingEvidence } from '../lib/recorder-sim.mjs';
import { VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB } from '../lib/vad-gate.mjs';

const samples = milliseconds => milliseconds * 16;

function feed(endpoint, evidence, durationMs) {
  return endpoint.process(evidence, samples(durationMs));
}

function startEndpoint(EndpointType = StreamingEndpoint, config = {}) {
  const endpoint = new EndpointType({ onsetMs: 10, endEvidenceMs: 100, ...config });
  assert.equal(feed(endpoint, E.strong, 10).type, 'startUtterance');
  return endpoint;
}

function enterEndPending(endpoint, silenceMs = 600) {
  assert.equal(feed(endpoint, E.silence, silenceMs).type, 'continueUtterance');
  assert.equal(endpoint.state, 'endPending');
}

function endPendingRewriteContext(endpoint) {
  return {
    accumulatedSilenceSamples: endpoint.accumulatedSilenceSamples,
    endpointSilenceSamples: endpoint.configuration.endpointSilenceSamples,
    ambiguousRescueSamples: endpoint.configuration.ambiguousRescueSamples,
    rescueAwareWindowsEnabled:
      endpoint.configuration.resumeToEndpointSilenceRatio !== undefined
      || endpoint.configuration.ambiguousRescueToEndpointSilenceRatio !== undefined,
  };
}

// This test-only fixture retains the pre-fix active-state behavior: ambiguous
// frames leave any previously accumulated silence untouched.
class PreFixAmbiguousEndpoint extends StreamingEndpoint {
  processActive(evidence, durationSamples) {
    if (evidence !== E.ambiguous) return super.processActive(evidence, durationSamples);
    this.utteranceDurationSamples += durationSamples;
    return this.continue();
  }
}

function replayInterspersedSoftSpeech(EndpointType) {
  const endpoint = startEndpoint(EndpointType, { endpointSilenceMs: 300 });
  for (let index = 0; index < 6; index += 1) {
    if (feed(endpoint, E.silence, 50).type === 'finalizeUtterance') {
      return { endpoint, finalized: true };
    }
    if (feed(endpoint, E.ambiguous, 5).type === 'finalizeUtterance') {
      return { endpoint, finalized: true };
    }
  }
  return { endpoint, finalized: false };
}

function preFixRecorderRewrite({
  endpointState,
  evidence,
  shortSpreadDb,
  dynamicsSpreadDb,
  flatSpreadDb,
}) {
  if (endpointState === 'endPending'
    && shortSpreadDb < flatSpreadDb
    && dynamicsSpreadDb < VAD_ADAPTIVE_END_PENDING_WIND_DISPERSION_DB
    && (evidence === E.continuing || evidence === E.ambiguous)) {
    return E.silence;
  }
  return evidence;
}

const lowSpread = {
  shortSpreadDb: 0,
  dynamicsSpreadDb: 0,
  flatSpreadDb: 2.5,
};

describe('VAD sentence-interruption fault injection', () => {
  it('does not bank pre-ambiguous silence during soft speech', () => {
    const preFix = replayInterspersedSoftSpeech(PreFixAmbiguousEndpoint);
    assert.equal(preFix.finalized, true);

    const fixed = replayInterspersedSoftSpeech(StreamingEndpoint);
    assert.equal(fixed.finalized, false);
    assert.equal(fixed.endpoint.state, 'speechActive');
    assert.equal(fixed.endpoint.accumulatedSilenceSamples, 0);
  });

  it('accepts proportional sweep parameters without changing legacy defaults or adding a maximum', () => {
    const defaults = makeStreamingEndpointConfig();
    assert.equal(defaults.resumeSamples, samples(120));
    assert.equal(defaults.ambiguousRescueSamples, samples(320));

    const proportional = makeStreamingEndpointConfig({
      endpointSilenceMs: 1000,
      resumeToEndpointSilenceRatio: 0.08,
      ambiguousRescueToEndpointSilenceRatio: 0.18,
    });
    assert.equal(proportional.resumeSamples, samples(80));
    assert.equal(proportional.ambiguousRescueSamples, samples(180));

    const aboveEndpointSilence = makeStreamingEndpointConfig({
      endpointSilenceMs: 1000,
      resumeToEndpointSilenceRatio: 2,
      ambiguousRescueToEndpointSilenceRatio: 2,
    });
    assert.equal(aboveEndpointSilence.resumeSamples, samples(2000));
    assert.equal(aboveEndpointSilence.ambiguousRescueSamples, samples(2000));
  });

  it('resumes soft onsets with and without the recorder rewrite in the path', () => {
    const candidateConfig = {
      endpointSilenceMs: 1000,
      resumeToEndpointSilenceRatio: 0.08,
      ambiguousRescueToEndpointSilenceRatio: 0.18,
    };

    const preFixDirect = startEndpoint(StreamingEndpoint, { endpointSilenceMs: 1000 });
    enterEndPending(preFixDirect, 900);
    assert.equal(feed(preFixDirect, E.continuing, 100).type, 'continueUtterance');
    assert.equal(preFixDirect.state, 'endPending');
    assert.equal(feed(preFixDirect, E.silence, 100).type, 'finalizeUtterance');

    const fixedDirect = startEndpoint(StreamingEndpoint, candidateConfig);
    enterEndPending(fixedDirect, 900);
    assert.equal(feed(fixedDirect, E.continuing, 100).type, 'continueUtterance');
    assert.equal(fixedDirect.state, 'speechActive');
    assert.notEqual(feed(fixedDirect, E.silence, 100).type, 'finalizeUtterance');

    const preFixRewritten = startEndpoint(StreamingEndpoint, { endpointSilenceMs: 1000 });
    enterEndPending(preFixRewritten, 900);
    const oldEvidence = preFixRecorderRewrite({
      endpointState: preFixRewritten.state,
      evidence: E.continuing,
      ...lowSpread,
    });
    assert.equal(oldEvidence, E.silence);
    assert.equal(feed(preFixRewritten, oldEvidence, 250).type, 'finalizeUtterance');

    const legacyDefaults = startEndpoint(StreamingEndpoint, { endpointSilenceMs: 1000 });
    enterEndPending(legacyDefaults, 900);
    assert.equal(classifyEndPendingEvidence({
      endpointState: legacyDefaults.state,
      evidence: E.continuing,
      ...lowSpread,
      ...endPendingRewriteContext(legacyDefaults),
    }), E.silence);

    const fixedRewritten = startEndpoint(StreamingEndpoint, candidateConfig);
    enterEndPending(fixedRewritten, 900);
    const softEvidence = classifyEndPendingEvidence({
      endpointState: fixedRewritten.state,
      evidence: E.continuing,
      ...lowSpread,
      ...endPendingRewriteContext(fixedRewritten),
    });
    assert.equal(softEvidence, E.ambiguous);
    assert.equal(classifyEndPendingEvidence({
      endpointState: fixedRewritten.state,
      evidence: E.ambiguous,
      ...lowSpread,
      ...endPendingRewriteContext(fixedRewritten),
    }), E.ambiguous);
    assert.equal(feed(fixedRewritten, softEvidence, 250).type, 'continueUtterance');
    assert.equal(fixedRewritten.state, 'speechActive');
    assert.notEqual(feed(fixedRewritten, E.silence, 100).type, 'finalizeUtterance');
  });

  it('never rewrites modulated soft evidence to silence while end-pending', () => {
    const endpoint = startEndpoint(StreamingEndpoint, { endpointSilenceMs: 1000 });
    enterEndPending(endpoint, 100);

    const evidence = classifyEndPendingEvidence({
      endpointState: endpoint.state,
      evidence: E.continuing,
      shortSpreadDb: 6,
      dynamicsSpreadDb: 6.1,
      flatSpreadDb: 5,
      ...endPendingRewriteContext(endpoint),
    });

    assert.equal(evidence, E.continuing);
  });
});
