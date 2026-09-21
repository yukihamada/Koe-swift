import Foundation

/// 文字起こしの進行状態
enum VoiceMemoTranscriptStatus: Codable, Equatable {
    case none
    case queued
    case running(Double)   // 0.0-1.0
    case done
    case failed(String)

    private enum Kind: String, Codable { case none, queued, running, done, failed }
    private struct Box: Codable {
        let kind: Kind
        var progress: Double?
        var message: String?
    }

    init(from decoder: Decoder) throws {
        let box = try Box(from: decoder)
        switch box.kind {
        case .none: self = .none
        case .queued: self = .queued
        case .running: self = .running(box.progress ?? 0)
        case .done: self = .done
        case .failed: self = .failed(box.message ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        let box: Box
        switch self {
        case .none: box = Box(kind: .none, progress: nil, message: nil)
        case .queued: box = Box(kind: .queued, progress: nil, message: nil)
        case .running(let p): box = Box(kind: .running, progress: p, message: nil)
        case .done: box = Box(kind: .done, progress: nil, message: nil)
        case .failed(let m): box = Box(kind: .failed, progress: nil, message: m)
        }
        try box.encode(to: encoder)
    }
}

/// 1件のボイスメモ(ディクテーション用 AudioRecorder/HistoryStore とは完全に独立したデータ系統)。
struct VoiceMemoRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// voicememos/ ディレクトリからの相対ファイル名 (memo_YYYYMMDD-HHmmss_xxxxxxxx.m4a)
    var fileName: String
    var createdAt: Date
    /// 秒。録音直後は 0 の可能性があり、起動時破損検知の判定に使う。
    var duration: Double
    var title: String
    var isFavorite: Bool = false
    var tags: [String] = []
    var sizeBytes: Int = 0
    var waveformPeaks: [Float]? = nil
    var transcript: String? = nil
    var transcriptStatus: VoiceMemoTranscriptStatus = .none
    var summary: String? = nil
    var koeListenURL: String? = nil
    var takibiLogID: String? = nil
    /// 🎙→📻 自分の声かどうかの判定結果(未実施=nil)。ラジオ(自分の部屋)へアップロード済みならtrue。
    var radioUploaded: Bool = false
    /// 録音開始時に一度だけ取得した地名(逆ジオコーディング済み・人が読める形。例: "渋谷区")。
    /// 位置情報が無効/権限なし/取得失敗の場合は nil のまま(黙って諦める。録音自体は失敗させない)。
    var location: String? = nil

    // 後方互換デコード(HistoryEntry と同じ方針: 将来フィールド追加でも既存 index.json を壊さない)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileName = try c.decode(String.self, forKey: .fileName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        waveformPeaks = try c.decodeIfPresent([Float].self, forKey: .waveformPeaks)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        transcriptStatus = try c.decodeIfPresent(VoiceMemoTranscriptStatus.self, forKey: .transcriptStatus) ?? .none
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        koeListenURL = try c.decodeIfPresent(String.self, forKey: .koeListenURL)
        takibiLogID = try c.decodeIfPresent(String.self, forKey: .takibiLogID)
        radioUploaded = try c.decodeIfPresent(Bool.self, forKey: .radioUploaded) ?? false
        location = try c.decodeIfPresent(String.self, forKey: .location)
    }

    init(fileName: String, createdAt: Date, duration: Double, title: String) {
        self.fileName = fileName
        self.createdAt = createdAt
        self.duration = duration
        self.title = title
    }

    var fileURL: URL {
        VoiceMemoLibrary.voicememosDir.appendingPathComponent(fileName)
    }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return "\(f.string(from: createdAt)) の録音"
    }
}

/// ボイスレコーダー機能のデータストア。既存 HistoryStore と同じ atomic 書込+debounced save パターン。
/// 保存先は AudioRecorder.audioDir (recordings/) や AudioArchive とは完全に別ディレクトリ
/// (自動 prune に巻き込まれないようにするための意図的な分離。VoiceMemoModels.swift 冒頭コメント参照)。
final class VoiceMemoLibrary: ObservableObject {
    static let shared = VoiceMemoLibrary()

    @Published var records: [VoiceMemoRecord] = []

    private var saveTimer: Timer?

    /// ユーザーが明示的に録音したボイスメモの保存先。
    /// recordings/ (ディクテーション用, 最新5件以外自動削除) には絶対に置かない。
    static let voicememosDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe/voicememos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static let ttsCacheDir: URL = {
        let dir = voicememosDir.appendingPathComponent("tts_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let indexURL: URL = voicememosDir.appendingPathComponent("index.json")

    private init() { load() }

    func add(_ record: VoiceMemoRecord) {
        DispatchQueue.main.async {
            self.records.insert(record, at: 0)
            self.saveNow()  // 録音は貴重なデータ。debounce せず即時保存
        }
    }

    /// メインスレッドから呼ぶこと(HistoryStore.toggleFavorite と同じ規約。ObservableObject の
    /// @Published 更新は UI コールバック起点が前提のため、ここでは非同期ディスパッチしない)。
    func update(id: UUID, _ mutate: (inout VoiceMemoRecord) -> Void) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[idx])
        debouncedSave()
    }

    /// 即時保存が必要な更新(文字起こし完了など、失っては困る変更)。メインスレッドから呼ぶこと。
    func updateAndSaveNow(id: UUID, _ mutate: (inout VoiceMemoRecord) -> Void) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[idx])
        saveNow()
    }

    func record(id: UUID) -> VoiceMemoRecord? {
        records.first { $0.id == id }
    }

    func delete(id: UUID) {
        guard let rec = records.first(where: { $0.id == id }) else { return }
        // ファイルはゴミ箱へ(即rmしない=誤操作からの復旧余地を残す)
        try? FileManager.default.trashItem(at: rec.fileURL, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: Self.ttsCacheDir.appendingPathComponent("\(rec.id.uuidString).mp3"))
        DispatchQueue.main.async {
            self.records.removeAll { $0.id == id }
            self.saveNow()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode([VoiceMemoRecord].self, from: data) else {
            let backup = indexURL.deletingLastPathComponent()
                .appendingPathComponent("index.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: indexURL, to: backup)
            klog("VoiceMemoLibrary: index.json corrupt — backed up to \(backup.lastPathComponent)")
            return
        }
        records = decoded
        reconcileWithDisk()
    }

    /// 起動時: duration==0 のまま残っている(録音中にクラッシュ等で終了した)エントリのファイルが
    /// 開けるか検査し、開ければ長さを補完、開けなければ「破損」として duration=-1 にする(黙って消さない)。
    private func reconcileWithDisk() {
        for i in records.indices where records[i].duration == 0 {
            let url = records[i].fileURL
            if let d = try? AVURLAssetDurationSeconds(url), d > 0 {
                records[i].duration = d
            } else if !FileManager.default.fileExists(atPath: url.path) {
                records[i].duration = -1
            } else {
                records[i].duration = -1
            }
        }
    }

    private func debouncedSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    /// 録音停止直後は peaks/transcript/summary が短時間に連続保存される。並行キューだと書込みの
    /// 完了順が入れ替わり得り、新しいスナップショットを古いスナップショットが後から上書きしてしまう
    /// (実機で summary が保存されない事象を引き起こした)。直列キューで発行順=書込み順を保証する。
    private static let writeQueue = DispatchQueue(label: "com.yuki.koe.voicememolibrary.write")

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        let snapshot = records
        Self.writeQueue.async { [weak self] in
            guard let self else { return }
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: self.indexURL, options: .atomic)
        }
    }
}

import AVFoundation

/// ファイルの duration を同期的に取る小ヘルパー(起動時の破損検知専用・軽量ファイルのみ想定)。
/// AVURLAsset.duration は非同期 load(.duration) が推奨だが、ここは軽量な m4a を起動時に
/// 1件ずつ検査するだけなので AVAudioPlayer の同期 duration で十分。
func AVURLAssetDurationSeconds(_ url: URL) throws -> Double {
    let player = try AVAudioPlayer(contentsOf: url)
    return player.duration
}
