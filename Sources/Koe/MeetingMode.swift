import Foundation
import AppKit

class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    @Published var isActive = false
    @Published var entryCount = 0
    @Published var charCount = 0
    @Published var isFormatting = false
    private var outputURL: URL?
    private var audioDir: URL?
    private var fileHandle: FileHandle?
    private var startDate: Date?
    /// LLM整形用に生テキストを蓄積
    private var rawEntries: [String] = []

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
        charCount = 0
        rawEntries = []
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
        var durationText = ""
        if let start = startDate {
            let duration = Int(Date().timeIntervalSince(start))
            let min = duration / 60
            let sec = duration % 60
            durationText = "\(min)分\(sec)秒"
            let footer = "\n---\n終了: \(Date())\n所要時間: \(durationText)\n発言数: \(entryCount)件\n"
            fileHandle?.write(Data(footer.utf8))
        }

        try? fileHandle?.close()
        fileHandle = nil
        isActive = false
        let savedEntries = rawEntries
        let savedDir = outputURL
        let savedCount = entryCount
        startDate = nil
        klog("MeetingMode: stopped (\(entryCount)件)")

        // LLMで整形
        if !savedEntries.isEmpty, let dir = savedDir {
            formatWithLLM(entries: savedEntries, duration: durationText,
                          count: savedCount, outputDir: dir)
        } else if let url = outputURL {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    // MARK: - LLM整形

    private func formatWithLLM(entries: [String], duration: String,
                                count: Int, outputDir: URL) {
        isFormatting = true
        let rawText = entries.joined(separator: "\n")
        klog("MeetingMode: formatting \(entries.count) entries with LLM...")

        let systemPrompt = """
        あなたは議事録整形アシスタントです。以下の音声認識テキストを整形してください。

        ルール:
        - 誤字・脱字を修正
        - 句読点を適切に追加
        - 話題ごとに段落分け
        - 重要なポイントや決定事項があれば「## 要点」としてまとめる
        - タイムスタンプは残す
        - 話者情報があれば活かす
        - 元の意味を変えない
        - Markdown形式で出力
        """

        let userPrompt = """
        所要時間: \(duration)
        発言数: \(count)件

        --- 生テキスト ---
        \(rawText)
        """

        // ローカルLLMのみ使用（リモートには送らない）
        let llm = LlamaContext.shared
        guard let localModel = llm.selectedModel, llm.isDownloaded(localModel) else {
            klog("MeetingMode: no local LLM available, skipping formatting")
            finishFormatting(nil, outputDir: outputDir)
            return
        }

        klog("MeetingMode: using local LLM (\(localModel.name))")

        let doGenerate = { [weak self] in
            llm.generate(system: systemPrompt, user: userPrompt, maxTokens: 1024) { result in
                DispatchQueue.main.async {
                    if let text = result, !text.isEmpty {
                        klog("MeetingMode: local LLM done (\(text.count) chars)")
                        self?.finishFormatting(text, outputDir: outputDir)
                    } else {
                        klog("MeetingMode: local LLM returned empty")
                        self?.finishFormatting(nil, outputDir: outputDir)
                    }
                }
            }
        }

        if llm.isLoaded {
            doGenerate()
        } else {
            llm.loadModel { [weak self] ok in
                if ok {
                    doGenerate()
                } else {
                    klog("MeetingMode: local LLM load failed")
                    DispatchQueue.main.async {
                        self?.finishFormatting(nil, outputDir: outputDir)
                    }
                }
            }
        }
    }

    private func finishFormatting(_ formatted: String?, outputDir: URL) {
        isFormatting = false

        if let text = formatted {
            // 整形済みファイルを保存
            let formattedURL = outputDir.appendingPathComponent("議事録_整形済み.md")
            try? text.write(to: formattedURL, atomically: true, encoding: .utf8)
            klog("MeetingMode: formatted file saved")
            // 整形済みファイルを開く
            NSWorkspace.shared.open(formattedURL)
        }

        // SRT字幕ファイルを生成
        exportSRT(outputDir: outputDir)

        // フォルダも開く
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputDir.path)
    }

    // MARK: - SRT/VTT Export

    /// SRT字幕ファイルとしてエクスポート
    private func exportSRT(outputDir: URL) {
        guard !rawEntries.isEmpty else { return }
        var srt = ""
        for (i, entry) in rawEntries.enumerated() {
            // "[HH:mm:ss] text" format
            let parts = entry.split(separator: "]", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let timeStr = String(parts[0].dropFirst()) // remove "["
            let text = parts[1].trimmingCharacters(in: .whitespaces)
            // Approximate: each entry is ~5 seconds
            let startSec = i * 5
            let endSec = (i + 1) * 5
            srt += "\(i + 1)\n"
            srt += "\(srtTime(startSec)) --> \(srtTime(endSec))\n"
            srt += "\(text)\n\n"
        }
        let srtURL = outputDir.appendingPathComponent("議事録.srt")
        try? srt.write(to: srtURL, atomically: true, encoding: .utf8)

        // VTT version
        var vtt = "WEBVTT\n\n"
        for (i, entry) in rawEntries.enumerated() {
            let parts = entry.split(separator: "]", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let text = parts[1].trimmingCharacters(in: .whitespaces)
            let startSec = i * 5
            let endSec = (i + 1) * 5
            vtt += "\(vttTime(startSec)) --> \(vttTime(endSec))\n"
            vtt += "\(text)\n\n"
        }
        let vttURL = outputDir.appendingPathComponent("議事録.vtt")
        try? vtt.write(to: vttURL, atomically: true, encoding: .utf8)
        klog("MeetingMode: SRT/VTT exported")
    }

    private func srtTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d,000", h, m, s)
    }

    private func vttTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d.000", h, m, s)
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
        rawEntries.append("[\(timeStr)]\(speakerLabel) \(text)")
        charCount += text.count
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
            rawEntries.append("[\(timeStr)] [話者\(entry.speaker + 1)] \(entry.text)")
            charCount += entry.text.count
            // audioNote は最初のエントリのみ
            audioNote = ""
        }
    }
}
