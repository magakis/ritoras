import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { SileroEvidenceProcessor, normalizeSileroEvidenceConfig } from '../lib/silero-evidence.mjs';
import { makeRecorderHarness } from '../lib/recorder-sim.mjs';

describe('Silero evidence mapping', () => {
  it('uses strong and continuing bands at their exact threshold boundaries', () => {
    const processor = new SileroEvidenceProcessor({ sileroSmoothingSteps: 1 });

    assert.equal(processor.consume(0.45).evidence, 'strong');
    assert.equal(processor.consume(0.30).evidence, 'continuing');
    assert.equal(processor.consume(0.299999).evidence, 'silence');
  });

  it('ramps in over available model steps instead of zero-padding the window', () => {
    const processor = new SileroEvidenceProcessor({ sileroSmoothingSteps: 5 });

    assert.deepEqual(processor.consume(0.60), {
      rawProbability: 0.60,
      smoothedProbability: 0.60,
      evidence: 'strong',
    });
    assert.deepEqual(processor.consume(0.40), {
      rawProbability: 0.40,
      smoothedProbability: 0.5,
      evidence: 'strong',
    });
  });

  it('keeps threshold-hover evidence stable while the moving average settles', () => {
    const processor = new SileroEvidenceProcessor({ sileroSmoothingSteps: 3 });
    const decisions = [0.43, 0.48, 0.48, 0.43, 0.48].map(value => processor.consume(value));

    assert.deepEqual(decisions.map(decision => decision.evidence), [
      'continuing', 'strong', 'strong', 'strong', 'strong',
    ]);
    assert.equal(decisions[0].smoothedProbability, 0.43);
    assert.ok(Math.abs(decisions[1].smoothedProbability - 0.455) < 1e-12);
    assert.ok(Math.abs(decisions[4].smoothedProbability - (1.39 / 3)) < 1e-12);
  });

  it('clamps stop threshold not to exceed start threshold', () => {
    const processor = new SileroEvidenceProcessor({
      sileroStartThreshold: 0.4,
      sileroStopThreshold: 0.8,
      sileroSmoothingSteps: 1,
    });

    assert.equal(processor.configuration.stopThreshold, 0.4);
    assert.equal(processor.consume(0.4).evidence, 'strong');
  });

  it('clamps threshold ranges and smoothing steps', () => {
    assert.deepEqual(normalizeSileroEvidenceConfig({
      sileroStartThreshold: -1,
      sileroStopThreshold: 2,
      sileroSmoothingSteps: 0,
    }), {
      startThreshold: 0.1,
      stopThreshold: 0.1,
      smoothingSteps: 1,
    });
    assert.equal(normalizeSileroEvidenceConfig({ sileroSmoothingSteps: 99 }).smoothingSteps, 15);
  });

  it('uses configured recorder thresholds when classifying Silero probabilities', () => {
    const harness = makeRecorderHarness({
      frameMs: 10,
      recorderConfig: {
        vadSource: 'silero',
        sileroStartThreshold: 0.80,
        sileroStopThreshold: 0.70,
        sileroSmoothingSteps: 1,
      },
    });

    const result = harness.drive(-24, 0.01, { sileroProbability: 0.50 });

    assert.equal(result.frameRecord.e, 'silence');
  });

  it('updates smoothing for every model step but returns only the latest decision', () => {
    const processor = new SileroEvidenceProcessor({ sileroSmoothingSteps: 3 });
    const latest = processor.consumeMany([0.5, 0.1, 0.8]);

    assert.deepEqual(latest, {
      rawProbability: 0.8,
      smoothedProbability: (0.5 + 0.1 + 0.8) / 3,
      evidence: 'strong',
    });
    assert.deepEqual(processor.consumeMany([0.1, 0.1]), {
      rawProbability: 0.1,
      smoothedProbability: (0.8 + 0.1 + 0.1) / 3,
      evidence: 'continuing',
    });
  });

  it('clears ramp-in history when reset', () => {
    const processor = new SileroEvidenceProcessor({ sileroSmoothingSteps: 3 });
    processor.consumeMany([0.9, 0.9]);
    processor.reset();

    assert.deepEqual(processor.consume(0.3), {
      rawProbability: 0.3,
      smoothedProbability: 0.3,
      evidence: 'continuing',
    });
  });

  it('mirrors Silero session knobs and probability fields in recorder telemetry', () => {
    const frames = [];
    const harness = makeRecorderHarness({
      frameMs: 10,
      recorderConfig: {
        vadSource: 'silero',
        sileroStartThreshold: 0.5,
        sileroStopThreshold: 0.35,
        sileroSmoothingSteps: 1,
      },
      onFrame: frame => frames.push(frame),
    });

    harness.drive(-24, 0.01, { sileroProbability: 0.8 });

    assert.equal(harness.sessionConfig.vadSource, 'silero');
    assert.equal(harness.sessionConfig.sileroStartThreshold, 0.5);
    assert.equal(harness.sessionConfig.sileroStopThreshold, 0.35);
    assert.equal(harness.sessionConfig.sileroSmoothingSteps, 1);
    assert.equal(frames[0].pr, 0.8);
    assert.equal(frames[0].pm, 0.8);
    assert.equal(frames[0].e, 'strong');
    assert.equal('th' in frames[0], false);
    assert.equal('ct' in frames[0], false);
    assert.equal('st' in frames[0], false);
  });

  it('preserves the fresh-session Silero emit chain after route reset', () => {
    const runSileroSession = resetRoute => {
      const frames = [];
      const events = [];
      const harness = makeRecorderHarness({
        frameMs: 10,
        endpointSilenceMs: 100,
        endpointConfig: {
          onsetMs: 20,
          endEvidenceMs: 30,
          resumeMs: 20,
          ambiguousRescueMs: 20,
        },
        recorderConfig: {
          vadSource: 'silero',
          sileroStartThreshold: 0.5,
          sileroStopThreshold: 0.3,
          sileroSmoothingSteps: 1,
        },
        onFrame: frame => frames.push(frame),
        onEvent: event => events.push(event),
      });

      if (resetRoute) {
        harness.resetAfterRouteChange();
        assert.equal(harness.effectiveVADSource, 'silero');
        assert.equal(harness.primingComplete, true);
      }
      // Route reset clears the moving average, so send fresh model-step outputs.
      for (let index = 0; index < 100; index += 1) {
        harness.drive(-24, 0.01, { sileroProbability: 0.9 });
      }
      const strongEvidence = {
        speechSamples: harness.speechSamples,
        accumulatorSamples: harness.accumulatorSamples,
      };

      // Leave enough frames for evidence decay and the configured endpoint-silence window.
      for (let index = 0; index < 20; index += 1) {
        harness.drive(-60, 0.01, { sileroProbability: 0.1 });
      }

      return {
        ...strongEvidence,
        sawEndPending: frames.some(frame => frame.es === 'endPending'),
        emitCount: events.filter(event => event.k === 'emit').length,
        primingDiscardCount: events.filter(event => event.r === 'priming_window').length,
      };
    };

    const freshSession = runSileroSession(false);
    const routeResetSession = runSileroSession(true);
    assert.deepEqual(freshSession, {
      speechSamples: 16_000,
      accumulatorSamples: 16_000,
      sawEndPending: true,
      emitCount: 1,
      primingDiscardCount: 0,
    });
    assert.deepEqual(routeResetSession, freshSession);
  });
});
