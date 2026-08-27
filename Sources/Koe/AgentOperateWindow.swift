import AppKit
import SwiftUI
import AVFoundation

/// 🤖 操作 — Koe MacアプリからClaude/Senteのプロセスを直接動かす窓(2026-08-26 本人指示
/// 「macもiosからもclaudeやsenteのプロセスにアクセスして操作できるようにしてほしい」)。
///
/// 2系統のバックエンドに指示を出す:
/// - **Claude**: koe.live/agent と同じ公開エンドポイント(認証不要・IPレート制限のみ)。
///   `POST /api/agent` → 依頼として takibi-worker-local(Macのlaunchdジョブ・30秒毎ポーリング)が
///   `claude -p` をMCPフル装備で実行 → `GET /api/agent/result?id=` でポーリングして結果を取る。
/// - **Sente**: sente-cloud(OpenCodeクラウド実行環境)。実行権限を持つセッショントークンは
///   koe-mcpサーバ側のみが保持し、このアプリには一切渡らない。`POST mcp.koe.live/api/agent/sente`
///   がkoe_api_key認証で中継し、同期的に結果を返す。
enum AgentEngine: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case sente = "Sente"
    var id: String { rawValue }
    var icon: String { self == .claude ? "sparkles" : "bolt.fill" }
    var hint: String {
        self == .claude
            ? "koe.live/agentと同じキュー経由(数十秒〜数分、MCPツールフル装備)"
            : "sente-cloud(OpenCodeクラウド実行環境)で即実行(数秒〜数分)"
    }
}

struct AgentExchange: Identifiable {
    let id = UUID()
    let engine: AgentEngine
    let prompt: String
    var status: String  // "送信中…" / "作業中…" / "完了" / "エラー"
    var result: String?
    var isDone: Bool { status == "完了" || status == "エラー" }
}

@MainActor
final class AgentOperateModel: ObservableObject {
    @Published var exchanges: [AgentExchange] = []
    @Published var sending = false

    private let koeBase = "https://mcp.koe.live"
    private let agentBase = "https://koe.live"

    func submit(engine: AgentEngine, prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        sending = true
        let index = exchanges.count
        exchanges.append(AgentExchange(engine: engine, prompt: prompt, status: "送信中…", result: nil))
        switch engine {
        case .claude: submitClaude(prompt: prompt, index: index)
        case .sente: submitSente(prompt: prompt, index: index)
        }
    }

    // MARK: - Claude(koe.live/agent と同じキュー)

    private func submitClaude(prompt: String, index: Int) {
        var req = URLRequest(url: URL(string: "\(agentBase)/api/agent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": prompt, "name": "優貴"])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.finish(index: index, status: "エラー", result: "送信に失敗しました")
                    return
                }
                if let reqID = j["req_id"] as? String {
                    self.updateStatus(index: index, status: "作業中…(takibi-workerが実行中)")
                    self.pollClaudeResult(reqID: reqID, index: index, attempt: 0)
                } else {
                    // 「〜って喋って」等の即応答系はreplyがそのまま結果。
                    self.finish(index: index, status: "完了", result: (j["reply"] as? String) ?? "(応答なし)")
                }
            }
        }.resume()
    }

    /// 6秒毎に最大5分ポーリング(takibi-workerの実行launchd間隔=30秒に合わせて余裕を持たせる)。
    private func pollClaudeResult(reqID: String, index: Int, attempt: Int) {
        guard attempt < 50 else {
            finish(index: index, status: "エラー", result: "タイムアウトしました(5分経過)。あとで受信箱を確認してください。")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            let url = URL(string: "\(self.agentBase)/api/agent/result?id=\(reqID)")!
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                DispatchQueue.main.async {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard let data, code == 200,
                          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.pollClaudeResult(reqID: reqID, index: index, attempt: attempt + 1)
                        return
                    }
                    if let ok = j["ok"] as? Bool, ok {
                        self.finish(index: index, status: "完了", result: (j["result"] as? String) ?? "(結果なし)")
                    } else {
                        self.pollClaudeResult(reqID: reqID, index: index, attempt: attempt + 1)
                    }
                }
            }.resume()
        }
    }

    // MARK: - Sente(sente-cloud、鍵はサーバ側のみ保持)

    private func submitSente(prompt: String, index: Int) {
        guard let key = KoeAccount.current else {
            finish(index: index, status: "エラー", result: "Koe アカウント未接続(設定から接続してください)")
            return
        }
        updateStatus(index: index, status: "作業中…(sente-cloudで実行中、最大数分)")
        var req = URLRequest(url: URL(string: "\(koeBase)/api/agent/sente")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 290
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": prompt])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, code == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.finish(index: index, status: "エラー", result: "sente-cloud呼び出しに失敗しました (HTTP \(code))")
                    return
                }
                if let text = j["text"] as? String, !text.isEmpty {
                    self.finish(index: index, status: "完了", result: text)
                } else if let err = j["error"] as? String, !err.isEmpty {
                    // 🪤 j["error"]はRust側でValue::Null(JSON null)の時も常にキーが存在し、
                    // JSONSerializationはそれをNSNull(≠nil)にデコードする。`if let err = j["error"]`
                    // だけだと null でも常に真になり、テキスト無しの正常応答が「エラー」表示に
                    // 化けてしまう(2026-08-27 fork agentレビューで発見)。String castで明示的に除外する。
                    self.finish(index: index, status: "エラー", result: err)
                } else {
                    self.finish(index: index, status: "完了", result: "(テキストでの応答はありませんでした。操作は実行された可能性があります)")
                }
            }
        }.resume()
    }

    private func updateStatus(index: Int, status: String) {
        guard exchanges.indices.contains(index) else { return }
        exchanges[index].status = status
    }

    private func finish(index: Int, status: String, result: String) {
        guard exchanges.indices.contains(index) else { return }
        exchanges[index].status = status
        exchanges[index].result = result
        sending = false
    }
}

struct AgentOperateView: View {
    @ObservedObject var model: AgentOperateModel
    @State private var engine: AgentEngine = .claude
    @State private var composing = ""
    @FocusState private var composeFocused: Bool
    @StateObject private var voiceInput = MessengerVoiceInput()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("🤖 操作").font(.title2).bold()
                Spacer()
                Picker("", selection: $engine) {
                    ForEach(AgentEngine.allCases) { e in
                        Label(e.rawValue, systemImage: e.icon).tag(e)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)

            Text(engine.hint)
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if model.exchanges.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "terminal").font(.system(size: 32)).foregroundColor(.secondary)
                            Text("ここからClaudeやSenteに指示を出せます").foregroundColor(.secondary).font(.callout)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.exchanges) { ex in
                                exchangeRow(ex).id(ex.id)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: model.exchanges.count) { _ in
                    if let last = model.exchanges.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: {
                    if voiceInput.isRecording {
                        voiceInput.stop { text in composing = composing.isEmpty ? text : composing + " " + text }
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

                TextField("\(engine.rawValue)への指示を入力(⌘Returnで送信)", text: $composing, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($composeFocused)
                    .onSubmit { send() }
                Button(action: send) {
                    if model.sending {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.sending || composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(Color(.windowBackgroundColor))
        }
        .onAppear { composeFocused = true }
    }

    private func send() {
        let text = composing
        composing = ""
        model.submit(engine: engine, prompt: text)
    }

    @ViewBuilder
    private func exchangeRow(_ ex: AgentExchange) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer(minLength: 40)
                Text(ex.prompt).font(.body).textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.16))
                    .cornerRadius(10)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ex.engine.icon).font(.caption2).foregroundColor(.secondary).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    if let result = ex.result {
                        Text(result).font(.body).textSelection(.enabled)
                    } else {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.6); Text(ex.status).font(.caption).foregroundColor(.secondary) }
                    }
                }
                .padding(10)
                .background(ex.status == "エラー" ? Color.red.opacity(0.1) : Color(.controlBackgroundColor))
                .cornerRadius(10)
                Spacer(minLength: 40)
            }
        }
    }
}

@MainActor
final class AgentOperateWindow {
    private var window: NSWindow?
    private let model = AgentOperateModel()
    static let shared = AgentOperateWindow()

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "🤖 操作"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 420, height: 400)
        win.isReleasedWhenClosed = false
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.contentView = NSHostingView(rootView: AgentOperateView(model: model))
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}
