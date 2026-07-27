import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { fusedPool } from '../lib/fused-pool.mjs';

describe('fusedPool', () => {
  // ──────────────────────────────────────────────
  // Behavior-preservation (no KenLM)
  // ──────────────────────────────────────────────
  it('with null kenlmScorer, output equals input pool minus dedup', () => {
    const pool = [
      { text: 'both', score: 0.61, source: 'symspell' },
      { text: 'bath', score: 0.65, source: 'symspell' },
      { text: 'boat', score: 0.40, source: 'symspell' },
    ];

    const result = fusedPool({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: null,
    });

    // No KenLM → scores unchanged, no Apple entries → no boost.
    assert.strictEqual(result.length, pool.length);
    for (const s of result) {
      const original = pool.find(p => p.text === s.text);
      assert.ok(original, `result contains "${s.text}" not in input`);
      assert.strictEqual(s.score, original.score, `score for "${s.text}" unchanged`);
      assert.strictEqual(s.source, original.source, `source for "${s.text}" unchanged`);
    }
  });

  // ──────────────────────────────────────────────
  // Apple boost fires
  // ──────────────────────────────────────────────
  it('apple boost fires when symspellMaxNonInput < 0.7', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },     // verbatim — excluded from max calc
      { text: 'bath', score: 0.50, source: 'symspell' },     // max non-input symspell = 0.5
      { text: 'both', score: 0.60, source: 'apple' },        // Apple — should be boosted
    ];

    const result = fusedPool({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: null,
    });

    const apple = result.find(s => s.text === 'both');
    assert.ok(apple, 'apple suggestion "both" is in result');
    // 0.6 * 1.2 = 0.72, capped at 1.0
    assert.strictEqual(apple.score, 0.72);
  });

  // ──────────────────────────────────────────────
  // Apple boost does NOT fire
  // ──────────────────────────────────────────────
  it('apple boost does not fire when symspellMaxNonInput >= 0.7', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },     // verbatim
      { text: 'bath', score: 0.75, source: 'symspell' },     // max non-input = 0.75 >= 0.7
      { text: 'both', score: 0.60, source: 'apple' },        // Apple — NOT boosted
    ];

    const result = fusedPool({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: null,
    });

    const apple = result.find(s => s.text === 'both');
    assert.ok(apple, 'apple suggestion "both" is in result');
    assert.strictEqual(apple.score, 0.60, 'apple score unchanged (boost condition not met)');
  });

  // ──────────────────────────────────────────────
  // KenLM blend formula
  // ──────────────────────────────────────────────
  it('kenlm blend: (1-w)*sym + w*normalized', () => {
    const pool = [
      { text: 'both', score: 0.61, source: 'symspell' },
      { text: 'bath', score: 0.65, source: 'symspell' },
    ];

    // Mock scorer: "both" gets high logProb, "bath" gets low.
    const mockScorer = (candidate) => {
      if (candidate === 'both') return -2.0;
      if (candidate === 'bath') return -8.0;
      return -10.0;
    };

    const result = fusedPool({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: mockScorer,
      blendWeight: 0.5,
    });

    // normalized(both) = (-2.0 - (-8.0)) / ((-2.0) - (-8.0)) = 6.0/6.0 = 1.0
    // normalized(bath) = (-8.0 - (-8.0)) / 6.0 = 0.0
    // blended(both)   = 0.5 * 0.61 + 0.5 * 1.0 = 0.805
    // blended(bath)   = 0.5 * 0.65 + 0.5 * 0.0 = 0.325
    const both = result.find(s => s.text === 'both');
    const bath = result.find(s => s.text === 'bath');
    assert.ok(both, '"both" in result');
    assert.ok(bath, '"bath" in result');

    // Floating point — use approximate equality.
    assert.ok(Math.abs(both.score - 0.805) < 0.001, `"both" score ${both.score} ≈ 0.805`);
    assert.ok(Math.abs(bath.score - 0.325) < 0.001, `"bath" score ${bath.score} ≈ 0.325`);

    // "both" wins after fusion
    assert.ok(both.score > bath.score, '"both" outscores "bath" after KenLM blend');
  });

  // ──────────────────────────────────────────────
  // Min-max single-candidate edge case
  // ──────────────────────────────────────────────
  it('single candidate: min==max → range defaults to 0.001 → normalized=0.0', () => {
    const pool = [
      { text: 'both', score: 0.61, source: 'symspell' },
    ];

    // Mock scorer returns same logProb for the one candidate.
    const mockScorer = () => -5.0;

    const result = fusedPool({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: mockScorer,
      blendWeight: 0.5,
    });

    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].text, 'both');

    // min==max → range = max(0, 0.001) = 0.001
    // normalized = (logProb - minLog) / 0.001 = 0.0 / 0.001 = 0.0
    // blended = 0.5 * 0.61 + 0.5 * 0.0 = 0.305
    assert.ok(Math.abs(result[0].score - 0.305) < 0.001,
      `score ${result[0].score} ≈ 0.305 when single candidate`);
  });

  // ──────────────────────────────────────────────
  // Dedup keeps max score
  // ──────────────────────────────────────────────
  it('dedup keeps highest score for duplicate text', () => {
    const pool = [
      { text: 'both', score: 0.61, source: 'symspell' },
      { text: 'both', score: 0.85, source: 'apple' },    // same text, higher score
      { text: 'bath', score: 0.65, source: 'symspell' },
    ];

    const result = fusedPool({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: null,
    });

    const both = result.find(s => s.text === 'both');
    assert.ok(both, '"both" is in result');
    // symspellMaxNonInput = max(0.61, 0.65) = 0.65 < 0.7 → Apple boost fires
    // 0.85 * 1.2 = 1.02 → capped at 1.0
    assert.strictEqual(both.score, 1.0, 'apple "both" boosted to 1.0, dedup keeps it');
    assert.strictEqual(result.length, 2, 'deduped to 2 unique entries');
  });
});
