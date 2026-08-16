import Foundation

/// Detects rapid documentIdentifier churn (host input-session flapping, e.g.
/// WKWebView+React recreating input sessions). Pure logic: no UIKit, injectable
/// clock, fixed-capacity ring — observe() must not allocate (Jetsam hot path).
struct DocumentIdentityMonitor {
    /// One observed document identity at a moment in time.
    private struct Slot {
        var id: UUID?
        var ts: TimeInterval
    }

    /// Fixed ring capacity: at most 8 observations are considered per flap check.
    private let capacity = 8

    /// Flap = >=2 distinct non-nil ids OR >=2 nil<->non-nil transitions
    /// observed within flapWindow.
    let flapWindow: TimeInterval    // default 0.5 s
    let cooldown: TimeInterval      // defensive mode lasts this long after last flap; default 2.0 s
    let stability: TimeInterval     // early exit: same non-nil id held this long; default 0.5 s

    /// True while document identity churn is recent (host flapping).
    private(set) var isDefensive = false

    /// Ring of observations; oldest entry sits at nextIndex.
    private var slots: [Slot]
    /// Index of the next slot to overwrite (the oldest entry).
    private var nextIndex = 0
    /// Timestamp of the most recent flap (extended on re-flap).
    private var lastFlapAt: TimeInterval = 0
    /// When the current run of one identical non-nil id started.
    private var stableIDSince: TimeInterval?

    init(flapWindow: TimeInterval = 0.5, cooldown: TimeInterval = 2.0, stability: TimeInterval = 0.5) {
        self.flapWindow = flapWindow
        self.cooldown = cooldown
        self.stability = stability
        slots = [Slot](repeating: Slot(id: nil, ts: -.infinity), count: capacity)
    }

    /// Record one observation. Returns isDefensive after the update.
    mutating func observe(_ id: UUID?, at ts: TimeInterval) -> Bool {
        // The slot before the one being overwritten holds the previous observation.
        let previousID = slots[(nextIndex + capacity - 1) % capacity].id
        slots[nextIndex] = Slot(id: id, ts: ts)
        nextIndex = (nextIndex + 1) % capacity

        // Track the run of one identical non-nil id (breaks on nil or on any id
        // change) for the stability early exit.
        if id != nil {
            if stableIDSince == nil || previousID != id {
                stableIDSince = ts
            }
        } else {
            stableIDSince = nil
        }

        if detectsFlap(now: ts) {
            isDefensive = true
            lastFlapAt = ts
        }

        if isDefensive {
            if ts - lastFlapAt >= cooldown {
                isDefensive = false
            } else if id != nil, let since = stableIDSince, ts - since >= stability {
                isDefensive = false
            }
        }

        return isDefensive
    }

    /// True when the visible ring entries (those within flapWindow) show a flap:
    /// >=2 distinct non-nil ids or >=2 nil<->non-nil transitions.
    private func detectsFlap(now: TimeInterval) -> Bool {
        let windowStart = now - flapWindow

        // nil<->non-nil transitions between consecutive visible entries.
        var transitions = 0
        var previousWasNil: Bool?
        for i in 0..<capacity {
            let slot = slots[(nextIndex + i) % capacity]
            guard slot.ts >= windowStart else { continue }
            let isNil = (slot.id == nil)
            if let previous = previousWasNil, previous != isNil {
                transitions += 1
            }
            previousWasNil = isNil
        }
        if transitions >= 2 { return true }

        // Distinct non-nil ids among visible entries (O(n²) over <=8 entries,
        // UUID comparisons only — no allocation).
        var distinct = 0
        for i in 0..<capacity {
            let slotI = slots[(nextIndex + i) % capacity]
            guard let idI = slotI.id, slotI.ts >= windowStart else { continue }
            var seenBefore = false
            for j in 0..<i {
                let slotJ = slots[(nextIndex + j) % capacity]
                guard let idJ = slotJ.id, slotJ.ts >= windowStart else { continue }
                if idJ == idI {
                    seenBefore = true
                    break
                }
            }
            if !seenBefore {
                distinct += 1
            }
        }
        return distinct >= 2
    }
}
