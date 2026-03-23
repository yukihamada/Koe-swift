import AppKit
import SwiftUI

/// 議事録に対してAIで質問応答するウィンドウ
class MeetingChatWindow {
    private var window: NSWindow?
    private let model = MeetingChatModel()

    func show(transcript: String, title: String = "議事録") {
        model.transcript = transcript
        model.title = title
        model.messages = [
            ChatMessage(role: .assistant, text: "議事録「\(title)」を読み込みました。\n\(transcript.count)文字、質問をどうぞ。")
        ]

        if window != nil { window?.makeKeyAndOrderFront(nil); return }

        let rect = NSRect(x: 0, y: 0, width: 500, height: 600)
        let win = NSWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Koe AI チャット — \(title)"
        win.minSize = NSSize(width: 350, height: 300)
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MeetingChatView(model: model))
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

// MARK: - Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    enum Role { case user, assistant }
}

class MeetingChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isGenerating = false
    var transcript = ""
    var title = ""

    func sendMessage() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isGenerating else { return }
        inputText = ""
        messages.append(ChatMessage(role: .user, text: query))
        isGenerating = true

        // 議事録テキストを制限（LLMのコンテキスト上限対策）
        let maxContext = 2500
        let context = transcript.count > maxContext ? String(transcript.prefix(maxContext)) : transcript

        let systemPrompt = """
        あなたは議事録分析アシスタントです。以下の議事録に基づいて質問に答えてください。
        議事録にない情報は「議事録には記載がありません」と答えてください。
        回答は簡潔に。

        --- 議事録 ---
        \(context)
        """

        let llm = LlamaContext.shared
        guard let localModel = llm.selectedModel, llm.isDownloaded(localModel) else {
            // ローカルLLMがない場合はLLMProcessor経由（リモート）
            LLMProcessor.shared.process(text: query, instruction: systemPrompt) { [weak self] result in
                DispatchQueue.main.async {
                    self?.messages.append(ChatMessage(role: .assistant, text: result))
                    self?.isGenerating = false
                }
            }
            return
        }

        // ローカルLLM
        let doGenerate = { [weak self] in
            llm.generate(system: systemPrompt, user: query, maxTokens: 512) { result in
                DispatchQueue.main.async {
                    let answer = result ?? "回答を生成できませんでした。"
                    self?.messages.append(ChatMessage(role: .assistant, text: answer))
                    self?.isGenerating = false
                }
            }
        }

        if llm.isLoaded {
            doGenerate()
        } else {
            llm.loadModel { ok in
                if ok { doGenerate() }
                else {
                    DispatchQueue.main.async {
                        self.messages.append(ChatMessage(role: .assistant, text: "LLMの読み込みに失敗しました。"))
                        self.isGenerating = false
                    }
                }
            }
        }
    }
}

// MARK: - View

struct MeetingChatView: View {
    @ObservedObject var model: MeetingChatModel

    var body: some View {
        VStack(spacing: 0) {
            // メッセージ一覧
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { msg in
                            HStack(alignment: .top, spacing: 8) {
                                if msg.role == .user {
                                    Spacer()
                                    Text(msg.text)
                                        .padding(8)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(8)
                                        .frame(maxWidth: 350, alignment: .trailing)
                                } else {
                                    Image(systemName: "brain.head.profile")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 2)
                                    Text(msg.text)
                                        .padding(8)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(8)
                                        .frame(maxWidth: 350, alignment: .leading)
                                    Spacer()
                                }
                            }
                            .id(msg.id)
                        }

                        if model.isGenerating {
                            HStack {
                                ProgressView().scaleEffect(0.6)
                                Text("考え中...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // 入力欄
            HStack(spacing: 8) {
                TextField("質問を入力...", text: $model.inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.sendMessage() }
                    .disabled(model.isGenerating)

                Button {
                    model.sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.inputText.trimmingCharacters(in: .whitespaces).isEmpty || model.isGenerating)
            }
            .padding(10)
        }
    }
}
