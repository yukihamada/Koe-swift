import Foundation

/// 音声アーカイブの自動 prune 処理。
/// - 設定で `audioArchiveAutoPrune` が ON の時のみ動作
/// - (a) `audioArchiveMaxDays` より古いファイルを削除
/// - (b) 残ったファイルの合計サイズが `audioArchiveMaxGB` を超えていれば古いものから削除
/// 全処理はバックグラウンドキューで非同期に行う。
enum AudioArchivePruner {
    private static let queue = DispatchQueue(label: "koe.AudioArchivePruner", qos: .utility)

    /// 設定を読んで非同期に prune 実行（メインスレッドからの呼び出しを想定）
    static func pruneIfNeeded() {
        let settings = AppSettings.shared
        guard settings.audioArchiveEnabled, settings.audioArchiveAutoPrune else { return }
        let dirPath = settings.audioArchiveResolvedPath
        let maxDays = settings.audioArchiveMaxDays
        let maxBytes = Int64(settings.audioArchiveMaxGB * 1_073_741_824)  // GB → bytes
        queue.async {
            runPrune(dirPath: dirPath, maxDays: maxDays, maxBytes: maxBytes)
        }
    }

    /// 同期実行版（テスト・コマンド経由用）
    static func runPrune(dirPath: String, maxDays: Int, maxBytes: Int64) {
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys
        ) else { return }

        // wav ファイルのみを対象。属性を一度取得してタプルでキャッシュ。
        struct Entry {
            let url: URL
            let created: Date
            let size: Int64
        }
        var entries: [Entry] = []
        for f in files where f.pathExtension == "wav" {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let created = v?.creationDate ?? Date.distantPast
            let size = Int64(v?.fileSize ?? 0)
            entries.append(Entry(url: f, created: created, size: size))
        }

        // (a) 日数超過 prune
        var removedByAge = 0
        if maxDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(maxDays) * 86400)
            entries = entries.filter { e in
                if e.created < cutoff {
                    try? FileManager.default.removeItem(at: e.url)
                    removedByAge += 1
                    return false
                }
                return true
            }
        }

        // (b) 容量超過 prune（古い順に削る）
        var removedBySize = 0
        var total: Int64 = entries.reduce(0) { $0 + $1.size }
        if maxBytes > 0, total > maxBytes {
            entries.sort { $0.created < $1.created }  // 古い順
            for e in entries {
                if total <= maxBytes { break }
                try? FileManager.default.removeItem(at: e.url)
                total -= e.size
                removedBySize += 1
            }
        }

        if removedByAge > 0 || removedBySize > 0 {
            klog("AudioArchive: pruned \(removedByAge) old + \(removedBySize) over-size")
        }
    }
}
