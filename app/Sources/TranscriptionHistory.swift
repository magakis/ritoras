import Foundation

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
}

class TranscriptionHistory: ObservableObject {
    static let shared = TranscriptionHistory()
    @Published private(set) var entries: [TranscriptionEntry] = []

    private let key = "transcription.history"
    private let maxEntries = 50

    init() {
        load()
    }

    func add(text: String) {
        let entry = TranscriptionEntry(id: UUID(), text: text, timestamp: Date())
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) else {
            return
        }
        entries = decoded
    }
}
