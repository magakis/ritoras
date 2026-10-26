import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  AAC_BITRATE_SELECTION_RULE,
  conservativeAACBitrateFallback,
  selectAACBitrate,
} from '../lib/aac-bitrate-selector.mjs';

const targetBitRate = 64_000;
const range = (minimum, maximum) => ({ minimum, maximum });

describe('AAC bitrate selection', () => {
  it('keeps 64 kbps when the target is supported and intersects ranges', () => {
    assert.deepStrictEqual(selectAACBitrate({
      availableRanges: [range(32_000, 64_000)],
      applicableBitRates: [32_000, 48_000, 64_000, 96_000],
      targetBitRate,
      fallbackBitRate: 32_000,
    }), {
      bitRate: 64_000,
      rule: AAC_BITRATE_SELECTION_RULE.TARGET_SUPPORTED,
    });
  });

  it('clamps to the highest supported bitrate below the target', () => {
    assert.deepStrictEqual(selectAACBitrate({
      availableRanges: [range(32_000, 48_000)],
      applicableBitRates: [32_000, 48_000],
      targetBitRate,
      fallbackBitRate: 32_000,
    }), {
      bitRate: 48_000,
      rule: AAC_BITRATE_SELECTION_RULE.HIGHEST_BELOW_TARGET,
    });
  });

  it('chooses the nearest supported bitrate when all candidates exceed the target', () => {
    assert.deepStrictEqual(selectAACBitrate({
      availableRanges: [range(80_000, 128_000)],
      applicableBitRates: [80_000, 96_000, 128_000],
      targetBitRate,
      fallbackBitRate: 32_000,
    }), {
      bitRate: 80_000,
      rule: AAC_BITRATE_SELECTION_RULE.NEAREST_ABOVE_TARGET,
    });
  });

  it('uses the sample-rate-specific conservative fallback for empty or failed queries', () => {
    const emptyIntersection = selectAACBitrate({
      availableRanges: [range(96_000, 128_000)],
      applicableBitRates: [32_000, 48_000],
      targetBitRate,
      fallbackBitRate: conservativeAACBitrateFallback(16_000).bitRate,
    });
    const failedQueryAt48K = conservativeAACBitrateFallback(48_000);

    assert.deepStrictEqual(emptyIntersection, {
      bitRate: 32_000,
      rule: AAC_BITRATE_SELECTION_RULE.CONSERVATIVE_FALLBACK,
    });
    assert.deepStrictEqual(failedQueryAt48K, {
      bitRate: 64_000,
      rule: AAC_BITRATE_SELECTION_RULE.CONSERVATIVE_FALLBACK,
    });
  });
});
