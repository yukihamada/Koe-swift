import SwiftUI
import Speech
import AVFoundation

/// 🤖 操作(iOS) — Koe iPhoneアプリからClaude/Senteのプロセスを直接動かす画面
/// (2026-08-26 本人指示「macもiosからもclaudeやsenteのプロセスにアクセスして操作できるように」)。
/// macOS版(Sources/Koe/AgentOperateWindow.swift)と同じ2バックエンドを使う:
/// - **Claude**: koe.live/agent と同じ公開エンドポイント(認証不要・IPレート制限のみ)。
///   `POST /api/agent` → takibi-worker-local(Macのlaunchdジョブ)が `claude -p` をMCPフル装備で実行
///   → `GET /api/agent/result?id=` でポーリング。
/// - **Sente**: `POST mcp.koe.live/api/agent/sente`(koe_api_key認証)がサーバ側でsente-cloudに中継。
///   実行権限を持つセッショントークンはこのアプリには一切渡らない。
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
    var status: String
    var result: String?
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

    private func submitClaude(prompt: String, index: Int) {
        var req = URLRequest(url: URL(string: "\(agentBase)/api/agent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": prompt, "name": "優貴"])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            Task { @MainActor in
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
                    self.finish(index: index, status: "完了", result: (j["reply"] as? String) ?? "(応答なし)")
                }
            }
        }.resume()
    }

    private func pollClaudeResult(reqID: String, index: Int, attempt: Int) {
        guard attempt < 50 else {
            finish(index: index, status: "エラー", result: "タイムアウトしました(5分経過)。あとで受信箱を確認してください。")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            let url = URL(string: "\(self.agentBase)/api/agent/result?id=\(reqID)")!
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                Task { @MainActor in
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

    private func submitSente(prompt: String, index: Int) {
        guard let key = KeychainHelper.get(key: "koe_api_key") else {
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
            Task { @MainActor in
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
                    // 🪤 j["error"]はValue::Null(JSON null)でもNSNull(≠nil)になるため、
                    // Stringキャストで明示的に除外する(2026-08-27 fork agentレビューで発見)。
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

/// 🎙 声で指示を入力するための最小録音+書き起こしヘルパー(Messenger版と同一設計)。
@MainActor
final class AgentVoiceInput: NSObject, ObservableObject {
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
        } catch { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent_voice_\(UUID().uuidString).m4a")
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

    func stop(onText: @escaping (String) -> Void) {
        guard isRecording, let rec = recorder, let url = recordingURL else { return }
        rec.stop()
        isRecording = false
        isProcessing = true
        recorder = nil
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            try? FileManager.default.removeItem(at: url)
            isProcessing = false
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result, result.isFinal else {
                if error != nil {
                    try? FileManager.default.removeItem(at: url)
                    Task { @MainActor in self?.isProcessing = false }
                }
                return
            }
            try? FileManager.default.removeItem(at: url)
            let text = result.bestTranscription.formattedString
            Task { @MainActor in
                self?.isProcessing = false
                onText(text)
            }
        }
    }
}

struct AgentOperateView: View {
    @ObservedObject var model: AgentOperateModel
    @State private var engine: AgentEngine = .claude
    @State private var composing = ""
    @FocusState private var composeFocused: Bool
    @StateObject private var voiceInput = AgentVoiceInput()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $engine) {
                ForEach(AgentEngine.allCases) { e in Label(e.rawValue, systemImage: e.icon).tag(e) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8)

            Text(engine.hint)
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 6)

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
                            ForEach(model.exchanges) { ex in exchangeRow(ex).id(ex.id) }
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

                TextField("\(engine.rawValue)への指示を入力", text: $composing, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($composeFocused)
                Button(action: send) {
                    if model.sending {
                        ProgressView()
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(model.sending || composing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(Color(.systemBackground))
        }
        .navigationTitle("🤖 操作")
        .navigationBarTitleDisplayMode(.inline)
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
                Spacer(minLength: 30)
                Text(ex.prompt).font(.body)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.16))
                    .cornerRadius(10)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ex.engine.icon).font(.caption2).foregroundColor(.secondary).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    if let result = ex.result {
                        Text(result).font(.body)
                    } else {
                        HStack(spacing: 6) { ProgressView(); Text(ex.status).font(.caption).foregroundColor(.secondary) }
                    }
                }
                .padding(10)
                .background(ex.status == "エラー" ? Color.red.opacity(0.1) : Color(.secondarySystemBackground))
                .cornerRadius(10)
                Spacer(minLength: 30)
            }
        }
    }
}

struct AgentOperateView_Previews: PreviewProvider {
    static var previews: some View {
        AgentOperateView(model: AgentOperateModel())
    }
}
