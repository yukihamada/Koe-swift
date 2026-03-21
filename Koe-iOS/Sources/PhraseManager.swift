import Foundation
import SwiftUI

class PhraseManager: ObservableObject {
    static let shared = PhraseManager()

    @AppStorage("koe_phrases") private var phrasesJSON: String = "[]"

    @Published var phrases: [String] = [] {
        didSet { save() }
    }

    private init() {
        load()
    }

    private func load() {
        guard let data = phrasesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            phrases = []
            return
        }
        phrases = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(phrases),
              let json = String(data: data, encoding: .utf8) else { return }
        phrasesJSON = json
    }

    func add(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phrases.append(trimmed)
    }

    func delete(at offsets: IndexSet) {
        phrases.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        phrases.move(fromOffsets: source, toOffset: destination)
    }

    func update(at index: Int, to newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phrases.indices.contains(index) else { return }
        phrases[index] = trimmed
    }
}
