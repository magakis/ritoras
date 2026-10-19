// Pure-logic mirror of keyboard/Sources/DictationDeliveryState.swift.
export const DeliveryPhase = Object.freeze({
  claimed: 'claimed',
  insertionIntent: 'insertionIntent',
  cleared: 'cleared',
});

const phaseOrder = Object.freeze({
  [DeliveryPhase.claimed]: 0,
  [DeliveryPhase.insertionIntent]: 1,
  [DeliveryPhase.cleared]: 2,
});

export class DictationDeliveryState {
  static capacity = 4;

  constructor(records = []) {
    this.records = records.slice(-DictationDeliveryState.capacity);
  }

  recordFor(id) {
    return this.records.find(record => record.id === id);
  }

  advance(id, originalTimestamp, phase) {
    const index = this.records.findIndex(record => record.id === id);
    if (index >= 0) {
      const current = this.records[index];
      if (phaseOrder[phase] <= phaseOrder[current.phase]) return;
      this.records[index] = { ...current, phase };
      return;
    }
    this.records.push({ id, originalTimestamp, phase });
    if (this.records.length > DictationDeliveryState.capacity) {
      this.records.splice(0, this.records.length - DictationDeliveryState.capacity);
    }
  }
}
