// Pure-logic JS port of keyboard/Sources/FollowMeDeliveryGate.swift. Kept in sync per AGENTS.md -> Test policy.

export const TerminalStatus = Object.freeze({
  completed: 'completed',
  error: 'error',
  cancelled: 'cancelled',
});

export const Decision = Object.freeze({
  deliver: 'deliver',
  waitNoField: 'waitNoField',
  dropConsumed: 'dropConsumed',
  dropExpired: 'dropExpired',
});

export function decideFollowMeDelivery({
  id,
  status,
  terminalAt,
  now,
  windowSeconds,
  consumedIDs,
  matchesPendingRequest,
  hasRealField,
}) {
  if (consumedIDs.includes(id)) return Decision.dropConsumed;
  if (!matchesPendingRequest && now - terminalAt > windowSeconds * 1000) return Decision.dropExpired;
  void status;
  return hasRealField ? Decision.deliver : Decision.waitNoField;
}

export class FollowMeConsumedIDRing {
  constructor(ids = [], capacity = 4) {
    this.capacity = Math.max(0, capacity);
    this.ids = this.capacity === 0 ? [] : ids.slice(-this.capacity);
  }

  static legacySeed(id) {
    return new FollowMeConsumedIDRing(id == null ? [] : [id]);
  }

  contains(id) {
    return this.ids.includes(id);
  }

  append(id) {
    if (this.capacity === 0) return;
    this.ids.push(id);
    if (this.ids.length > this.capacity) {
      this.ids.splice(0, this.ids.length - this.capacity);
    }
  }
}
