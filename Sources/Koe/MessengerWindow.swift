import AppKit
import SwiftUI
import UserNotifications

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
                    self.unread = 0
                    self.error = nil
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                    self.error = "送信失敗 (HTTP \(code)): \((msg?["detail"] as? String) ?? "")"
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
}

struct MessengerView: View {
    @ObservedObject var model: MessengerModel
    @State private var selection: MsgItem?
    @State private var composing = ""

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("💬 メッセンジャー")
                    .font(.title2).bold()
                if model.unread > 0 {
                    Text("\(model.unread) 件未読")
                        .font(.caption).foregroundColor(.orange)
                }
                Spacer()
                Button(action: { model.unread = 0 }) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("未読をクリア")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

            if let err = model.error {
                Text("⚠ \(err)")
                    .font(.caption).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 4)
            }

            Divider()

            // メイン分割ビュー
            NavigationSplitView {
                Group {
                    if model.items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("まだ届いていません")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(model.items, id: \.id, selection: $selection) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.source == "line" ? "💬 LINE" : "🔥 焚き火")
                                        .font(.caption2).fontWeight(.bold)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(item.source == "line" ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                        .foregroundColor(item.source == "line" ? .green : .orange)
                                        .clipShape(Capsule())
                                    if !item.group.isEmpty, item.group != "焚き火" {
                                        Text(item.group)
                                            .font(.caption2).foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(String(item.ts.prefix(16)))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Text(item.who)
                                    .font(.callout).fontWeight(.semibold)
                                Text(item.text)
                                    .font(.subheadline).lineLimit(4)
                            }
                            .padding(.vertical, 4)
                            .tag(item)
                        }
                        .listStyle(.inset)
                    }
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            } detail: {
                if let target = selection {
                    detailView(for: target)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("左の一覧からスレッドを選ぶと、ここに全文が表示されます")
                            .font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // 返信欄
            if let target = selection {
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("返信: \(target.source == "line" ? target.group : "焚き火")へ",
                              text: $composing, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button(action: {
                        let text = composing
                        composing = ""
                        model.send(to: target, text: text)
                    }) {
                        if model.sending {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(model.sending || composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.replyTo.isEmpty)
                }
                .padding(10)
                .background(Color(.windowBackgroundColor))
            }
        }
        .onAppear { model.start() }
        .onChange(of: selection) { _ in model.unread = 0 }
    }

    @ViewBuilder
    private func detailView(for item: MsgItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.source == "line" ? "💬 LINE · \(item.group)" : "🔥 焚き火")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(item.ts).font(.caption).foregroundColor(.secondary)
                }
                Text(item.who)
                    .font(.title3).fontWeight(.semibold)
                Text(item.text)
                    .font(.body).textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

final class MessengerWindow {
    private var window: NSWindow?
    private let model = MessengerModel()
    /// singleton化（AppDelegateの@objcから常に同じインスタンスを使う）。
    static let shared = MessengerWindow()

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
