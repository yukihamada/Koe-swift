import Foundation

/// カスタム辞書: 略語 → 展開テキスト
@MainActor
final class TextExpansionStore: ObservableObject {
    static let shared = TextExpansionStore()

    struct Entry: Identifiable, Codable {
        let id: UUID
        var shortcut: String  // 例: "えねあい"
        var expansion: String // 例: "ENAI"
        init(shortcut: String, expansion: String) {
            self.id = UUID()
            self.shortcut = shortcut
            self.expansion = expansion
        }
    }

    @Published var entries: [Entry] = []

    private let key = "koe_text_expansions"

    init() { load() }

    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }
        var result = text
        for entry in entries where !entry.shortcut.isEmpty {
            result = result.replacingOccurrences(of: entry.shortcut, with: entry.expansion)
        }
        return result
    }

    func add(shortcut: String, expansion: String) {
        entries.append(Entry(shortcut: shortcut, expansion: expansion))
        save()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets as IndexSet)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = items
    }
}
