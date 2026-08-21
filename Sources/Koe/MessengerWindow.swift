import AppKit
import SwiftUI

/// 💬 メッセンジャー — takibi(焚き火)/LINE の届いた連絡を1つの窓で見る・返す。
///
/// バックエンド = mcp.koe.live の /api/messenger/inbox・/api/messenger/reply
/// (2026-08-21 本人指示「takibiとかLINEに連絡きたらKoeアプリのメッセンジャーで見れるように」)。
/// 管理鍵はサーバ側のみが保持し、アプリは自分の koe_… キー(KoeAccount)で叩く。
struct MsgItem: Identifiable, Hashable {
    let id: String
    let source: String   // "line" | "takibi"
    let slug: String
    let ts: String
    let who: String
    let group: String
    let text: String
    let replyTo: String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: MsgItem, b: MsgItem) -> Bool { a.id == b.id }
}

final class MessengerModel: ObservableObject {
    @Published var items: [MsgItem] = []
    @Published var error: String?
    @Published var composing = ""
    @Published var sending = false
    @Published var unread = 0

    private let base = "https://mcp.koe.live"
    private var seen = Set<String>()
    private var timer: Timer?

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
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/inbox?limit=60")!)
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
                        slug: (x["slug"] as? String) ?? "",
                        ts: (x["ts"] as? String) ?? "",
                        who: (x["who"] as? String) ?? "名無し",
                        group: (x["group"] as? String) ?? "",
                        text: (x["text"] as? String) ?? "",
                        replyTo: (x["reply_to"] as? String) ?? ""
                    )
                    if !self.seen.contains(item.id) {
                        self.seen.insert(item.id)
                        if !self.items.isEmpty { // 初回ロードは通知しない
                            self.unread += 1
                            MessengerModel.notify(item)
                        }
                        fresh.append(item)
                    }
                }
                self.items = fresh + self.items
            }
        }.resume()
    }

    func markRead() { unread = 0 }

    func send(to item: MsgItem) {
        let text = composing.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    self.composing = ""
                    self.error = nil
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                    self.error = "送信失敗 (HTTP \(code)): \((msg?["detail"] as? String) ?? "")"
                }
            }
        }.resume()
    }

    private static func notify(_ item: MsgItem) {
        let n = NSUserNotification()
        n.title = item.source == "line" ? "LINE: \(item.group)" : "🔥 焚き火"
        n.informativeText = "\(item.who): \(item.text.prefix(80))"
        n.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(n)
    }
}

struct MessengerView: View {
    @ObservedObject var model: MessengerModel
    @State private var selection: MsgItem?

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.error {
                Text(err).font(.caption).foregroundColor(.red).padding(6)
            }
            if model.items.isEmpty {
                Spacer()
                Text("まだ届いていません").foregroundColor(.secondary)
                Spacer()
            } else {
                List(model.items, selection: $selection) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.source == "line" ? "💬 LINE · \(item.group)" : "🔥 焚き火")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text(item.ts).font(.caption2).foregroundColor(.secondary)
                        }
                        Text(item.who).font(.headline)
                        Text(item.text).font(.body).lineLimit(4)
                    }
                    .padding(.vertical, 3)
                }
            }
            if let target = selection ?? model.items.first {
                HStack(alignment: .bottom) {
                    TextField("返信: \(target.source == "line" ? target.group : "焚き火")へ",
                              text: $model.composing)
                        .textFieldStyle(.roundedBorder)
                    Button(model.sending ? "…" : "送信") { model.send(to: target) }
                        .disabled(model.sending || model.composing.isEmpty)
                }
                .padding(8)
                .onAppear { model.markRead() }
            }
        }
        .onAppear { model.start() }
        // ウィンドウを閉じてもポーリングを止めない(未読バッジと通知を受け続けるため)
    }
}

final class MessengerWindow {
    private var window: NSWindow?
    private let model = MessengerModel()

    /// singleton化（AppDelegateの@objcから常に同じインスタンスを使う）。
    static let shared = MessengerWindow()

    func show() {
        // LSUIElement(メニューバーアプリ)のままだとアプリが前面化せず、
        // IME(ひらがな⇄英字の切替)が他アプリ側に吸われてテキスト入力が英字固定になる。
        // 既存ウィンドウ(KoeWebWindow/VoiceMessageWindow)と同じく activate を必ず呼ぶ。
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "💬 メッセンジャー"
        win.minSize = NSSize(width: 360, height: 320)
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
