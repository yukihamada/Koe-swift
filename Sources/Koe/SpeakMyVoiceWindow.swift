import AppKit
import AVFoundation

/// 🗣 自分の声で読み上げ — 何を読むかを見て/選んでから読み上げる小窓。
///
/// 開いた時点で「選択中のテキスト → クリップボード → 直近の認識結果」の順で
/// 候補を1つプリフィルするが、そのままテキストを直接編集して読ませる内容を変えられる。
/// 履歴からの選び直しもポップアップで可能。合成は MyVoiceTTS(本人声クローン)、
/// 失敗時は AVSpeechSynthesizer のシステム音声にフォールバックする(誰でも必ず声が出る)。
final class SpeakMyVoiceWindow: NSObject, NSWindowDelegate {
    static let shared = SpeakMyVoiceWindow()

    private var window: NSWindow?
    private var bodyView: NSTextView!
    private var historyPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var speakButton: NSButton!
    private let systemSpeech = AVSpeechSynthesizer()

    private static let maxChars = 800

    func show() {
        if window == nil { buildWindow() }
        bodyView.string = resolveInitialText()
        refreshHistoryPopup()
        statusLabel.stringValue = ""
        speakButton.isEnabled = true
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 選択テキスト → クリップボード → 直近の認識結果 の順で最初の候補を決める。
    private func resolveInitialText() -> String {
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var focused: AnyObject?
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
            if let el = focused {
                var sel: AnyObject?
                AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel)
                if let text = sel as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        if let clip = NSPasteboard.general.string(forType: .string),
           !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clip
        }
        return HistoryStore.shared.entries.first?.text ?? ""
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "🗣 自分の声で読み上げ"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))

        let bodyLabel = NSTextField(labelWithString: "何を読みますか？（〜\(Self.maxChars)字・直接編集可）")
        bodyLabel.frame = NSRect(x: 20, y: 284, width: 400, height: 20)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor
        content.addSubview(bodyLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 84, width: 400, height: 196))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        bodyView = NSTextView(frame: scroll.bounds)
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.isRichText = false
        bodyView.autoresizingMask = [.width]
        scroll.documentView = bodyView
        content.addSubview(scroll)

        historyPopup = NSPopUpButton(frame: NSRect(x: 20, y: 52, width: 400, height: 24), pullsDown: true)
        historyPopup.target = self
        historyPopup.action = #selector(historyItemSelected(_:))
        content.addSubview(historyPopup)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 20, width: 210, height: 20)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        speakButton = NSButton(title: "読み上げる", target: self, action: #selector(speakTapped))
        speakButton.frame = NSRect(x: 300, y: 16, width: 120, height: 32)
        speakButton.bezelStyle = .rounded
        speakButton.keyEquivalent = "\r"
        content.addSubview(speakButton)

        w.contentView = content
        window = w
    }

    /// 「履歴から選ぶ」ポップアップの中身を最新化。
    private func refreshHistoryPopup() {
        historyPopup.removeAllItems()
        historyPopup.addItem(withTitle: "履歴から選び直す…")
        let entries = Array(HistoryStore.shared.entries.prefix(8))
        for (i, entry) in entries.enumerated() {
            let preview = entry.text.prefix(60) + (entry.text.count > 60 ? "…" : "")
            let item = NSMenuItem(title: String(preview), action: nil, keyEquivalent: "")
            item.tag = i
            historyPopup.menu?.addItem(item)
        }
        historyPopup.isEnabled = !entries.isEmpty
    }

    @objc private func historyItemSelected(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, item.tag >= 0 || sender.indexOfSelectedItem > 0 else { return }
        let entries = Array(HistoryStore.shared.entries.prefix(8))
        let idx = sender.indexOfSelectedItem - 1
        guard idx >= 0, idx < entries.count else { return }
        bodyView.string = entries[idx].text
    }

    @objc private func speakTapped() {
        let trimmed = bodyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLabel.stringValue = "⚠️ 読み上げるテキストがありません"
            return
        }
        // 長文ガード: Qwen3-TTS は長文で品質が落ちるため maxChars で切る
        let target = String(trimmed.prefix(Self.maxChars))
        speakButton.isEnabled = false
        statusLabel.stringValue = "🗣 自分の声で生成中…"
        MyVoiceTTS.shared.speak(target) { [weak self] ok, message in
            guard let self else { return }
            self.speakButton.isEnabled = true
            if ok {
                self.statusLabel.stringValue = "✅ 読み上げました"
            } else {
                // 本人声が使えない(オフライン/未疎通/鍵なし)時も、必ず声は出す。
                self.speakWithSystemVoice(target)
                self.statusLabel.stringValue = "🔈 オフライン音声で読み上げました（本人声: \(message)）"
            }
        }
    }

    /// macOS 内蔵の音声合成で読み上げる（オフライン・鍵不要のフォールバック）。
    private func speakWithSystemVoice(_ text: String) {
        systemSpeech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        let hasJa = text.unicodeScalars.contains { $0.value >= 0x3040 && $0.value <= 0x30FF
            || ($0.value >= 0x4E00 && $0.value <= 0x9FFF) }
        u.voice = AVSpeechSynthesisVoice(language: hasJa ? "ja-JP" : "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        systemSpeech.speak(u)
    }

    func windowWillClose(_ notification: Notification) {
        MyVoiceTTS.shared.stop()
    }
}
