import SwiftUI
import UserNotifications
import AVFoundation
import Speech

/// 💬 メッセンジャー(iOS) — takibi(焚き火)/LINE の届いた連絡を1つの窓で見る・返す。
///
/// バックエンド = mcp.koe.live の /api/messenger/* (macOS版と共通のエンドポイント群)。
/// 2026-08-26 本人指示「これを完全にiosアプリに対応してほしい」を受け、macOS版
/// (Sources/Koe/MessengerWindow.swift)と機能的に同等になるよう全面刷新。
/// 管理鍵はサーバ側のみが保持し、アプリは自分の koe_… キー(KeychainHelper)で叩く。
struct MessengerItem: Identifiable, Hashable {
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
    let imageURL: String
    /// LINEグループが紐づくプロジェクト名(サーバのproject_for_groupで判定・無ければ空文字)。
    let project: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: MessengerItem, b: MessengerItem) -> Bool { a.id == b.id }
}

/// LINEはグループ名・焚き火はスレッド(slug)単位の一意キー。macOS版と同じ定義を共有する。
func messengerThreadKey(for item: MessengerItem) -> String {
    item.source == "line" ? "line:\(item.group)" : "takibi:\(item.slug.isEmpty ? "misc" : item.slug)"
}

func messengerProjectIcon(_ project: String) -> String {
    switch project {
    case "焚き火": return "🔥"
    case "イネブラ本体": return "🏢"
    case "JiuFlow": return "🥋"
    case "nagaiki.app": return "🐕"
    case "MU": return "👕"
    case "SOLUNA": return "🌙"
    case "": return ""
    default: return "📁"
    }
}

struct MessengerQuickReactionResult {
    let needsReply: Bool
    let reactions: [String]
}

struct MessengerTriageResult {
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

struct MessengerDuplicateGroup: Identifiable {
    var id: String { threadIDs.joined(separator: ",") }
    let threadIDs: [String]
    let topic: String
}

/// グループ(LINEグループ or 焚き火スレッド)単位でまとめた1セクション分。
struct MessengerThread: Identifiable, Hashable {
    let id: String
    let label: String
    let color: Color
    let items: [MessengerItem]

    var project: String { items.first(where: { !$0.project.isEmpty })?.project ?? "" }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: MessengerThread, b: MessengerThread) -> Bool { a.id == b.id }
}

@MainActor
final class MessengerModel: ObservableObject {
    @Published var items: [MessengerItem] = []
    @Published var errorMessage: String?
    @Published var sending = false
    @Published var unread = 0
    /// スレッド単位の既読管理。以前は選択に関係なく`unread`全体を0にしていたが、
    /// スレッド単位に修正(macOS版と同じ設計、2026-08-26)。
    @Published var unreadItemIDs: Set<String> = []
    @Published var mutedThreadIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "messenger.mutedThreads.ios") ?? [])
    @Published var briefs: [String: String] = [:]
    @Published var briefLoading: Set<String> = []
    @Published var recaps: [String: String] = [:]
    @Published var recapLoading: Set<String> = []
    @Published var draftReplies: [String: [String]] = [:]
    @Published var draftLoading: Set<String> = []
    @Published var quickReactions: [String: MessengerQuickReactionResult] = [:]
    @Published var quickReactionsLoading: Set<String> = []
    @Published var triageResults: [String: MessengerTriageResult] = [:]
    private var triageComputedForLatestID: [String: String] = [:]
    @Published var triageLoading: Set<String> = []
    @Published var imageDescriptions: [String: String] = [:]
    private var imageDescLoading: Set<String> = []
    @Published var digestLoading = false
    @Published var duplicateGroups: [MessengerDuplicateGroup] = []
    private var duplicatesChecked = false

    /// これ未満の文字数の本文は自動読み上げしない(本人指示「読み上げは長いやつだけ」)。
    static var speakMinLength: Int { 30 }

    private let base = "https://mcp.koe.live"
    private var seen = Set<String>()
    private var timer: Timer?
    private var player: AVAudioPlayer?

    private func authKey() -> String? { KeychainHelper.get(key: "koe_api_key") }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() async {
        guard let key = authKey(), !key.isEmpty else {
            errorMessage = "Koe アカウント未接続(設定から接続してください)"
            items = []
            return
        }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/inbox?limit=200")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = j["items"] as? [[String: Any]] else {
                errorMessage = code == 403 ? "このメッセンジャーは管理者専用です" : "応答異常 (HTTP \(code))"
                return
            }
            errorMessage = nil
            var fresh: [MessengerItem] = []
            for x in list {
                let item = MessengerItem(
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
                    imageURL: (x["image_url"] as? String) ?? "",
                    project: (x["project"] as? String) ?? ""
                )
                if !seen.contains(item.id) {
                    seen.insert(item.id)
                    if !items.isEmpty { // 初回ロードは通知しない
                        if !item.selfAuthored {
                            unread += 1
                            unreadItemIDs.insert(item.id)
                            notify(item)
                            speakIfNeeded(item)
                        }
                    }
                    fresh.append(item)
                }
            }
            items = fresh + items
        } catch {
            errorMessage = "接続失敗: \(error.localizedDescription)"
        }
    }

    func markRead() { unread = 0; unreadItemIDs.removeAll() }

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
        UserDefaults.standard.set(Array(mutedThreadIDs), forKey: "messenger.mutedThreads.ios")
    }

    func send(to item: MessengerItem, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let key = authKey() else { return }
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
            Task { @MainActor in
                self.sending = false
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    let tid = messengerThreadKey(for: item)
                    self.markRead(itemIDs: self.items.filter { messengerThreadKey(for: $0) == tid }.map { $0.id })
                    self.errorMessage = nil
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                    self.errorMessage = "送信失敗 (HTTP \(code)): \((msg?["detail"] as? String) ?? (msg?["error"] as? String) ?? "")"
                }
            }
        }.resume()
    }

    private func notify(_ item: MessengerItem) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = item.source == "line" ? "LINE: \(item.group)" : "🔥 焚き火"
        content.body = "\(item.who): \(item.text)"
        content.sound = .default
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    private func speakIfNeeded(_ item: MessengerItem) {
        guard !mutedThreadIDs.contains(messengerThreadKey(for: item)) else { return }
        guard !item.imageURL.isEmpty || item.text.count >= Self.speakMinLength else { return }
        Task {
            let who = item.who
            let group = item.group.isEmpty ? "" : "「\(item.group)」"
            let text = "\(who) さんから、\(group) への連絡です。\(item.text)"
            await KoeTTS.shared.speakInMyVoice(text)
        }
    }

    // MARK: - AI機能(すべて判定・生成のみ。実際の送信は必ず人間の明示的なタップを経て
    // send(to:text:) が別途行う。自動送信するコードパスはここには一切無い)

    func fetchRecap(for thread: MessengerThread) {
        guard recaps[thread.id] == nil, !recapLoading.contains(thread.id), let key = authKey() else { return }
        recapLoading.insert(thread.id)
        let itemsPayload = thread.items.prefix(20).map { ["who": $0.who, "text": $0.text, "ts": $0.ts] }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/recap")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["items": itemsPayload])
        let threadID = thread.id
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                self.recapLoading.remove(threadID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recap = j["recap"] as? String, !recap.isEmpty else { return }
                self.recaps[threadID] = recap
            }
        }.resume()
    }

    func fetchDraftReplies(for thread: MessengerThread, instruction: String = "") {
        guard !draftLoading.contains(thread.id), let key = authKey() else { return }
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
            Task { @MainActor in
                guard let self else { return }
                self.draftLoading.remove(threadID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let drafts = j["drafts"] as? [String], !drafts.isEmpty else { return }
                self.draftReplies[threadID] = drafts
            }
        }.resume()
    }

    func fetchQuickReactions(for item: MessengerItem) {
        let tid = messengerThreadKey(for: item)
        guard !quickReactionsLoading.contains(tid), let key = authKey() else { return }
        quickReactionsLoading.insert(tid)
        let body: [String: Any] = ["who": item.who, "text": item.text, "source": item.source, "kind": item.kind]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/quick-reactions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                self.quickReactionsLoading.remove(tid)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let needsReply = j["needs_reply"] as? Bool,
                      let reactions = j["reactions"] as? [String] else { return }
                self.quickReactions[tid] = MessengerQuickReactionResult(needsReply: needsReply, reactions: reactions)
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

    func fetchTriage(for thread: MessengerThread) {
        guard let latest = thread.items.first else { return }
        guard triageComputedForLatestID[thread.id] != latest.id else { return }
        guard !triageLoading.contains(thread.id), let key = authKey() else { return }
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
            Task { @MainActor in
                guard let self else { return }
                self.triageLoading.remove(threadID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let priority = j["priority"] as? String else { return }
                let reason = (j["reason"] as? String) ?? ""
                self.triageResults[threadID] = MessengerTriageResult(priority: priority, reason: reason)
                self.triageComputedForLatestID[threadID] = latestID
            }
        }.resume()
    }

    func toneCheck(draft: String, toWho: String, completion: @escaping (_ flagged: Bool, _ note: String) -> Void) {
        guard let key = authKey() else { completion(false, ""); return }
        let body: [String: Any] = ["draft": draft, "to_who": toWho]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/tone-check")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            Task { @MainActor in
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let flagged = j["flagged"] as? Bool else {
                    completion(false, "")
                    return
                }
                completion(flagged, (j["note"] as? String) ?? "")
            }
        }.resume()
    }

    func fetchImageDescription(for item: MessengerItem) {
        guard !item.imageURL.isEmpty, imageDescriptions[item.id] == nil,
              !imageDescLoading.contains(item.id), let key = authKey() else { return }
        imageDescLoading.insert(item.id)
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/describe-image")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["image_url": item.imageURL])
        let itemID = item.id
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                self.imageDescLoading.remove(itemID)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let desc = j["description"] as? String, !desc.isEmpty else { return }
                self.imageDescriptions[itemID] = desc
            }
        }.resume()
    }

    func playDigest(threads: [MessengerThread]) {
        guard !digestLoading, let key = authKey() else { return }
        digestLoading = true
        let payload = threads.prefix(10).map { t -> [String: Any] in
            let latest = t.items.first
            let unread = t.items.reduce(0) { self.unreadItemIDs.contains($1.id) ? $0 + 1 : $0 }
            return ["label": t.label, "latest_who": latest?.who ?? "", "latest_text": latest?.text ?? "", "unread_count": unread]
        }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/digest")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["threads": payload])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                self.digestLoading = false
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let b64 = j["audio_base64"] as? String,
                      let audioData = Data(base64Encoded: b64) else { return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.playback, mode: .default)
                    try? session.setActive(true)
                    self.player = try AVAudioPlayer(data: audioData)
                    self.player?.play()
                } catch {
                    // 再生失敗は静かに諦める(致命的ではない)
                }
            }
        }.resume()
    }

    func checkDuplicates(threads: [MessengerThread]) {
        guard !duplicatesChecked, let key = authKey() else { return }
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
            Task { @MainActor in
                guard let self else { return }
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let groups = j["duplicate_groups"] as? [[String: Any]] else { return }
                self.duplicateGroups = groups.compactMap { g in
                    guard let ids = g["thread_ids"] as? [String], let topic = g["topic"] as? String else { return nil }
                    return MessengerDuplicateGroup(threadIDs: ids, topic: topic)
                }
            }
        }.resume()
    }

    /// 1件を要約+読み上げる(一覧/詳細の「要約して読み上げ」ボタン用)。
    func speakBrief(for item: MessengerItem) {
        guard !briefLoading.contains(item.id), let key = authKey() else { return }
        briefLoading.insert(item.id)
        let body: [String: Any] = ["item": [
            "who": item.who, "group": item.group, "text": item.text,
            "source": item.source, "kind": item.kind, "ts": item.ts,
        ]]
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/brief")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                self.briefLoading.remove(item.id)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let b64 = j["audio_base64"] as? String,
                      let audioData = Data(base64Encoded: b64) else { return }
                let text = (j["text"] as? String) ?? ""
                self.briefs[item.id] = text
                do {
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.playback, mode: .default)
                    try? session.setActive(true)
                    self.player = try AVAudioPlayer(data: audioData)
                    self.player?.play()
                } catch {}
            }
        }.resume()
    }
}

/// 「🎙 声で入力」用の最小録音+書き起こしヘルパー(iOS)。Apple標準のSFSpeechRecognizerで
/// 書き起こし→/api/messenger/polish-textでフィラー除去、を行いテキストだけを返す。
/// 録音ファイルは使い捨てで即削除する。
@MainActor
final class MessengerVoiceInput: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("messenger_voice_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        rec.record()
        recorder = rec
        recordingURL = url
        isRecording = true
    }

    func cancel() {
        recorder?.stop()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        isRecording = false
    }

    func stop(onText: @escaping (String) -> Void) {
        guard isRecording, let rec = recorder, let url = recordingURL else { return }
        rec.stop()
        isRecording = false
        isProcessing = true
        recorder = nil
        transcribe(url: url) { [weak self] raw in
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in
                guard let self else { return }
                guard !raw.isEmpty else {
                    self.isProcessing = false
                    return
                }
                self.polish(raw) { polished in
                    self.isProcessing = false
                    onText(polished)
                }
            }
        }
    }

    nonisolated private func transcribe(url: URL, completion: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            completion("")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        recognizer.recognitionTask(with: request) { result, error in
            guard let result, result.isFinal else {
                if error != nil { completion("") }
                return
            }
            completion(result.bestTranscription.formattedString)
        }
    }

    private func polish(_ text: String, completion: @escaping (String) -> Void) {
        guard let key = KeychainHelper.get(key: "koe_api_key") else { completion(text); return }
        var req = URLRequest(url: URL(string: "https://mcp.koe.live/api/messenger/polish-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["raw_text": text])
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            Task { @MainActor in
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let polished = j["text"] as? String, !polished.isEmpty else {
                    completion(text)
                    return
                }
                completion(polished)
            }
        }.resume()
    }
}

struct MessengerView: View {
    @ObservedObject var model: MessengerModel
    @State private var searchText = ""
    @State private var sourceFilter: MessengerSourceFilter = .all

    private enum MessengerSourceFilter: String, CaseIterable, Identifiable {
        case all = "すべて", line = "LINE", takibi = "焚き火"
        var id: String { rawValue }
    }

    /// model.items(新着が先頭)を、LINEはグループ名・焚き火はスレッド(slug)単位でまとめる。
    private var groupedThreads: [MessengerThread] {
        var order: [String] = []
        var buckets: [String: [MessengerItem]] = [:]
        for item in model.items {
            let key = messengerThreadKey(for: item)
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]!.append(item)
        }
        return order.map { key in
            let items = buckets[key]!
            let first = items[0]
            if first.source == "line" {
                let name = first.group.isEmpty ? "LINE" : first.group
                return MessengerThread(id: key, label: "💬 \(name)", color: .green, items: items)
            } else {
                let root = items.first(where: { $0.kind != "comment" }) ?? first
                let title = String(root.text.prefix(40))
                return MessengerThread(id: key, label: "🔥 \(title)", color: .orange, items: items)
            }
        }
    }

    private var filteredThreads: [MessengerThread] {
        groupedThreads.filter { thread in
            switch sourceFilter {
            case .all: break
            case .line: guard thread.id.hasPrefix("line:") else { return false }
            case .takibi: guard thread.id.hasPrefix("takibi:") else { return false }
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            if thread.label.localizedCaseInsensitiveContains(q) { return true }
            return thread.items.contains { $0.who.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let err = model.errorMessage {
                    Text("⚠ \(err)")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                ForEach(model.duplicateGroups) { group in
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.caption2).foregroundColor(.accentColor)
                        Text("「\(group.topic)」が複数のスレッドで進んでいるかも").font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Button(action: { model.duplicateGroups.removeAll { $0.id == group.id } }) {
                            Image(systemName: "xmark").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                    TextField("検索(相手・本文)", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.top, 4)

                Picker("", selection: $sourceFilter) {
                    ForEach(MessengerSourceFilter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.vertical, 6)

                if groupedThreads.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 32)).foregroundColor(.secondary)
                        Text("まだ届いていません").foregroundColor(.secondary)
                    }
                    Spacer()
                } else if filteredThreads.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundColor(.secondary)
                        Text("見つかりませんでした").foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List(filteredThreads) { thread in
                        NavigationLink(value: thread) {
                            threadRow(thread)
                        }
                        .onAppear { model.fetchTriage(for: thread) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("💬 連絡")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MessengerThread.self) { thread in
                detailView(for: thread)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button(action: { model.playDigest(threads: groupedThreads) }) {
                            if model.digestLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "waveform")
                            }
                        }
                        .disabled(model.digestLoading || groupedThreads.isEmpty)
                        if model.unread > 0 {
                            Text("\(model.unread)")
                                .font(.caption2).foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                        }
                        Button(action: { model.markRead() }) {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.items.count) { _ in model.checkDuplicates(threads: groupedThreads) }
    }

    @ViewBuilder
    private func threadRow(_ thread: MessengerThread) -> some View {
        let latest = thread.items.first
        let unreadCount = thread.items.reduce(0) { model.unreadItemIDs.contains($1.id) ? $0 + 1 : $0 }
        let muted = model.mutedThreadIDs.contains(thread.id)
        HStack(alignment: .top, spacing: 8) {
            if let latest { avatar(for: latest.who, selfAuthored: latest.selfAuthored, size: 34) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let triage = model.triageResults[thread.id] {
                        Circle().fill(triage.dotColor).frame(width: 7, height: 7)
                    }
                    if !thread.project.isEmpty {
                        Text(messengerProjectIcon(thread.project)).font(.caption)
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
                        Text(String(ts.prefix(16))).font(.caption2).foregroundColor(.secondary)
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
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(muted ? "ミュート解除" : "ミュート") { model.toggleMute(thread.id) }
                .tint(.gray)
            Button("既読") { model.markRead(itemIDs: thread.items.map { $0.id }) }
                .tint(.blue)
                .disabled(unreadCount == 0)
        }
    }

    @ViewBuilder
    private func avatar(for who: String, selfAuthored: Bool, size: CGFloat = 30) -> some View {
        if who == "不明な発信者" {
            Circle().fill(Color.secondary.opacity(0.3)).frame(width: size, height: size)
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

    private static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let attrRange = Range<AttributedString.Index>(range, in: attributed) else { continue }
            attributed[attrRange].link = url
            attributed[attrRange].foregroundColor = .accentColor
            attributed[attrRange].underlineStyle = .single
        }
        return attributed
    }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
    private static let dayHeadingFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日(E)"; f.locale = Locale(identifier: "ja_JP"); return f
    }()

    private func dayKey(_ ts: String) -> String { String(ts.prefix(10)) }
    private func dayHeading(_ ts: String) -> String {
        guard let date = Self.tsFormatter.date(from: String(ts.prefix(16))) else { return String(ts.prefix(10)) }
        return Self.dayHeadingFormatter.string(from: date)
    }

    fileprivate struct DetailRow: Identifiable {
        let id: String
        let item: MessengerItem
        let dayHeading: String?
    }

    private func detailRows(for thread: MessengerThread) -> [DetailRow] {
        var rows: [DetailRow] = []
        var lastDay: String?
        for item in thread.items.reversed() {
            let day = dayKey(item.ts)
            rows.append(DetailRow(id: item.id, item: item, dayHeading: day != lastDay ? dayHeading(item.ts) : nil))
            lastDay = day
        }
        return rows
    }

    @ViewBuilder
    private func detailView(for thread: MessengerThread) -> some View {
        MessengerThreadDetailView(
            thread: thread,
            model: model,
            rows: detailRows(for: thread),
            linkify: Self.linkified
        )
    }
}

/// スレッド詳細(会話本体+返信欄)。@State を独立させるため専用Viewに切り出している
/// (macOS版と同じくAI下書き・声入力・トーンチェック・近況しおりをここに集約)。
private struct MessengerThreadDetailView: View {
    let thread: MessengerThread
    @ObservedObject var model: MessengerModel
    let rows: [MessengerView.DetailRow]
    let linkify: (String) -> AttributedString

    @State private var composing = ""
    @FocusState private var composeFocused: Bool
    @StateObject private var voiceInput = MessengerVoiceInput()
    @State private var toneWarning: String?
    @State private var toneCheckPending = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let recap = model.recaps[thread.id], !recap.isEmpty {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "bookmark.fill").font(.caption2).foregroundColor(.accentColor)
                                Text(recap).font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        } else if model.recapLoading.contains(thread.id) {
                            HStack(spacing: 5) { ProgressView().scaleEffect(0.7); Text("近況を思い出しています…").font(.caption2).foregroundColor(.secondary) }
                        }
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { row in
                                if let heading = row.dayHeading {
                                    dayDivider(heading)
                                }
                                messageBubble(row.item).id(row.item.id)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if let last = thread.items.first?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            Divider()
            composeBar
        }
        .navigationTitle(thread.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !thread.project.isEmpty {
                    Text("\(messengerProjectIcon(thread.project)) \(thread.project)")
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .onAppear {
            model.markRead(itemIDs: thread.items.map { $0.id })
            model.fetchRecap(for: thread)
            if let latest = thread.items.first, !latest.selfAuthored {
                model.fetchQuickReactions(for: latest)
            }
        }
    }

    @ViewBuilder
    private func dayDivider(_ heading: String) -> some View {
        HStack {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            Text(heading).font(.caption2).foregroundColor(.secondary).fixedSize()
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func avatar(for who: String, selfAuthored: Bool) -> some View {
        let initial = String(who.prefix(1)).uppercased()
        Circle()
            .fill(selfAuthored ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .overlay(Text(initial).font(.system(size: 11)).fontWeight(.bold).foregroundColor(.white))
    }

    @ViewBuilder
    private func messageBubble(_ item: MessengerItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if item.selfAuthored { Spacer(minLength: 30) }
            if !item.selfAuthored { avatar(for: item.who, selfAuthored: false) }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.who).font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text(String(item.ts.prefix(16))).font(.caption2).foregroundColor(.secondary)
                }
                if let brief = model.briefs[item.id] {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "sparkles").font(.caption2).foregroundColor(.accentColor)
                        Text(brief).font(.body)
                    }
                }
                if !item.imageURL.isEmpty {
                    AuthenticatedRemoteImage(urlString: item.imageURL)
                        .onAppear { model.fetchImageDescription(for: item) }
                    if let desc = model.imageDescriptions[item.id] {
                        Text(desc).font(.caption2).foregroundColor(.secondary)
                    }
                } else {
                    Text(linkify(item.text)).font(.body)
                }
                Button(action: { model.speakBrief(for: item) }) {
                    if model.briefLoading.contains(item.id) {
                        HStack(spacing: 4) { ProgressView().scaleEffect(0.6); Text("まとめています…") }
                    } else {
                        Label(model.briefs[item.id] == nil ? "要約して読み上げ" : "もう一度読み上げ", systemImage: "waveform")
                    }
                }
                .disabled(model.briefLoading.contains(item.id))
                .font(.caption2)
            }
            .padding(10)
            .background(item.selfAuthored ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground))
            .cornerRadius(10)
            .frame(maxWidth: 320, alignment: item.selfAuthored ? .trailing : .leading)
            if !item.selfAuthored { Spacer(minLength: 30) }
        }
    }

    @ViewBuilder
    private var composeBar: some View {
        guard let latest = thread.items.first else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
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
                if let qr = model.quickReactions[thread.id], !qr.needsReply, !qr.reactions.isEmpty, composing.isEmpty {
                    HStack(spacing: 6) {
                        Text("返信は無くても大丈夫そう:").font(.caption2).foregroundColor(.secondary)
                        ForEach(qr.reactions, id: \.self) { emoji in
                            Button(action: { model.send(to: latest, text: emoji) }) {
                                Text(emoji).font(.title3)
                            }
                            .disabled(model.sending || latest.replyTo.isEmpty)
                        }
                    }
                }
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
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Button(action: {
                        if voiceInput.isRecording {
                            voiceInput.stop { text in composing = composing.isEmpty ? text : composing + " " + text }
                        } else {
                            voiceInput.start()
                        }
                    }) {
                        if voiceInput.isProcessing {
                            ProgressView()
                        } else {
                            Image(systemName: voiceInput.isRecording ? "mic.fill" : "mic")
                                .foregroundColor(voiceInput.isRecording ? .red : .secondary)
                        }
                    }
                    .disabled(voiceInput.isProcessing)

                    Button(action: { model.fetchDraftReplies(for: thread) }) {
                        if model.draftLoading.contains(thread.id) {
                            ProgressView()
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                    .disabled(model.draftLoading.contains(thread.id))

                    TextField("メッセージを入力", text: $composing, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($composeFocused)
                        .onChange(of: composing) { _ in toneWarning = nil }

                    Button(action: { sendComposing(to: latest) }) {
                        if model.sending || toneCheckPending {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(model.sending || toneCheckPending || composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || latest.replyTo.isEmpty)
                }
            }
            .padding(10)
            .background(Color(.systemBackground))
        )
    }

    private func sendComposing(to item: MessengerItem) {
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

    private func sendDespiteToneWarning(to item: MessengerItem) {
        let text = composing.trimmingCharacters(in: .whitespacesAndNewlines)
        toneWarning = nil
        guard !text.isEmpty else { return }
        composing = ""
        model.send(to: item, text: text)
    }
}

/// LINEの画像/動画/スタンプを表示する(iOS版)。/api/messenger/line-image/:id はBearer認証必須。
private struct AuthenticatedRemoteImage: View {
    let urlString: String
    @State private var uiImage: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 240)
                    .cornerRadius(8)
            } else if failed {
                Label("画像を読み込めませんでした", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ProgressView().frame(width: 80, height: 80)
            }
        }
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let url = URL(string: urlString), let key = KeychainHelper.get(key: "koe_api_key") else {
            failed = true
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else {
                failed = true
                return
            }
            uiImage = img
        } catch {
            failed = true
        }
    }
}

struct MessengerView_Previews: PreviewProvider {
    static var previews: some View {
        MessengerView(model: MessengerModel())
    }
}
