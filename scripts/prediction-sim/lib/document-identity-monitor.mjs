// Pure-logic JS port of keyboard/Sources/DocumentIdentityMonitor.swift.
// Kept in sync per AGENTS.md -> Test policy.

/**
 * Detects rapid documentIdentifier churn (host input-session flapping, e.g.
 * WKWebView+React recreating input sessions). Pure logic, no UIKit; callers
 * supply their own clock via the `at` timestamp argument. Mirrors
 * DocumentIdentityMonitor in Swift: ids are strings (or null), timestamps are
 * caller-supplied numbers (fake clock).
 *
 * Flap = >=2 distinct non-nil ids OR >=2 nil<->non-nil transitions observed
 * within flapWindow. A flap sets isDefensive and records lastFlapAt; a new flap
 * while defensive extends the window. Defensive mode exits when cooldown has
 * elapsed since the last flap, or when the same non-nil id has been
 * continuously observed for >= stability (early exit).
 *
 * @param {number} [flapWindow=0.5] - Detection window in seconds.
 * @param {number} [cooldown=2.0] - Defensive mode lasts this long after the
 *   last flap.
 * @param {number} [stability=0.5] - Same non-nil id held this long exits early.
 */
export class DocumentIdentityMonitor {
  constructor(flapWindow = 0.5, cooldown = 2.0, stability = 0.5) {
    this.flapWindow = flapWindow;
    this.cooldown = cooldown;
    this.stability = stability;
    this.isDefensive = false;
    this.capacity = 8;
    // Fixed ring of slots; entries older than flapWindow are invisible.
    this.slots = [];
    for (let i = 0; i < this.capacity; i++) {
      this.slots.push({ id: null, ts: Number.NEGATIVE_INFINITY });
    }
    this.nextIndex = 0;
    this.lastFlapAt = 0;
    this.stableIDSince = null;
  }

  /**
   * Record one observation. Returns isDefensive after the update.
   * @param {string|null} id - Document identity, or null for none.
   * @param {number} at - Timestamp in seconds (caller-supplied fake clock).
   * @returns {boolean}
   */
  observe(id, at) {
    // The slot before the one being overwritten holds the previous observation.
    const previousID = this.slots[(this.nextIndex + this.capacity - 1) % this.capacity].id;
    this.slots[this.nextIndex] = { id, ts: at };
    this.nextIndex = (this.nextIndex + 1) % this.capacity;

    // Track the run of one identical non-nil id (breaks on null or on any id
    // change) for the stability early exit.
    if (id !== null) {
      if (this.stableIDSince === null || previousID !== id) {
        this.stableIDSince = at;
      }
    } else {
      this.stableIDSince = null;
    }

    if (this.detectsFlap(at)) {
      this.isDefensive = true;
      this.lastFlapAt = at;
    }

    if (this.isDefensive) {
      if (at - this.lastFlapAt >= this.cooldown) {
        this.isDefensive = false;
      } else if (id !== null && this.stableIDSince !== null && at - this.stableIDSince >= this.stability) {
        this.isDefensive = false;
      }
    }

    return this.isDefensive;
  }

  /**
   * True when the visible ring entries (those within flapWindow) show a flap:
   * >=2 distinct non-nil ids or >=2 nil<->non-nil transitions.
   * @param {number} now
   * @returns {boolean}
   */
  detectsFlap(now) {
    const windowStart = now - this.flapWindow;

    // nil<->non-nil transitions between consecutive visible entries.
    let transitions = 0;
    let previousWasNil = null;
    for (let i = 0; i < this.capacity; i++) {
      const slot = this.slots[(this.nextIndex + i) % this.capacity];
      if (slot.ts < windowStart) continue;
      const isNil = slot.id === null;
      if (previousWasNil !== null && previousWasNil !== isNil) transitions++;
      previousWasNil = isNil;
    }
    if (transitions >= 2) return true;

    // Distinct non-nil ids among visible entries (O(n²) over <=8 entries,
    // comparisons only).
    let distinct = 0;
    for (let i = 0; i < this.capacity; i++) {
      const slotI = this.slots[(this.nextIndex + i) % this.capacity];
      if (slotI.id === null || slotI.ts < windowStart) continue;
      let seenBefore = false;
      for (let j = 0; j < i; j++) {
        const slotJ = this.slots[(this.nextIndex + j) % this.capacity];
        if (slotJ.id === null || slotJ.ts < windowStart) continue;
        if (slotJ.id === slotI.id) {
          seenBefore = true;
          break;
        }
      }
      if (!seenBefore) distinct++;
    }
    return distinct >= 2;
  }
}
