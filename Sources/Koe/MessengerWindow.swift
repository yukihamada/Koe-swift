import AppKit
import SwiftUI
import UserNotifications
import AVFoundation

/// 💬 メッセンジャー — takibi(焚き火)/LINE の届いた連絡を1つの窓で見る・返す。
///
/// バックエンド = mcp.koe.live の /api/messenger/inbox・/api/messenger/reply
/// (2026-08-21 本人指示「takibiとかLINEに連絡きたらKoeアプリのメッセンジャーで見れるように」)。
/// 管理鍵はサーバ側のみが保持し、アプリは自分の koe_… キー(KoeAccount)で叩く。
/// 新着時は内容を音声で読み上げる(koe.live/api/speak 経由・本人指示「届いたら読み上げる」)。
struct MsgItem: Identifiable, Hashable {
    let id: String
    let source: String   // "line" | "takibi"
    let kind: String     // "post" | "comment" | ""(line)
    let slug: String
    let ts: String
    let who: String
    let group: String
    let text: String
    let replyTo: String
    let selfAuthored: Bool
    /// LINEの画像/動画/スタンプの実体URL(mcp.koe.live 経由の認証付きプロキシ・Bearer必須)。
    /// あれば text は "📷 画像" 等のプレースホルダー(2026-08-25 本人指摘「画像表示されない」)。
    let imageURL: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: MsgItem, b: MsgItem) -> Bool { a.id == b.id }
}

extension Notification.Name {
    /// 未読件数が変わった時に発火(メニューバーの表示を即時更新するため)。
    static let messengerUnreadChanged = Notification.Name("koe.messenger.unreadChanged")
}

/// LINEはグループ名・焚き火はスレッド(slug)単位の一意キー。一覧のグルーピング・
/// 未読バッジ・ミュート判定のすべてで同じ定義を使う(2026-08-26 UI刷新で共通化)。
func threadKey(for item: MsgItem) -> String {
    item.source == "line" ? "line:\(item.group)" : "takibi:\(item.slug.isEmpty ? "misc" : item.slug)"
}

/// /api/messenger/quick-reactions の結果。needsReply=false の時だけ reactions を見せる。
struct QuickReactionResult {
    let needsReply: Bool
    let reactions: [String]
}

/// /api/messenger/triage の結果。
struct TriageResult {
    let priority: String  // "needs_reply" | "fyi" | "done"
    let reason: String

    var dotColor: Color {
        switch priority {
        case "needs_reply": return .red
        case "fyi": return .yellow
        default: return .green
        }
    }
}

/// /api/messenger/detect-duplicates の1グループ。
struct DuplicateGroup: Identifiable {
    var id: String { threadIDs.joined(separator: ",") }
    let threadIDs: [String]
    let topic: String
}

final class MessengerModel: ObservableObject {
    @Published var items: [MsgItem] = []
    @Published var error: String?
    @Published var sending = false
    @Published var unread = 0 {
        didSet {
            if oldValue != unread {
                NotificationCenter.default.post(name: .messengerUnreadChanged, object: nil)
            }
        }
    }
    /// 未読の個別メッセージID。以前は選択したスレッドに関係なく `unread` を丸ごと0にしていて、
    /// 1スレッド見るだけで他の未読まで消えていた。スレッド単位で既読管理するために追加
    /// (2026-08-26 本人指示「圧倒的使いやすく見やすく」を受けたUI刷新)。
    @Published var unreadItemIDs: Set<String> = []
    /// ミュート中のスレッドキー(threadKey形式)。ミュートは自動読み上げ(TTS)だけを止め、
    /// 通知バナーと未読バッジは残す(声が煩わしいだけで見逃したくはない、という使い分け)。
    @Published var mutedThreadIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: MessengerModel.mutedKey) ?? [])
    /// 新着を要約+次の一手にまとめたテキスト(id → まとめ文)。/api/messenger/brief の結果を
    /// 音声再生後も捨てずに残し、UI(一覧・詳細)に表示する(2026-08-25 本人指示「次何やるかも欲しい」)。
    @Published var briefs: [String: String] = [:]
    /// まとめ生成中の item.id(ボタン多重タップ防止・スピナー表示用)。
    @Published var briefLoading: Set<String> = []
    /// スレッドを開いた時に出す「近況しおり」(threadKey → 一言)。/api/messenger/recap の結果。
    /// 返信前に相手の直近の文脈を思い出せるよう、会話ヘッダーに固定表示する
    /// (2026-08-25 Fable発案・本人採用のバックエンドがあったが未配線だったものを接続)。
    @Published var recaps: [String: String] = [:]
    @Published var recapLoading: Set<String> = []
    /// AI返信ドラフト(threadKey → 案の配列)。/api/messenger/draft-reply の結果。
    /// あくまで下書きで、composing欄に入れるだけ・送信は必ずユーザーのタップを経る
    /// (2026-08-26 本人依頼「AI返信ドラフト生成」)。
    @Published var draftReplies: [String: [String]] = [:]
    @Published var draftLoading: Set<String> = []
    /// 「返信不要+リアクション候補」判定結果(threadKey → 判定)。/api/messenger/quick-reactions。
    @Published var quickReactions: [String: QuickReactionResult] = [:]
    @Published var quickReactionsLoading: Set<String> = []
    /// 優先度トリアージ(threadKey → 判定)。/api/messenger/triage。一覧行に色ドットで出す。
    @Published var triageResults: [String: TriageResult] = [:]
    /// 直近どのitem.id時点で計算したか(新着が来たら再計算するためのキャッシュ無効化キー)。
    private var triageComputedForLatestID: [String: String] = [:]
    @Published var triageLoading: Set<String> = []
    /// 添付画像の1行AI説明(item.id → 説明文)。/api/messenger/describe-image。
    @Published var imageDescriptions: [String: String] = [:]
    private var imageDescLoading: Set<String> = []
    /// 横断音声ダイジェスト再生中フラグ(2026-08-26 本人指示)。
    @Published var digestLoading = false
    /// 重複スレッド検知は起動セッション中1回だけ実行する(全スレッド横断のLLM呼び出しは重いため)。
    private var duplicatesChecked = false
    @Published var duplicateGroups: [DuplicateGroup] = []

    private static let mutedKey = "messenger.mutedThreadIDs"
    private let base = "https://mcp.koe.live"
    private var seen = Set<String>()
    private var timer: Timer?
    private var player: AVAudioPlayer?

    /// 読み上げに使う声（設定で変更可能）。既定は本人声。
    static var speakVoiceID: String {
        UserDefaults.standard.string(forKey: "messenger.speakVoiceID") ?? "yuki"
    }
    /// 読み上げを無効化するスイッチ。既定=ON。
    static var speakEnabled: Bool {
        UserDefaults.standard.object(forKey: "messenger.speakEnabled") as? Bool ?? true
    }
    /// 読み上げる対象（"all" / "line" / "takibi"）。既定=全部。
    static var speakFilter: String {
        UserDefaults.standard.string(forKey: "messenger.speakFilter") ?? "all"
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard let key = KoeAccount.current else {
            DispatchQueue.main.async { self.error = "Koe アカウント未接続(設定から接続してください)"; self.items = [] }
            return
        }
        // limit=60だとjiuflow-line追加後は件数が足りず古い会話が切れていた
        // (2026-08-25 本人指摘「全部のメッセージ見えるように」・サーバ側上限200)。
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/inbox?limit=200")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err { self.error = "接続失敗: \(err.localizedDescription)"; return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, code == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = j["items"] as? [[String: Any]] else {
                    self.error = code == 403 ? "このメッセンジャーは管理者専用です" : "応答異常 (HTTP \(code))"
                    return
                }
                self.error = nil
                var fresh: [MsgItem] = []
                for x in list {
                    let item = MsgItem(
                        id: (x["id"] as? String) ?? "",
                        source: (x["source"] as? String) ?? "",
                        kind: (x["kind"] as? String) ?? "",
                        slug: (x["slug"] as? String) ?? "",
                        ts: (x["ts"] as? String) ?? "",
                        who: (x["who"] as? String) ?? "名無し",
                        group: (x["group"] as? String) ?? "",
                        text: (x["text"] as? String) ?? "",
                        replyTo: (x["reply_to"] as? String) ?? "",
                        selfAuthored: (x["self_authored"] as? Bool) ?? false,
                        imageURL: (x["image_url"] as? String) ?? ""
                    )
                    if !self.seen.contains(item.id) {
                        self.seen.insert(item.id)
                        if !self.items.isEmpty { // 初回ロードは通知しない
                            // 自分発の投稿/コメントは「連絡が来た」ではないので通知も読み上げもしない
                            // 自分宛の返信だけ読み上げる(他人の投稿は通知だけ)。本人指示「自分宛だけ」
                            if !item.selfAuthored {
                                self.unread += 1
                                self.unreadItemIDs.insert(item.id)
                                MessengerModel.notify(item)
                                self.speakIfNeeded(item)
                                klog("Messenger: new \(item.source)/\(item.kind) from \(item.who): \(item.text.prefix(40))")
                            } else {
                                klog("Messenger: self-authored \(item.kind) seen (no notify/speak)")
                            }
                        }
                        fresh.append(item)
                    }
                }
                self.items = fresh + self.items
            }
        }.resume()
    }

    func markRead() { unread = 0; unreadItemIDs.removeAll() }

    /// 指定したメッセージ群だけを既読にする(スレッドを開いた時に使う)。他スレッドの
    /// 未読はそのまま残る — これが今回のUI刷新のコア修正。
    func markRead(itemIDs: [String]) {
        let removed = unreadItemIDs.intersection(itemIDs)
        guard !removed.isEmpty else { return }
        unreadItemIDs.subtract(removed)
        unread = max(0, unread - removed.count)
    }

    func toggleMute(_ threadID: String) {
        if mutedThreadIDs.contains(threadID) {
            mutedThreadIDs.remove(threadID)
        } else {
            mutedThreadIDs.insert(threadID)
        }
        UserDefaults.standard.set(Array(mutedThreadIDs), forKey: MessengerModel.mutedKey)
    }

    func send(to item: MsgItem, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let key = KoeAccount.current else { return }
        sending = true
        let body: [String: Any] = [
            "source": item.source,
            "to": item.replyTo,
            "text": text,
            "slug": item.slug.isEmpty ? "takibi-line" : item.slug,
        ]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/reply")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            DispatchQueue.main.async {
                self.sending = false
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    self.markRead(itemIDs: self.items.filter { threadKey(for: $0) == threadKey(for: item) }.map { $0.id })
                    self.error = nil
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                    self.error = "送信失敗 (HTTP \(code)): \((msg?["detail"] as? String) ?? "")"
                }
            }
        }.resume()
    }

    /// スレッドを開いた時に一度だけ「近況しおり」を取りに行く(threadIDでキャッシュ済みなら再取得しない)。
    func fetchRecap(for thread: MsgThread) {
        guard recaps[thread.id] == nil, !recapLoading.contains(thread.id), let key = KoeAccount.current else { return }
        recapLoading.insert(thread.id)
        let itemsPayload = thread.items.prefix(20).map { ["who": $0.who, "text": $0.text, "ts": $0.ts] }
        let body: [String: Any] = ["items": itemsPayload]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/recap")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let threadID = thread.id
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.recapLoading.remove(threadID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recap = j["recap"] as? String, !recap.isEmpty else { return }
                self.recaps[threadID] = recap
            }
        }.resume()
    }

    /// AI返信ドラフトを生成する。instructionを変えて呼び直すことで再生成もできる(結果は上書き)。
    func fetchDraftReplies(for thread: MsgThread, instruction: String = "") {
        guard !draftLoading.contains(thread.id), let key = KoeAccount.current else { return }
        draftLoading.insert(thread.id)
        let itemsPayload = thread.items.prefix(20).map {
            ["who": $0.who, "text": $0.text, "self_authored": $0.selfAuthored, "ts": $0.ts]
        }
        var body: [String: Any] = ["items": itemsPayload]
        if !instruction.isEmpty { body["instruction"] = instruction }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/draft-reply")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let threadID = thread.id
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.draftLoading.remove(threadID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let drafts = j["drafts"] as? [String], !drafts.isEmpty else { return }
                self.draftReplies[threadID] = drafts
            }
        }.resume()
    }

    /// 1件のメッセージについて「文章の返信が要るか・リアクションだけで済むか」を判定する。
    func fetchQuickReactions(for item: MsgItem) {
        let tid = threadKey(for: item)
        guard !quickReactionsLoading.contains(tid), let key = KoeAccount.current else { return }
        quickReactionsLoading.insert(tid)
        let body: [String: Any] = ["who": item.who, "text": item.text, "source": item.source, "kind": item.kind]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/quick-reactions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.quickReactionsLoading.remove(tid)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let needsReply = j["needs_reply"] as? Bool,
                      let reactions = j["reactions"] as? [String] else { return }
                self.quickReactions[tid] = QuickReactionResult(needsReply: needsReply, reactions: reactions)
            }
        }.resume()
    }

    private static let nowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    /// スレッドの優先度(要返信/FYI/完了)を判定する。一覧行が表示された時に呼ぶ想定で、
    /// 同じ最新メッセージに対しては再計算しない(新着が来た時だけ再判定)。
    func fetchTriage(for thread: MsgThread) {
        guard let latest = thread.items.first else { return }
        guard triageComputedForLatestID[thread.id] != latest.id else { return }
        guard !triageLoading.contains(thread.id), let key = KoeAccount.current else { return }
        triageLoading.insert(thread.id)
        let itemsPayload = thread.items.prefix(20).map {
            ["who": $0.who, "text": $0.text, "self_authored": $0.selfAuthored, "ts": $0.ts]
        }
        let body: [String: Any] = ["items": itemsPayload, "now": Self.nowFormatter.string(from: Date())]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/triage")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let threadID = thread.id
        let latestID = latest.id
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.triageLoading.remove(threadID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let priority = j["priority"] as? String else { return }
                let reason = (j["reason"] as? String) ?? ""
                self.triageResults[threadID] = TriageResult(priority: priority, reason: reason)
                self.triageComputedForLatestID[threadID] = latestID
            }
        }.resume()
    }

    /// 送信前のトーンチェック。flagged=falseなら即送信してよい(UIはこの結果を待たずブロックしない設計にはしない —
    /// 呼び出し元が結果を見てから送信するかを決める)。
    func toneCheck(draft: String, toWho: String, completion: @escaping (_ flagged: Bool, _ note: String) -> Void) {
        guard let key = KoeAccount.current else { completion(false, ""); return }
        let body: [String: Any] = ["draft": draft, "to_who": toWho]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/tone-check")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let flagged = j["flagged"] as? Bool else {
                DispatchQueue.main.async { completion(false, "") }
                return
            }
            let note = (j["note"] as? String) ?? ""
            DispatchQueue.main.async { completion(flagged, note) }
        }.resume()
    }

    /// 添付画像の1行AI説明を取りに行く(未取得の時だけ)。
    func fetchImageDescription(for item: MsgItem) {
        guard !item.imageURL.isEmpty, imageDescriptions[item.id] == nil,
              !imageDescLoading.contains(item.id), let key = KoeAccount.current else { return }
        imageDescLoading.insert(item.id)
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/describe-image")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["image_url": item.imageURL])
        let itemID = item.id
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.imageDescLoading.remove(itemID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let desc = j["description"] as? String, !desc.isEmpty else { return }
                self.imageDescriptions[itemID] = desc
            }
        }.resume()
    }

    /// 複数スレッドの状況を1本の音声ダイジェストにまとめて再生する(2026-08-26 本人指示「横断音声ダイジェスト」)。
    func playDigest(threads: [MsgThread]) {
        guard !digestLoading, let key = KoeAccount.current else { return }
        digestLoading = true
        let payload = threads.prefix(10).map { t -> [String: Any] in
            let latest = t.items.first
            let unread = t.items.reduce(0) { self.unreadItemIDs.contains($1.id) ? $0 + 1 : $0 }
            return [
                "label": t.label,
                "latest_who": latest?.who ?? "",
                "latest_text": latest?.text ?? "",
                "unread_count": unread,
            ]
        }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/digest")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 45  // 複数スレッド分の要約+TTS合成なのでbriefより長め
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["threads": payload])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.digestLoading = false
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let b64 = j["audio_base64"] as? String,
                      let audioData = Data(base64Encoded: b64) else {
                    klog("Messenger: digest failed")
                    return
                }
                do {
                    self.player = try AVAudioPlayer(data: audioData)
                    self.player?.play()
                } catch {
                    klog("Messenger: digest audio play error: \(error)")
                }
            }
        }.resume()
    }

    /// 直近アクティブなスレッド群を見比べ、同じ話題が複数スレッドに分散していないか一度だけ確認する。
    func checkDuplicates(threads: [MsgThread]) {
        guard !duplicatesChecked, let key = KoeAccount.current else { return }
        duplicatesChecked = true
        let payload = threads.prefix(15).map { t -> [String: Any] in
            ["id": t.id, "label": t.label, "recent_text": t.items.first?.text ?? ""]
        }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/detect-duplicates")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["threads": payload])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let groups = j["duplicate_groups"] as? [[String: Any]] else { return }
                self.duplicateGroups = groups.compactMap { g in
                    guard let ids = g["thread_ids"] as? [String], let topic = g["topic"] as? String else { return nil }
                    return DuplicateGroup(threadIDs: ids, topic: topic)
                }
            }
        }.resume()
    }

    private static func notify(_ item: MsgItem) {
        // NSUserNotification は deprecated のため UNUserNotificationCenter を使う。
        // (entitlements/plist の通知権があれば音・バナーで届く)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = item.source == "line" ? "LINE: \(item.group)" : "🔥 焚き火"
        content.body = "\(item.who): \(item.text)"
        content.sound = .default
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    /// 新着メッセージが来た時だけ、設定に応じて自動で読み上げる(speakBrief に委譲)。
    private func speakIfNeeded(_ item: MsgItem) {
        guard MessengerModel.speakEnabled else { return }
        guard MessengerModel.speakFilter == "all" || MessengerModel.speakFilter == item.source else { return }
        guard !mutedThreadIDs.contains(threadKey(for: item)) else { return }
        speakBrief(for: item)
    }

    /// 1件を /api/messenger/brief でまとめ、音声を再生する。
    /// ただ本文を読むのではなく、『誰から・どの文脈で・何を求めているか』を1〜2文でまとめ、
    /// 必要な時は次の一手を添えた文章に変えてから、発信者の koe 同意済み声(推定できる場合)で再生する。
    /// 本人指示「背景を考えてまとめるなどしてください。あとその人の声を使ってください。
    /// 僕の声でまとめたり提案したりして次のアクション」。
    /// まとめ文は再生後も `briefs[item.id]` に残し、一覧/詳細のテキストとしても見られるようにする
    /// (2026-08-25 本人指示「次何やるかも欲しい」)。自動読み上げ時も、一覧の「要約する」ボタンからの
    /// 手動再生成時も、このメソッドを共通で使う。
    func speakBrief(for item: MsgItem) {
        guard !briefLoading.contains(item.id) else { return }
        briefLoading.insert(item.id)

        let body: [String: Any] = [
            "item": [
                "who": item.who,
                "group": item.group,
                "text": item.text,
                "source": item.source,
                "kind": item.kind,
                "ts": item.ts,
            ]
        ]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/brief")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120  // Gemini + TTS の合成時間(混雑時は 90s を超えることがある)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(KoeAccount.current ?? "")", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            DispatchQueue.main.async { self.briefLoading.remove(item.id) }
            guard let data, error == nil,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = j["audio_base64"] as? String,
                  let audioData = Data(base64Encoded: b64) else {
                klog("Messenger: brief/speak failed: \(error?.localizedDescription ?? "bad response")")
                return
            }
            let text = (j["text"] as? String) ?? ""
            let voice = (j["voice_used"] as? String) ?? "yukihamada"
            DispatchQueue.main.async {
                self.briefs[item.id] = text
                do {
                    self.player = try AVAudioPlayer(data: audioData)
                    self.player?.play()
                    klog("Messenger: speaking brief from \(item.who) with voice=\(voice): \(text.prefix(50))")
                } catch {
                    klog("Messenger: audio play error: \(error)")
                }
            }
        }.resume()
    }

    /// 読み上げを手動で止める(設定UIやウィンドウ操作から呼ぶ想定)。
    func stopSpeaking() {
        player?.stop()
        player = nil
    }
}

/// メッセンジャー返信欄の「🎙 声で入力」用の最小録音+書き起こしヘルパー。
/// VoiceMemoRecorder(履歴保存が前提の設計)とは切り離し、ここでは一時ファイルに録音→
/// 既存のSpeechEngineで書き起こし→/api/messenger/polish-textでフィラー除去、を行って
/// テキストだけを呼び出し元に返す(録音ファイルは使い捨てで即削除)。
final class MessengerVoiceInput: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false

    private var recorder: AVAudioRecorder?
    private let speech = SpeechEngine()

    func start() {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("messenger_voice_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record()
            recorder = rec
            isRecording = true
        } catch {
            klog("MessengerVoiceInput: 録音開始失敗 \(error)")
        }
    }

    func cancel() {
        recorder?.stop()
        if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        isRecording = false
    }

    /// 停止→書き起こし→フィラー除去、まで行って本文だけをonTextに渡す。
    func stop(onText: @escaping (String) -> Void) {
        guard isRecording, let rec = recorder else { return }
        rec.stop()
        isRecording = false
        isProcessing = true
        let url = rec.url
        recorder = nil
        speech.recognize(url: url) { [weak self] raw in
            try? FileManager.default.removeItem(at: url)
            guard let self else { return }
            guard !raw.isEmpty else {
                DispatchQueue.main.async { self.isProcessing = false }
                return
            }
            self.polish(raw) { polished in
                DispatchQueue.main.async {
                    self.isProcessing = false
                    onText(polished)
                }
            }
        }
    }

    private func polish(_ text: String, completion: @escaping (String) -> Void) {
        guard let key = KoeAccount.current else { completion(text); return }
        var req = URLRequest(url: URL(string: "https://mcp.koe.live/api/messenger/polish-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["raw_text": text])
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let polished = j["text"] as? String, !polished.isEmpty else {
                completion(text)
                return
            }
            completion(polished)
        }.resume()
    }
}

/// LINEグループ名 / 焚き火スレッド(slug)単位でまとめた1セクション分。
struct MsgThread: Identifiable {
    let id: String
    let label: String
    let color: Color
    let items: [MsgItem]
}

struct MessengerView: View {
    @ObservedObject var model: MessengerModel
    /// 選択は「グループ(スレッド)」単位。以前は個々のメッセージを選ぶ設計で、左に
    /// スレッド内の全メッセージが展開されて縦に長くなっていた。LINE/焚き火のグループ名・
    /// slugのような細部は隠し、左=グループ一覧/右=そのグループのやり取り、という
    /// 一般的なメッセンジャーの2ペイン構成に変更(2026-08-25 本人指示)。
    @State private var selectedThreadID: String?
    @State private var composing = ""
    /// 一覧の絞り込み(相手名・本文)。2026-08-26 UI刷新「圧倒的使いやすく見やすく」で追加。
    @State private var searchText = ""
    /// LINE/焚き火だけを見たい時のセグメント切替。
    @State private var sourceFilter: SourceFilter = .all
    @FocusState private var composeFocused: Bool
    @StateObject private var voiceInput = MessengerVoiceInput()
    @State private var draftInstruction = ""
    /// トーンチェックで引っかかった時の確認バナー(nilなら非表示)。
    @State private var toneWarning: String?
    @State private var toneCheckPending = false

    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "すべて", line = "LINE", takibi = "焚き火"
        var id: String { rawValue }
    }

    /// model.items(新着が先頭)を、LINEはグループ名・焚き火はスレッド(slug)単位でまとめる。
    /// 配列の出現順=各スレッドの最新メッセージが登場した順なので、新しい会話が上に来る。
    private var groupedThreads: [MsgThread] {
        var order: [String] = []
        var buckets: [String: [MsgItem]] = [:]
        for item in model.items {
            let key = threadKey(for: item)
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]!.append(item)
        }
        return order.map { key in
            let items = buckets[key]!
            let first = items[0]
            if first.source == "line" {
                let name = first.group.isEmpty ? "LINE" : first.group
                return MsgThread(id: key, label: "💬 \(name)", color: .green, items: items)
            } else {
                // 焚き火はコメントでなく元投稿の本文をスレッド見出しに使う(無ければ先頭アイテム)。
                // 22文字だと一覧で意味が取れないほど切れていた(2026-08-25実機確認)ので40文字に拡張、
                // 表示側のlineLimitで幅に応じて自然に省略する。
                let root = items.first(where: { $0.kind != "comment" }) ?? first
                let title = String(root.text.prefix(40))
                return MsgThread(id: key, label: "🔥 \(title)", color: .orange, items: items)
            }
        }
    }

    /// 検索/ソースフィルターを適用した一覧表示用スレッド。選択中スレッドの検索は
    /// groupedThreads(絞り込み前)から探すので、フィルターを変えても選択状態は保たれる。
    private var filteredThreads: [MsgThread] {
        groupedThreads.filter { thread in
            switch sourceFilter {
            case .all: break
            case .line: guard thread.id.hasPrefix("line:") else { return false }
            case .takibi: guard thread.id.hasPrefix("takibi:") else { return false }
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            if thread.label.localizedCaseInsensitiveContains(q) { return true }
            return thread.items.contains {
                $0.who.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q)
            }
        }
    }

    private var selectedThread: MsgThread? {
        groupedThreads.first { $0.id == selectedThreadID }
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
    private static let timeOnly: DateFormatter = { let f = DateFormatter(); f.dateFormat = "H:mm"; return f }()
    private static let monthDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M/d"; return f }()
    private static let dayHeadingFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日(E)"; f.locale = Locale(identifier: "ja_JP"); return f }()

    /// 一覧行用の短い時刻表示: 今日はHH:mm、それ以外はM/d(2026-08-26改善・以前は
    /// "2026-08-25 22:17" が生のまま表示され幅を取っていた)。
    private func shortTimestamp(_ ts: String) -> String {
        guard let date = Self.tsFormatter.date(from: String(ts.prefix(16))) else { return String(ts.prefix(16)) }
        if Calendar.current.isDateInToday(date) { return Self.timeOnly.string(from: date) }
        return Self.monthDay.string(from: date)
    }

    /// 会話ペインの日付区切り線に使う見出し。
    private func dayHeading(_ ts: String) -> String {
        guard let date = Self.tsFormatter.date(from: String(ts.prefix(16))) else { return String(ts.prefix(10)) }
        return Self.dayHeadingFormatter.string(from: date)
    }

    private func dayKey(_ ts: String) -> String { String(ts.prefix(10)) }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack(spacing: 10) {
                Text("💬 メッセンジャー")
                    .font(.title2).bold()
                if model.unread > 0 {
                    Text("\(model.unread)")
                        .font(.caption).fontWeight(.bold).foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
                Spacer()
                // 横断音声ダイジェスト: 今開いている一覧の状況を1本の音声にまとめて聞く。
                Button(action: { model.playDigest(threads: groupedThreads) }) {
                    if model.digestLoading {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "waveform")
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.digestLoading || groupedThreads.isEmpty)
                .help("🎙 今の状況をまとめて聞く")
                // 読み上げトグル
                Button(action: {
                    let new = !MessengerModel.speakEnabled
                    UserDefaults.standard.set(new, forKey: "messenger.speakEnabled")
                    if !new { model.stopSpeaking() }
                }) {
                    Image(systemName: MessengerModel.speakEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                        .foregroundColor(MessengerModel.speakEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(MessengerModel.speakEnabled ? "読み上げ ON(クリックでOFF)" : "読み上げ OFF(クリックでON)")
                Button(action: { model.markRead() }) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("すべて既読にする")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

            if let err = model.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 4)
            }

            // 重複スレッド検知: 同じ話題が複数スレッドに分かれて進んでいる時だけ表示。
            ForEach(model.duplicateGroups) { group in
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.caption2).foregroundColor(.accentColor)
                    Text("「\(group.topic)」が複数のスレッドで進んでいるかも").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button(action: { model.duplicateGroups.removeAll { $0.id == group.id } }) {
                        Image(systemName: "xmark").font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }

            Divider()

            // メイン分割ビュー: 左=検索/フィルター+グループ一覧、右=選んだグループの
            // やり取り全体をチャット形式で表示。
            NavigationSplitView {
                VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                        TextField("検索(相手・本文)", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.callout)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    Picker("", selection: $sourceFilter) {
                        ForEach(SourceFilter.allCases) { f in Text(f.rawValue).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 10).padding(.top, 8)

                Group {
                    if groupedThreads.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("まだ届いていません")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredThreads.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("見つかりませんでした")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filteredThreads, id: \.id, selection: $selectedThreadID) { thread in
                            threadRow(thread).tag(thread.id)
                        }
                        .listStyle(.sidebar)
                    }
                }
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            } detail: {
                if let thread = selectedThread {
                    conversationView(for: thread)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("左の一覧からグループを選ぶと、やり取りがここに表示されます")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // 返信欄: 選んだグループの最新メッセージ(=返信先)へ送る
            if let thread = selectedThread, let latest = thread.items.first {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    // 送信前トーンチェックで引っかかった時だけ出す確認バナー。
                    if let warning = toneWarning {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange)
                            Text(warning).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("書き直す") { toneWarning = nil }.font(.caption)
                            Button("このまま送る") { sendDespiteToneWarning(to: latest) }.font(.caption).foregroundColor(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }

                    // 返信不要+リアクション候補: タップで即送信(=これも明示的なユーザー操作)。
                    // needs_reply=trueの間は何も出さない(文章の返信を促す通常フローのまま)。
                    if let qr = model.quickReactions[thread.id], !qr.needsReply, !qr.reactions.isEmpty, composing.isEmpty {
                        HStack(spacing: 6) {
                            Text("文章の返信は無くても大丈夫そう。リアクションだけでも:")
                                .font(.caption2).foregroundColor(.secondary)
                            ForEach(qr.reactions, id: \.self) { emoji in
                                Button(action: { model.send(to: latest, text: emoji) }) {
                                    Text(emoji).font(.title3)
                                }
                                .buttonStyle(.plain)
                                .disabled(model.sending || latest.replyTo.isEmpty)
                            }
                        }
                    }

                    // AI返信ドラフト: タップでcomposing欄に入るだけ、送信は別途ユーザーが行う。
                    if let drafts = model.draftReplies[thread.id], !drafts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(drafts.enumerated()), id: \.offset) { _, draft in
                                Button(action: { composing = draft; composeFocused = true }) {
                                    HStack(alignment: .top, spacing: 4) {
                                        Image(systemName: "sparkles").font(.caption2)
                                        Text(draft).font(.caption).multilineTextAlignment(.leading)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        Button(action: {
                            if voiceInput.isRecording {
                                voiceInput.stop { text in
                                    composing = composing.isEmpty ? text : composing + " " + text
                                }
                            } else {
                                voiceInput.start()
                            }
                        }) {
                            if voiceInput.isProcessing {
                                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                            } else {
                                Image(systemName: voiceInput.isRecording ? "mic.fill" : "mic")
                                    .foregroundColor(voiceInput.isRecording ? .red : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(voiceInput.isProcessing)
                        .help(voiceInput.isRecording ? "タップで録音終了→文字起こし" : "🎙 声で入力")

                        Button(action: { model.fetchDraftReplies(for: thread, instruction: draftInstruction) }) {
                            if model.draftLoading.contains(thread.id) {
                                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "sparkles")
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.draftLoading.contains(thread.id))
                        .help("✨ AIに返信を下書きしてもらう")

                        // 返信先は上の会話ヘッダーで既に分かるため、ここは短く
                        // (2026-08-25 実機確認: 絵文字付きの長いスレッド名がそのまま出て読みにくかった)。
                        TextField("メッセージを入力(⌘Returnで送信)", text: $composing, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .focused($composeFocused)
                            .onChange(of: composing) { _ in toneWarning = nil }
                            .onSubmit { sendComposing(to: latest) }
                        Button(action: { sendComposing(to: latest) }) {
                            if model.sending || toneCheckPending {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.sending || toneCheckPending || composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || latest.replyTo.isEmpty)
                    }
                }
                .padding(10)
                .background(Color(.windowBackgroundColor))
            }
        }
        .onAppear { model.start() }
        .onChange(of: model.items.count) { _ in model.checkDuplicates(threads: groupedThreads) }
        .onChange(of: selectedThreadID) { _ in
            if let thread = selectedThread {
                model.markRead(itemIDs: thread.items.map { $0.id })
                model.fetchRecap(for: thread)
                if let latest = thread.items.first, !latest.selfAuthored {
                    model.fetchQuickReactions(for: latest)
                }
            }
            draftInstruction = ""
            composeFocused = true
        }
    }

    /// 送信直前にトーンをチェックし、引っかかった時だけ確認を挟む(通常の短い返信はチェックすら
    /// 走らない — バックエンドが20字未満は即スルーする設計なので体感の遅さはほぼ無い)。
    private func sendComposing(to item: MsgItem) {
        let text = composing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !toneCheckPending else { return }
        toneCheckPending = true
        model.toneCheck(draft: text, toWho: item.who) { flagged, note in
            toneCheckPending = false
            if flagged, !note.isEmpty {
                toneWarning = note
            } else {
                composing = ""
                model.send(to: item, text: text)
            }
        }
    }

    /// トーン確認バナーで「このまま送る」を選んだ時、今のcomposing内容をそのまま送る。
    private func sendDespiteToneWarning(to item: MsgItem) {
        let text = composing.trimmingCharacters(in: .whitespacesAndNewlines)
        toneWarning = nil
        guard !text.isEmpty else { return }
        composing = ""
        model.send(to: item, text: text)
    }

    /// 左の一覧: グループ名+最新メッセージのひとこと(要約があればそちら)のみ。
    /// slug/kind等の内部情報はここには出さない。誰の発言かは名前+アバターで分かるように。
    /// 未読件数があれば太字+バッジで強調し、既読は薄く沈めて視線誘導する
    /// (2026-08-26 UI刷新「圧倒的使いやすく見やすく」)。
    @ViewBuilder
    private func threadRow(_ thread: MsgThread) -> some View {
        let latest = thread.items.first
        let unreadCount = thread.items.reduce(0) { model.unreadItemIDs.contains($1.id) ? $0 + 1 : $0 }
        let muted = model.mutedThreadIDs.contains(thread.id)
        HStack(alignment: .top, spacing: 8) {
            if let latest { avatar(for: latest.who, selfAuthored: latest.selfAuthored, size: 32) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let triage = model.triageResults[thread.id] {
                        Circle().fill(triage.dotColor).frame(width: 7, height: 7)
                            .help(triage.reason.isEmpty ? triage.priority : triage.reason)
                    }
                    Text(thread.label)
                        .font(.callout).fontWeight(unreadCount > 0 ? .bold : .semibold)
                        .foregroundColor(thread.color)
                        .lineLimit(1)
                    if muted {
                        Image(systemName: "speaker.slash.fill").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let ts = latest?.ts {
                        Text(shortTimestamp(ts))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    if let latest {
                        let preview = model.briefs[latest.id] ?? latest.text
                        Text("\(latest.who): \(preview)")
                            .font(.subheadline)
                            .foregroundColor(unreadCount > 0 ? .primary.opacity(0.85) : .secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2).fontWeight(.bold).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onAppear { model.fetchTriage(for: thread) }
        .contextMenu {
            Button(action: { model.markRead(itemIDs: thread.items.map { $0.id }) }) {
                Label("既読にする", systemImage: "checkmark.circle")
            }
            .disabled(unreadCount == 0)
            Button(action: { model.toggleMute(thread.id) }) {
                Label(muted ? "ミュート解除" : "ミュート(読み上げない)", systemImage: muted ? "speaker.wave.2" : "speaker.slash")
            }
        }
    }

    /// 発言者を一目で示すイニシャル・アバター。名前ごとに色を固定して視覚的に区別する
    /// (2026-08-25 本人指摘「誰が書いてるかわからない」)。
    @ViewBuilder
    private func avatar(for who: String, selfAuthored: Bool, size: CGFloat = 26) -> some View {
        // 「不明な発信者」は全員同じイニシャル(不)になり、むしろ「全部同じ人」に見えて
        // 逆効果だった(2026-08-25実機確認)。この場合だけ汎用の人物アイコンにする。
        if who == "不明な発信者" {
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundColor(.secondary))
        } else {
            let initial = String(who.prefix(1)).uppercased()
            Circle()
                .fill(selfAuthored ? Color.accentColor : colorForName(who))
                .frame(width: size, height: size)
                .overlay(Text(initial).font(.system(size: size * 0.42)).fontWeight(.bold).foregroundColor(.white))
        }
    }

    private func colorForName(_ name: String) -> Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.65)
    }

    /// 会話1行分: メッセージ本体と、直前の行と日付が変わっていれば区切り見出し。
    private struct ConversationRow: Identifiable {
        let id: String
        let item: MsgItem
        let dayHeading: String?
    }

    /// thread.items(新着が先頭)を古い→新しい順に並べ替え、日付が変わる行にだけ見出しを付ける。
    /// ForEachのcontent内で可変状態を書き換えるとSwiftUIの再評価タイミングに依存して壊れやすいため、
    /// 通常のSwift関数として事前に1回だけ計算する。
    private func conversationRows(for thread: MsgThread) -> [ConversationRow] {
        var rows: [ConversationRow] = []
        var lastDay: String?
        for item in thread.items.reversed() {
            let day = dayKey(item.ts)
            rows.append(ConversationRow(id: item.id, item: item, dayHeading: day != lastDay ? dayHeading(item.ts) : nil))
            lastDay = day
        }
        return rows
    }

    /// 右のやり取り: 選んだグループの全メッセージを古い→新しいの順(チャット形式)で表示。
    /// 日付が変わるところに区切り線を入れ、下端に自動スクロールする
    /// (2026-08-26 UI刷新: 長いスレッドでも「いつの話か」「最新はどこか」が一目で分かるように)。
    @ViewBuilder
    private func conversationView(for thread: MsgThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(thread.label)
                            .font(.title3).fontWeight(.semibold).foregroundColor(thread.color)
                        Spacer()
                        Button(action: { model.toggleMute(thread.id) }) {
                            Label(
                                model.mutedThreadIDs.contains(thread.id) ? "ミュート中" : "ミュートする",
                                systemImage: model.mutedThreadIDs.contains(thread.id) ? "speaker.slash.fill" : "speaker.slash"
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.caption).foregroundColor(.secondary)
                    }
                    if let recap = model.recaps[thread.id], !recap.isEmpty {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "bookmark.fill").font(.caption2).foregroundColor(.accentColor)
                            Text(recap).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    } else if model.recapLoading.contains(thread.id) {
                        HStack(spacing: 5) { ProgressView().scaleEffect(0.5); Text("近況を思い出しています…").font(.caption2).foregroundColor(.secondary) }
                    }
                    ForEach(conversationRows(for: thread)) { row in
                        if let heading = row.dayHeading {
                            dayDivider(heading)
                        }
                        messageBubble(row.item).id(row.item.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let last = thread.items.first?.id { proxy.scrollTo(last, anchor: .bottom) } }
            .onChange(of: thread.id) { _ in if let last = thread.items.first?.id { proxy.scrollTo(last, anchor: .bottom) } }
        }
    }

    @ViewBuilder
    private func dayDivider(_ heading: String) -> some View {
        HStack {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            Text(heading)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 1件のメッセージ。自分発(selfAuthored)は右寄せ+アクセントカラーで、相手の発言と
    /// 見た目で区別する。誰の発言かはアバター+名前で常に分かるようにする
    /// (2026-08-25 本人指摘「誰が書いてるかわからない」)。
    @ViewBuilder
    private func messageBubble(_ item: MsgItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if item.selfAuthored { Spacer(minLength: 40) }
            if !item.selfAuthored { avatar(for: item.who, selfAuthored: false) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.who).font(.callout).fontWeight(.semibold)
                    if item.kind == "comment" {
                        Text("↳ コメント").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(shortTimestamp(item.ts)).font(.caption2).foregroundColor(.secondary)
                }
                if let brief = model.briefs[item.id] {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "sparkles").font(.caption2).foregroundColor(.accentColor)
                        Text(brief).font(.body).textSelection(.enabled)
                    }
                    .padding(8)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(8)
                }
                if !item.imageURL.isEmpty {
                    AuthenticatedImageView(urlString: item.imageURL)
                        .onAppear { model.fetchImageDescription(for: item) }
                    if let desc = model.imageDescriptions[item.id] {
                        Text(desc).font(.caption2).foregroundColor(.secondary)
                    }
                } else {
                    Text(item.text).font(.body).textSelection(.enabled)
                }
                Button(action: { model.speakBrief(for: item) }) {
                    if model.briefLoading.contains(item.id) {
                        HStack(spacing: 4) { ProgressView().scaleEffect(0.5); Text("まとめています…") }
                    } else {
                        Label(model.briefs[item.id] == nil ? "要約して読み上げ" : "もう一度読み上げ", systemImage: "waveform")
                    }
                }
                .disabled(model.briefLoading.contains(item.id))
                .font(.caption2)
            }
            .padding(10)
            .background(item.selfAuthored ? Color.accentColor.opacity(0.16) : Color(.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .cornerRadius(10)
            .frame(maxWidth: 460, alignment: item.selfAuthored ? .trailing : .leading)
            if item.selfAuthored { avatar(for: item.who, selfAuthored: true) }
            if !item.selfAuthored { Spacer(minLength: 40) }
        }
    }
}

/// LINEの画像/動画/スタンプを表示する。/api/messenger/line-image/:id はBearer認証必須で
/// AsyncImageではヘッダを付けられないため、URLSessionで自前取得する
/// (2026-08-25 本人指摘「画像表示されない」)。
private struct AuthenticatedImageView: View {
    let urlString: String
    @State private var nsImage: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 260)
                    .cornerRadius(8)
            } else if failed {
                Label("画像を読み込めませんでした", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ProgressView()
                    .frame(width: 80, height: 80)
            }
        }
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let url = URL(string: urlString), let key = KoeAccount.current else {
            await MainActor.run { failed = true }
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else {
                await MainActor.run { failed = true }
                return
            }
            await MainActor.run { nsImage = img }
        } catch {
            await MainActor.run { failed = true }
        }
    }
}

final class MessengerWindow {
    private var window: NSWindow?
    private let model = MessengerModel()
    /// singleton化（AppDelegateの@objcから常に同じインスタンスを使う）。
    static let shared = MessengerWindow()

    /// アプリ起動時にバックグラウンドポーリングを開始する(ウィンドウを開かなくても
    /// 新着検知→通知→読み上げが動くように。本人指示「届いたら読み上げる」)。
    func startBackgroundPolling() {
        model.start()
        klog("Messenger: background polling started (30s interval)")
    }

    func show() {
        // LSUIElement(メニューバーアプリ)は activate しないと IME が別アプリに吸われ
        // 日本語入力切替が効かない既知の macOS 罠(2026-08-21)。既存の KoeWebWindow/
        // VoiceMessageWindow と同じく activate が必須。
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "💬 メッセンジャー"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 420, height: 400)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MessengerView(model: model))
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    /// メニューバーの未読カウントを返す(設定は AppDelegate 側で model.start() を回しても良いが、
    /// 簡単のためウィンドウが閉じていても start() is driven by the view lifecycle
    func unreadCount() -> Int { model.unread }
}
