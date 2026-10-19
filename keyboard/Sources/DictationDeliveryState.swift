import Foundation

struct DictationDeliveryState: Codable, Equatable {
    enum Phase: String, Codable {
        case claimed
        case insertionIntent
        case cleared
    }

    struct Record: Codable, Equatable {
        let id: UUID
        let originalTimestamp: Date
        let phase: Phase
    }

    static let capacity = 4

    private(set) var records: [Record]

    private enum CodingKeys: String, CodingKey {
        case records
    }

    init(records: [Record] = []) {
        self.records = Array(records.suffix(Self.capacity))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = Array(try container.decode([Record].self, forKey: .records).suffix(Self.capacity))
    }

    func record(for id: UUID) -> Record? {
        records.first { $0.id == id }
    }

    mutating func advance(id: UUID, originalTimestamp: Date, to phase: Phase) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            let current = records[index]
            guard Self.order(phase) > Self.order(current.phase) else { return }
            records[index] = Record(id: id, originalTimestamp: current.originalTimestamp, phase: phase)
            return
        }
        records.append(Record(id: id, originalTimestamp: originalTimestamp, phase: phase))
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    private static func order(_ phase: Phase) -> Int {
        switch phase {
        case .claimed: return 0
        case .insertionIntent: return 1
        case .cleared: return 2
        }
    }
}
