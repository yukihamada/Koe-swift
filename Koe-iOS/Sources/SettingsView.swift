import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelManager = ModelManager.shared
    @ObservedObject var recorder: RecordingManager
    @ObservedObject private var macBridge = MacBridge.shared
    @AppStorage("koe_language") private var language = "ja-JP"
    @AppStorage("koe_auto_copy") private var autoCopy = false
    @AppStorage("koe_llm_enabled") private var llmEnabled = false
    @AppStorage("koe_llm_mode") private var llmMode = "correct"
    @AppStorage("koe_silence_duration") private var silenceDuration = 3.0
    @AppStorage("koe_auto_send_mac") private var autoSendMac = true
    @AppStorage("koe_continuous_mode") private var continuousMode = false
    @AppStorage("koe_translate_target") private var translateTarget = "en"
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @State private var newPhrase = ""
    @State private var showAddPhrase = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - History (top section)
                historySection

                // MARK: - Language
                Section {
                    Picker("言語", selection: $language) {
                        ForEach(Self.languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                }

                // MARK: - AI Processing
                Section {
                    Toggle("AI文章補正", isOn: $llmEnabled)
                    if llmEnabled {
                        Picker("スタイル", selection: $llmMode) {
                            Text("修正").tag("correct")
                            Text("メール").tag("email")
                            Text("チャット").tag("chat")
                            Text("翻訳 日↔英").tag("translate")
                        }
                        .pickerStyle(.menu)
                        if llmMode == "translate" {
                            Picker("翻訳先", selection: $translateTarget) {
                                Text("英語").tag("en")
                                Text("日本語").tag("ja")
                                Text("中国語").tag("zh")
                                Text("韓国語").tag("ko")
                            }
                            .pickerStyle(.menu)
                        }
                    }
                } footer: {
                    Text("音声認識後にAIがテキストを整えます")
                }

                // MARK: - Output
                Section {
                    Toggle("認識後に自動コピー", isOn: $autoCopy)
                    Toggle("Macに自動送信", isOn: $autoSendMac)
                    Toggle("連続認識モード", isOn: $continuousMode)
                } footer: {
                    if continuousMode {
                        Text("認識完了後に自動で次の録音を開始します")
                    }
                }

                // MARK: - Mac
                Section {
                    HStack {
                        Text("Mac連携")
                        Spacer()
                        if macBridge.isConnected {
                            Label("接続中", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        } else {
                            Text("未接続")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("同じWiFiのMacでKoeが起動中なら自動接続します")
                }

                // MARK: - Beta
                Section {
                    Toggle("Mac画面コンテキスト", isOn: $screenContextEnabled)
                } header: {
                    Text("ベータ機能")
                } footer: {
                    Text("Macのウィンドウ情報をiPhoneに表示します。Screenタブが有効になります。")
                }

                // MARK: - Recording
                Section("録音") {
                    Picker("無音で自動停止", selection: $silenceDuration) {
                        Text("1.5秒").tag(1.5)
                        Text("2秒").tag(2.0)
                        Text("3秒").tag(3.0)
                        Text("5秒").tag(5.0)
                    }
                }

                // MARK: - Whisper Model
                Section("音声認識エンジン") {
                    engineStatus
                    if !modelManager.isModelReady {
                        Button {
                            modelManager.download(modelManager.currentModel)
                        } label: {
                            Label("高精度モデルをダウンロード (\(modelManager.currentModel.sizeMB)MB)",
                                  systemImage: "arrow.down.circle")
                        }
                    }
                    if modelManager.isDownloading {
                        ProgressView(value: modelManager.downloadProgress)
                            .tint(.orange)
                    }
                }

                // MARK: - More Features
                Section("その他の機能") {
                    NavigationLink {
                        MeetingView()
                    } label: {
                        Label("議事録", systemImage: "doc.text")
                    }
                    NavigationLink {
                        VoiceMemoView(recorder: recorder)
                    } label: {
                        Label("音声メモ検索", systemImage: "magnifyingglass")
                    }
                    NavigationLink {
                        ConversationView()
                    } label: {
                        Label("対面翻訳", systemImage: "bubble.left.and.bubble.right")
                    }
                    NavigationLink {
                        AudioToolsView()
                    } label: {
                        Label("オーディオツール", systemImage: "waveform")
                    }
                    NavigationLink {
                        SolunaView()
                    } label: {
                        Label("Soluna", systemImage: "dot.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        SoundMemoryView()
                    } label: {
                        Label("Sound Memory", systemImage: "brain.head.profile")
                    }
                }

                // MARK: - Quick Phrases
                quickPhrasesSection

                // MARK: - About
                Section {
                    LabeledContent("バージョン",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    Link(destination: URL(string: "https://app.koe.live")!) {
                        Label("公式サイト", systemImage: "globe")
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - History Section

    @ViewBuilder
    private var historySection: some View {
        if recorder.history.isEmpty {
            Section("履歴") {
                Text("音声入力するとここに表示されます")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        } else {
            Section {
                ForEach(recorder.history.prefix(5)) { item in
                    Button {
                        UIPasteboard.general.string = item.text
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(item.date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if recorder.history.count > 5 {
                    NavigationLink {
                        HistoryView(recorder: recorder)
                    } label: {
                        Text("すべて表示 (\(recorder.history.count)件)")
                            .font(.subheadline)
                    }
                }
            } header: {
                HStack {
                    Text("履歴")
                    Spacer()
                    if !recorder.history.isEmpty {
                        Button("全削除") { recorder.clearHistory() }
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Engine Status

    @ViewBuilder
    private var engineStatus: some View {
        HStack {
            Text("エンジン")
            Spacer()
            if WhisperContext.shared.isLoaded {
                Text("whisper.cpp")
                    .foregroundStyle(.green)
            } else if modelManager.isModelReady {
                Text("準備完了")
                    .foregroundStyle(.orange)
            } else {
                Text("Apple Speech")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    // MARK: - Quick Phrases Section

    @ViewBuilder
    private var quickPhrasesSection: some View {
        Section {
            ForEach(recorder.quickPhrases, id: \.self) { phrase in
                Button {
                    recorder.sendQuickPhrase(phrase)
                } label: {
                    HStack {
                        Text(phrase)
                            .foregroundStyle(.primary)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "paperplane")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            .onDelete { offsets in
                recorder.removeQuickPhrase(at: offsets)
            }
            Button {
                showAddPhrase = true
            } label: {
                Label("定型文を追加", systemImage: "plus.circle")
                    .font(.subheadline)
            }
        } header: {
            Text("定型文（クイックフレーズ）")
        } footer: {
            Text("タップでMacに送信。左スワイプで削除。")
        }
        .alert("定型文を追加", isPresented: $showAddPhrase) {
            TextField("フレーズを入力", text: $newPhrase)
            Button("追加") {
                let trimmed = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    recorder.addQuickPhrase(trimmed)
                }
                newPhrase = ""
            }
            Button("キャンセル", role: .cancel) { newPhrase = "" }
        }
    }

    // MARK: - Languages

    private static let languages = [
        ("ja-JP", "🇯🇵 日本語"),
        ("en-US", "🇺🇸 English"),
        ("zh-CN", "🇨🇳 中文"),
        ("ko-KR", "🇰🇷 한국어"),
        ("es-ES", "🇪🇸 Español"),
        ("fr-FR", "🇫🇷 Français"),
        ("de-DE", "🇩🇪 Deutsch"),
        ("pt-BR", "🇵🇹 Português"),
        ("ru-RU", "🇷🇺 Русский"),
        ("th-TH", "🇹🇭 ไทย"),
        ("vi-VN", "🇻🇳 Tiếng Việt"),
        ("ar-SA", "🇸🇦 العربية"),
    ]
}
