import AppKit
import ApplicationServices

/// 認識精度を上げるためにアクティブアプリ・クリップボード・画面テキストから
/// コンテキスト情報を収集し、whisper の initial_prompt に渡す。
/// すべて同期・軽量で、録音開始時に ~1ms で完了。
///
/// 重要: whisper の initial_prompt は短く、日本語のキーワードのみが効果的。
/// 長い英語テキストやコード片を渡すと認識精度が大幅に低下する。
struct ContextCollector {

    /// 現在のコンテキストを収集して prompt 用テキストを生成
    static func collect(appBundleID: String, profilePrompt: String) -> String {
        let settings = AppSettings.shared
        var parts: [String] = []

        // 1. アプリプロファイルのプロンプト（常に含む — ユーザーが明示的に設定したもの）
        if !profilePrompt.isEmpty {
            parts.append(profilePrompt)
        }

        // 2. ユーザーのカスタムプロンプト（常に含む）
        if !settings.contextCustomPrompt.isEmpty {
            parts.append(settings.contextCustomPrompt)
        }

        // 3: コンテキスト認識が有効な場合のみ
        if settings.contextAwareEnabled {
            // アプリヒント（日本語キーワードのみ）
            if settings.contextUseAppHint, let hint = appHint(bundleID: appBundleID) {
                parts.append(hint)
            }

            // クリップボードから日本語キーワード抽出（デフォルトOFF）
            if settings.contextUseClipboard, let keywords = japaneseKeywords(from: clipboardText()) {
                parts.append(keywords)
            }
        }

        let combined = parts.joined(separator: " ")
        // whisper prompt は100文字以下が最適。長いと逆効果。
        let trimmed = String(combined.prefix(100))
        return trimmed
    }

    // MARK: - Super Mode (LLM用リッチコンテキスト)

    /// LLM処理に渡すリッチなコンテキスト情報を収集（whisper promptとは別）
    /// Super Mode有効時にアプリ名・選択テキスト・クリップボードキーワードを含む
    static func collectForLLM(appBundleID: String) -> String? {
        guard AppSettings.shared.superModeEnabled else { return nil }

        var parts: [String] = []

        // アプリ名
        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? appBundleID
            parts.append("ユーザーは \(name) を使用中。")
        }

        // 選択テキスト（Accessibility API）
        if let selected = selectedText(), !selected.isEmpty {
            let trimmed = String(selected.prefix(500))
            parts.append("選択中のテキスト: \(trimmed)")
        }

        // クリップボードのキーワード
        if let keywords = japaneseKeywords(from: clipboardText()) {
            parts.append("クリップボード: \(keywords)")
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    // MARK: - Selected Text (Accessibility API)

    /// AXUIElement APIでアクティブアプリの選択テキストを取得
    private static func selectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else { return nil }
        var selectedText: AnyObject?
        // focusedElement is always AXUIElement when CopyAttributeValue succeeds
        let axElement = focusedElement as! AXUIElement
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success else { return nil }
        return selectedText as? String
    }

    // MARK: - App Hint

    /// アプリのバンドルIDからドメイン固有のヒントワードを返す
    /// ウィンドウタイトル取得は廃止 — 英語タイトルがwhisperを混乱させるため
    private static func appHint(bundleID: String) -> String? {
        // 主要アプリのドメインヒント（日本語キーワード）
        let hints: [String: String] = [
            "com.apple.mail": "メール 件名 宛先",
            "com.apple.Notes": "メモ ノート",
            "com.microsoft.Word": "文書 ドキュメント",
            "com.microsoft.Excel": "表 データ 数値",
            "com.microsoft.Powerpoint": "スライド プレゼン",
            "com.apple.iChat": "メッセージ チャット",
            "com.tinyspeck.slackmacgap": "メッセージ チャット",
            "jp.naver.line.mac": "メッセージ チャット",
            "com.apple.Safari": "検索 ウェブ",
            "com.google.Chrome": "検索 ウェブ",
            "com.apple.finder": "ファイル フォルダ",
            "com.apple.Terminal": "コマンド ターミナル",
            "com.apple.dt.Xcode": "コード プログラミング",
            "com.microsoft.VSCode": "コード プログラミング",
        ]
        return hints[bundleID]
    }

    // MARK: - Clipboard (raw)

    /// クリップボードの生テキストを取得
    private static func clipboardText() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Japanese keyword extraction

    /// テキストから日本語（ひらがな・カタカナ・漢字）の単語のみを抽出
    /// 英語・記号・コードはwhisperを混乱させるので除外
    private static func japaneseKeywords(from text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return nil }

        // 日本語文字のみを抽出（連続する日本語文字をトークンとして扱う）
        var keywords: [String] = []
        var current = ""
        for char in text {
            if char.isJapanese {
                current.append(char)
            } else {
                if current.count >= 2 {  // 1文字の助詞などは除外
                    keywords.append(current)
                }
                current = ""
            }
        }
        if current.count >= 2 {
            keywords.append(current)
        }

        guard !keywords.isEmpty else { return nil }

        // 重複排除して最大5キーワード
        let unique = Array(NSOrderedSet(array: keywords)) as! [String]
        let selected = unique.prefix(5)
        return selected.joined(separator: " ")
    }
}

// MARK: - Character extension

private extension Character {
    /// ひらがな・カタカナ・漢字・長音符を日本語として判定
    var isJapanese: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let v = scalar.value
        // ひらがな (3040-309F), カタカナ (30A0-30FF), CJK統合漢字 (4E00-9FFF), 長音 (30FC)
        return (0x3040...0x309F).contains(v) ||
               (0x30A0...0x30FF).contains(v) ||
               (0x4E00...0x9FFF).contains(v)
    }
}
