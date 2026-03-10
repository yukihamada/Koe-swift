import Foundation
import AppKit

class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    @Published var isActive = false
    @Published var entryCount = 0
    private var outputURL: URL?
    private var audioDir: URL?
    private var fileHandle: FileHandle?
    private var startDate: Date?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = fmt.string(from: Date())
        startDate = Date()

        // 議事録フォルダを作成（テキスト + 音声を格納）
        let baseDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe_議事録_\(timestamp)")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // テキストファイル
        let textURL = baseDir.appendingPathComponent("議事録.txt")
        FileManager.default.createFile(atPath: textURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: textURL)
        outputURL = baseDir

        // 音声保存用サブフォルダ
        let aDir = baseDir.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        audioDir = aDir

        isActive = true
        entryCount = 0
        klog("MeetingMode: started \(baseDir.lastPathComponent)")

        let header = """
        # Koe 議事録
        開始: \(Date())
        ---

        """
        fileHandle?.write(Data(header.utf8))
    }

    func stop() {
        // フッター追加
        if let start = startDate {
            let duration = Int(Date().timeIntervalSince(start))
            let min = duration / 60
            let sec = duration % 60
            let footer = "\n---\n終了: \(Date())\n所要時間: \(min)分\(sec)秒\n発言数: \(entryCount)件\n"
            fileHandle?.write(Data(footer.utf8))
        }

        try? fileHandle?.close()
        fileHandle = nil
        isActive = false
        startDate = nil
        klog("MeetingMode: stopped (\(entryCount)件)")

        if let url = outputURL {
            // フォルダをFinderで開く
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    /// テキストを追記（音声URLがあれば音声も保存）
    func append(text: String, audioURL: URL? = nil, speaker: Int? = nil) {
        guard isActive else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let timeStr = fmt.string(from: Date())

        entryCount += 1

        // 音声ファイルをコピー保存
        var audioNote = ""
        if let src = audioURL, let dir = audioDir {
            let fileName = String(format: "%03d_%@.wav", entryCount, timeStr.replacingOccurrences(of: ":", with: ""))
            let dest = dir.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                audioNote = " [audio: \(fileName)]"
                klog("MeetingMode: saved audio \(fileName)")
            } catch {
                klog("MeetingMode: audio save failed \(error.localizedDescription)")
            }
        }

        let speakerLabel = speaker.map { " [話者\($0 + 1)]" } ?? ""
        let line = "[\(timeStr)]\(speakerLabel) \(text)\(audioNote)\n"
        fileHandle?.write(Data(line.utf8))
    }

    /// 話者分離付きセグメントを一括追記
    func appendSpeakerSegments(_ segments: [WhisperContext.SpeakerSegment], audioURL: URL? = nil) {
        guard isActive, !segments.isEmpty else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let timeStr = fmt.string(from: Date())

        // 同じ話者の連続セグメントをマージ
        var merged: [(speaker: Int, text: String)] = []
        for seg in segments {
            if let last = merged.last, last.speaker == seg.speaker {
                merged[merged.count - 1].text += seg.text
            } else {
                merged.append((speaker: seg.speaker, text: seg.text))
            }
        }

        // 音声ファイルをコピー保存
        var audioNote = ""
        if let src = audioURL, let dir = audioDir {
            let fileName = String(format: "%03d_%@.wav", entryCount + 1, timeStr.replacingOccurrences(of: ":", with: ""))
            let dest = dir.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                audioNote = " [audio: \(fileName)]"
                klog("MeetingMode: saved audio \(fileName)")
            } catch {
                klog("MeetingMode: audio save failed \(error.localizedDescription)")
            }
        }

        for entry in merged {
            entryCount += 1
            let line = "[\(timeStr)] [話者\(entry.speaker + 1)] \(entry.text)\(audioNote)\n"
            fileHandle?.write(Data(line.utf8))
            // audioNote は最初のエントリのみ
            audioNote = ""
        }
    }
}
