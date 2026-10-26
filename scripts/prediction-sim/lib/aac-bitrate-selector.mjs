// Pure-logic JS mirror of app/Sources/AACBitRateSelector.swift.

export const AAC_BITRATE_SELECTION_RULE = Object.freeze({
  TARGET_SUPPORTED: 'targetSupported',
  HIGHEST_BELOW_TARGET: 'highestBelowTarget',
  NEAREST_ABOVE_TARGET: 'nearestAboveTarget',
  CONSERVATIVE_FALLBACK: 'conservativeFallback',
});

export function conservativeAACBitrateFallback(sourceSampleRate) {
  return {
    bitRate: sourceSampleRate === 16_000 ? 32_000 : 64_000,
    rule: AAC_BITRATE_SELECTION_RULE.CONSERVATIVE_FALLBACK,
  };
}

export function selectAACBitrate({
  availableRanges,
  applicableBitRates,
  targetBitRate,
  fallbackBitRate,
}) {
  const supportedBitRates = [...new Set(applicableBitRates.filter((bitRate) => (
    Number.isInteger(bitRate)
      && bitRate > 0
      && availableRanges.some(({ minimum, maximum }) => (
        minimum <= bitRate && bitRate <= maximum
      ))
  )))].sort((left, right) => left - right);

  if (supportedBitRates.length === 0) {
    return {
      bitRate: fallbackBitRate,
      rule: AAC_BITRATE_SELECTION_RULE.CONSERVATIVE_FALLBACK,
    };
  }
  if (supportedBitRates.includes(targetBitRate)) {
    return {
      bitRate: targetBitRate,
      rule: AAC_BITRATE_SELECTION_RULE.TARGET_SUPPORTED,
    };
  }

  const highestBelowTarget = supportedBitRates.filter((bitRate) => bitRate < targetBitRate).at(-1);
  if (highestBelowTarget !== undefined) {
    return {
      bitRate: highestBelowTarget,
      rule: AAC_BITRATE_SELECTION_RULE.HIGHEST_BELOW_TARGET,
    };
  }
  return {
    bitRate: supportedBitRates[0],
    rule: AAC_BITRATE_SELECTION_RULE.NEAREST_ABOVE_TARGET,
  };
}
