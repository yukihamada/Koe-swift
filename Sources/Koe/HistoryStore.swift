import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id: UUID = UUID()
    let text: String
    let date: Date
}

class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() { load() }

    func add(_ text: String) {
        let entry = HistoryEntry(text: text, date: Date())
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > 500 { self.entries = Array(self.entries.prefix(500)) }
            self.save()
        }
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL)
    }
}
