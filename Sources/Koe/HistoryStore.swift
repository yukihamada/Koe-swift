import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var text: String
    let date: Date
    var isFavorite: Bool = false
    /// 紐付く音声ファイルのID（AudioArchive で保存）
    var audioFileID: String?
    /// 認識にかかった時間（秒）
    var recognitionTime: Double?
    /// 使用したモデル名
    var modelName: String?
    /// 再認識前の元テキスト（精度比較用）
    var originalText: String?

    // Backward-compatible decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        date = try container.decode(Date.self, forKey: .date)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        audioFileID = try container.decodeIfPresent(String.self, forKey: .audioFileID)
        recognitionTime = try container.decodeIfPresent(Double.self, forKey: .recognitionTime)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText)
    }

    init(text: String, date: Date, isFavorite: Bool = false, audioFileID: String? = nil,
         recognitionTime: Double? = nil, modelName: String? = nil) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.isFavorite = isFavorite
        self.audioFileID = audioFileID
        self.recognitionTime = recognitionTime
        self.modelName = modelName
    }
}

class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published var entries: [HistoryEntry] = []

    private let maxEntries = 2000
    private var saveTimer: Timer?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() { load() }

    func add(_ text: String, audioFileID: String? = nil,
             recognitionTime: Double? = nil, modelName: String? = nil) {
        let entry = HistoryEntry(text: text, date: Date(), audioFileID: audioFileID,
                                  recognitionTime: recognitionTime, modelName: modelName)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries { self.entries.removeLast(self.entries.count - self.maxEntries) }
            self.debouncedSave()
        }
    }

    func clear() {
        entries = []
        saveNow()
    }

    func search(_ query: String) -> [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        let lowered = query.lowercased()
        return entries.filter { $0.text.lowercased().contains(lowered) }
    }

    func toggleFavorite(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite.toggle()
        debouncedSave()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        debouncedSave()
    }

    func updateText(id: UUID, newText: String, modelName: String? = nil, recognitionTime: Double? = nil) {
        DispatchQueue.main.async {
            guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
            // 元テキストを保存（初回の再認識時のみ）
            if self.entries[index].originalText == nil {
                self.entries[index].originalText = self.entries[index].text
            }
            self.entries[index].text = newText
            if let m = modelName { self.entries[index].modelName = m }
            if let t = recognitionTime { self.entries[index].recognitionTime = t }
            self.debouncedSave()
        }
    }

    func exportAsText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return entries.map { "\(formatter.string(from: $0.date)) | \($0.text)" }
            .joined(separator: "\n")
    }

    func exportAsCSV() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let bom = "\u{FEFF}"
        let header = "日時,テキスト,お気に入り"
        let rows = entries.map { entry -> String in
            let escaped = entry.text.replacingOccurrences(of: "\"", with: "\"\"")
            let fav = entry.isFavorite ? "★" : ""
            return "\(formatter.string(from: entry.date)),\"\(escaped)\",\(fav)"
        }
        return bom + ([header] + rows).joined(separator: "\n")
    }

    func exportAsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func debouncedSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.entries) else { return }
            try? data.write(to: self.fileURL)
        }
    }
}
