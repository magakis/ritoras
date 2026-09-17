import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { VADHighPassFilter } from '../lib/vad-hpf.mjs';
import { VADThresholdGate, dbFromRms } from '../lib/vad-gate.mjs';

const sampleRate = 16000;

function sineFrame(frequency, amplitude = 1, length = 1600, phase = 0) {
  return Array.from(
    { length },
    (_, index) => amplitude * Math.sin((2 * Math.PI * frequency * index) / sampleRate + phase),
  );
}

function rms(samples) {
  return Math.sqrt(samples.reduce((sum, sample) => sum + sample * sample, 0) / samples.length);
}

describe('VADHighPassFilter', () => {
  it('strongly attenuates DC and sub-60Hz energy while preserving 300Hz energy', () => {
    const dc = new VADHighPassFilter();
    const dcOutput = dc.process(Array(1600).fill(0.5));
    assert.ok(rms(dcOutput) < 1e-6);

    const low = new VADHighPassFilter();
    const lowInput = sineFrame(30);
    const lowRatio = rms(low.process(lowInput)) / rms(lowInput);
    assert.ok(lowRatio < 0.5, `30Hz ratio ${lowRatio}`);

    const high = new VADHighPassFilter();
    const highInput = sineFrame(300);
    const highRatio = rms(high.process(highInput)) / rms(highInput);
    assert.ok(highRatio > 0.9, `300Hz ratio ${highRatio}`);
  });

  it('preserves state across frames exactly as one concatenated pass', () => {
    const first = sineFrame(180, 0.4, 777);
    const second = sineFrame(180, 0.4, 923, 0.3);
    const byFrame = new VADHighPassFilter();
    const splitOutput = [...byFrame.process(first), ...byFrame.process(second)];
    const onePass = new VADHighPassFilter().process([...first, ...second]);

    assert.equal(splitOutput.length, onePass.length);
    splitOutput.forEach((value, index) => {
      assert.ok(Math.abs(value - onePass[index]) < 1e-12, `sample ${index}`);
    });
  });

  it('seeds startup state from the first sample without a transient spike', () => {
    const input = Array(1600).fill(0.5);
    const filter = new VADHighPassFilter();
    const output = filter.process(input);
    assert.equal(output[0], 0);
    assert.ok(Math.max(...output.map(Math.abs)) < 1e-6);
  });

  it('does not mutate the PCM input used for the upload path', () => {
    const input = sineFrame(220, 0.25);
    const original = [...input];
    new VADHighPassFilter().process(input);
    assert.deepEqual(input, original);
  });

  it('turns low-frequency wind from speech evidence into silence', () => {
    const wind = sineFrame(30, 0.04);
    const filtered = new VADHighPassFilter().process(wind);
    const rawGate = new VADThresholdGate({ mode: 'static', staticRms: 0.025 });
    const filteredGate = new VADThresholdGate({ mode: 'static', staticRms: 0.025 });
    assert.equal(rawGate.process(dbFromRms(rms(wind)), 0.1).evidence, 'strong');

    const evidence = filteredGate.process(dbFromRms(rms(filtered)), 0.1).evidence;
    assert.ok(evidence === 'silence' || evidence === 'ambiguous', evidence);
  });

  it('keeps a 90Hz deep-voice signal at continuing evidence or stronger', () => {
    const voice = sineFrame(90, 0.05);
    const filtered = new VADHighPassFilter().process(voice);
    const gate = new VADThresholdGate({ mode: 'static', staticRms: 0.025 });
    const evidence = gate.process(dbFromRms(rms(filtered)), 0.1).evidence;
    assert.ok(evidence === 'continuing' || evidence === 'strong', evidence);
  });
});
