import Foundation

enum FollowMeDeliveryGate {
    enum TerminalStatus {
        case completed
        case error
        case cancelled
    }

    enum Decision {
        case deliver
        case waitNoField
        case dropConsumed
        case dropExpired
    }

    static func decide(
        id: UUID,
        status: TerminalStatus,
        terminalAt: Date,
        now: Date,
        windowSeconds: Int,
        consumedIDs: [String],
        hasRealField: Bool
    ) -> Decision {
        let idString = id.uuidString
        guard !consumedIDs.contains(idString) else { return .dropConsumed }
        guard now.timeIntervalSince(terminalAt) <= Double(windowSeconds) else {
            return .dropExpired
        }
        _ = status
        return hasRealField ? .deliver : .waitNoField
    }
}

struct FollowMeConsumedIDRing {
    private(set) var ids: [String]
    let capacity: Int

    init(ids: [String] = [], capacity: Int = 4) {
        self.capacity = max(0, capacity)
        self.ids = Array(ids.suffix(max(0, capacity)))
    }

    static func legacySeed(_ id: String?) -> FollowMeConsumedIDRing {
        FollowMeConsumedIDRing(ids: id.map { [$0] } ?? [])
    }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    mutating func append(_ id: String) {
        guard capacity > 0 else { return }
        ids.append(id)
        if ids.count > capacity {
            ids.removeFirst(ids.count - capacity)
        }
    }
}
