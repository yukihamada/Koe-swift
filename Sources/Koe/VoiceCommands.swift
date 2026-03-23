import Foundation

/// 音声フォーマットコマンド: 認識テキスト内のキーワードを書式文字に変換
/// 例: 「こんにちは改行世界」→「こんにちは\n世界」
enum VoiceCommands {

    // MARK: - Filler Removal

    /// 日本語フィラーワード（えー、あの、えっと等）
    private static let jaFillers = [
        "えーと", "えーっと", "えっと", "えっとー",
        "あのー", "あのう", "あの",
        "えー", "えーー", "ええと",
        "うーん", "うーんと", "うん",
        "そのー", "そのう",
        "まあ", "まぁ",
        "なんか", "なんていうか", "なんというか",
        "ほら", "ほらほら",
        "こう", "こうなんていうか",
        "やっぱ", "やっぱり",
    ]

    /// 英語フィラーワード
    private static let enFillers = [
        "uh", "uhh", "um", "umm", "hmm", "hm",
        "like", "you know", "I mean", "basically",
        "actually", "literally", "right",
        "so yeah", "yeah so",
    ]

    /// フィラーワードを除去する
    static func removeFillers(_ text: String, language: String = "ja-JP") -> String {
        var result = text
        let fillers = language.hasPrefix("ja") ? jaFillers : enFillers

        // 長いフィラーから先に処理（「えーっと」を「えー」より先に）
        let sorted = fillers.sorted { $0.count > $1.count }
        for filler in sorted {
            // 単語境界を考慮: フィラーの前後が句読点・スペース・文頭文末
            if language.hasPrefix("ja") {
                // 日本語: そのまま置換（助詞の一部にならないよう全角マッチ）
                result = result.replacingOccurrences(of: filler, with: "")
            } else {
                // 英語: 単語境界で置換（大小無視）
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
                }
            }
        }

        // 連続スペースを1つに
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // 句読点前のスペースを除去
        result = result.replacingOccurrences(of: " 、", with: "、")
        result = result.replacingOccurrences(of: " 。", with: "。")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")

        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Formatting Commands

    /// テキスト内の音声フォーマットコマンドを検出して変換する
    static func applyFormatting(_ text: String) -> String {
        var result = text

        // 改行系
        for keyword in ["改行", "かいぎょう", "新しい行", "ニューライン"] {
            result = result.replacingOccurrences(of: keyword, with: "\n")
        }

        // 段落（2改行）
        for keyword in ["新しい段落", "段落", "だんらく"] {
            result = result.replacingOccurrences(of: keyword, with: "\n\n")
        }

        // タブ
        for keyword in ["タブ", "たぶ"] {
            result = result.replacingOccurrences(of: keyword, with: "\t")
        }

        // 句読点（whisperが自動で入れない場合の補助）
        result = result.replacingOccurrences(of: "句点", with: "。")
        result = result.replacingOccurrences(of: "読点", with: "、")
        result = result.replacingOccurrences(of: "くてん", with: "。")
        result = result.replacingOccurrences(of: "とうてん", with: "、")
        result = result.replacingOccurrences(of: "ピリオド", with: ".")
        result = result.replacingOccurrences(of: "カンマ", with: ",")
        result = result.replacingOccurrences(of: "コロン", with: ":")
        result = result.replacingOccurrences(of: "セミコロン", with: ";")

        // 記号
        result = result.replacingOccurrences(of: "かっこ開き", with: "（")
        result = result.replacingOccurrences(of: "かっこ閉じ", with: "）")
        result = result.replacingOccurrences(of: "カッコ開き", with: "（")
        result = result.replacingOccurrences(of: "カッコ閉じ", with: "）")
        result = result.replacingOccurrences(of: "かぎかっこ開き", with: "「")
        result = result.replacingOccurrences(of: "かぎかっこ閉じ", with: "」")

        // スペース
        result = result.replacingOccurrences(of: "スペース", with: " ")
        result = result.replacingOccurrences(of: "半角スペース", with: " ")
        result = result.replacingOccurrences(of: "全角スペース", with: "\u{3000}")

        // 疑問符・感嘆符
        result = result.replacingOccurrences(of: "はてな", with: "？")
        result = result.replacingOccurrences(of: "クエスチョン", with: "？")
        result = result.replacingOccurrences(of: "ビックリマーク", with: "！")
        result = result.replacingOccurrences(of: "びっくりマーク", with: "！")
        result = result.replacingOccurrences(of: "エクスクラメーション", with: "！")

        // 不要な先頭・末尾の空白を整理（改行は保持）
        let lines = result.components(separatedBy: "\n")
        result = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                      .joined(separator: "\n")
                      .trimmingCharacters(in: .whitespaces)

        return result
    }

    // MARK: - Punctuation Style

    enum PunctuationStyle: String, CaseIterable {
        case japanese  = "japanese"   // 、。（デフォルト）
        case technical = "technical"  // , .（技術文書）
        case minimal   = "minimal"    // 句読点最小限

        var displayName: String {
            switch self {
            case .japanese:  return "日本語（、。）"
            case .technical: return "技術文書（,.）"
            case .minimal:   return "最小限"
            }
        }
    }

    /// 句読点スタイルを変換
    static func applyPunctuationStyle(_ text: String, style: PunctuationStyle) -> String {
        switch style {
        case .japanese:
            return text  // デフォルト、変換不要
        case .technical:
            return text
                .replacingOccurrences(of: "、", with: ", ")
                .replacingOccurrences(of: "。", with: ". ")
        case .minimal:
            return text
                .replacingOccurrences(of: "、", with: " ")
                .replacingOccurrences(of: "。", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: ".", with: " ")
        }
    }

    // MARK: - Command Mode (音声テキスト編集)

    /// テキスト全体がCommand Modeの指示かどうかを判定
    /// 「これを丁寧にして」「箇条書きにして」等
    static func detectCommandMode(_ text: String) -> CommandModeAction? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 丁寧にする
        for kw in ["丁寧にして", "敬語にして", "フォーマルにして", "ですます調にして"] {
            if t.contains(kw) { return .rewrite("丁寧で敬語を使ったビジネス文体に書き換えてください。変換後のテキストのみ出力。") }
        }
        // カジュアルにする
        for kw in ["カジュアルにして", "くだけた感じにして", "友達に話すように"] {
            if t.contains(kw) { return .rewrite("カジュアルで親しみやすい文体に書き換えてください。変換後のテキストのみ出力。") }
        }
        // 箇条書き
        for kw in ["箇条書きにして", "リストにして", "箇条書きに変換"] {
            if t.contains(kw) { return .rewrite("箇条書き（・）形式に変換してください。要点を簡潔に。変換後のテキストのみ出力。") }
        }
        // 要約
        for kw in ["要約して", "まとめて", "短くして", "簡潔にして"] {
            if t.contains(kw) { return .rewrite("要点を保ちつつ短く簡潔にまとめてください。変換後のテキストのみ出力。") }
        }
        // 翻訳
        if t.contains("英語にして") || t.contains("英訳して") || t.contains("英語に翻訳") {
            return .rewrite("自然な英語に翻訳してください。翻訳後のテキストのみ出力。")
        }
        if t.contains("日本語にして") || t.contains("和訳して") || t.contains("日本語に翻訳") {
            return .rewrite("自然な日本語に翻訳してください。翻訳後のテキストのみ出力。")
        }
        // 修正
        for kw in ["誤字を直して", "校正して", "修正して", "チェックして"] {
            if t.contains(kw) { return .rewrite("誤字脱字を修正し、句読点を整えてください。意味を変えず、修正後のテキストのみ出力。") }
        }
        // 長くする
        for kw in ["もっと詳しく", "膨らませて", "詳細にして", "長くして"] {
            if t.contains(kw) { return .rewrite("内容をより詳細に膨らませてください。元の意味を保ちつつ、具体例や補足を追加。変換後のテキストのみ出力。") }
        }

        return nil
    }

    enum CommandModeAction {
        case rewrite(String)  // LLMプロンプト付きの書き換え指示
    }

    // MARK: - Editing Commands (全文がコマンドの場合)

    /// テキスト全体が編集コマンドかどうか判定
    static func detectEditCommand(_ text: String) -> EditCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 「削除」「取り消し」→ 直前の入力を取り消す
        if t == "削除" || t == "取り消し" || t == "取消" || t == "元に戻す" || t == "アンドゥ" {
            return .undo
        }

        // 「全部削除」「全削除」
        if t == "全部削除" || t == "全削除" || t == "すべて削除" || t == "オールデリート" {
            return .deleteAll
        }

        return nil
    }

    enum EditCommand {
        case undo       // Cmd+Z
        case deleteAll  // Cmd+A → Delete
    }

    // MARK: - Meeting Voice Commands

    /// 議事録用音声コマンドの検出
    enum MeetingCommand {
        case markImportant  // 「ここ重要」「重要」「マーク」
    }

    static func detectMeetingCommand(_ text: String) -> MeetingCommand? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let importantTriggers = ["ここ重要", "重要", "マーク", "ここマーク", "important", "mark this", "mark it"]
        if importantTriggers.contains(where: { t.contains($0) }) {
            return .markImportant
        }
        return nil
    }
}
