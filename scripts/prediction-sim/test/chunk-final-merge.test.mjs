import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mergeChunkFinal } from '../lib/chunk-final-merge.mjs';

const segment = (chunkId, chunkLocalText, startMs, endMs) => ({ chunkId, chunkLocalText, startMs, endMs });

describe('chunk final continuation merge', () => {
  it('joins the Airbnb continuation and lowercases For', () => {
    const final = 'I have sent you a request on Airbnb. For the extra charge, you should have received it in your email';
    assert.equal(mergeChunkFinal(final, [
      segment(1, 'I have sent you a request on Airbnb.', 0, 5000),
      segment(2, 'For the extra charge, you should have received it in your email', 6192, 9000),
    ]), 'I have sent you a request on Airbnb for the extra charge, you should have received it in your email');
  });

  it('does not merge a capitalized non-continuation sentence', () => {
    const text = 'All done. Thanks for your help.';
    assert.equal(mergeChunkFinal(text, [segment(1, 'All done.', 0, 100), segment(2, 'Thanks for your help.', 200, 400)]), text);
  });

  it('does not merge continuation text beyond the configured gap', () => {
    const text = 'All done. For the record.';
    assert.equal(mergeChunkFinal(text, [segment(1, 'All done.', 0, 100), segment(2, 'For the record.', 2701, 3000)]), text);
  });

  it('merges a lowercase-start chunk', () => {
    assert.equal(mergeChunkFinal('It is ready. and available now.', [
      segment(1, 'It is ready.', 0, 100), segment(2, 'and available now.', 200, 300),
    ]), 'It is ready and available now.');
  });

  it('handles period, question mark, and exclamation mark', () => {
    for (const punctuation of ['.', '?', '!']) {
      assert.equal(mergeChunkFinal(`Ready${punctuation} for pickup.`, [
        segment(1, `Ready${punctuation}`, 0, 100), segment(2, 'for pickup.', 200, 300),
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
    assert.equal(mergeChunkFinal(text, [segment(1, 'Unmatched first chunk.', 0, 100), segment(2, 'for you.', 200, 300)]), text);
  });

  it('applies multiple consecutive merges', () => {
    assert.equal(mergeChunkFinal('One. And two. But three.', [
      segment(1, 'One.', 0, 100), segment(2, 'And two.', 200, 300), segment(3, 'But three.', 400, 500),
    ]), 'One and two but three.');
  });
});
