import Foundation

/// 議事録の要約テンプレート
enum MeetingTemplate: String, CaseIterable, Codable {
    case general = "general"
    case oneOnOne = "1on1"
    case standup = "standup"
    case sales = "sales"
    case brainstorm = "brainstorm"
    case interview = "interview"

    var displayName: String {
        switch self {
        case .general:    return "一般会議"
        case .oneOnOne:   return "1on1"
        case .standup:    return "朝会/スタンドアップ"
        case .sales:      return "商談/営業"
        case .brainstorm: return "ブレインストーミング"
        case .interview:  return "面接/インタビュー"
        }
    }

    var systemPrompt: String {
        let base = """
        あなたは議事録整形アシスタントです。以下の音声認識テキストを整形してください。
        ルール: 誤字脱字修正、句読点追加、話題ごとに段落分け、タイムスタンプ維持、話者情報活用、Markdown出力。
        """

        switch self {
        case .general:
            return base + """

            最後に以下を追加:
            ## 要約
            会議の概要を3-5文で簡潔にまとめる
            ## 決定事項
            決まったことを箇条書き（なければ「特になし」）
            ## TODO
            次にやるべきことを担当者付きで箇条書き（なければ「特になし」）
            """

        case .oneOnOne:
            return base + """

            1on1ミーティングの形式で整形:
            ## 進捗・成果
            前回からの進捗を箇条書き
            ## 課題・困っていること
            相談事項を箇条書き
            ## フィードバック
            お互いのフィードバックを整理
            ## ネクストアクション
            次回までにやることを担当者付きで箇条書き
            ## メンタル/モチベーション
            気になる発言があれば記録
            """

        case .standup:
            return base + """

            スタンドアップ/朝会の形式で整形:
            各メンバーごとに以下をまとめる:
            ## [メンバー名]
            - **昨日やったこと**:
            - **今日やること**:
            - **ブロッカー**:

            ## 共有事項
            全体に関わる連絡事項
            """

        case .sales:
            return base + """

            商談/営業会議の形式で整形:
            ## 顧客情報
            会社名、担当者名、役職（わかる範囲で）
            ## ニーズ/課題
            顧客が抱えている課題を箇条書き
            ## 提案内容
            こちらから提案した内容
            ## 反応/懸念点
            顧客の反応、気になった発言
            ## 競合情報
            言及された競合の情報（あれば）
            ## ネクストステップ
            次のアクション（見積もり送付、デモ等）
            ## 受注確度
            A(高)/B(中)/C(低) で判定
            """

        case .brainstorm:
            return base + """

            ブレインストーミングの形式で整形:
            ## テーマ
            議論のテーマを1行で
            ## アイデア一覧
            出たアイデアを全て箇条書き（否定せず全て記録）
            ## グルーピング
            似たアイデアをカテゴリ分け
            ## 有望なアイデア TOP3
            投票や盛り上がりから判断
            ## ネクストステップ
            どのアイデアを深掘りするか、誰が調べるか
            """

        case .interview:
            return base + """

            面接/インタビューの形式で整形:
            ## 候補者情報
            名前、経歴の概要（わかる範囲で）
            ## 質問と回答
            Q&A形式で整理
            ## 強み
            印象的だったスキルや経験
            ## 懸念点
            気になった点
            ## 総合評価
            採用/見送り/次回面接 の推奨（あくまで議事録としての記録）
            """
        }
    }
}
