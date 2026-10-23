const V1_CONTINUATION_WORD_LIST = Object.freeze([
  'for', 'and', 'but', 'or', 'nor', 'so', 'yet', 'which', 'that', 'because',
  'with', 'also', 'to', 'from', 'when', 'while', 'since', 'although', 'however', 'plus',
]);
const V1_CONTINUATION_WORDS = new Set(V1_CONTINUATION_WORD_LIST);

export const ZERO_RISK_MERGER_CONFIG = Object.freeze({
  name: 'zero-risk',
  ruleA: Object.freeze({
    maxGapMs: 2_500,
    acceptLowercaseHead: true,
    continuationWords: V1_CONTINUATION_WORD_LIST,
  }),
  ruleB: Object.freeze({
    minGapExclusiveMs: 2_500,
    maxGapMs: 10_000,
    auxiliaryWords: Object.freeze([
      'is', 'are', 'was', 'were', 'be', 'been', 'being', 'am', 'will', 'would',
      'have', 'has', 'had', 'do', 'does', 'did', 'can', 'could', 'should', 'must', 'may', 'might',
    ]),
    hangingClauseAdverbs: Object.freeze(['essentially', 'basically', 'rather', 'actually']),
    rightHeadGerundSuffix: 'ing',
  }),
});

// Compatibility surface for the existing sweep harness. Decision behavior comes
// only from the named ruleA/ruleB config above; score fields no longer affect it.
export const MERGER_V2_DEFAULTS = Object.freeze({
  ...ZERO_RISK_MERGER_CONFIG,
  leftTailWordClasses: Object.freeze({
    auxiliaries: ZERO_RISK_MERGER_CONFIG.ruleB.auxiliaryWords,
    adverbs: ZERO_RISK_MERGER_CONFIG.ruleB.hangingClauseAdverbs,
  }),
  rightHeadContinuationWords: V1_CONTINUATION_WORD_LIST,
  rightHeadSoftContinuationWords: Object.freeze([]),
  auxiliaryWords: ZERO_RISK_MERGER_CONFIG.ruleB.auxiliaryWords,
  weakEvidenceScoreThreshold: 1,
  strongEvidenceScoreThreshold: 2,
  weakEvidenceMaxGapMs: 2_500,
  strongEvidenceMaxGapMs: 10_000,
});

export const MERGER_V2_VARIANTS = Object.freeze([
  Object.freeze({ name: ZERO_RISK_MERGER_CONFIG.name, options: ZERO_RISK_MERGER_CONFIG }),
]);

function wordsIn(text) {
  return [...text.matchAll(/[\p{L}]+/gu)];
}

function terminalPunctuation(text) {
  const match = text.match(/[.!?](?=["'”’)]*\s*$)/u);
  return match ? { index: match.index, value: match[0] } : null;
}

function wordSet(words) {
  return new Set([...words].map(word => word.toLowerCase()));
}

function resolveConfiguration(configuration = ZERO_RISK_MERGER_CONFIG) {
  const source = configuration?.ruleA && configuration?.ruleB
    ? configuration
    : ZERO_RISK_MERGER_CONFIG;
  return {
    ruleA: {
      ...source.ruleA,
      continuationWords: wordSet(source.ruleA.continuationWords),
    },
    ruleB: {
      ...source.ruleB,
      auxiliaryWords: wordSet(source.ruleB.auxiliaryWords),
      hangingClauseAdverbs: wordSet(source.ruleB.hangingClauseAdverbs),
    },
  };
}

function hasAuxiliaryAdverbTail(leftWords, ruleB) {
  if (leftWords.length < 2) return false;
  const auxiliary = leftWords[leftWords.length - 2][0].toLowerCase();
  const adverb = leftWords[leftWords.length - 1][0].toLowerCase();
  return ruleB.auxiliaryWords.has(auxiliary) && ruleB.hangingClauseAdverbs.has(adverb);
}

function isGerundHead(rightWords, suffix) {
  return rightWords[0]?.[0].toLowerCase().endsWith(suffix) === true;
}

function evaluateWithConfiguration(leftText, rightText, gapMs, configuration) {
  const leftWords = wordsIn(leftText);
  const rightWords = wordsIn(rightText);
  const firstRightWord = rightWords[0]?.[0];
  const rightHead = firstRightWord?.toLowerCase();
  const rightHeadIsLowercase = firstRightWord !== undefined
    && firstRightWord[0] === firstRightWord[0].toLowerCase()
    && firstRightWord[0] !== firstRightWord[0].toUpperCase();
  const punctuation = terminalPunctuation(leftText);
  const ruleA = punctuation !== null
    && rightHead !== undefined
    && ((configuration.ruleA.acceptLowercaseHead && rightHeadIsLowercase)
      || configuration.ruleA.continuationWords.has(rightHead))
    && gapMs <= configuration.ruleA.maxGapMs;

  // Requiring an auxiliary+adverb pair avoids admitting bare-auxiliary collisions
  // like “we are | Going” while retaining the approved “are essentially | Going” seam.
  const ruleBPatternMatched = hasAuxiliaryAdverbTail(leftWords, configuration.ruleB)
    && isGerundHead(rightWords, configuration.ruleB.rightHeadGerundSuffix);
  const ruleB = ruleBPatternMatched
    && gapMs > configuration.ruleA.maxGapMs
    && gapMs > configuration.ruleB.minGapExclusiveMs
    && gapMs <= configuration.ruleB.maxGapMs;

  const rule = ruleA ? 'A' : ruleB ? 'B' : null;
  return {
    rule,
    ruleBPatternMatched,
    shouldMerge: rule !== null,
  };
}

export function evaluateChunkFinalSeam(
  leftText,
  rightText,
  gapMs,
  configuration = ZERO_RISK_MERGER_CONFIG,
) {
  return evaluateWithConfiguration(leftText, rightText, gapMs, resolveConfiguration(configuration));
}

export function mergeChunkFinal(finalText, segments, configuration = ZERO_RISK_MERGER_CONFIG) {
  const resolvedConfiguration = resolveConfiguration(configuration);
  const chunks = segments.filter(segment => segment.chunkLocalText.trim().length > 0);
  const boundaries = [];
  let searchFrom = 0;
  for (const segment of chunks) {
    const chunkText = segment.chunkLocalText.trim();
    const anchor = chunkText.slice(0, 24);
    const anchorAt = finalText.indexOf(anchor, searchFrom);
    if (anchorAt < 0 || !finalText.startsWith(chunkText, anchorAt)) return finalText;
    const end = anchorAt + chunkText.length;
    boundaries.push({ segment, start: anchorAt, end, text: chunkText });
    searchFrom = end;
  }

  const edits = [];
  for (let index = 0; index < boundaries.length - 1; index += 1) {
    const left = boundaries[index];
    const right = boundaries[index + 1];
    const decision = evaluateWithConfiguration(
      left.text,
      right.text,
      right.segment.startMs - left.segment.endMs,
      resolvedConfiguration,
    );
    if (!decision.shouldMerge) continue;

    const punctuation = terminalPunctuation(left.text);
    const firstWord = wordsIn(right.text)[0];
    if (!firstWord) continue;
    const word = firstWord[0];
    const wordAt = right.start + firstWord.index;

    if (decision.rule === 'A' && punctuation) {
      const punctuationAt = left.start + punctuation.index;
      edits.push({ start: punctuationAt, end: wordAt, value: ' ' });
      if (word[0] === word[0].toUpperCase() && word[0] !== word[0].toLowerCase()) {
        edits.push({ start: wordAt, end: wordAt + word.length, value: word[0].toLowerCase() + word.slice(1) });
      }
      continue;
    }

    if (punctuation) {
      const punctuationAt = left.start + punctuation.index;
      edits.push({ start: punctuationAt, end: punctuationAt + punctuation.value.length, value: '' });
    }
    if (word[0] === word[0].toUpperCase() && word[0] !== word[0].toLowerCase()) {
      edits.push({ start: wordAt, end: wordAt + word.length, value: word[0].toLowerCase() + word.slice(1) });
    }
  }

  let result = finalText;
  for (const edit of edits.sort((a, b) => b.start - a.start)) {
    result = result.slice(0, edit.start) + edit.value + result.slice(edit.end);
  }
  return result;
}

// Keep this implementation unchanged for before/after comparisons only.
export function mergeChunkFinalV1(finalText, segments, maxGapMs = 2500) {
  const chunks = segments.filter(segment => segment.chunkLocalText.trim().length > 0);
  const boundaries = [];
  let searchFrom = 0;
  for (const segment of chunks) {
    const chunkText = segment.chunkLocalText.trim();
    const anchor = chunkText.slice(0, 24);
    const anchorAt = finalText.indexOf(anchor, searchFrom);
    if (anchorAt < 0 || !finalText.startsWith(chunkText, anchorAt)) return finalText;
    const end = anchorAt + chunkText.length;
    boundaries.push({ segment, start: anchorAt, end, text: chunkText });
    searchFrom = end;
  }

  const edits = [];
  for (let index = 0; index < boundaries.length - 1; index += 1) {
    const left = boundaries[index];
    const right = boundaries[index + 1];
    const punctuation = left.text.match(/[.!?](?=["'”’)]*\s*$)/u);
    const firstWord = right.text.match(/[\p{L}]+/u);
    if (!punctuation || !firstWord || right.segment.startMs - left.segment.endMs > maxGapMs) continue;
    const word = firstWord[0];
    if (!(word[0] === word[0].toLowerCase() && word[0] !== word[0].toUpperCase())
      && !V1_CONTINUATION_WORDS.has(word.toLowerCase())) continue;

    const punctuationAt = left.start + punctuation.index;
    const wordAt = right.start + firstWord.index;
    const replaceWord = V1_CONTINUATION_WORDS.has(word.toLowerCase()) && word[0] === word[0].toUpperCase()
      ? word[0].toLowerCase() + word.slice(1)
      : word;
    edits.push({ start: punctuationAt, end: wordAt, value: ' ' });
    if (replaceWord !== word) edits.push({ start: wordAt, end: wordAt + word.length, value: replaceWord });
  }

  let result = finalText;
  for (const edit of edits.sort((a, b) => b.start - a.start)) {
    result = result.slice(0, edit.start) + edit.value + result.slice(edit.end);
  }
  return result;
}

// Swift port note: mirror ZERO_RISK_MERGER_CONFIG as a named configuration on
// ChunkFinalMerger (ChunkFinalMerger.swift:10–18); keep the auxiliary+adverb tail
// gate and 2,500 ms rule boundary explicit. Implement tail/head helpers beside
// the existing merger helpers (ChunkFinalMerger.swift:76–103), not in endpoint timing code.
