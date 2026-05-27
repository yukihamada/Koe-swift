import Foundation

/// 認識済み音声ファイルを永続保存し、後から学習データとして利用可能にする。
///
/// 保存はユーザー同意 (`AppSettings.audioArchiveEnabled`) が ON の時のみ行う。
/// 保存先・容量上限・日数上限は AppSettings から都度参照する。
/// ファイル名: {UUID}.wav  （HistoryEntry.audioFileID と対応）
class AudioArchive {
    static let shared = AudioArchive()

    /// 互換用: かつての固定保存日数。新コードは AppSettings.audioArchiveMaxDays を参照する。
    var retentionDays = 30

    /// 現在の保存ディレクトリ URL を返し、必要なら作成する。
    /// アーカイブが無効化されていても、過去ファイルを読むために URL は返す。
    private func archiveDir() -> URL {
        let path = AppSettings.shared.audioArchiveResolvedPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    /// 音声ファイルを永続ストレージにコピーし、ファイルIDを返す。
    /// `audioArchiveEnabled = false` の時は何もせず nil を返す（プライバシー保護）。
    func save(tempURL: URL) -> String? {
        guard AppSettings.shared.audioArchiveEnabled else {
            klog("AudioArchive: skipped (disabled by user)")
            return nil
        }
        let fileID = UUID().uuidString
        let dest = archiveDir().appendingPathComponent("\(fileID).wav")
        do {
            try FileManager.default.copyItem(at: tempURL, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            klog("AudioArchive: saved \(fileID).wav (\(size / 1024)KB)")
            // 保存のたびに上限チェック → 必要なら prune
            AudioArchivePruner.pruneIfNeeded()
            return fileID
        } catch {
            klog("AudioArchive: save failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// ファイルIDからURLを取得（無効化中でも過去ファイルは参照可能）
    func url(for fileID: String) -> URL? {
        let url = archiveDir().appendingPathComponent("\(fileID).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 保存済みファイル数とトータルサイズ
    func stats() -> (count: Int, totalMB: Double) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: archiveDir(), includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        let wavFiles = files.filter { $0.pathExtension == "wav" }
        var total: Int64 = 0
        for f in wavFiles {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return (wavFiles.count, Double(total) / 1_048_576)
    }

    /// 古いファイル削除（互換 API — 内部実装は AudioArchivePruner に委譲）
    func cleanOldFiles() {
        AudioArchivePruner.pruneIfNeeded()
    }

    /// 全音声ファイルを削除
    func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: archiveDir(), includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
        klog("AudioArchive: cleared all files")
    }
}
