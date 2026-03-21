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
    @AppStorage("koe_silence_duration") private var silenceDuration = 0.0
    @AppStorage("koe_auto_send_mac") private var autoSendMac = true
    @AppStorage("koe_continuous_mode") private var continuousMode = false
    @AppStorage("koe_translate_target") private var translateTarget = "en"
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @AppStorage("koe_streaming_preview") private var streamingPreview = false
    @State private var newPhrase = ""
    @State private var showAddPhrase = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - History (top section)
                historySection

                // MARK: - Language
                Section {
                    Picker(L10n.language, selection: $language) {
                        ForEach(Self.languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                }

                // MARK: - AI Processing
                Section {
                    Toggle(L10n.aiTextCorrection, isOn: $llmEnabled)
                    if llmEnabled {
                        Picker(L10n.style, selection: $llmMode) {
                            Text(L10n.styleCorrect).tag("correct")
                            Text(L10n.styleEmail).tag("email")
                            Text(L10n.styleChat).tag("chat")
                            Text(L10n.styleTranslate).tag("translate")
                        }
                        .pickerStyle(.menu)
                        if llmMode == "translate" {
                            Picker(L10n.translateTarget, selection: $translateTarget) {
                                Text(L10n.english).tag("en")
                                Text(L10n.japanese).tag("ja")
                                Text(L10n.chinese).tag("zh")
                                Text(L10n.korean).tag("ko")
                            }
                            .pickerStyle(.menu)
                        }
                    }
                } footer: {
                    Text(L10n.aiFooter)
                }

                // MARK: - Output
                Section {
                    Toggle(L10n.autoCopyAfterRecognition, isOn: $autoCopy)
                    Toggle(L10n.autoSendToMac, isOn: $autoSendMac)
                    Toggle(L10n.continuousMode, isOn: $continuousMode)
                } footer: {
                    if continuousMode {
                        Text(L10n.continuousModeFooter)
                    }
                }

                // MARK: - Mac
                Section {
                    HStack {
                        Text(L10n.macLink)
                        Spacer()
                        if macBridge.isConnected {
                            Label(L10n.connected, systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        } else {
                            Text(L10n.notConnected)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(L10n.macAutoConnect)
                }

                // MARK: - Beta
                Section {
                    Toggle(L10n.macScreenContext, isOn: $screenContextEnabled)
                } header: {
                    Text(L10n.betaFeatures)
                } footer: {
                    Text(L10n.screenContextFooter)
                }

                // MARK: - Recording
                Section {
                    Picker(L10n.silenceAutoStop, selection: $silenceDuration) {
                        Text(L10n.offManual).tag(0.0)
                        Text("1.5s").tag(1.5)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                    }
                    Toggle(L10n.realtimePreview, isOn: $streamingPreview)
                } header: {
                    Text(L10n.recording)
                } footer: {
                    if streamingPreview {
                        Text(L10n.streamingPreviewFooter)
                    }
                }

                // MARK: - Whisper Model
                Section(L10n.speechEngine) {
                    engineStatus
                    if !modelManager.isModelReady {
                        Button {
                            modelManager.download(modelManager.currentModel)
                        } label: {
                            Label(L10n.downloadModelLabel(modelManager.currentModel.sizeMB),
                                  systemImage: "arrow.down.circle")
                        }
                    }
                    if modelManager.isDownloading {
                        ProgressView(value: modelManager.downloadProgress)
                            .tint(.orange)
                    }
                }

                // MARK: - Quick Phrases
                quickPhrasesSection

                // MARK: - About
                Section {
                    LabeledContent(L10n.version,
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    Link(destination: URL(string: "https://app.koe.live")!) {
                        Label(L10n.officialSite, systemImage: "globe")
                    }
                }
            }
            .navigationTitle(L10n.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.done) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - History Section

    @ViewBuilder
    private var historySection: some View {
        if recorder.history.isEmpty {
            Section(L10n.history) {
                Text(L10n.historyEmpty)
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
                        Text(L10n.showAll(recorder.history.count))
                            .font(.subheadline)
                    }
                }
            } header: {
                HStack {
                    Text(L10n.history)
                    Spacer()
                    if !recorder.history.isEmpty {
                        Button(L10n.deleteAll) { recorder.clearHistory() }
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
            Text(L10n.engine)
            Spacer()
            if WhisperContext.shared.isLoaded {
                Text("whisper.cpp")
                    .foregroundStyle(.green)
            } else if modelManager.isModelReady {
                Text(L10n.ready)
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
                Label(L10n.addPhrase, systemImage: "plus.circle")
                    .font(.subheadline)
            }
        } header: {
            Text(L10n.quickPhrases)
        } footer: {
            Text(L10n.quickPhrasesFooter)
        }
        .alert(L10n.addPhrase, isPresented: $showAddPhrase) {
            TextField(L10n.enterPhrase, text: $newPhrase)
            Button(L10n.add) {
                let trimmed = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    recorder.addQuickPhrase(trimmed)
                }
                newPhrase = ""
            }
            Button(L10n.cancelAction, role: .cancel) { newPhrase = "" }
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
