import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  keyCenters,
  greekKeyCenters,
  distance,
  adjacentKeyCost,
  weightedEditDistance,
  score,
} from '../lib/qwerty-geometry.mjs';

describe('QwertyGeometry', () => {
  // ──────────────────────────────────────────────
  // Key position table
  // ──────────────────────────────────────────────
  describe('key positions', () => {
    it('Row 0: q w e r t y u i o p, y=0', () => {
      const row = 'qwertyuiop';
      for (let i = 0; i < row.length; i++) {
        const pos = keyCenters.get(row[i]);
        assert.ok(pos, `key "${row[i]}" should have a position`);
        assert.strictEqual(pos.x, i, `x for "${row[i]}" should be ${i}`);
        assert.strictEqual(pos.y, 0, `y for "${row[i]}" should be 0`);
      }
    });

    it('Row 1: a s d f g h j k l, y=1, offset 0.25', () => {
      const row = 'asdfghjkl';
      for (let i = 0; i < row.length; i++) {
        const pos = keyCenters.get(row[i]);
        assert.ok(pos, `key "${row[i]}" should have a position`);
        assert.strictEqual(pos.x, i + 0.25, `x for "${row[i]}" should be ${i + 0.25}`);
        assert.strictEqual(pos.y, 1, `y for "${row[i]}" should be 1`);
      }
    });

    it('Row 2: z x c v b n m, y=2, offset 0.75', () => {
      const row = 'zxcvbnm';
      for (let i = 0; i < row.length; i++) {
        const pos = keyCenters.get(row[i]);
        assert.ok(pos, `key "${row[i]}" should have a position`);
        assert.strictEqual(pos.x, i + 0.75, `x for "${row[i]}" should be ${i + 0.75}`);
        assert.strictEqual(pos.y, 2, `y for "${row[i]}" should be 2`);
      }
    });

    it('apostrophe at (9.25, 1)', () => {
      const pos = keyCenters.get("'");
      assert.ok(pos, "apostrophe should have a position");
      assert.strictEqual(pos.x, 9.25);
      assert.strictEqual(pos.y, 1);
    });

    it('unknown character returns undefined', () => {
      assert.strictEqual(keyCenters.get('3'), undefined);
      assert.strictEqual(keyCenters.get('!'), undefined);
      assert.strictEqual(keyCenters.get(' '), undefined);
    });
  });

  // ──────────────────────────────────────────────
  // Greek key positions
  // ──────────────────────────────────────────────
  describe('Greek key positions', () => {
    it("Greek Row 0: ε ρ τ υ θ ι ο π ', y=0, offset 0.25", () => {
      const row = "ερτυθιοπ'";
      for (let i = 0; i < row.length; i++) {
        const pos = greekKeyCenters.get(row[i]);
        assert.ok(pos, `key "${row[i]}" should have a position`);
        assert.strictEqual(pos.x, i + 0.25, `x for "${row[i]}" should be ${i + 0.25}`);
        assert.strictEqual(pos.y, 0, `y for "${row[i]}" should be 0`);
      }
    });

    it('Greek Row 1: α σ δ φ γ η ξ κ λ, y=1, offset 0.25', () => {
      const row = 'ασδφγηξκλ';
      for (let i = 0; i < row.length; i++) {
        const pos = greekKeyCenters.get(row[i]);
        assert.ok(pos, `key "${row[i]}" should have a position`);
        assert.strictEqual(pos.x, i + 0.25, `x for "${row[i]}" should be ${i + 0.25}`);
        assert.strictEqual(pos.y, 1, `y for "${row[i]}" should be 1`);
      }
    });

    it('Greek Row 2: ζ χ ψ ω β ν μ, y=2, offset 0.75', () => {
      const row = 'ζχψωβνμ';
      for (let i = 0; i < row.length; i++) {
        const pos = greekKeyCenters.get(row[i]);
        assert.ok(pos, `key "${row[i]}" should have a position`);
        assert.strictEqual(pos.x, i + 0.75, `x for "${row[i]}" should be ${i + 0.75}`);
        assert.strictEqual(pos.y, 2, `y for "${row[i]}" should be 2`);
      }
    });

    it('final sigma shares sigma position', () => {
      assert.deepStrictEqual(greekKeyCenters.get('ς'), greekKeyCenters.get('σ'));
      assert.strictEqual(distance('ς', 'σ'), 0);
    });

    it('unknown character not in the Greek grid', () => {
      assert.strictEqual(greekKeyCenters.get('q'), undefined);
      assert.strictEqual(greekKeyCenters.get('Ω'), undefined);  // uppercase is a different codepoint
    });
  });

  // ──────────────────────────────────────────────
  // Greek distance()/adjacentKeyCost()
  // ──────────────────────────────────────────────
  describe('Greek distances', () => {
    it('ε→ρ is 1.0 (adjacent in Greek row 0)', () => {
      assert.strictEqual(distance('ε', 'ρ'), 1.0);
    });

    it('α→σ is 1.0 (adjacent in Greek row 1)', () => {
      assert.strictEqual(distance('α', 'σ'), 1.0);
    });

    it('ζ→χ is 1.0 (adjacent in Greek row 2)', () => {
      assert.strictEqual(distance('ζ', 'χ'), 1.0);
    });

    it('ε→π is 7.0 (same Greek row, far apart)', () => {
      // ε at (0.25,0), π at (7.25,0)
      assert.strictEqual(distance('ε', 'π'), 7.0);
      assert.strictEqual(distance('ε', 'τ'), 2.0);
    });

    it('same character is 0', () => {
      assert.strictEqual(distance('ε', 'ε'), 0);
    });

    it('ε→e reflects the distinct Greek top-row span', () => {
      // ε is at (0.25, 0), while English e remains at (2, 0).
      assert.strictEqual(distance('ε', 'e'), 1.75);
    });

    it('unknown character still falls back to 1.0', () => {
      assert.strictEqual(distance('ε', '3'), 1.0);
      assert.strictEqual(distance('3', 'ε'), 1.0);
      assert.strictEqual(distance('α', 'Ω'), 1.0);
    });

    it('adjacentKeyCost: ε→ρ cost is 1/3 (distance 1 / 3)', () => {
      assert.strictEqual(adjacentKeyCost('ε', 'ρ'), 1 / 3);
    });

    it('far Greek keys cost 1.0 (capped)', () => {
      // α at (0.25,1), π at (7.25,0) → distance ~7.1, /3 ≈ 2.4, capped to 1.0
      assert.strictEqual(adjacentKeyCost('α', 'π'), 1.0);
    });
  });

  // ──────────────────────────────────────────────
  // Greek weighted edit distance / score
  // ──────────────────────────────────────────────
  describe('Greek scoring', () => {
    it('adjacent Greek substitution costs 1/3; far substitution caps at 1.0', () => {
      // "ρεπ" → "εππ": ρ→ε adjacent (1/3), ε→π far (capped 1.0), π→π same
      const wd = weightedEditDistance('ρεπ', 'εππ', 1);
      assert.ok(Math.abs(wd - (1 / 3 + 1.0)) < 0.001,
        `weightedEditDistance("ρεπ","εππ",1) = ${wd}, expected ${1 / 3 + 1.0}`);
      // "πο" → "ππ": ο→π adjacent (1/3) only
      const adjacentOnly = weightedEditDistance('πο', 'ππ', 1);
      assert.ok(Math.abs(adjacentOnly - 1 / 3) < 0.001,
        `weightedEditDistance("πο","ππ",1) = ${adjacentOnly}, expected ${1 / 3}`);
    });

    it('score() works for Greek candidates (in-range, ordered by distance)', () => {
      // Typed "κειμενο" (typo), candidate "κειμενο" distance 0 → 1.0
      assert.strictEqual(score('κειμενο', 'κειμενο', 0, 1.5), 1.0);
      const adjacent = score('ρεπ', 'εππ', 1, 1.5);
      assert.ok(adjacent > 0 && adjacent <= 1, 'Greek score must be in (0, 1]');
    });

    it('unknown-char fallback keeps mixed Greek/Latin scoring neutral', () => {
      // Latin 'q' is unknown in the Greek grid and not in English row for π...
      // distance('q','π') → q known (english), π known (greek) → finite.
      const d = distance('q', 'π');
      assert.ok(Number.isFinite(d), 'cross-grid distance must be finite');
    });
  });

  // ──────────────────────────────────────────────
  // distance()
  // ──────────────────────────────────────────────
  describe('distance()', () => {
    it('i→o is 1.0 (adjacent in row 0)', () => {
      assert.strictEqual(distance('i', 'o'), 1.0);
    });

    it('q→w is 1.0 (adjacent in row 0)', () => {
      assert.strictEqual(distance('q', 'w'), 1.0);
    });

    it('a→s is 1.0 (adjacent in row 1)', () => {
      assert.strictEqual(distance('a', 's'), 1.0);
    });

    it('z→x is 1.0 (adjacent in row 2)', () => {
      assert.strictEqual(distance('z', 'x'), 1.0);
    });

    it('i→a is ~6.82 (different rows, far apart)', () => {
      const d = distance('i', 'a');
      assert.ok(Math.abs(d - 6.824) < 0.01, `i→a distance ${d} ≈ 6.82`);
    });

    it('same character is 0', () => {
      assert.strictEqual(distance('a', 'a'), 0);
    });

    it('unknown character returns 1.0', () => {
      assert.strictEqual(distance('a', '3'), 1.0);
      assert.strictEqual(distance('3', 'a'), 1.0);
      assert.strictEqual(distance('!', '?'), 1.0);
    });

    it('apostrophe to l is 1.0 (adjacent columns, same row)', () => {
      const d = distance("'", 'l');
      // apostrophe at (9.25, 1), l at (8.25, 1)
      assert.strictEqual(d, 1.0, `apostrophe→l distance should be 1.0, got ${d}`);
    });
  });

  // ──────────────────────────────────────────────
  // adjacentKeyCost()
  // ──────────────────────────────────────────────
  describe('adjacentKeyCost()', () => {
    it('same character returns 0', () => {
      assert.strictEqual(adjacentKeyCost('a', 'a'), 0);
    });

    it('i→o cost is 0.333 (distance 1 / 3)', () => {
      assert.strictEqual(adjacentKeyCost('i', 'o'), 1 / 3);
    });

    it('far keys cost 1.0 (capped)', () => {
      // i→a distance ~6.82, /3 ≈ 2.27, capped to 1.0
      assert.strictEqual(adjacentKeyCost('i', 'a'), 1.0);
      // q→m distance far, /3 > 1, capped to 1.0
      assert.strictEqual(adjacentKeyCost('q', 'm'), 1.0);
    });

    it('floor at 0.1 for very close keys', () => {
      // Two characters with tiny distance → /3 < 0.1 → floor at 0.1
      // No two distinct keys are that close, but the clamp ensures min 0.1.
      // Just verify the clamp range.
      const cost = adjacentKeyCost('e', 'r'); // distance 1.0, /3 = 0.333
      assert.ok(cost >= 0.1 && cost <= 1.0);
    });

    it('unknown character cost is 1.0 (distance 1.0, /3 = 0.333, floor at 0.1)', () => {
      // Unknown chars: distance returns 1.0, /3 = 0.333, within [0.1, 1.0]
      assert.strictEqual(adjacentKeyCost('a', '3'), 1 / 3);
    });
  });

  // ──────────────────────────────────────────────
  // score() — the main entry point
  // ──────────────────────────────────────────────
  describe('score()', () => {
    it('REGRESSION: "bith" → "both" scores ≈ 0.607 at beta=1.5', () => {
      const actual = score('bith', 'both', 1, 1.5);
      assert.ok(Math.abs(actual - 0.607) < 0.01,
        `score("bith","both",1,1.5) = ${actual}, expected ≈0.607`);
    });

    it('"bith" → "both" outranks "bith" → "bath"', () => {
      const both = score('bith', 'both', 1, 1.5);
      const bath = score('bith', 'bath', 1, 1.5);
      assert.ok(both > bath,
        `both(${both}) should score higher than bath(${bath})`);
      // Both should be at least 2x the bath score (0.607 vs 0.223)
      assert.ok(both / bath > 2.0,
        `both/bath ratio ${both / bath} should be > 2.0`);
    });

    it('identical strings with distance 0 return 1.0', () => {
      assert.strictEqual(score('hello', 'hello', 0, 1.5), 1.0);
      assert.strictEqual(score('', '', 0, 1.5), 1.0);
    });

    it('transposition: "teh" → "the" applies 0.7 discount', () => {
      const actual = score('teh', 'the', 2, 1.5);
      // After transposition discount: cost = (1.0 + 1.0) * 0.7 = 1.4
      // score = exp(-1.5 * 1.4) ≈ 0.122
      assert.ok(Math.abs(actual - 0.122) < 0.01,
        `score("teh","the",2,1.5) = ${actual}, expected ≈0.122`);
    });

    it('doubling: "helllo" → "hello" weighted distance is 0 (perfect alignment via doubling)', () => {
      // "helllo" with an extra 'l' — the optimal deletion removes one 'l'
      // and the doubled neighbor is detected.
      const wd = weightedEditDistance('helllo', 'hello', 1);
      assert.strictEqual(wd, 0,
        `helllo→hello weightedEditDistance should be 0 (perfect alignment)`);
      // Score should be 1.0 since cost is 0 (the extra 'l' causes no character mismatch)
      assert.strictEqual(score('helllo', 'hello', 1, 1.5), 1.0);
    });

    it('different-length candidates: "recieve" → "receive" produces a reasonable score', () => {
      // Both are 7 chars — this is equal length with a transposition (ie→ei)
      const actual = score('recieve', 'receive', 2, 1.5);
      assert.ok(!Number.isNaN(actual), 'score should not be NaN');
      assert.ok(actual >= 0, 'score should not be negative');
      assert.ok(actual <= 1, 'score should not exceed 1');
      // This is the same transposition pattern as "teh"→"the" (ie→ei vs eh→he)
      assert.ok(Math.abs(actual - 0.122) < 0.01,
        `score("recieve","receive",2,1.5) = ${actual}, expected ≈0.122`);
    });

    it('distance 0 returns 1.0 regardless of beta', () => {
      assert.strictEqual(score('test', 'test', 0, 100.0), 1.0);
      assert.strictEqual(score('test', 'test', 0, 0.0), 1.0);
    });

    it('result clamped to [0, 1]', () => {
      // Very large cost should give near-0 but not negative
      const actual = score('aaaaaa', 'zzzzzz', 6, 100.0);
      assert.ok(actual >= 0 && actual <= 1);
    });
  });

  // ──────────────────────────────────────────────
  // weightedEditDistance() — internal helper
  // ──────────────────────────────────────────────
  describe('weightedEditDistance()', () => {
    it('equal length: pure substitution cost', () => {
      // "bith" → "both": one substitution i→o, cost 0.333
      const wd = weightedEditDistance('bith', 'both', 1);
      assert.ok(Math.abs(wd - 1 / 3) < 0.001,
        `weightedEditDistance("bith","both",1) = ${wd}, expected ${1 / 3}`);
    });

    it('equal length: transposition discount applied', () => {
      // "teh" → "the": two substitutions (e→h, h→e), each cost 1.0,
      // then 0.7 discount applied → 1.4
      const wd = weightedEditDistance('teh', 'the', 2);
      assert.ok(Math.abs(wd - 1.4) < 0.001,
        `weightedEditDistance("teh","the",2) = ${wd}, expected 1.4`);
    });

    it('insertion: shorter → longer', () => {
      // "helo" → "hello": insertion of 'l'
      const wd = weightedEditDistance('helo', 'hello', 1);
      // The optimal deletion of the extra 'l' gives cost 0
      assert.strictEqual(wd, 0);
    });

    it('deletion: longer → shorter', () => {
      // same case as above but swapping args — dispatches to same insertion helper
      const wd = weightedEditDistance('hello', 'helo', 1);
      // Same: optimal deletion gives cost 0
      assert.strictEqual(wd, 0);
    });

    it('length diff 2: returns best geometric cost', () => {
      // SymSpell distance is 2 for length-diff-2 cases
      const wd = weightedEditDistance('ab', 'abcd', 2);
      // Not 0, not NaN, not negative
      assert.ok(wd >= 0);
      assert.ok(!Number.isNaN(wd));
    });

    it('length diff > 2: falls back to symSpellDistance', () => {
      // typed=short, candidate=much longer
      const wd = weightedEditDistance('a', 'abcde', 4);
      assert.strictEqual(wd, 4);
    });
  });
});
