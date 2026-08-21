import SwiftUI
import UserNotifications

/// 💬 メッセンジャー(iOS) — takibi(焚き火)/LINE の届いた連絡を1つの窓で見る・返す。
///
/// バックエンド = mcp.koe.live の /api/messenger/inbox・/api/messenger/reply
/// (2026-08-21 本人指示「iPhoneも作って」)。
/// 管理鍵はサーバ側のみが保持し、アプリは自分の koe_… キー(KeychainHelper)で叩く。
/// 新着(自分宛の返信)は KoeTTS.speakInMyVoice で読み上げる。
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

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: MessengerItem, b: MessengerItem) -> Bool { a.id == b.id }
}

@MainActor
final class MessengerModel: ObservableObject {
    @Published var items: [MessengerItem] = []
    @Published var errorMessage: String?
    @Published var sending = false
    @Published var unread = 0

    private let base = "https://mcp.koe.live"
    private var seen = Set<String>()
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() async {
        guard let key = KeychainHelper.get(key: "koe_api_key"), !key.isEmpty else {
            errorMessage = "Koe アカウント未接続(設定から接続してください)"
            items = []
            return
        }
        var req = URLRequest(url: URL(string: "\(base)/api/messenger/inbox?limit=60")!)
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
                    selfAuthored: (x["self_authored"] as? Bool) ?? false
                )
                if !seen.contains(item.id) {
                    seen.insert(item.id)
                    if !items.isEmpty { // 初回ロードは通知しない
                        // 自分宛の返信だけ読み上げる(他人の投稿は通知だけ)。本人指示「自分宛だけ」
                        if item.kind == "comment" && item.selfAuthored {
                            unread += 1
                            notify(item)
                            speak(item)
                        } else {
                            // 他人の投稿も通知は出す(未読バッジで見逃さないため)
                            unread += 1
                            notify(item)
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

    func markRead() { unread = 0 }

    func send(to item: MessengerItem, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let key = KeychainHelper.get(key: "koe_api_key") else { return }
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
                    self.unread = 0
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

    /// 自分宛の返信を本人声で読み上げる(「誰から・どの文脈で・何を求めているか」を1〜2文で)。
    private func speak(_ item: MessengerItem) {
        Task {
            let who = item.who
            let group = item.group.isEmpty ? "" : "「\(item.group)」"
            let text = "\(who) さんから、\(group) への返信が届きました。\(item.text)"
            await KoeTTS.shared.speakInMyVoice(text)
        }
    }
}

struct MessengerView: View {
    @ObservedObject var model: MessengerModel
    @State private var selection: MessengerItem?
    @State private var composing = ""

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
                List(model.items, id: \.id, selection: $selection) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.source == "line" ? "💬 LINE" : (item.kind == "comment" ? "🔥💬 コメント" : "🔥 焚き火"))
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
                    }
                }
                .listStyle(.inset)
                .navigationDestination(for: MessengerItem.self) { item in
                    detailView(for: item)
                }
            }
            .navigationTitle("💬 連絡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if model.unread > 0 {
                            Text("\(model.unread)")
                                .font(.caption2).foregroundColor(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Button(action: { model.unread = 0 }) {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private func detailView(for item: MessengerItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(item.source == "line" ? "💬 LINE · \(item.group)" : "🔥 焚き火")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(item.ts).font(.caption).foregroundColor(.secondary)
                }
                Text(item.who)
                    .font(.title3).fontWeight(.semibold)
                Text(item.text)
                    .font(.body)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    TextField("返信", text: $composing)
                        .textFieldStyle(.roundedBorder)
                    Button(model.sending ? "…" : "送信") {
                        let text = composing
                        composing = ""
                        model.send(to: item, text: text)
                    }
                    .disabled(model.sending || composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.replyTo.isEmpty)
                }
            }
        }
    }
}

struct MessengerView_Previews: PreviewProvider {
    static var previews: some View {
        MessengerView(model: MessengerModel())
    }
}
