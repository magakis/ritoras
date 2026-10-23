import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  evaluateChunkFinalSeam,
  mergeChunkFinal,
  mergeChunkFinalV1,
  MERGER_V2_VARIANTS,
  ZERO_RISK_MERGER_CONFIG,
} from '../lib/chunk-final-merge.mjs';

const segment = (chunkId, chunkLocalText, startMs, endMs) => ({ chunkId, chunkLocalText, startMs, endMs });

function pair(leftText, rightText, gapMs) {
  const finalText = `${leftText} ${rightText}`;
  const leftEndMs = 1_000;
  const rightStartMs = leftEndMs + gapMs;
  return {
    finalText,
    segments: [
      segment(1, leftText, 0, leftEndMs),
      segment(2, rightText, rightStartMs, rightStartMs + 1_000),
    ],
  };
}

describe('zero-risk chunk final continuation merge', () => {
  it('exposes one named config for merger, sweep, and Swift parity', () => {
    assert.equal(ZERO_RISK_MERGER_CONFIG.name, 'zero-risk');
    assert.equal(MERGER_V2_VARIANTS.length, 1);
    assert.strictEqual(MERGER_V2_VARIANTS[0].options, ZERO_RISK_MERGER_CONFIG);
    assert.equal(ZERO_RISK_MERGER_CONFIG.ruleA.maxGapMs, 2_500);
    assert.equal(ZERO_RISK_MERGER_CONFIG.ruleA.acceptLowercaseHead, true);
    assert.equal(ZERO_RISK_MERGER_CONFIG.ruleB.minGapExclusiveMs, 2_500);
    assert.equal(ZERO_RISK_MERGER_CONFIG.ruleB.maxGapMs, 10_000);
  });

  it('preserves four measured v1-class corpus joins', () => {
    const fixtures = [
      {
        left: 'I want you to commit.',
        right: 'And then push or rather merge with main so that you',
        gapMs: 2_113,
        expected: 'I want you to commit and then push or rather merge with main so that you',
      },
      {
        left: 'tokens per second.',
        right: "But that's quite low, I think.",
        gapMs: 1_403,
        expected: "tokens per second but that's quite low, I think.",
      },
      {
        left: 'evaluate the result and see if it looks better or not.',
        right: 'Or worse.',
        gapMs: 0,
        expected: 'evaluate the result and see if it looks better or not or worse.',
      },
      {
        left: 'already ended my speech, and that was while I was talking.',
        right: 'So obviously there is something wrong here.',
        gapMs: 0,
        expected: 'already ended my speech, and that was while I was talking '
          + 'so obviously there is something wrong here.',
      },
    ];

    for (const fixture of fixtures) {
      const { finalText, segments } = pair(fixture.left, fixture.right, fixture.gapMs);
      assert.equal(mergeChunkFinalV1(finalText, segments), fixture.expected);
      assert.equal(mergeChunkFinal(finalText, segments), fixture.expected);
      assert.equal(
        evaluateChunkFinalSeam(fixture.left, fixture.right, fixture.gapMs).rule,
        'A',
      );
    }
  });

  it('preserves the Airbnb v1 result', () => {
    const final = 'I have sent you a request on Airbnb. '
      + 'For the extra charge, you should have received it in your email';
    const expected = 'I have sent you a request on Airbnb '
      + 'for the extra charge, you should have received it in your email';
    const segments = [
      segment(1, 'I have sent you a request on Airbnb.', 0, 5_000),
      segment(2, 'For the extra charge, you should have received it in your email', 6_192, 9_000),
    ];

    assert.equal(mergeChunkFinalV1(final, segments), expected);
    assert.equal(mergeChunkFinal(final, segments), expected);
    assert.equal(evaluateChunkFinalSeam(segments[0].chunkLocalText, segments[1].chunkLocalText, 1_192).rule, 'A');
  });

  it('restores the lowercase-head v1 branch for the 913.25 ms corpus seam', () => {
    const left = 'It takes quite some time for the S1 model to process.';
    const right = 'are recordings. So so therefore, for long recordings,';
    const { finalText, segments } = pair(left, right, 913.25);
    const expected = 'It takes quite some time for the S1 model to process '
      + 'are recordings. So so therefore, for long recordings,';

    assert.equal(mergeChunkFinalV1(finalText, segments), expected);
    assert.equal(evaluateChunkFinalSeam(left, right, 913.25).rule, 'A');
    assert.equal(mergeChunkFinal(finalText, segments), expected);
  });

  it('does not merge a capitalized, unlisted head under rule A at a short gap', () => {
    const left = 'Thank you for the update.';
    const right = 'I hope you enjoy your stay.';
    const { finalText, segments } = pair(left, right, 1_000);

    assert.equal(mergeChunkFinalV1(finalText, segments), finalText);
    assert.equal(evaluateChunkFinalSeam(left, right, 1_000).rule, null);
    assert.equal(mergeChunkFinal(finalText, segments), finalText);
  });

  it('repairs the 9,191.25 ms fabricated-period specimen through rule B', () => {
    const left = 'the case where we are essentially.';
    const right = 'Going to attach the merger V2. The rest is unchanged.';
    const { finalText, segments } = pair(left, right, 9_191.25);

    assert.equal(mergeChunkFinalV1(finalText, segments), finalText);
    assert.deepEqual(evaluateChunkFinalSeam(left, right, 9_191.25), {
      rule: 'B',
      ruleBPatternMatched: true,
      shouldMerge: true,
    });
    assert.equal(
      mergeChunkFinal(finalText, segments, ZERO_RISK_MERGER_CONFIG),
      'the case where we are essentially going to attach the merger V2. The rest is unchanged.',
    );
  });

  it('does not broaden v1 to punctuation-free comparator seams', () => {
    const left = 'The estimate gives less';
    const right = 'errors than the Parakeet V3 model.';
    const { finalText, segments } = pair(left, right, 1_700);

    assert.equal(mergeChunkFinalV1(finalText, segments), finalText);
    assert.equal(mergeChunkFinal(finalText, segments), finalText);
    assert.deepEqual(evaluateChunkFinalSeam(left, right, 1_700), {
      rule: null,
      ruleBPatternMatched: false,
      shouldMerge: false,
    });
  });

  it('rejects adversarial bare-auxiliary collisions for the long-gap extension', () => {
    const fixtures = [
      { left: "That's what we are.", right: 'Going to the beach tomorrow?', gapMs: 4_000 },
      { left: 'I did.', right: 'Doing it later was easier.', gapMs: 4_000 },
      { left: 'We have.', right: "Going forward, it's fine.", gapMs: 3_000 },
    ];

    for (const fixture of fixtures) {
      const { finalText, segments } = pair(fixture.left, fixture.right, fixture.gapMs);
      const decision = evaluateChunkFinalSeam(fixture.left, fixture.right, fixture.gapMs);
      assert.equal(decision.ruleBPatternMatched, false);
      assert.equal(decision.rule, null);
      assert.equal(mergeChunkFinalV1(finalText, segments), finalText);
      assert.equal(mergeChunkFinal(finalText, segments), finalText);
    }
  });

  it('retains the prior corpus-derived anti-merge fixtures', () => {
    const fixtures = [
      {
        left: 'Thank you for letting me know.',
        right: 'I hope you enjoy your stay and have a wonderful time in Athens.',
        gapMs: 4_200,
      },
      {
        left: 'You enjoy your stay and have a wonderful time in Athens.',
        right: "I'll send you a message tomorrow at some point in order to meet.",
        gapMs: 4_200,
      },
      {
        left: 'Enabled this?',
        right: 'Essentially giving the cleanup LLM more power.',
        gapMs: 999,
      },
      {
        left: 'error percentage, meaning it gives less',
        right: 'You found through some research that in reality for streaming inputs,',
        gapMs: 2_090,
      },
      {
        left: 'I have sent you a request on Airbnb.',
        right: 'For the extra charge, you should have received it in your email.',
        gapMs: 10_000,
      },
    ];

    for (const fixture of fixtures) {
      const { finalText, segments } = pair(fixture.left, fixture.right, fixture.gapMs);
      assert.equal(mergeChunkFinal(finalText, segments), finalText);
    }
  });

  it('structurally blocks rule B at and below the v1 gap boundary', () => {
    const left = 'we are essentially.';
    const right = 'Going to attach the merger V2.';
    const atBoundary = pair(left, right, 2_500);
    const overBoundary = pair(left, right, 2_501);

    assert.deepEqual(evaluateChunkFinalSeam(left, right, 2_500), {
      rule: null,
      ruleBPatternMatched: true,
      shouldMerge: false,
    });
    assert.equal(mergeChunkFinalV1(atBoundary.finalText, atBoundary.segments), atBoundary.finalText);
    assert.equal(mergeChunkFinal(atBoundary.finalText, atBoundary.segments), atBoundary.finalText);
    assert.equal(evaluateChunkFinalSeam(left, right, 2_501).rule, 'B');
    assert.equal(
      mergeChunkFinal(overBoundary.finalText, overBoundary.segments),
      'we are essentially going to attach the merger V2.',
    );

    const ruleAAtBoundary = pair('All done.', 'For the record.', 2_500);
    assert.equal(evaluateChunkFinalSeam('All done.', 'For the record.', 2_500).rule, 'A');
    assert.equal(mergeChunkFinalV1(ruleAAtBoundary.finalText, ruleAAtBoundary.segments),
      'All done for the record.');
    assert.equal(
      mergeChunkFinal(ruleAAtBoundary.finalText, ruleAAtBoundary.segments),
      'All done for the record.',
    );
  });

  it('accepts the strong extension ceiling and rejects the next millisecond', () => {
    const left = 'The case is essentially.';
    const right = 'Going to continue from here.';
    const atCeiling = pair(left, right, ZERO_RISK_MERGER_CONFIG.ruleB.maxGapMs);
    const overCeiling = pair(left, right, ZERO_RISK_MERGER_CONFIG.ruleB.maxGapMs + 1);

    assert.equal(evaluateChunkFinalSeam(left, right, 10_000).rule, 'B');
    assert.equal(mergeChunkFinal(atCeiling.finalText, atCeiling.segments),
      'The case is essentially going to continue from here.');
    assert.equal(evaluateChunkFinalSeam(left, right, 10_001).rule, null);
    assert.equal(mergeChunkFinal(overCeiling.finalText, overCeiling.segments), overCeiling.finalText);
  });

  it('does not merge an unrecognized new-sentence head', () => {
    const text = 'All done. Thanks for your help.';
    const segments = [segment(1, 'All done.', 0, 100), segment(2, 'Thanks for your help.', 200, 400)];
    assert.equal(mergeChunkFinal(text, segments), text);
  });

  it('does not merge a v1 connector beyond the short-gap window', () => {
    const text = 'All done. For the record.';
    const segments = [segment(1, 'All done.', 0, 100), segment(2, 'For the record.', 2_701, 3_000)];
    assert.equal(mergeChunkFinal(text, segments), text);
  });

  it('merges a lowercase-start v1 connector', () => {
    assert.equal(mergeChunkFinal('It is ready. and available now.', [
      segment(1, 'It is ready.', 0, 100), segment(2, 'and available now.', 200, 300),
    ]), 'It is ready and available now.');
  });

  it('handles each v1 terminal punctuation mark', () => {
    for (const punctuation of ['.', '?', '!']) {
      assert.equal(mergeChunkFinal(`Ready${punctuation} For pickup.`, [
        segment(1, `Ready${punctuation}`, 0, 100), segment(2, 'For pickup.', 200, 300),
      ]), 'Ready for pickup.');
    }
  });

  it('skips whitespace-only chunk texts', () => {
    assert.equal(mergeChunkFinal('Hello. for you.', [
      segment(1, 'Hello.', 0, 100), segment(2, ' \n ', 100, 100), segment(3, 'for you.', 200, 300),
    ]), 'Hello for you.');
  });

  it('passes through unchanged when ordered anchoring fails', () => {
    const text = 'Cleaned text. for you.';
    assert.equal(mergeChunkFinal(text, [
      segment(1, 'Unmatched first chunk.', 0, 100), segment(2, 'for you.', 200, 300),
    ]), text);
  });

  it('applies multiple consecutive v1 joins', () => {
    assert.equal(mergeChunkFinal('One. And two. But three.', [
      segment(1, 'One.', 0, 100), segment(2, 'And two.', 200, 300), segment(3, 'But three.', 400, 500),
    ]), 'One and two but three.');
  });
});
