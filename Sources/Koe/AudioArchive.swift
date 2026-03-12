import Foundation

/// 認識済み音声ファイルを永続保存し、後から学習データとして利用可能にする。
/// 保存先: ~/Library/Application Support/com.yuki.koe/audio/
/// ファイル名: {UUID}.wav  （HistoryEntry.audioFileID と対応）
class AudioArchive {
    static let shared = AudioArchive()

    /// 保存日数（これより古いファイルは自動削除）
    var retentionDays = 30

    private let audioDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir
    }()

    /// 音声ファイルを永続ストレージにコピーし、ファイルIDを返す
    func save(tempURL: URL) -> String? {
        let fileID = UUID().uuidString
        let dest = audioDir.appendingPathComponent("\(fileID).wav")
        do {
            try FileManager.default.copyItem(at: tempURL, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            klog("AudioArchive: saved \(fileID).wav (\(size / 1024)KB)")
            return fileID
        } catch {
            klog("AudioArchive: save failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// ファイルIDからURLを取得
    func url(for fileID: String) -> URL? {
        let url = audioDir.appendingPathComponent("\(fileID).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 保存済みファイル数とトータルサイズ
    func stats() -> (count: Int, totalMB: Double) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey]) else {
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

    /// retentionDays より古いファイルを削除
    func cleanOldFiles() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: audioDir, includingPropertiesForKeys: [.creationDateKey]
            ) else { return }
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            var removed = 0
            for file in files where file.pathExtension == "wav" {
                guard let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate),
                      created < cutoff else { continue }
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
            if removed > 0 {
                klog("AudioArchive: cleaned \(removed) files older than \(retentionDays) days")
            }
        }
    }

    /// 全音声ファイルを削除
    func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
        klog("AudioArchive: cleared all files")
    }
}
