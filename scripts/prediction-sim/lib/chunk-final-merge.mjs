const CONTINUATION_WORDS = new Set([
  'for', 'and', 'but', 'or', 'nor', 'so', 'yet', 'which', 'that', 'because',
  'with', 'also', 'to', 'from', 'when', 'while', 'since', 'although', 'however', 'plus',
]);

export function mergeChunkFinal(finalText, segments, maxGapMs = 2500) {
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
      && !CONTINUATION_WORDS.has(word.toLowerCase())) continue;

    const punctuationAt = left.start + punctuation.index;
    const wordAt = right.start + firstWord.index;
    const replaceWord = CONTINUATION_WORDS.has(word.toLowerCase()) && word[0] === word[0].toUpperCase()
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
