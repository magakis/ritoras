import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

const frameMs = 10;
const frameDuration = frameMs / 1000;

function makeSpeechActiveHarness(endpointSilenceMs, floorDb = -60) {
  const harness = makeRecorderHarness({
    frameMs,
    endpointSilenceMs,
    endpointConfig: {
      onsetMs: 70,
      endEvidenceMs: 100,
      endpointSilenceMs,
      resumeMs: 120,
      ambiguousRescueMs: 320,
    },
    minChunkSamples: 300 * 16,
    minSpeechSamples: 300 * 16,
    gateConfig: { adaptiveAbsoluteSpeechFloorDb: -40 },
  });
  harness.gate.floorDb = floorDb;
  harness.gate.adaptiveRefinementComplete = true;
  harness.gate.coldStartConverged = true;
  harness.gate.adaptivePrimed = true;
  harness.primingComplete = true;
  for (let index = 0; index < 40; index += 1) {
    harness.gate.process(floorDb, frameDuration);
  }
  harness.gate.updateFloorTracking = () => {};
  for (let index = 0; index < 40; index += 1) harness.drive(-20);
  return harness;
}

describe('chunk-splitter speech-free endpoint window', () => {
  it('waits for configured quiet after decaying modulated sub-silence speech', () => {
    const endpointSilenceMs = 700;
    const harness = makeSpeechActiveHarness(endpointSilenceMs);
    const speechShape = [-60, -62, -64, -66, -68, -67, -65, -63];
    let sawSpeechShapedTail = false;

    for (let index = 0; index < 80; index += 1) {
      const decayedDb = Math.floor(index / 20) * 0.5;
      const frameDb = speechShape[index % speechShape.length] - decayedDb;
      const frame = harness.drive(frameDb);

      assert.ok(frameDb < frame.output.silenceThresholdDb);
      if (frame.output.speechShaped) {
        sawSpeechShapedTail = true;
        assert.ok(frame.output.shortSpreadDb >= harness.gate.effectiveFlatSpreadDb);
        assert.equal(frame.output.evidence, 'silence');
        assert.equal(frame.endpointEvidence, 'continuing');
      } else {
        assert.equal(frame.output.evidence, 'silence');
      }
      assert.ok(harness.endpoint.accumulatedSilenceSamples < 100 * 16);
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.equal(sawSpeechShapedTail, true);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.equal(harness.chunkCount, 0);

    let trueQuietMs = 0;
    let firstBankedSilenceMs = null;
    let finalizedAtMs = null;
    for (let index = 0; index < 200; index += 1) {
      const frame = harness.drive(-80);
      trueQuietMs += frameMs;
      if (firstBankedSilenceMs === null && frame.endpointEvidence === 'silence') {
        firstBankedSilenceMs = trueQuietMs;
      }
      if (firstBankedSilenceMs !== null) assert.equal(frame.endpointEvidence, 'silence');
      if (frame.decision.type === 'finalizeUtterance') {
        finalizedAtMs = trueQuietMs;
        break;
      }
    }

    assert.ok(firstBankedSilenceMs !== null);
    assert.ok(firstBankedSilenceMs <= 110);
    assert.ok(finalizedAtMs !== null);
    assert.ok(finalizedAtMs >= endpointSilenceMs);
    assert.ok(Math.abs(
      finalizedAtMs - firstBankedSilenceMs + frameMs - endpointSilenceMs,
    ) <= frameMs);
    assert.equal(harness.chunkCount, 1);
  });

  it('resumes on a soft modulated onset after a pause instead of banking it', () => {
    const endpointSilenceMs = 1_200;
    const harness = makeSpeechActiveHarness(endpointSilenceMs);
    for (let index = 0; index < 80; index += 1) {
      const frame = harness.drive(-80);
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.equal(harness.endpoint.state, 'endPending');

    const softOnsetShape = [
      -80, -78, -76, -74, -72, -70, -68, -66, -64, -62,
      -60, -58, -60, -62, -64, -66, -68, -70, -72, -74,
      -76, -78, -80, -78, -76,
    ];
    let sawSpeechShapedOnset = false;
    for (let index = 0; index < 25; index += 1) {
      const frameDb = softOnsetShape[index];
      const frame = harness.drive(frameDb);
      assert.ok(frameDb < frame.output.silenceThresholdDb);
      if (frame.output.speechShaped) {
        sawSpeechShapedOnset = true;
        assert.notEqual(frame.endpointEvidence, 'silence');
      }
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }
    assert.equal(sawSpeechShapedOnset, true);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.equal(harness.endpoint.accumulatedSilenceSamples, 0);
    assert.equal(harness.chunkCount, 0);

    let trueQuietMs = 0;
    let finalized = false;
    for (let index = 0; index < 260; index += 1) {
      const frame = harness.drive(-80);
      trueQuietMs += frameMs;
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }

    assert.equal(finalized, true);
    assert.ok(trueQuietMs >= endpointSilenceMs);
    assert.equal(harness.chunkCount, 1);
  });

  it('banks flat ambient noise and finalizes at the configured window across levels', () => {
    const endpointSilenceMs = 600;
    for (const ambientDb of [-65, -55, -45]) {
      const harness = makeRecorderHarness({
        frameMs,
        endpointSilenceMs,
        endpointConfig: {
          onsetMs: 70,
          endEvidenceMs: 100,
          endpointSilenceMs,
          resumeMs: 120,
          ambiguousRescueMs: 320,
        },
        minChunkSamples: 300 * 16,
        minSpeechSamples: 300 * 16,
        gateConfig: { adaptiveAbsoluteSpeechFloorDb: -40 },
      });
      let previousFloorDb = harness.gate.snapshot.floorDb;
      for (let index = 0; index < 500; index += 1) {
        harness.drive(ambientDb);
        const floorDb = harness.gate.snapshot.floorDb;
        assert.ok(floorDb - previousFloorDb <= 12 * frameDuration + 1e-9);
        previousFloorDb = floorDb;
      }

      assert.equal(harness.endpoint.state, 'idle');
      assert.ok(Math.abs(harness.gate.snapshot.floorDb - ambientDb) < 1);

      for (let index = 0; index < 40; index += 1) harness.drive(-20);
      assert.equal(harness.endpoint.state, 'speechActive');

      let ambientMs = 0;
      let firstBankedSilenceMs = null;
      let finalizedAtMs = null;
      for (let index = 0; index < 200; index += 1) {
        const frame = harness.drive(ambientDb);
        ambientMs += frameMs;
        if (firstBankedSilenceMs === null && frame.endpointEvidence === 'silence') {
          firstBankedSilenceMs = ambientMs;
          assert.equal(frame.output.speechShaped, false);
        }
        if (frame.decision.type === 'finalizeUtterance') {
          finalizedAtMs = ambientMs;
          break;
        }
      }

      assert.ok(firstBankedSilenceMs !== null, `ambient ${ambientDb} dBFS never banked silence`);
      assert.ok(finalizedAtMs !== null, `ambient ${ambientDb} dBFS never finalized`);
      assert.ok(finalizedAtMs >= endpointSilenceMs);
      assert.ok(Math.abs(
        finalizedAtMs - firstBankedSilenceMs + frameMs - endpointSilenceMs,
      ) <= frameMs);
      assert.equal(harness.chunkCount, 1);
    }
  });

  it('keeps modulated static-mode tails out of the silence window without floor tracking', () => {
    const endpointSilenceMs = 500;
    const harness = makeRecorderHarness({
      frameMs,
      endpointSilenceMs,
      endpointConfig: {
        onsetMs: 70,
        endEvidenceMs: 100,
        endpointSilenceMs,
        resumeMs: 120,
        ambiguousRescueMs: 320,
      },
      gateConfig: { mode: 'static', staticRms: 0.025 },
    });
    for (let index = 0; index < 40; index += 1) harness.drive(-20);

    const speechTail = [-40, -42, -44, -46, -48, -47, -45, -43];
    let sawSpeechShapedTail = false;
    for (let index = 0; index < 40; index += 1) {
      const frame = harness.drive(speechTail[index % speechTail.length]);
      sawSpeechShapedTail ||= frame.output.speechShaped;
      if (frame.output.speechShaped) {
        assert.equal(frame.output.evidence, 'silence');
        assert.equal(frame.endpointEvidence, 'continuing');
      }
      assert.notEqual(frame.decision.type, 'finalizeUtterance');
    }

    assert.equal(sawSpeechShapedTail, true);
    assert.equal(harness.endpoint.state, 'speechActive');
    assert.equal(harness.gate.snapshot.floorDb, null);
    let finalized = false;
    for (let index = 0; index < 100; index += 1) {
      const frame = harness.drive(-80);
      if (frame.decision.type === 'finalizeUtterance') {
        finalized = true;
        break;
      }
    }
    assert.equal(finalized, true);
    assert.equal(harness.chunkCount, 1);
  });
});
