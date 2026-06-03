import AppKit

/// 🔊 声を送る — テキストを濱田優貴クローン声にして、相手へメールで届ける。
///
/// バックエンドは Koe MCP (mcp.koe.live) の `send_voice` ツール:
///   テキスト → ElevenLabs クローン声 MP3 → /v/:file 試聴ページ →
///   書き起こし付き HTML メールを宛先へ送信（Resend）。
/// API キーは Keychain (`voiceSendKey`) に保存。未設定なら初回にペースト用
/// ダイアログを出す（mcp.koe.live/login で誰でも自分の鍵を発行できる）。
final class VoiceMessageWindow: NSObject, NSWindowDelegate {
    static let shared = VoiceMessageWindow()

    private var window: NSWindow?
    private var recipientField: NSTextField!
    private var bodyView: NSTextView!
    private var statusLabel: NSTextField!
    private var sendButton: NSButton!

    private static let endpoint = URL(string: "https://mcp.koe.live/mcp")!
    private static let keychainKey = "voiceSendKey"
    private static let lastRecipientKey = "voiceMsgLastRecipient"
    private static let maxChars = 500

    func show() {
        if window == nil { buildWindow() }
        // 本文は最新の音声入力（あれば）をプリフィル — 「しゃべって、そのまま送る」動線。
        if bodyView.string.isEmpty, let latest = HistoryStore.shared.entries.first?.text {
            bodyView.string = latest
        }
        recipientField.stringValue = UserDefaults.standard.string(forKey: Self.lastRecipientKey) ?? ""
        statusLabel.stringValue = ""
        sendButton.isEnabled = true
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "🔊 声を送る"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))

        let toLabel = NSTextField(labelWithString: "宛先メール:")
        toLabel.frame = NSRect(x: 20, y: 276, width: 90, height: 20)
        content.addSubview(toLabel)

        recipientField = NSTextField(frame: NSRect(x: 110, y: 272, width: 310, height: 26))
        recipientField.placeholderString = "aite@example.com"
        content.addSubview(recipientField)

        let bodyLabel = NSTextField(labelWithString: "本文（クローン声で読み上げ・〜\(Self.maxChars)字）:")
        bodyLabel.frame = NSRect(x: 20, y: 244, width: 400, height: 20)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor
        content.addSubview(bodyLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 84, width: 400, height: 156))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        bodyView = NSTextView(frame: scroll.bounds)
        bodyView.font = .systemFont(ofSize: 13)
        bodyView.isRichText = false
        bodyView.autoresizingMask = [.width]
        scroll.documentView = bodyView
        content.addSubview(scroll)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 52, width: 400, height: 20)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        let hint = NSTextField(labelWithString: "相手には ▶試聴リンク＋書き起こし付きメールが届きます")
        hint.frame = NSRect(x: 20, y: 14, width: 290, height: 28)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        content.addSubview(hint)

        sendButton = NSButton(title: "送信", target: self, action: #selector(sendTapped))
        sendButton.frame = NSRect(x: 340, y: 12, width: 80, height: 32)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        content.addSubview(sendButton)

        w.contentView = content
        window = w
    }

    // MARK: - 送信

    @objc private func sendTapped() {
        let to = recipientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = bodyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.contains("@"), to.count >= 5 else {
            statusLabel.stringValue = "⚠️ 宛先メールアドレスを入れてください"
            return
        }
        guard !text.isEmpty else {
            statusLabel.stringValue = "⚠️ 本文が空です"
            return
        }
        guard text.count <= Self.maxChars else {
            statusLabel.stringValue = "⚠️ 本文が長すぎます（\(text.count)/\(Self.maxChars)字）"
            return
        }
        guard let key = resolveApiKey() else { return }

        UserDefaults.standard.set(to, forKey: Self.lastRecipientKey)
        sendButton.isEnabled = false
        statusLabel.stringValue = "🎙 声を生成して送信中…（数秒かかります）"
        klog("VoiceMessage: sending to \(to) (\(text.count) chars)")

        Task { [weak self] in
            let result = await Self.callSendVoice(apiKey: key, to: to, text: text)
            await MainActor.run { self?.didFinish(result) }
        }
    }

    /// send_voice の結果。String は Error 不適合なので Result でなく自前 enum。
    private enum SendOutcome {
        case success(emailed: Bool, listenURL: String)
        case failure(String)
    }

    private func didFinish(_ result: SendOutcome) {
        sendButton.isEnabled = true
        switch result {
        case .success(let emailed, let listenURL):
            if emailed {
                statusLabel.stringValue = "✅ 届けました（試聴リンクはコピー済み）"
            } else {
                statusLabel.stringValue = "⚠️ 声はできたがメール未送信 — リンクをコピーしたので自分で渡してください"
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(listenURL, forType: .string)
            klog("VoiceMessage: ok emailed=\(emailed) url=\(listenURL)")
        case .failure(let msg):
            statusLabel.stringValue = "❌ \(msg)"
            klog("VoiceMessage: error \(msg)")
        }
    }

    // MARK: - API キー（Keychain・初回はペースト）

    private func resolveApiKey() -> String? {
        if let k = KeychainHelper.get(Self.keychainKey), !k.isEmpty { return k }
        let alert = NSAlert()
        alert.messageText = "Koe API キーが未設定です"
        alert.informativeText = "mcp.koe.live/login でメール認証すると koe_… キーが発行されます。ここに貼り付けてください（Keychain に保存されます）。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "koe_…"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        KeychainHelper.set(key, for: Self.keychainKey)
        return key
    }

    // MARK: - MCP 呼び出し

    private static func callSendVoice(
        apiKey: String, to: String, text: String
    ) async -> SendOutcome {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 90 // TTS 生成に数十秒かかることがある
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "send_voice", "arguments": ["text": text, "to": to]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            return .failure("接続失敗: \(error.localizedDescription)")
        }
        // JSON-RPC → result.content[0].text（JSON文字列）→ {emailed, listen_url, note}
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let content = (result["content"] as? [[String: Any]])?.first,
            let inner = content["text"] as? String
        else {
            return .failure("応答を解釈できませんでした")
        }
        if (result["isError"] as? Bool) == true {
            return .failure(inner.prefix(120).description)
        }
        guard
            let innerObj = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any],
            let listen = innerObj["listen_url"] as? String
        else {
            return .failure("応答を解釈できませんでした: \(inner.prefix(80))")
        }
        let emailed = (innerObj["emailed"] as? Bool) ?? false
        return .success(emailed: emailed, listenURL: listen)
    }

    func windowWillClose(_ notification: Notification) {
        // 本文は閉じても保持（誤クローズ対策）。クリアは次回プリフィル判定に任せる。
    }
}
