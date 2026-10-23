export const ChunkResultKind = Object.freeze({
  partial: 'partial',
  final: 'final',
});

export class ChunkResultStore {
  constructor() {
    this.results = new Map();
  }

  store(chunkId, kind, text) {
    if (kind !== ChunkResultKind.partial && kind !== ChunkResultKind.final) {
      throw new TypeError(`Unknown chunk result kind: ${kind}`);
    }

    // Swift's receive site distinguishes partial/final, but its callback drops
    // that kind and the view model first-wins (WhisperStreamClient.swift:761–815;
    // DictationViewModel.swift:2570–2575). Preserve first-wins except that a
    // final must displace an earlier partial.
    const existing = this.results.get(chunkId);
    if (existing
      && !(existing.kind === ChunkResultKind.partial && kind === ChunkResultKind.final)) {
      return false;
    }

    this.results.set(chunkId, { kind, text });
    return true;
  }

  get(chunkId) {
    const result = this.results.get(chunkId);
    return result ? { ...result } : undefined;
  }

  entries() {
    return [...this.results].map(([chunkId, result]) => ({ chunkId, ...result }));
  }
}
