import AppKit
import Foundation

/// 音声認識の結果とユーザー編集後テキストのペアを保存。
/// 後から学習データとして活用できる。
struct CorrectionEntry: Codable {
    let original: String
    let corrected: String
    let date: Date
    let appBundleID: String?
}

class CorrectionStore {
    static let shared = CorrectionStore()

    private var pendingOriginal: String?
    private var pendingAppBundleID: String?
    private var checkTimer: Timer?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("corrections.jsonl")
    }()

    /// テキスト入力直後に呼ぶ。数秒後にテキストフィールドを再読取して差分を検出する。
    func trackDelivery(original: String, appBundleID: String?) {
        checkTimer?.invalidate()
        pendingOriginal = original
        pendingAppBundleID = appBundleID

        // 5秒後にユーザーの編集を確認
        checkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.checkForCorrection()
        }
    }

    private func checkForCorrection() {
        guard let original = pendingOriginal, !original.isEmpty else { return }
        pendingOriginal = nil

        // AXUIElementでフォーカス中のテキストフィールドの値を読み取る
        guard let currentText = readFocusedText() else { return }

        // 元のテキストが含まれているか確認し、編集部分を抽出
        let corrected = extractCorrectedText(from: currentText, original: original)
        guard let corrected, corrected != original else { return }

        let entry = CorrectionEntry(
            original: original,
            corrected: corrected,
            date: Date(),
            appBundleID: pendingAppBundleID
        )
        save(entry)
        klog("Correction saved: '\(original.prefix(30))' → '\(corrected.prefix(30))'")
    }

    /// フォーカス中テキストフィールドのテキスト全体を取得
    private func readFocusedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else { return nil }
        let axElement = focusedElement as! AXUIElement

        // まず選択テキストを試行、なければフィールド全体の値
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String {
            return text
        }
        return nil
    }

    /// テキストフィールドの内容から、元のテキストに対応する編集後テキストを抽出
    private func extractCorrectedText(from fieldText: String, original: String) -> String? {
        // フィールド全体が元テキストだった場合
        let trimmed = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == original { return nil } // 未編集

        // 元テキストがフィールドに含まれていない → ユーザーが全体を書き換えた
        // フィールドテキストの末尾付近（入力した箇所）を確認
        // 元テキストの長さ±50%の範囲で末尾を切り出して比較
        let len = original.count
        // 末尾からoriginalの長さ付近のテキストを取得
        let endIndex = fieldText.endIndex
        let checkLen = min(len * 2, fieldText.count)
        let startIndex = fieldText.index(endIndex, offsetBy: -checkLen)
        let tail = String(fieldText[startIndex..<endIndex])

        // 元テキストがそのまま残っている → 未編集
        if tail.hasSuffix(original) { return nil }

        // 編集されている場合、末尾のoriginal長さ分を修正後テキストとして返す
        let correctedLen = min(len + 50, tail.count) // 少し余裕を持たせる
        let correctedStart = tail.index(tail.endIndex, offsetBy: -min(correctedLen, tail.count))
        let corrected = String(tail[correctedStart..<tail.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

        // 差分が小さすぎる（同じ）または大きすぎる（別の内容）場合はスキップ
        guard corrected != original else { return nil }
        let similarity = jaroWinkler(original, corrected)
        guard similarity > 0.3 && similarity < 1.0 else { return nil }

        return corrected
    }

    /// 簡易Jaro-Winkler類似度（0.0〜1.0）
    private func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let matchDist = max(1, max(a.count, b.count) / 2 - 1)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0, transpositions = 0
        for i in 0..<a.count {
            let lo = max(0, i - matchDist), hi = min(b.count - 1, i + matchDist)
            guard lo <= hi else { continue }
            for j in lo...hi {
                guard !bMatched[j], a[i] == b[j] else { continue }
                aMatched[i] = true; bMatched[j] = true; matches += 1; break
            }
        }
        guard matches > 0 else { return 0.0 }
        var k = 0
        for i in 0..<a.count {
            guard aMatched[i] else { continue }
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - Double(transpositions) / 2) / m) / 3
        var prefix = 0
        for i in 0..<min(4, min(a.count, b.count)) {
            if a[i] == b[i] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    private func save(_ entry: CorrectionEntry) {
        DispatchQueue.global(qos: .utility).async { [fileURL] in
            guard let data = try? JSONEncoder().encode(entry),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            guard let lineData = line.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: fileURL) {
                fh.seekToEndOfFile()
                try? fh.write(contentsOf: lineData)
                try? fh.close()
            } else {
                try? lineData.write(to: fileURL)
            }
        }
    }

    /// 保存済みの修正データを全件読み込み
    func loadAll() -> [CorrectionEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(CorrectionEntry.self, from: data)
        }
    }

    /// 修正データから頻出の「正しい単語」を抽出し、whisperプロンプト用ヒントを生成。
    /// bundleID指定時はそのアプリの修正データを優先し、グローバルデータで補完。
    func learningHint(for bundleID: String? = nil, limit: Int = 20) -> String {
        let entries = loadAll()
        guard !entries.isEmpty else { return "" }

        // アプリ別の頻度カウント（指定時）
        var appFreq: [String: Int] = [:]
        var globalFreq: [String: Int] = [:]

        for entry in entries {
            let words = extractKeywords(from: entry.corrected)
            let isTargetApp = bundleID != nil && entry.appBundleID == bundleID
            for word in words {
                globalFreq[word, default: 0] += 1
                if isTargetApp {
                    appFreq[word, default: 0] += 1
                }
            }
        }

        // アプリ別ヒントを優先、残り枠をグローバルで埋める
        var hints: [String] = []
        if !appFreq.isEmpty {
            let appHints = appFreq
                .filter { $0.value >= 1 }  // アプリ別は1回でも採用
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { $0.key }
            hints.append(contentsOf: appHints)
        }

        let remaining = limit - hints.count
        if remaining > 0 {
            let appSet = Set(hints)
            let globalHints = globalFreq
                .filter { $0.value >= 2 && !appSet.contains($0.key) }
                .sorted { $0.value > $1.value }
                .prefix(remaining)
                .map { $0.key }
            hints.append(contentsOf: globalHints)
        }

        return hints.joined(separator: "、")
    }

    /// テキストから特徴的なキーワードを抽出（ひらがなのみの短い単語は除外）
    private func extractKeywords(from text: String) -> [String] {
        // 簡易的にカタカナ・漢字を含む3文字以上の連続を抽出
        var keywords: [String] = []
        var current = ""
        for char in text {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                if current.count >= 3, containsKanjiOrKatakana(current) {
                    keywords.append(current)
                }
                current = ""
            }
        }
        if current.count >= 3, containsKanjiOrKatakana(current) {
            keywords.append(current)
        }
        return keywords
    }

    private func containsKanjiOrKatakana(_ s: String) -> Bool {
        // 漢字またはカタカナを含む場合のみ採用（英字のみの単語はwhisperを混乱させるため除外）
        s.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||  // CJK漢字
            (0x30A0...0x30FF).contains(scalar.value)     // カタカナ
        }
    }

    var entryCount: Int {
        loadAll().count
    }
}
