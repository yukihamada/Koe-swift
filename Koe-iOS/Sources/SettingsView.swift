import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var modelManager = ModelManager.shared
    @AppStorage("koe_language") private var language = "ja-JP"

    private let languages = [
        ("ja-JP", "🇯🇵 日本語"),
        ("en-US", "🇺🇸 English"),
        ("zh-CN", "🇨🇳 中文(简体)"),
        ("zh-TW", "🇹🇼 中文(繁體)"),
        ("ko-KR", "🇰🇷 한국어"),
        ("es-ES", "🇪🇸 Español"),
        ("fr-FR", "🇫🇷 Français"),
        ("de-DE", "🇩🇪 Deutsch"),
        ("it-IT", "🇮🇹 Italiano"),
        ("pt-BR", "🇵🇹 Português"),
        ("ru-RU", "🇷🇺 Русский"),
        ("hi-IN", "🇮🇳 हिन्दी"),
        ("th-TH", "🇹🇭 ไทย"),
        ("vi-VN", "🇻🇳 Tiếng Việt"),
        ("id-ID", "🇮🇩 Indonesia"),
        ("nl-NL", "🇳🇱 Nederlands"),
        ("pl-PL", "🇵🇱 Polski"),
        ("tr-TR", "🇹🇷 Türkçe"),
        ("ar-SA", "🇸🇦 العربية"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("音声認識") {
                    Picker("言語", selection: $language) {
                        ForEach(languages, id: \.0) { code, name in
                            Text("\(name)").tag(code)
                        }
                    }

                    LabeledContent("エンジン") {
                        if WhisperContext.shared.isLoaded {
                            Text("whisper.cpp (Metal GPU)")
                                .foregroundStyle(.green)
                        } else if modelManager.isModelReady {
                            Text("whisper.cpp (未ロード)")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Apple Speech")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("whisper.cpp モデル") {
                    ForEach(ModelManager.availableModels) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.subheadline.bold())
                                Text("\(model.description) (\(model.sizeMB)MB)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if modelManager.isDownloading && modelManager.currentModel.id == model.id {
                                ProgressView()
                            } else if modelManager.isDownloaded(model) {
                                if modelManager.currentModel.id == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Button("使用") {
                                        modelManager.selectModel(model)
                                        modelManager.loadWhisperModel { _ in }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            } else {
                                Button("DL") {
                                    modelManager.download(model)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if modelManager.isDownloaded(model) {
                                Button("削除", role: .destructive) {
                                    modelManager.deleteModel(model)
                                }
                            }
                        }
                    }

                    if modelManager.isDownloading {
                        VStack(spacing: 4) {
                            ProgressView(value: modelManager.downloadProgress)
                            Text(modelManager.downloadStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("出力") {
                    Toggle("認識後に自動コピー", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "koe_auto_copy") },
                        set: { UserDefaults.standard.set($0, forKey: "koe_auto_copy") }
                    ))

                    Text("認識完了後、テキストを自動でクリップボードにコピーします")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("LLM後処理") {
                    Toggle("テキスト修正", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "koe_llm_enabled") },
                        set: { UserDefaults.standard.set($0, forKey: "koe_llm_enabled") }
                    ))

                    Picker("モード", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "koe_llm_mode") ?? "correct" },
                        set: { UserDefaults.standard.set($0, forKey: "koe_llm_mode") }
                    )) {
                        Text("修正（誤字・句読点）").tag("correct")
                        Text("メール（丁寧な文体）").tag("email")
                        Text("チャット（カジュアル）").tag("chat")
                        Text("翻訳（日↔英）").tag("translate")
                    }

                    Text("chatweb.ai を使用（無料・API キー不要）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("詳細設定") {
                    Picker("認識精度 (best_of)", selection: Binding(
                        get: { UserDefaults.standard.object(forKey: "koe_whisper_best_of") as? Int ?? 1 },
                        set: { UserDefaults.standard.set($0, forKey: "koe_whisper_best_of") }
                    )) {
                        Text("1 (最速)").tag(1)
                        Text("2").tag(2)
                        Text("3 (バランス)").tag(3)
                        Text("5 (高精度)").tag(5)
                    }

                    Picker("無音で自動停止", selection: Binding(
                        get: { UserDefaults.standard.object(forKey: "koe_silence_duration") as? Double ?? 3.0 },
                        set: { UserDefaults.standard.set($0, forKey: "koe_silence_duration") }
                    )) {
                        Text("1.5秒 (短文向き)").tag(1.5)
                        Text("2.0秒").tag(2.0)
                        Text("3.0秒 (標準)").tag(3.0)
                        Text("5.0秒 (長文向き)").tag(5.0)
                    }

                    Text("best_of: 候補数を増やすと精度向上・速度低下。無音停止: 長いほど途中で切れにくい。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("オーディオ入力") {
                    let inputManager = AudioInputManager.shared

                    LabeledContent("現在の入力") {
                        HStack(spacing: 4) {
                            if inputManager.isExternalInput {
                                Image(systemName: "cable.connector")
                                    .foregroundStyle(.green)
                            }
                            Text(inputManager.currentInput)
                                .foregroundStyle(inputManager.isExternalInput ? .green : .secondary)
                        }
                    }

                    if inputManager.availableInputs.count > 1 {
                        Picker("入力デバイス", selection: Binding(
                            get: {
                                AVAudioSession.sharedInstance().preferredInput?.uid ?? ""
                            },
                            set: { uid in
                                if let port = inputManager.availableInputs.first(where: { $0.uid == uid }) {
                                    inputManager.selectInput(port)
                                }
                            }
                        )) {
                            ForEach(inputManager.availableInputs, id: \.uid) { port in
                                Text(port.portName).tag(port.uid)
                            }
                        }
                    }

                    if inputManager.isExternalInput {
                        Button("楽器モードに設定（低レイテンシ）") {
                            inputManager.configureForInstrument()
                        }
                        .font(.subheadline)
                    }

                    Text("外部オーディオインターフェース（Babyface Pro, iRig等）を接続すると自動検出されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("情報") {
                    LabeledContent("バージョン", value: "1.1.0")
                    Link("公式サイト", destination: URL(string: "https://koe.elio.love")!)
                    Link("GitHub", destination: URL(string: "https://github.com/yukihamada/Koe-swift")!)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
