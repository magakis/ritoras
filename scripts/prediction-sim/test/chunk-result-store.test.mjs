import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mergeChunkFinal } from '../lib/chunk-final-merge.mjs';
import { ChunkResultKind, ChunkResultStore } from '../lib/chunk-result-store.mjs';

describe('chunk result store', () => {
  it('lets a chunk final replace a partial before merger input selection', () => {
    const finalText = 'The delay caused a problem. For the billing issue we need a refund.';
    const chunks = [
      { chunkId: 1, startMs: 0, endMs: 900 },
      { chunkId: 2, startMs: 1200, endMs: 2000 },
    ];
    const messages = [
      { chunkId: 1, kind: ChunkResultKind.final, text: 'The delay caused a problem.' },
      { chunkId: 2, kind: ChunkResultKind.partial, text: 'And support is still checking.' },
      { chunkId: 2, kind: ChunkResultKind.final, text: 'For the billing issue we need a refund.' },
    ];

    // The pre-fix type-blind first-result-wins store keeps the partial, so its
    // text cannot anchor in the terminal transcript and the merger passes it through.
    const preFixResults = new Map();
    for (const message of messages) {
      if (!preFixResults.has(message.chunkId)) {
        preFixResults.set(message.chunkId, message.text);
      }
    }
    const preFixSegments = chunks.map(chunk => ({
      ...chunk,
      chunkLocalText: preFixResults.get(chunk.chunkId),
    }));
    assert.equal(mergeChunkFinal(finalText, preFixSegments), finalText);

    const store = new ChunkResultStore();
    for (const message of messages) {
      store.store(message.chunkId, message.kind, message.text);
    }
    const mergerSegments = chunks.map(chunk => ({
      ...chunk,
      chunkLocalText: store.get(chunk.chunkId).text,
    }));

    assert.deepStrictEqual(store.get(2), {
      kind: ChunkResultKind.final,
      text: 'For the billing issue we need a refund.',
    });
    assert.equal(
      mergeChunkFinal(finalText, mergerSegments),
      'The delay caused a problem for the billing issue we need a refund.',
    );
  });

  it('keeps the first partial and first final, while allowing the final to supersede a partial', () => {
    const store = new ChunkResultStore();
    assert.equal(store.store(7, ChunkResultKind.partial, 'draft one'), true);
    assert.equal(store.store(7, ChunkResultKind.partial, 'draft two'), false);
    assert.equal(store.store(7, ChunkResultKind.final, 'finished'), true);
    assert.equal(store.store(7, ChunkResultKind.partial, 'late draft'), false);
    assert.equal(store.store(7, ChunkResultKind.final, 'late final'), false);
    assert.deepStrictEqual(store.entries(), [
      { chunkId: 7, kind: ChunkResultKind.final, text: 'finished' },
    ]);
  });
});
