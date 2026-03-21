import Foundation

struct FeedbackEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let screenName: String
    let text: String
    let hasScreenshot: Bool

    init(screenName: String, text: String, hasScreenshot: Bool = false) {
        self.id = UUID()
        self.timestamp = Date()
        self.screenName = screenName
        self.text = text
        self.hasScreenshot = hasScreenshot
    }
}

@MainActor
final class FeedbackManager: ObservableObject {
    static let shared = FeedbackManager()

    private let storageKey = "koe_feedback_entries"

    @Published private(set) var entries: [FeedbackEntry] = []

    private init() {
        entries = loadEntries()
    }

    func submit(screenName: String, text: String, hasScreenshot: Bool = false) {
        let entry = FeedbackEntry(screenName: screenName, text: text, hasScreenshot: hasScreenshot)
        entries.insert(entry, at: 0)
        saveEntries()
    }

    func deleteEntry(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        saveEntries()
    }

    func clearAll() {
        entries.removeAll()
        saveEntries()
    }

    /// Export all feedback as a plain-text string for sharing.
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.screenName)] \(entry.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func loadEntries() -> [FeedbackEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FeedbackEntry].self, from: data) else {
            return []
        }
        return decoded
    }
}
