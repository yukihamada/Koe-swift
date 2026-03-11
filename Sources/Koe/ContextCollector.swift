import AppKit
import ApplicationServices

/// 認識精度を上げるためにアクティブアプリ・クリップボード・画面テキストから
/// コンテキスト情報を収集し、whisper の initial_prompt に渡す。
/// すべて同期・軽量で、録音開始時に ~1ms で完了。
///
/// 重要: whisper の initial_prompt は短く、日本語のキーワードのみが効果的。
/// 長い英語テキストやコード片を渡すと認識精度が大幅に低下する。
struct ContextCollector {

    /// 現在の言語が日本語系か判定
    private static var isJapanese: Bool {
        let lang = AppSettings.shared.language
        return lang.hasPrefix("ja")
    }

    /// 現在のコンテキストを収集して prompt 用テキストを生成
    static func collect(appBundleID: String, profilePrompt: String) -> String {
        let settings = AppSettings.shared
        var parts: [String] = []

        // 0. 言語別システムプロンプト: 言語ごとに最適なヒントを設定
        parts.append(languagePrompt(for: settings.language))

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

        // 4: 過去の修正データから学習したヒントワード
        let learningHint = CorrectionStore.shared.learningHint()
        if !learningHint.isEmpty {
            parts.append(learningHint)
        }

        let combined = parts.joined(separator: " ")
        // whisper prompt は150文字以下が最適。長いと逆効果。
        let trimmed = String(combined.prefix(150))
        return trimmed
    }

    // MARK: - Super Mode (LLM用リッチコンテキスト)

    /// LLM処理に渡すリッチなコンテキスト情報を収集（whisper promptとは別）
    /// Super Mode有効時にアプリ名・選択テキスト・クリップボードキーワードを含む
    static func collectForLLM(appBundleID: String) -> String? {
        guard AppSettings.shared.superModeEnabled else { return nil }

        var parts: [String] = []

        // システムコンテキスト
        if isJapanese {
            parts.append("ユーザーはMacから音声入力でテキストを入力しています。")
        } else {
            parts.append("The user is typing via voice input on Mac.")
        }

        // アプリ名
        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? appBundleID
            parts.append(isJapanese ? "ユーザーは \(name) を使用中。" : "User is using \(name).")
        }

        // 選択テキスト（Accessibility API）
        if let selected = selectedText(), !selected.isEmpty {
            let trimmed = String(selected.prefix(500))
            parts.append(isJapanese ? "選択中のテキスト: \(trimmed)" : "Selected text: \(trimmed)")
        }

        // クリップボードのキーワード（日本語モードのみ — 他言語では効果薄い）
        if isJapanese, let keywords = japaneseKeywords(from: clipboardText()) {
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
            // メール
            "com.apple.mail": "メール 件名 宛先 返信",
            "com.microsoft.Outlook": "メール 件名 宛先 返信",
            "com.google.Gmail": "メール 件名 宛先",
            // ドキュメント
            "com.apple.Notes": "メモ ノート 箇条書き",
            "com.apple.Pages": "文書 ドキュメント 見出し",
            "com.microsoft.Word": "文書 ドキュメント 段落",
            "com.microsoft.Excel": "表 データ 数値 関数",
            "com.microsoft.Powerpoint": "スライド プレゼン 図表",
            "com.google.Chrome.app.Docs": "文書 ドキュメント",
            // チャット・メッセージ
            "com.apple.iChat": "メッセージ チャット",
            "com.tinyspeck.slackmacgap": "メッセージ チャット チャンネル",
            "jp.naver.line.mac": "メッセージ チャット スタンプ",
            "com.microsoft.teams2": "会議 チャット 画面共有",
            "us.zoom.xos": "会議 ミーティング 画面共有",
            "com.hnc.Discord": "チャット サーバー チャンネル",
            // ブラウザ
            "com.apple.Safari": "検索 ウェブ サイト",
            "com.google.Chrome": "検索 ウェブ サイト",
            "company.thebrowser.Browser": "検索 ウェブ タブ",
            // 開発
            "com.apple.finder": "ファイル フォルダ",
            "com.apple.Terminal": "コマンド ターミナル シェル",
            "com.mitchellh.ghostty": "コマンド ターミナル git",
            "com.apple.dt.Xcode": "コード SwiftUI ビルド",
            "com.microsoft.VSCode": "コード プログラミング デバッグ",
            "dev.zed.Zed": "コード エディタ プログラミング",
            "com.jetbrains.intellij": "コード Java プログラミング",
            // クリエイティブ
            "com.figma.Desktop": "デザイン レイアウト コンポーネント",
            "com.adobe.Photoshop": "画像 レイヤー フィルター",
            "com.apple.FinalCut": "動画 編集 タイムライン",
            // Notion / Obsidian
            "notion.id": "ノート ページ データベース",
            "md.obsidian": "ノート マークダウン リンク",
        ]
        return hints[bundleID]
    }

    // MARK: - Language-specific prompt

    /// 言語ごとに最適な initial_prompt を返す。
    /// その言語のテキストを含めることで whisper がその言語として認識しやすくなる。
    private static func languagePrompt(for langCode: String) -> String {
        let prefix = langCode.components(separatedBy: "-").first ?? langCode
        switch prefix {
        case "ja": return "macOS音声入力。正確な日本語で書き起こしてください。"
        case "en": return "macOS voice input. Transcribe accurately in English."
        case "zh": return "macOS语音输入。请用中文准确转录。"
        case "ko": return "macOS 음성 입력. 한국어로 정확하게 받아써주세요."
        case "fr": return "Saisie vocale macOS. Transcrivez en français."
        case "de": return "macOS Spracheingabe. Bitte auf Deutsch transkribieren."
        case "es": return "Entrada de voz macOS. Transcriba con precisión en español."
        case "it": return "Input vocale macOS. Trascrivi in italiano."
        case "pt": return "Entrada de voz macOS. Transcreva em português."
        case "ru": return "Голосовой ввод macOS. Транскрибируйте на русском языке."
        case "hi": return "macOS ध्वनि इनपुट। हिन्दी में सटीक रूप से लिखें।"
        case "th": return "การป้อนเสียง macOS ถอดความเป็นภาษาไทย"
        case "vi": return "Nhập giọng nói macOS. Chép lại bằng tiếng Việt."
        case "id": return "Input suara macOS. Transkripsikan dalam bahasa Indonesia."
        case "nl": return "macOS spraakinvoer. Transcribeer in het Nederlands."
        case "pl": return "Wprowadzanie głosowe macOS. Transkrybuj po polsku."
        case "tr": return "macOS ses girişi. Türkçe olarak yazıya dökün."
        case "ar": return "إدخال صوتي macOS. قم بالنسخ باللغة العربية."
        default:   return "macOS voice input"
        }
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
