import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { topCorrection, topCorrectionOutcome } from '../lib/top-correction.mjs';
import { fusionIsActive } from '../lib/fusion-is-active.mjs';
import { fusedPool } from '../lib/fused-pool.mjs';

const APOSTROPHE_CURLY = '\u{2019}';

// Normalize apostrophes: map both ASCII (') and curly (') to curly for matching.
function normalizeApostrophe(word) {
  return word.replace(/'/g, APOSTROPHE_CURLY);
}

/**
 * Reusable mock bigram scorer: P(both|for) high, P(bath|for) low.
 * Handles both ASCII (') and curly (\u{2019}) apostrophes by normalizing.
 */
function mockBigramScorer(candidate, previousWord) {
  const norm = normalizeApostrophe(candidate);
  if (previousWord?.toLowerCase() === 'for') {
    if (norm === 'both') return -2.0;   // P=0.01, plausible
    if (norm === 'bath') return -8.5;   // P=3.16e-9, implausible
  }
  if (previousWord?.toLowerCase() === 'i') {
    if (norm === `don${APOSTROPHE_CURLY}t`) return -1.5;   // P=0.032, common contraction
  }
  return -10.0;  // unseen
}

describe('fusionIsActive', () => {
  it('true when previousWord exists and trigram is ready', () => {
    assert.strictEqual(fusionIsActive({ previousWord: 'for', trigramReady: true }), true);
  });

  it('false when previousWord is null even if trigram is ready', () => {
    assert.strictEqual(fusionIsActive({ previousWord: null, trigramReady: true }), false);
  });

  it('false when previousWord exists but trigram is not ready', () => {
    assert.strictEqual(fusionIsActive({ previousWord: 'for', trigramReady: false }), false);
  });

  it('false when previousWord is empty', () => {
    assert.strictEqual(fusionIsActive({ previousWord: '', trigramReady: true }), false);
  });

  it('false when previousWord is undefined', () => {
    assert.strictEqual(fusionIsActive({ previousWord: undefined, trigramReady: true }), false);
  });
});

describe('topCorrection', () => {
  // ──────────────────────────────────────────────
  // Absolute-floor gate
  // ──────────────────────────────────────────────
  it('rejects winner when rawLogProb is below the absolute floor (-8.0)', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },   // verbatim
      { text: 'bath', score: 0.65, source: 'symspell' },   // candidate, but logProb = -8.5
    ];

    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: mockBigramScorer,
      trigramReady: true,
      blendWeight: 0.5,
      floorPolicy: 'absolute',
      absoluteLogProbFloor: -8.0,
    });

    assert.strictEqual(result, null, 'topCorrection rejects candidate with logProb below -8.0 floor');
  });

  it('returns winner when rawLogProb is above the absolute floor', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },
      { text: 'both', score: 0.55, source: 'symspell' },
      { text: 'bath', score: 0.50, source: 'symspell' },
    ];

    // Override scorer to return -5.0 for "both" (above -8.0 floor)
    const highScorer = (candidate) => {
      if (candidate === 'both') return -5.0;
      return -10.0;
    };

    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: highScorer,
      trigramReady: true,
      blendWeight: 0.5,
      floorPolicy: 'absolute',
      absoluteLogProbFloor: -8.0,
    });

    assert.ok(result !== null, 'topCorrection returns winner when logProb ≥ floor');
    assert.strictEqual(result.text, 'both', 'winner is "both"');
  });

  // ──────────────────────────────────────────────
  // "for bith" → "for both" end-to-end
  // ──────────────────────────────────────────────
  it('"for bith" → "for both": contextual KenLM lifts both above 0.65 fused threshold', () => {
    // SymSpell-like pool for "bith":
    //   - "both" at 0.61 (i→o adjacent key, high frequency)
    //   - "bath" at 0.65 (i→a adjacent key, slightly lower frequency but shorter distance?)
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },   // verbatim
      { text: 'both', score: 0.61, source: 'symspell' },   // scored by Qwerty distance
      { text: 'bath', score: 0.65, source: 'symspell' },
    ];

    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: mockBigramScorer,
      trigramReady: true,
      blendWeight: 0.5,
    });

    assert.ok(result !== null, 'topCorrection returns a candidate for "bith" with context "for"');
    assert.strictEqual(result.text, 'both', 'winner should be "both"');

    // Verify the blended score clears the fused threshold (0.65).
    // normalized(both) = (-2.0 - (-8.5)) / max((-2.0)-(-8.5), 0.001) = 6.5/6.5 = 1.0
    // normalized(bath) = (-8.5 - (-8.5)) / 6.5 = 0.0
    // blended(both)   = 0.5 * 0.61 + 0.5 * 1.0 = 0.805
    // blended(bath)   = 0.5 * 0.65 + 0.5 * 0.0 = 0.325
    assert.ok(result.score >= 0.65, `"both" blended score ${result.score} >= 0.65 fused threshold`);
    assert.ok(Math.abs(result.score - 0.805) < 0.001,
      `"both" score ${result.score} ≈ 0.805`);
  });

  // ──────────────────────────────────────────────
  // No-context case
  // ──────────────────────────────────────────────
  it('no previous word: fusion inactive, candidate score remains raw 0.61 (below 0.70 threshold)', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },
      { text: 'both', score: 0.61, source: 'symspell' },
      { text: 'bath', score: 0.65, source: 'symspell' },
    ];

    // No KenLM scorer — fusion can't run anyway.
    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: null,
      previousWord2: null,
      kenlmScorer: null,
      trigramReady: false,
    });

    // topCorrection returns the best candidate, but at raw SymSpell score.
    assert.ok(result !== null, 'topCorrection returns a candidate even without context');
    // "bath" has highest raw score (0.65) of non-verbatim candidates.
    assert.strictEqual(result.text, 'bath', 'best raw SymSpell score is "bath" (0.65)');
    // Verify fusion is inactive — fusionIsActive check:
    assert.strictEqual(fusionIsActive({ previousWord: null, trigramReady: false }), false,
      'fusion not active without previous word');

    // The fusedPool (without KenLM) leaves scores intact.
    const fused = fusedPool({ pool, currentWord: 'bith', previousWord: null, previousWord2: null, kenlmScorer: null });
    const candidate = fused.find(s => s.text === 'both');
    assert.ok(candidate, '"both" in fused pool');
    assert.strictEqual(candidate.score, 0.61,
      '"both" score remains 0.61 (no KenLM lift) — below 0.70 unfused threshold');
  });

  // ──────────────────────────────────────────────
  // Contraction integration
  // ──────────────────────────────────────────────
  it('"I dont" → "I don\'t": contraction scores 0.9, fusion confirms', () => {
    const APOSTROPHE = '\u{2019}';
    const dontExpanded = `don${APOSTROPHE}t`;

    // Pool simulating merged providers for "dont" with prev "I".
    const pool = [
      { text: 'dont', score: 1.0, source: 'symspell' },          // verbatim
      { text: dontExpanded, score: 0.9, source: 'symspell' },     // contraction entry
    ];

    const result = topCorrection({
      pool,
      currentWord: 'dont',
      previousWord: 'I',
      previousWord2: null,
      kenlmScorer: mockBigramScorer,
      trigramReady: true,
      blendWeight: 0.5,
    });

    assert.ok(result !== null, 'topCorrection returns a candidate for "dont"');
    assert.strictEqual(result.text, dontExpanded,
      `contraction "${dontExpanded}" wins`);

    // Score after fusion: normalized(don't|I) = (-1.5 - (-10.0)) / ((-1.5)-(-10.0)) = 8.5/8.5 = 1.0
    // blended = 0.5 * 0.9 + 0.5 * 1.0 = 0.95 — well above 0.65
    assert.ok(result.score >= 0.65,
      `contraction score ${result.score} >= 0.65 threshold`);
  });

  // ──────────────────────────────────────────────
  // Manufactured-confidence rejection
  // ──────────────────────────────────────────────
  it('absolute-floor gate rejects manufactured confidence from min-max normalization', () => {
    // Pool where the least-bad candidate has a terrible logProb (-8.5).
    // Without the floor gate, min-max gives it normalized=1.0, blended score clears 0.65.
    // WITH the floor gate, it's rejected because rawLogProb < -8.0.
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },
      { text: 'xyzz', score: 0.10, source: 'symspell' },   // bad edit but only candidate
    ];

    // All candidates get very low logProb from the mock.
    const lowScorer = () => -8.5;

    const noGateResult = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: lowScorer,
      trigramReady: true,
      blendWeight: 0.5,
      floorPolicy: 'absolute',
      // Very permissive floor so it passes
      absoluteLogProbFloor: -10.0,
    });

    assert.ok(noGateResult !== null, 'without gate, candidate passes (permissive floor)');

    const gatedResult = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: 'for',
      previousWord2: null,
      kenlmScorer: lowScorer,
      trigramReady: true,
      blendWeight: 0.5,
      floorPolicy: 'absolute',
      absoluteLogProbFloor: -8.0,  // strict floor — -8.5 < -8.0 → rejected
    });

    assert.strictEqual(gatedResult, null,
      'absolute-floor gate rejects candidate with rawLogProb=-8.5 < -8.0 floor');
  });

  // ──────────────────────────────────────────────
  // Edge cases
  // ──────────────────────────────────────────────
  it('returns null when pool has no non-verbatim candidates', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },
    ];

    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: null,
      previousWord2: null,
      kenlmScorer: null,
      trigramReady: false,
    });

    assert.strictEqual(result, null, 'no non-verbatim candidates → null');
  });

  it('excludes .trigram source candidates', () => {
    const pool = [
      { text: 'bith', score: 1.0, source: 'symspell' },
      { text: 'whatever', score: 0.95, source: 'trigram' },  // excluded
      { text: 'both', score: 0.61, source: 'symspell' },
    ];

    const result = topCorrection({
      pool,
      currentWord: 'bith',
      previousWord: null,
      previousWord2: null,
      kenlmScorer: null,
      trigramReady: false,
    });

    assert.ok(result !== null);
    assert.strictEqual(result.text, 'both', 'trigram candidate "whatever" excluded');
    assert.notStrictEqual(result.text, 'whatever', 'trigram source not in results');
  });

  // ──────────────────────────────────────────────
  // Fusion degradation — no ready trigram (Greek ships without a trigram:
  // Greek KenLM is Phase 6, deferred). Documents the structural guarantee:
  // with no ready trigram the KenLM re-score and the absolute-floor gate are
  // skipped, so SymSpell/Apple ranking passes through on raw provider scores.
  // (The Apple boost step is NOT KenLM-dependent — it still applies, as in
  // the fused-pool tests. Ambiguous contractions are the one special case:
  // the Swift guard hard-rejects them without LM context.)
  // ──────────────────────────────────────────────
  describe('no ready trigram → SymSpell/Apple ranking unchanged', () => {
    it('winner is the max raw provider score, unchanged by any KenLM transform', () => {
      const pool = [
        { text: 'bith', score: 1.0, source: 'symspell' },   // verbatim (excluded)
        { text: 'bath', score: 0.5, source: 'symspell' },
        { text: 'both', score: 0.61, source: 'symspell' },  // top raw provider score
      ];

      const result = topCorrection({
        pool,
        currentWord: 'bith',
        previousWord: 'for',
        previousWord2: null,
        kenlmScorer: null,
        trigramReady: false,
        blendWeight: 0.5,
      });

      assert.ok(result !== null);
      assert.strictEqual(result.text, 'both');
      assert.strictEqual(result.score, 0.61, 'score untouched — no KenLM re-score (Apple boost only affects .apple entries)');
    });

    it('absolute-floor gate does not run without a ready trigram', () => {
      // The winner would be rejected by the -8.0 floor IF KenLM were ready
      // (mock scorer gives it -8.5). With no trigram the floor is skipped.
      const pool = [
        { text: 'bith', score: 1.0, source: 'symspell' },
        { text: 'bath', score: 0.65, source: 'symspell' },
      ];

      const result = topCorrection({
        pool,
        currentWord: 'bith',
        previousWord: 'for',
        previousWord2: null,
        kenlmScorer: mockBigramScorer,
        trigramReady: false,
        floorPolicy: 'absolute',
        absoluteLogProbFloor: -8.0,
      });

      assert.ok(result !== null, 'floor gate skipped when trigram is not ready');
      assert.strictEqual(result.text, 'bath');
    });

    it('ambiguous-contraction winner is hard-rejected without a ready trigram (mirrors Swift guard)', () => {
      // Swift: `guard fusionIsActive(...) ... else { return nil }` — a real
      // dictionary word is never auto-flipped to its contraction form without
      // LM context. With no trigram the guard fails and topCorrection is nil.
      const pool = [
        { text: 'its', score: 1.0, source: 'symspell' },
        { text: `it${APOSTROPHE_CURLY}s`, score: 0.5, source: 'ambiguousContraction' },
      ];

      const result = topCorrection({
        pool,
        currentWord: 'its',
        previousWord: 'for',
        previousWord2: null,
        kenlmScorer: null,
        trigramReady: false,
      });

      assert.strictEqual(result, null, 'ambiguous contraction requires a ready trigram');
    });
  });
});

describe('topCorrection floor-policy modes', () => {
  function options(overrides = {}) {
    return {
      pool: [
        { text: 'typed', score: 1.0, source: 'symspell' },
        { text: 'winner', score: 0.8, source: 'symspell' },
      ],
      currentWord: 'typed',
      previousWord: 'known',
      previousWord2: 'known',
      kenlmScorer: () => -9.0,
      trigramReady: true,
      ...overrides,
    };
  }

  it('defaults to a 2.0 sub-floor rescue while preserving the old absolute policy', () => {
    const exactMarginScorer = candidate => ({
      winner: -9.0,
      typed: -11.0,
    }[candidate] ?? -10.0);
    const selectedPolicy = topCorrection(options({ kenlmScorer: exactMarginScorer }));
    assert.strictEqual(selectedPolicy.text, 'winner');
    assert.strictEqual(topCorrection(options({
      floorPolicy: 'absolute',
      kenlmScorer: exactMarginScorer,
    })), null);

    const aboveFloorScorer = candidate => ({
      winner: -7.0,
      typed: -6.0,
    }[candidate] ?? -10.0);
    assert.strictEqual(
      topCorrection(options({ kenlmScorer: aboveFloorScorer })).text,
      'winner',
    );
  });

  it('scores the typed literal only when the winner is below the absolute floor', () => {
    const literalScoreCalls = [];
    const scorer = candidate => {
      if (candidate === 'typed') {
        literalScoreCalls.push(candidate);
        return -11.0;
      }
      return candidate === 'winner' ? -7.0 : -10.0;
    };
    const shared = {
      pool: [
        { text: 'typed', score: 1.0, source: 'symspell' },
        { text: 'winner', score: 0.8, source: 'symspell' },
      ],
      currentWord: 'typed',
      previousWord: 'known',
      previousWord2: null,
      kenlmScorer: scorer,
      trigramReady: true,
    };

    assert.strictEqual(topCorrectionOutcome(shared).cause, 'candidate');
    assert.strictEqual(literalScoreCalls.length, 1, 'typed literal was scored only in fusion');

    literalScoreCalls.length = 0;
    const subFloorOutcome = topCorrectionOutcome({
      ...shared,
      kenlmScorer: candidate => {
        if (candidate === 'typed') {
          literalScoreCalls.push(candidate);
          return -11.0;
        }
        return candidate === 'winner' ? -9.0 : -10.0;
      },
    });
    assert.strictEqual(subFloorOutcome.cause, 'candidate');
    assert.strictEqual(literalScoreCalls.length, 2, 'gate scores the literal after the floor fails');
  });

  it('allows the opt-in floor-off endpoint to bypass only the absolute floor', () => {
    const result = topCorrection(options({ floorPolicy: 'off' }));
    assert.strictEqual(result.text, 'winner');
  });

  it('relaxes the floor only when built-in membership finds an OOV context token', () => {
    const isBuiltInWord = word => word === 'known';
    const shared = {
      floorPolicy: 'oovAware',
      oovRelaxedLogProbFloor: -10.0,
      isBuiltInWord,
    };

    assert.strictEqual(topCorrection(options({
      ...shared,
      previousWord2: 'known',
    })), null);
    const relaxed = topCorrection(options({
      ...shared,
      previousWord2: '€50',
    }));
    assert.strictEqual(relaxed.text, 'winner');
  });

  it('scales the floor relaxation by the fraction of OOV context tokens', () => {
    const shared = {
      floorPolicy: 'contextAdjusted',
      contextFloorRelaxationLog10: 4.0,
      isBuiltInWord: word => word === 'known',
      kenlmScorer: () => -9.5,
    };

    assert.strictEqual(topCorrection(options({
      ...shared,
      previousWord2: 'known',
    })), null);
    const adjusted = topCorrection(options({
      ...shared,
      previousWord2: '€50',
    }));
    assert.strictEqual(adjusted.text, 'winner');
  });

  it('lets a sufficient winner-over-typed-literal margin augment the absolute floor', () => {
    const scorer = candidate => ({
      winner: -9.0,
      typed: -11.0,
    }[candidate] ?? -10.0);
    const shared = {
      floorPolicy: 'typedLiteralMargin',
      typedLiteralLogProbMargin: 1.0,
      kenlmScorer: scorer,
    };

    const accepted = topCorrection(options(shared));
    assert.strictEqual(accepted.text, 'winner');

    const rejected = topCorrection(options({
      ...shared,
      kenlmScorer: candidate => (candidate === 'typed' ? -9.5 : -9.0),
    }));
    assert.strictEqual(rejected, null);
  });

  it('requires built-in membership rather than silently inferring OOV from KenLM', () => {
    assert.throws(() => topCorrection(options({
      floorPolicy: 'oovAware',
      oovRelaxedLogProbFloor: -10.0,
    })), /requires isBuiltInWord/);
    assert.throws(() => topCorrection(options({
      floorPolicy: 'contextAdjusted',
      contextFloorRelaxationLog10: 4.0,
    })), /requires isBuiltInWord/);
  });
});
