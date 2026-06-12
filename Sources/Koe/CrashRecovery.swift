import Foundation

// MARK: - PartialTranscriptStore

/// 録音中のストリーミング認識テキストをセッション毎のファイルに逐次永続化する。
/// アプリが強制終了・クラッシュしても、直前までの認識結果が次回起動時に復旧できる。
///
/// ファイル: ~/Library/Application Support/com.yuki.koe/partials/partial_{sessionID}.json
/// 正常に認識が完了して履歴に保存されたら finish(id:) で削除する。
/// 起動時に残っているファイル = 前回セッションがクラッシュした証拠 → CrashRecovery が履歴へ復旧。
final class PartialTranscriptStore {
    static let shared = PartialTranscriptStore()

    struct Session: Codable {
        let id: UUID
        let startedAt: Date
        var text: String
        var audioPath: String?
    }

    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe/partials", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()

    private(set) var currentSessionID: UUID?
    private var currentSession: Session?
    private let queue = DispatchQueue(label: "com.yuki.koe.partial", qos: .utility)
    private var lastWrite = Date.distantPast
    /// 書き込み間隔の下限（毎40msのストリーミング更新で都度 fsync しない）
    private let minWriteInterval: TimeInterval = 0.5

    private static func fileURL(for id: UUID) -> URL {
        dir.appendingPathComponent("partial_\(id.uuidString).json")
    }

    /// 録音開始時に呼ぶ。新しいセッションのIDを返す。
    @discardableResult
    func begin(audioPath: String?) -> UUID {
        let session = Session(id: UUID(), startedAt: Date(), text: "", audioPath: audioPath)
        currentSessionID = session.id
        currentSession = session
        lastWrite = .distantPast
        write(session, force: true)
        return session.id
    }

    /// ストリーミング途中結果が更新されるたびに呼ぶ（内部で0.5秒スロットル）。
    func update(text: String) {
        guard var session = currentSession else { return }
        session.text = text
        currentSession = session
        write(session, force: false)
    }

    /// 認識完了（履歴へ保存済み）またはユーザーキャンセル時に呼ぶ。該当ファイルを削除。
    func finish(id: UUID?) {
        guard let id else { return }
        if currentSessionID == id {
            currentSessionID = nil
            currentSession = nil
        }
        let url = Self.fileURL(for: id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// 現在進行中のセッションを終了（ESCキャンセル等）。
    func finishCurrent() { finish(id: currentSessionID) }

    private func write(_ session: Session, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) >= minWriteInterval else { return }
        lastWrite = now
        let url = Self.fileURL(for: session.id)
        queue.async {
            guard let data = try? JSONEncoder().encode(session) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 起動時: 前回クラッシュで残ったセッションを列挙（現行セッションは存在しない前提＝起動直後に呼ぶ）。
    static func pendingSessions() -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files.filter { $0.lastPathComponent.hasPrefix("partial_") }
            .compactMap { url -> Session? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Session.self, from: data)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func removePendingFile(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}

// MARK: - CrashRecovery

/// 起動時に前回セッションの残骸を回収する:
/// 1. 録音中だった孤児 WAV（rec_*.wav）→ AudioArchive へ永続保存
/// 2. 認識途中テキスト（partials/）→ 履歴へ [復旧] エントリとして登録
/// 3. 回収済みアイテムを返し、AppDelegate がバックグラウンドで再認識する
enum CrashRecovery {

    struct RecoveredItem {
        let historyID: UUID
        let audioURL: URL?   // 再認識用（アーカイブ済みの恒久パス）
    }

    /// 1秒未満 (16kHz/16bit mono ≈ 32KB/s) の録音はノイズとみなして破棄
    private static let minMeaningfulBytes = 32_000

    @discardableResult
    static func run() -> [RecoveredItem] {
        var items: [RecoveredItem] = []

        // ── 1. 孤児録音のスキャン（新ディレクトリ + 旧 tmp ディレクトリ）──
        var orphanAudio: [String: URL] = [:]  // 元パス → アーカイブ後URL
        let dirs = [AudioRecorder.audioDir, AudioRecorder.legacyTmpDir]
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            // rec_*.wav（録音中だった孤児）+ 旧版の固定名 rec.wav のみ。
            // recognize_*.wav は処理済み/意図的スキップ分なので対象外（毎起動の重複復旧を防ぐ）。
            for file in files where (file.lastPathComponent.hasPrefix("rec_") || file.lastPathComponent == "rec.wav")
                                     && file.pathExtension == "wav" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size < minMeaningfulBytes {
                    // prepare() だけして録音されなかった残骸 → 掃除
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                klog("CrashRecovery: found orphan recording \(file.lastPathComponent) (\(size / 1024)KB)")
                if let archiveID = AudioArchive.shared.save(tempURL: file),
                   let archivedURL = AudioArchive.shared.url(for: archiveID) {
                    orphanAudio[file.path] = archivedURL
                    orphanAudioIDs[file.path] = archiveID
                    try? FileManager.default.removeItem(at: file)
                } else {
                    // アーカイブ無効/失敗 → 消さずに saved_*.wav へ改名して保持
                    // （rec* のままだと次回起動の復旧スキャンに再ヒットして履歴が重複する）
                    let kept = AudioRecorder.audioDir.appendingPathComponent(
                        "saved_\(UUID().uuidString.prefix(8)).wav")
                    if (try? FileManager.default.moveItem(at: file, to: kept)) != nil {
                        orphanAudio[file.path] = kept
                    } else {
                        orphanAudio[file.path] = file
                    }
                }
            }
        }

        // ── 2. 認識途中テキストの復旧 ──
        var claimedAudioPaths = Set<String>()
        for session in PartialTranscriptStore.pendingSessions() {
            let audioPath = session.audioPath
            let archivedURL = audioPath.flatMap { orphanAudio[$0] }
            let archiveID = audioPath.flatMap { orphanAudioIDs[$0] }
            if let p = audioPath { claimedAudioPaths.insert(p) }

            let trimmed = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // テキストも音声もない残骸は捨てる
            if trimmed.isEmpty && archivedURL == nil {
                PartialTranscriptStore.removePendingFile(id: session.id)
                continue
            }
            let text = trimmed.isEmpty ? "[復旧] 前回の録音（認識前に終了）" : "[復旧・途中まで] \(trimmed)"
            let entryID = HistoryStore.shared.addSync(text, audioFileID: archiveID,
                                                      modelName: "復旧 (Apple Speech 途中結果)",
                                                      date: session.startedAt)
            klog("CrashRecovery: restored partial transcript '\(trimmed.prefix(40))' (audio: \(archivedURL != nil))")
            items.append(RecoveredItem(historyID: entryID, audioURL: archivedURL))
            PartialTranscriptStore.removePendingFile(id: session.id)
        }

        // ── 3. 途中テキストと紐付かなかった孤児録音も履歴に登録 ──
        for (origPath, url) in orphanAudio where !claimedAudioPaths.contains(origPath) {
            let entryID = HistoryStore.shared.addSync("[復旧] 前回の録音（未認識）",
                                                      audioFileID: orphanAudioIDs[origPath],
                                                      modelName: "復旧",
                                                      date: Date())
            items.append(RecoveredItem(historyID: entryID, audioURL: url))
        }

        if !items.isEmpty {
            HistoryStore.shared.flushSync()
            klog("CrashRecovery: recovered \(items.count) item(s)")
        }
        orphanAudioIDs = [:]
        return items
    }

    /// run() 内の一時マップ（元パス → AudioArchive fileID）
    private static var orphanAudioIDs: [String: String] = [:]
}
