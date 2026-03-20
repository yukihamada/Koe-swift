import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Koe 設定"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Luxury Design Tokens
private enum Lux {
    static let gold      = Color(red: 0.78, green: 0.68, blue: 0.50)
    static let champagne = Color(red: 0.90, green: 0.84, blue: 0.72)
    static let charcoal  = Color(red: 0.10, green: 0.09, blue: 0.08)
}

struct SettingsRootView: View {
    @State private var selectedPersona: Persona?

    var body: some View {
        VStack(spacing: 0) {
            // Persona quick-select bar
            PersonaBar(selectedPersona: $selectedPersona)

            TabView {
                GeneralTab()
                    .tabItem { Label("一般", systemImage: "gear") }
                VoiceTab()
                    .tabItem { Label("音声", systemImage: "waveform") }
                AITab()
                    .tabItem { Label("AI", systemImage: "brain.head.profile") }
                AutomationTab()
                    .tabItem { Label("自動化", systemImage: "bolt.fill") }
                StatsTab()
                    .tabItem { Label("統計", systemImage: "chart.bar.fill") }
                HistoryTab()
                    .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
            }
        }
        .padding(16)
        .frame(width: 580, height: 580)
        .sheet(item: $selectedPersona) { persona in
            PersonaDetailView(persona: persona) { selectedPersona = nil }
        }
    }
}

// MARK: - Persona System

struct Persona: Identifiable {
    let id: String
    let name: String
    let icon: String
    let subtitle: String
    let description: String
    let settings: PersonaSettings
}

struct PersonaSettings {
    let language: String
    let llmEnabled: Bool
    let llmMode: String          // maps to LLMMode raw
    let agentMode: Bool
    let streamingPreview: Bool
    let silenceWait: Double
    let beamSearch: Bool
    let superMode: Bool
    let customPrompt: String
    let tips: [String]
}

enum PersonaCatalog {
    static let all: [Persona] = [
        Persona(
            id: "business",
            name: "ビジネス",
            icon: "briefcase.fill",
            subtitle: "メール・議事録・報告書",
            description: "ビジネス文書に最適化。敬語の誤り修正、句読点の自動挿入、フォーマルな文体への整形を行います。",
            settings: PersonaSettings(
                language: "ja-JP",
                llmEnabled: true,
                llmMode: "formal",
                agentMode: false,
                streamingPreview: false,
                silenceWait: 1.5,
                beamSearch: true,
                superMode: true,
                customPrompt: "ビジネス文書として適切な敬語・句読点・改行に整形してください。箇条書きは「・」で統一。",
                tips: [
                    "「改行」で段落を分けられます",
                    "「句点」「読点」で句読点を挿入",
                    "Super Modeでアプリに合わせた出力",
                    "メールアプリではより丁寧な文体に"
                ]
            )
        ),
        Persona(
            id: "engineer",
            name: "エンジニア",
            icon: "chevron.left.forwardslash.chevron.right",
            subtitle: "コード・コメント・ドキュメント",
            description: "プログラミング用語を正確に認識。変数名やAPI名の誤変換を防ぎ、技術文書に適した出力を生成します。",
            settings: PersonaSettings(
                language: "ja-JP",
                llmEnabled: true,
                llmMode: "custom",
                agentMode: true,
                streamingPreview: true,
                silenceWait: 2.0,
                beamSearch: true,
                superMode: true,
                customPrompt: "技術文書・コードコメントとして整形。プログラミング用語は英語のまま保持。カタカナ語は原語に近い表記に。",
                tips: [
                    "エージェントモードで「ターミナルでgit status」",
                    "Super ModeでIDE検知→コメント形式を自動調整",
                    "「タブ」でインデント挿入",
                    "コードエディタではコメント形式に最適化"
                ]
            )
        ),
        Persona(
            id: "creator",
            name: "クリエイター",
            icon: "paintbrush.fill",
            subtitle: "文章・SNS・ブログ",
            description: "自然で読みやすい文体に整形。文章のリズムを保ちながら、適切な句読点と改行を挿入します。",
            settings: PersonaSettings(
                language: "ja-JP",
                llmEnabled: true,
                llmMode: "custom",
                agentMode: false,
                streamingPreview: true,
                silenceWait: 2.0,
                beamSearch: false,
                superMode: false,
                customPrompt: "自然で読みやすい文体に整形。話し言葉のニュアンスを活かしつつ、読みやすく。過度なフォーマル化は避ける。",
                tips: [
                    "「改行」「段落」で構成を整える",
                    "「かぎかっこ開き」「閉じ」で会話文を挿入",
                    "「はてな」「ビックリマーク」で記号入力",
                    "ゆっくりモードで長文も正確に"
                ]
            )
        ),
        Persona(
            id: "student",
            name: "学生",
            icon: "graduationcap.fill",
            subtitle: "レポート・ノート・メモ",
            description: "レポートやノート向け。学術用語を正確に認識し、論理的な文章構成をサポートします。",
            settings: PersonaSettings(
                language: "ja-JP",
                llmEnabled: true,
                llmMode: "custom",
                agentMode: false,
                streamingPreview: false,
                silenceWait: 1.5,
                beamSearch: true,
                superMode: false,
                customPrompt: "レポート・学術文書として整形。「である」調に統一。専門用語は正確に。",
                tips: [
                    "「段落」で段落分け",
                    "高精度モードで専門用語を正確に",
                    "文脈引き継ぎで長いレポートも一貫性を維持",
                    "履歴タブで過去のメモを検索"
                ]
            )
        ),
        Persona(
            id: "multilingual",
            name: "多言語",
            icon: "globe",
            subtitle: "英語・翻訳・国際会議",
            description: "多言語対応に最適化。英語の音声認識や、日英混在の文章を適切に処理します。",
            settings: PersonaSettings(
                language: "en-US",
                llmEnabled: true,
                llmMode: "custom",
                agentMode: false,
                streamingPreview: false,
                silenceWait: 1.5,
                beamSearch: true,
                superMode: false,
                customPrompt: "Fix grammar and punctuation. Preserve the original language. For mixed Japanese-English text, keep each language segment natural.",
                tips: [
                    "メニューバーから言語を素早く切り替え",
                    "「スペース」で英単語間のスペースを挿入",
                    "Beam Searchで多言語を正確に認識",
                    "コンテキスト認識で言語を自動判定"
                ]
            )
        ),
    ]
}

// MARK: - Persona Bar (top of settings)

struct PersonaBar: View {
    @Binding var selectedPersona: Persona?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("プリセット")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(.secondary)
                    .tracking(0.5)

                Spacer()

                ForEach(PersonaCatalog.all) { persona in
                    Button {
                        selectedPersona = persona
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: persona.icon)
                                .font(.system(size: 9))
                            Text(persona.name)
                                .font(.system(size: 10, weight: .light))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Lux.gold.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

// MARK: - Persona Detail View

struct PersonaDetailView: View {
    let persona: Persona
    let onDismiss: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var applied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: persona.icon)
                    .font(.system(size: 28, weight: .thin))
                    .foregroundColor(Lux.gold)
                    .frame(width: 48, height: 48)
                    .background(
                        Circle()
                            .fill(Lux.gold.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(persona.name)
                        .font(.system(size: 20, weight: .light))
                        .tracking(1)
                    Text(persona.subtitle)
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Description
                    Text(persona.description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineSpacing(4)

                    // Settings preview
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            settingRow("言語", persona.settings.language == "ja-JP" ? "日本語" : "English")
                            settingRow("LLM後処理", persona.settings.llmEnabled ? "有効" : "無効")
                            settingRow("高精度モード", persona.settings.beamSearch ? "ON" : "OFF")
                            settingRow("エージェントモード", persona.settings.agentMode ? "ON" : "OFF")
                            settingRow("Super Mode", persona.settings.superMode ? "ON" : "OFF")
                            settingRow("待ち時間", "\(String(format: "%.1f", persona.settings.silenceWait))秒")
                            if !persona.settings.customPrompt.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("カスタムプロンプト").font(.system(size: 10, weight: .medium))
                                    Text(persona.settings.customPrompt)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("適用される設定", systemImage: "gearshape.2")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Lux.gold)
                    }

                    // Tips
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(persona.settings.tips, id: \.self) { tip in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("·")
                                        .foregroundColor(Lux.gold)
                                        .font(.system(size: 14, weight: .light))
                                    Text(tip)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("使いこなしヒント", systemImage: "lightbulb")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Lux.gold)
                    }
                }
                .padding(20)
            }

            Divider()

            // Actions
            HStack {
                Button("閉じる") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if applied {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("適用しました")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                }
                Button("この設定を適用") {
                    applyPersona(persona)
                    applied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applied)
            }
            .padding(16)
        }
        .frame(width: 420, height: 520)
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func applyPersona(_ p: Persona) {
        let s = p.settings
        settings.language = s.language
        settings.llmEnabled = s.llmEnabled
        settings.agentModeEnabled = s.agentMode
        settings.streamingPreviewEnabled = s.streamingPreview
        settings.silenceAutoStopSeconds = s.silenceWait
        settings.whisperBeamSearch = s.beamSearch
        settings.superModeEnabled = s.superMode
        if !s.customPrompt.isEmpty {
            settings.llmCustomPrompt = s.customPrompt
        }
        klog("Persona applied: \(p.name)")
    }
}

// MARK: - Agent Tab

struct AgentTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("エージェントモードを有効にする", isOn: $settings.agentModeEnabled)
                Text("音声コマンドでアプリを開いたり検索したりできます。通常のテキスト入力と併用でき、コマンドとして認識されない発話はそのまま入力されます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: { Text("エージェントモード β") }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    agentCommandRow(command: "アプリを開く", examples: "「Safariを開いて」「Slackを開く」")
                    Divider()
                    agentCommandRow(command: "検索", examples: "「天気を検索」「SwiftUIで検索して」")
                    Divider()
                    agentCommandRow(command: "スクリーンショット", examples: "「スクショ撮って」「スクリーンショット」")
                    Divider()
                    agentCommandRow(command: "タイマー", examples: "「5分タイマー」「タイマー10分」")
                    Divider()
                    agentCommandRow(command: "ターミナル", examples: "「ターミナルでls」「コマンドでpwd」")
                    Divider()
                    agentCommandRow(command: "ショートカット", examples: "「ショートカット集中モードを実行」")
                }
            } header: { Text("対応コマンド一覧") }
        }
        .formStyle(.grouped)
    }

    private func agentCommandRow(command: String, examples: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command).font(.system(.body, design: .default).bold())
            Text(examples).font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - General Tab (基本: ショートカット、言語、動作)

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isRecordingKey = false
    @State private var keyMonitor: Any?

    let presets: [(String, Int, UInt)] = [
        ("⌥Space", 49, NSEvent.ModifierFlags.option.rawValue),
        ("⌘⌥V",  9,  NSEvent.ModifierFlags([.command, .option]).rawValue),
        ("F5",   96, 0),
        ("F6",   97, 0),
        ("⌃Space", 49, NSEvent.ModifierFlags.control.rawValue),
    ]

    var body: some View {
        Form {
            Section {
                // Language — most frequently changed
                Picker("言語", selection: $settings.language) {
                    ForEach(AppSettings.quickLanguages, id: \.code) { lang in
                        Text("\(lang.flag) \(lang.name)").tag(lang.code)
                    }
                }

                // Shortcut
                HStack {
                    Text("ショートカット")
                    Spacer()
                    Text(settings.shortcutDisplayString)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(5)
                        .font(.system(.body, design: .monospaced))
                }
                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { name, code, mods in
                        Button(name) {
                            settings.shortcutKeyCode  = code
                            settings.shortcutModifiers = mods
                            AppDelegate.shared?.reregisterHotkey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if isRecordingKey {
                        Text("キーを押して…").foregroundColor(.secondary).font(.caption)
                        Button("×") { stopRecording() }.controlSize(.small)
                    } else {
                        Button("カスタム") { startRecording() }.controlSize(.small)
                    }
                }

                Picker("録音モード", selection: $settings.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.recordingMode) { _ in AppDelegate.shared?.reregisterHotkey() }
            } header: {
                Label("基本", systemImage: "keyboard")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("ログイン時に自動起動", isOn: $settings.launchAtLogin)
                Toggle("クリップボードにコピー", isOn: $settings.autoCopyToClipboard)
                Toggle("完了時に通知", isOn: $settings.notifyOnComplete)
                Toggle("フローティングボタン", isOn: $settings.floatingButtonEnabled)

                HStack {
                    Text("入力モード")
                    Spacer()
                    Picker("", selection: $settings.streamingPreviewEnabled) {
                        Text("声入力").tag(true)
                        Text("直接入力").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Toggle("左⌘→英語 / 右⌘→日本語", isOn: $settings.cmdIMESwitchEnabled)
                Toggle("環境ノイズレベル表示", isOn: $settings.showNoiseLevel)
            } header: {
                Label("動作", systemImage: "slider.horizontal.3")
                    .foregroundColor(Lux.gold)
            }

            Section {
                DisclosureGroup("メニューバーの言語") {
                    Text("チェックした言語がメニューバーに表示されます").font(.system(size: 10)).foregroundColor(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 2) {
                        ForEach(AppSettings.quickLanguages, id: \.code) { lang in
                            Toggle("\(lang.flag) \(lang.name)", isOn: Binding(
                                get: { settings.menuBarLanguageCodes.contains(lang.code) },
                                set: { on in
                                    if on {
                                        if !settings.menuBarLanguageCodes.contains(lang.code) {
                                            settings.menuBarLanguageCodes.append(lang.code)
                                        }
                                    } else {
                                        settings.menuBarLanguageCodes.removeAll { $0 == lang.code }
                                    }
                                }
                            )).font(.system(size: 11))
                        }
                    }
                }

                DisclosureGroup("権限") {
                    HStack {
                        Image(systemName: "mic").font(.caption)
                        Text("マイク").font(.caption)
                        Spacer()
                        Button("開く") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }.buttonStyle(.link).font(.caption)
                    }
                    HStack {
                        Image(systemName: "hand.raised").font(.caption)
                        Text("アクセシビリティ").font(.caption)
                        Spacer()
                        Text(AXIsProcessTrusted() ? "OK" : "未許可").foregroundColor(AXIsProcessTrusted() ? Lux.gold : .orange)
                            .font(.caption)
                        Button("開く") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }.buttonStyle(.link).font(.caption)
                    }
                }

                // Version
                HStack {
                    Text("バージョン").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Label("その他", systemImage: "ellipsis.circle")
                    .foregroundColor(Lux.gold)
            }
        }
        .formStyle(.grouped)
    }

    private func startRecording() {
        isRecordingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.isEmpty || event.keyCode >= 96 {
                self.settings.shortcutKeyCode  = Int(event.keyCode)
                self.settings.shortcutModifiers = flags.rawValue
                AppDelegate.shared?.reregisterHotkey()
                self.stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecordingKey = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Voice Tab (音声: エンジン、モデル、認識パラメータ)

struct VoiceTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("認識エンジン", selection: $settings.recognitionEngine) {
                    ForEach(RecognitionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: settings.recognitionEngine) { _ in
                    AppDelegate.shared?.reloadSpeechEngine()
                }

                if settings.recognitionEngine == .whisperCpp {
                    WhisperCppSettingsView()
                }
                if settings.recognitionEngine == .whisper {
                    HStack {
                        Text("OpenAI APIキー")
                        SecureFieldWithReveal(text: $settings.whisperAPIKey, placeholder: "sk-...")
                    }
                }
            } header: {
                Label("エンジン", systemImage: "waveform")
                    .foregroundColor(Lux.gold)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("高精度モード (Beam Search)", isOn: $settings.whisperBeamSearch)
                    Text("精度が上がりますが少し遅くなります")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("文脈を引き継ぐ", isOn: $settings.whisperUseContext)
                    Text("長い文章で固有名詞や文体が安定します")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                HStack {
                    Text("話し終わりの待ち時間")
                    Spacer()
                    Picker("", selection: $settings.silenceAutoStopSeconds) {
                        Text("速い (1.0s)").tag(1.0); Text("普通 (1.5s)").tag(1.5); Text("ゆっくり (2.0s)").tag(2.0)
                        Text("長め (3.0s)").tag(3.0); Text("最長 (5.0s)").tag(5.0)
                    }.frame(width: 160)
                }
                HStack {
                    Text("認識のゆらぎ")
                        .help("0で最も確実な結果、高いと多様な候補から選びます")
                    Spacer()
                    Picker("", selection: $settings.whisperTemperature) {
                        Text("確実 (0)").tag(0.0); Text("少し柔軟 (0.2)").tag(0.2); Text("柔軟 (0.4)").tag(0.4)
                    }.frame(width: 160)
                }
                HStack {
                    Text("あいまい判定")
                        .help("低いと不確かな認識結果を棄却します")
                    Spacer()
                    Picker("", selection: $settings.whisperEntropyThreshold) {
                        Text("厳しい (2.0)").tag(2.0); Text("普通 (2.4)").tag(2.4); Text("緩い (3.0)").tag(3.0)
                    }.frame(width: 160)
                }
            } header: {
                Label("認識チューニング", systemImage: "tuningfork")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("フィラー自動除去", isOn: $settings.fillerRemovalEnabled)
                Text("「えー」「あの」「えっと」等の言い淀みを自動的に除去します")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                Picker("句読点スタイル", selection: $settings.punctuationStyle) {
                    ForEach(VoiceCommands.PunctuationStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }

                Toggle("Command Mode", isOn: $settings.commandModeEnabled)
                Text("「丁寧にして」「箇条書きにして」等で選択テキストをAIで書き換え")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } header: {
                Label("テキスト処理", systemImage: "text.badge.checkmark")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("コンテキスト認識", isOn: $settings.contextAwareEnabled)
                if settings.contextAwareEnabled {
                    Toggle("アプリ別ヒント", isOn: $settings.contextUseAppHint)
                    Toggle("クリップボード活用", isOn: $settings.contextUseClipboard)
                }
                TextField("カスタムプロンプト", text: $settings.contextCustomPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            } header: {
                Label("コンテキスト", systemImage: "text.viewfinder")
                    .foregroundColor(Lux.gold)
            }

            Section {
                LearningDictionaryView()
            } header: {
                Label("学習辞書", systemImage: "book.closed")
                    .foregroundColor(Lux.gold)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Learning Dictionary View (自動学習辞書)

struct LearningDictionaryView: View {
    @State private var entries: [CorrectionEntry] = []
    @State private var keywords: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: entries.isEmpty ? "brain" : "brain.head.profile")
                    .foregroundColor(entries.isEmpty ? .secondary : Lux.gold)
                Text("\(entries.count) 件の修正から学習中")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !keywords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("学習済みキーワード:")
                        .font(.system(size: 10, weight: .medium))
                    FlowLayout(spacing: 4) {
                        ForEach(keywords, id: \.self) { word in
                            Text(word)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Lux.gold.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            } else {
                Text("音声入力を使うと、修正パターンを自動的に学習して精度が向上します")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            if !entries.isEmpty {
                DisclosureGroup("最近の修正 (\(min(entries.count, 5))件)") {
                    ForEach(entries.prefix(5), id: \.date) { entry in
                        HStack(alignment: .top, spacing: 4) {
                            Text(entry.original)
                                .font(.system(size: 10))
                                .foregroundColor(.red.opacity(0.7))
                                .lineLimit(1)
                                .strikethrough()
                            Text("→")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(entry.corrected)
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                                .lineLimit(1)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .onAppear {
            entries = CorrectionStore.shared.loadAll().suffix(20).reversed()
            let hint = CorrectionStore.shared.learningHint(limit: 30)
            keywords = hint.isEmpty ? [] : hint.components(separatedBy: "、")
        }
    }
}

/// 簡易FlowLayout（キーワードタグ表示用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (idx, pos) in result.positions.enumerated() where idx < subviews.count {
            subviews[idx].place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxW = proposal.width ?? 400
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowH = max(rowH, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxW, height: y + rowH), positions)
    }
}

// MARK: - App Profiles Tab

struct AppProfilesTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showAdd   = false
    @State private var editTarget: AppProfile?

    var body: some View {
        VStack(spacing: 0) {
            if settings.appProfiles.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("アプリ別プロファイルなし")
                        .foregroundColor(.secondary)
                    Text("アプリごとにプロンプトや言語を切り替えられます")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List {
                    ForEach(settings.appProfiles) { profile in
                        ProfileRow(profile: profile)
                            .contentShape(Rectangle())
                            .onTapGesture { editTarget = profile }
                    }
                    .onDelete { idx in settings.appProfiles.remove(atOffsets: idx) }
                }
            }
            Divider()
            HStack {
                Text("\(settings.appProfiles.count) 件")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("+ 追加") { showAdd = true }
                    .buttonStyle(.bordered)
            }
            .padding(8)
        }
        .sheet(isPresented: $showAdd) {
            ProfileEditSheet(profile: nil) { p in settings.appProfiles.append(p) }
        }
        .sheet(item: $editTarget) { p in
            ProfileEditSheet(profile: p) { updated in
                if let i = settings.appProfiles.firstIndex(where: { $0.id == updated.id }) {
                    settings.appProfiles[i] = updated
                }
            }
        }
    }
}

struct ProfileRow: View {
    let profile: AppProfile
    var body: some View {
        HStack(spacing: 10) {
            appIcon(for: profile.bundleID)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.appName).font(.system(size: 13, weight: .medium))
                Text(profile.prompt.isEmpty ? "プロンプトなし" : profile.prompt)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if !profile.language.isEmpty {
                Text(profile.language)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 3)
    }

    private func appIcon(for bundleID: String) -> some View {
        Group {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let icon = app.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                      let bundle = Bundle(url: url),
                      let iconFile = bundle.infoDictionary?["CFBundleIconFile"] as? String,
                      let icon = NSImage(contentsOfFile: bundle.path(forResource: iconFile, ofType: nil) ?? "") {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.fill").foregroundColor(.secondary)
            }
        }
    }
}

struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: AppProfile?
    let onSave: (AppProfile) -> Void

    @State private var selectedApp: RunningAppInfo?
    @State private var prompt    = ""
    @State private var language  = ""
    @State private var manualBundle = ""
    @State private var llmInstruction = ""

    // Running apps for picker
    private var runningApps: [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { RunningAppInfo(app: $0) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile == nil ? "プロファイルを追加" : "プロファイルを編集")
                .font(.headline)

            // App picker
            GroupBox("対象アプリ") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("実行中のアプリ", selection: $selectedApp) {
                        Text("選択してください").tag(Optional<RunningAppInfo>.none)
                        ForEach(runningApps) { app in
                            Text(app.name).tag(Optional(app))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedApp) { app in
                        if let app { manualBundle = app.bundleID }
                    }
                    TextField("Bundle ID を直接入力", text: $manualBundle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(4)
            }

            // Language override
            GroupBox("言語（空欄 = グローバル設定を使用）") {
                Picker("", selection: $language) {
                    Text("グローバル設定").tag("")
                    Text("日本語").tag("ja-JP")
                    Text("English").tag("en-US")
                    Text("中文").tag("zh-CN")
                    Text("한국어").tag("ko-KR")
                    Text("Français").tag("fr-FR")
                    Text("Deutsch").tag("de-DE")
                    Text("Español").tag("es-ES")
                    Text("Português").tag("pt-BR")
                    Text("Italiano").tag("it-IT")
                    Text("Русский").tag("ru-RU")
                }
                .labelsHidden()
                .padding(4)
            }

            // Prompt
            GroupBox("プロンプト（Whisper / コンテキストヒント）") {
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            }

            // LLM instruction
            GroupBox("LLM後処理指示（空欄 = デフォルトの後処理を使用）") {
                TextEditor(text: $llmInstruction)
                    .font(.system(size: 12))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                if llmInstruction.isEmpty {
                    Text("空欄の場合: AI設定タブのデフォルトプロンプト（誤字修正・句読点追加）が適用されます")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") {
                    let appName: String
                    if let sel = selectedApp {
                        appName = sel.name
                    } else if !manualBundle.isEmpty {
                        appName = manualBundle.components(separatedBy: ".").last ?? manualBundle
                    } else { return }

                    let p = AppProfile(
                        id: profile?.id ?? UUID(),
                        bundleID: manualBundle,
                        appName: appName,
                        prompt: prompt,
                        language: language,
                        llmInstruction: llmInstruction
                    )
                    onSave(p)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualBundle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 480)
        .onAppear {
            if let p = profile {
                prompt = p.prompt
                language = p.language
                manualBundle = p.bundleID
                llmInstruction = p.llmInstruction
            }
        }
    }
}

struct RunningAppInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    init(app: NSRunningApplication) {
        self.bundleID = app.bundleIdentifier ?? ""
        self.id = bundleID
        self.name = app.localizedName ?? bundleID
    }
}

// MARK: - AI Tab

struct AITab: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section {
                Toggle("LLM後処理を有効にする", isOn: $s.llmEnabled)
                if s.llmEnabled {
                    Text("音声認識後にLLMで誤字修正・句読点追加を行います")
                        .font(.caption).foregroundColor(.secondary)

                    Picker("処理モード", selection: $s.llmMode) {
                        ForEach(LLMMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Picker("処理エンジン", selection: $s.llmUseLocal) {
                        Text("ローカル (llama.cpp + Metal GPU)").tag(true)
                        Text("クラウド (API)").tag(false)
                    }

                    if s.llmUseLocal {
                        LocalLLMSettingsView()
                    } else {
                        Picker("プロバイダ", selection: $s.llmProvider) {
                            ForEach(LLMProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }

                        if s.llmProvider.requiresAPIKey {
                            HStack {
                                Text("APIキー")
                                SecureFieldWithReveal(
                                    text: $s.llmAPIKey,
                                    placeholder: s.llmProvider == .anthropic ? "sk-ant-..." : "sk-..."
                                )
                            }
                        }

                        HStack {
                            Text("モデル")
                            TextField(s.llmProvider.defaultModel, text: $s.llmModel)
                                .textFieldStyle(.roundedBorder)
                        }

                        if s.llmProvider == .custom {
                            HStack {
                                Text("ベースURL")
                                TextField("https://api.example.com", text: $s.llmBaseURL)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Group {
                            switch s.llmProvider {
                            case .chatweb:
                                Text("chatweb.ai: APIキー不要・無料で利用可能")
                            case .openai:
                                Text("OpenAI: GPT-4o-mini等。APIキーはplatform.openai.comで取得")
                            case .anthropic:
                                Text("Anthropic: Claude Haiku等。APIキーはconsole.anthropic.comで取得")
                            case .groq:
                                Text("Groq: 超高速推論。APIキーはconsole.groq.comで取得")
                            case .custom:
                                Text("OpenAI互換APIのベースURLを指定してください")
                            }
                        }
                        .font(.caption2).foregroundColor(.secondary)
                    }

                    if s.llmMode == .custom {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("カスタムプロンプト")
                                .font(.caption).foregroundColor(.secondary)
                            TextEditor(text: $s.llmCustomPrompt)
                                .font(.system(size: 11))
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                            if s.llmCustomPrompt.isEmpty {
                                Text("空欄の場合はデフォルト（誤字修正・句読点追加）が使用されます")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Button("クリア") { s.llmCustomPrompt = "" }
                                .buttonStyle(.link).font(.caption2)
                                .disabled(s.llmCustomPrompt.isEmpty)
                        }
                    }
                }
            } header: {
                Label("LLM後処理", systemImage: "brain.head.profile")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("Super Mode（画面コンテキスト認識）", isOn: $s.superModeEnabled)
                if s.superModeEnabled {
                    Text("アクティブなアプリ名や選択中のテキストをLLMに渡し、文脈に合った出力を生成します。")
                        .font(.caption).foregroundColor(.secondary)
                    if !AXIsProcessTrusted() {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("アクセシビリティ権限が未許可です")
                                .font(.caption).foregroundColor(.orange)
                            Button("設定を開く") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }.buttonStyle(.link).font(.caption)
                        }
                    }
                } else {
                    Text("使用中のアプリや選択テキストに応じてLLMが最適なフォーマットで出力します")
                        .font(.caption2).foregroundColor(.secondary)
                }
            } header: {
                Label("Super Mode", systemImage: "sparkles")
                    .foregroundColor(Lux.gold)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Automation Tab (自動化: ウェイクワード、エージェント、プロファイル、テキスト展開)

struct AutomationTab: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        Form {
            Section {
                Toggle("ウェイクワードで録音開始", isOn: $s.wakeWordEnabled)
                if s.wakeWordEnabled {
                    WakeWordTemplateView()
                }
            } header: {
                Label("ウェイクワード", systemImage: "ear")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("エージェントモード", isOn: $s.agentModeEnabled)
                Text("「Safariを開いて」「5分タイマー」などの音声コマンドを実行")
                    .font(.caption).foregroundColor(.secondary)
                if s.agentModeEnabled {
                    DisclosureGroup("対応コマンド") {
                        VStack(alignment: .leading, spacing: 6) {
                            agentRow("アプリを開く", "Safariを開いて")
                            agentRow("検索", "天気を検索")
                            agentRow("スクリーンショット", "スクショ撮って")
                            agentRow("タイマー", "5分タイマー")
                            agentRow("ターミナル", "ターミナルでls")
                            agentRow("ショートカット", "集中モードを実行")
                        }
                    }
                }
            } header: {
                Label("エージェント", systemImage: "bolt.fill")
                    .foregroundColor(Lux.gold)
            }

            Section {
                DisclosureGroup("アプリ別プロファイル (\(s.appProfiles.count)件)") {
                    AppProfilesInlineView()
                }
            } header: {
                Label("アプリ連携", systemImage: "app.badge")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("LLM処理を適用", isOn: $s.iphoneBridgeLLM)
                    .font(.system(size: 12))
                if s.iphoneBridgeLLM {
                    HStack {
                        Text("モード").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $s.llmMode) {
                            ForEach(LLMMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
                Toggle("入力後に自動Enter", isOn: $s.iphoneBridgeAutoEnter)
                    .font(.system(size: 12))
            } header: {
                Label("iPhone連携", systemImage: "iphone.and.arrow.forward")
                    .foregroundColor(Lux.gold)
            }

            Section {
                DisclosureGroup("テキスト展開 (\(s.textExpansions.count)件)") {
                    TextExpansionsInlineView()
                }
            } header: {
                Label("テキスト展開", systemImage: "text.word.spacing")
                    .foregroundColor(Lux.gold)
            }
        }
        .formStyle(.grouped)
    }

    private func agentRow(_ cmd: String, _ example: String) -> some View {
        HStack {
            Text(cmd).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(example).font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - App Profiles (inline for AI tab)
struct AppProfilesInlineView: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        ForEach(s.appProfiles.indices, id: \.self) { i in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(s.appProfiles[i].appName).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(s.appProfiles[i].bundleID).font(.system(size: 10)).foregroundColor(.secondary)
                }
                if !s.appProfiles[i].llmInstruction.isEmpty {
                    Text(s.appProfiles[i].llmInstruction)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
        Button("アプリプロファイルを編集…") {
            // Open full profiles editor (could be a sheet)
        }
        .font(.caption)
        .disabled(true)
    }
}

// MARK: - Text Expansions (inline for AI tab)
struct TextExpansionsInlineView: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        if s.textExpansions.isEmpty {
            Text("テキスト展開ルールはまだありません")
                .font(.caption).foregroundColor(.secondary)
        } else {
            ForEach(Array(s.textExpansions.enumerated()), id: \.offset) { _, exp in
                HStack {
                    Text(exp.trigger).font(.system(size: 12, design: .monospaced))
                    Text("→").foregroundColor(.secondary)
                    Text(exp.expansion).font(.system(size: 12)).lineLimit(1)
                }
            }
        }
    }
}

struct WakeWordTemplateView: View {
    @State private var templateCount = WakeWordEngine.shared.templates.count
    @State private var countdown: Int? = nil
    @State private var recording = false
    @State private var lastResult: Bool? = nil
    @State private var lastError = ""
    @State private var threshold: Float = WakeWordEngine.shared.distThreshold > 0 ? WakeWordEngine.shared.distThreshold : 2.0
    @State private var currentRound = 0  // 連続録音の何回目か

    private let minRequired = WakeWordEngine.minTemplates  // 最低3回

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status
            HStack {
                if templateCount >= minRequired {
                    Image(systemName: "waveform.badge.checkmark").foregroundColor(.green)
                    Text("\(templateCount) テンプレート録音済み — 使用可能")
                        .font(.caption).foregroundColor(.secondary)
                } else if templateCount > 0 {
                    Image(systemName: "waveform").foregroundColor(.orange)
                    Text("\(templateCount) / \(minRequired) 録音済み — あと\(minRequired - templateCount)回必要")
                        .font(.caption).foregroundColor(.orange)
                } else {
                    Image(systemName: "waveform.slash").foregroundColor(.orange)
                    Text("テンプレート未登録 — 最低\(minRequired)回録音が必要です")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Recording button
            HStack(spacing: 12) {
                if recording {
                    HStack {
                        Image(systemName: "stop.circle.fill").foregroundColor(.red)
                        if let c = countdown, c > 0 {
                            Text("\(currentRound)/\(minRequired) 回目: \(c)秒後に録音開始...")
                        } else {
                            Text("\(currentRound)/\(max(minRequired, currentRound)) 回目: 録音中...")
                        }
                    }
                } else if templateCount < minRequired {
                    Button(action: { startMultiRecording() }) {
                        HStack {
                            Image(systemName: "mic.circle.fill").foregroundColor(.accentColor)
                            Text("ウェイクワードを\(minRequired)回録音する")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: { startSingleRecording() }) {
                        HStack {
                            Image(systemName: "mic.circle.fill").foregroundColor(.accentColor)
                            Text("追加で録音する")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if templateCount > 0 && !recording {
                    Button("すべてクリア") {
                        WakeWordEngine.shared.clearTemplates()
                        templateCount = 0
                        lastResult = nil
                        lastError = ""
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.link)
                }
            }

            if let ok = lastResult {
                Text(ok ? "✓ 録音完了！ (\(templateCount)個)" : "")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if !lastError.isEmpty {
                Text(lastError)
                    .font(.caption).foregroundColor(.red)
            }

            // Progress dots for multi-recording
            if recording || (templateCount > 0 && templateCount < minRequired) {
                HStack(spacing: 6) {
                    ForEach(0..<max(minRequired, templateCount), id: \.self) { i in
                        Circle()
                            .fill(i < templateCount ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
            }

            // Threshold slider
            if templateCount >= minRequired {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("感度").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("現在: \(String(format: "%.1f", threshold))").font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("厳しい").font(.caption2).foregroundColor(.secondary)
                        Slider(value: $threshold, in: 1.0...5.0, step: 0.1)
                            .onChange(of: threshold) { v in WakeWordEngine.shared.distThreshold = v }
                        Text("緩い").font(.caption2).foregroundColor(.secondary)
                    }
                    Text("ウェイクワード以外で誤検出する場合は左に。反応しない場合は右に").font(.caption2).foregroundColor(.secondary)
                }
            }

            Text("同じウェイクワード（例:「ヘイこえ」）を繰り返し録音します。声のトーンを少し変えると精度が上がります。")
                .font(.caption2).foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.vertical, 4)
    }

    /// 最低回数の連続録音を開始
    private func startMultiRecording() {
        // まず既存をクリア
        WakeWordEngine.shared.clearTemplates()
        templateCount = 0
        lastResult = nil
        lastError = ""
        currentRound = 1
        recordOneRound(remaining: minRequired)
    }

    /// 追加1回録音
    private func startSingleRecording() {
        lastResult = nil
        lastError = ""
        currentRound = templateCount + 1
        recordOneRound(remaining: 1)
    }

    private func recordOneRound(remaining: Int) {
        guard remaining > 0 else {
            recording = false
            lastResult = true
            return
        }

        recording = true
        countdown = 2

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if let c = countdown, c > 0 {
                countdown = c - 1
            } else {
                timer.invalidate()
                countdown = nil
                WakeWordEngine.shared.recordTemplate(duration: 1.5) { ok in
                    templateCount = WakeWordEngine.shared.templates.count
                    if ok {
                        currentRound += 1
                        if remaining - 1 > 0 {
                            // 次のラウンドへ（少し間をあける）
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                recordOneRound(remaining: remaining - 1)
                            }
                        } else {
                            recording = false
                            lastResult = true
                        }
                    } else {
                        // 無音だった場合はリトライ
                        lastError = "✗ 音声が検出されませんでした。もう少し大きな声で話してください。"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            lastError = ""
                            recordOneRound(remaining: remaining)  // 同じラウンドをリトライ
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Text Expansions Tab

struct TextExpansionsTab: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        VStack(spacing: 0) {
            if s.textExpansions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.word.spacing").font(.system(size: 32)).foregroundColor(.secondary)
                    Text("音声ショートカットなし").foregroundColor(.secondary)
                    Text("「メアド」と言うと展開されるような辞書を作れます").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach($s.textExpansions) { $exp in
                        HStack(spacing: 8) {
                            TextField("トリガー", text: $exp.trigger).textFieldStyle(.roundedBorder).frame(width: 120)
                            Text("→")
                            TextField("展開後テキスト", text: $exp.expansion).textFieldStyle(.roundedBorder)
                        }
                    }
                    .onDelete { s.textExpansions.remove(atOffsets: $0) }
                }
            }
            Divider()
            HStack {
                Text("\(s.textExpansions.count) 件").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("+ 追加") { s.textExpansions.append(TextExpansion(trigger: "", expansion: "")) }
                    .buttonStyle(.bordered)
            }
            .padding(8)
        }
    }
}

// MARK: - WhisperCppSettingsView

struct WhisperCppSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadDetail = ""

    private let dl = ModelDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Memory status
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .foregroundColor(.secondary)
                Text(MemoryMonitor.statusText)
                    .font(.caption2).foregroundColor(.secondary)
            }

            // Current model
            HStack(spacing: 6) {
                Image(systemName: dl.isModelAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(dl.isModelAvailable ? .green : .red)
                Text(dl.isModelAvailable ? "モデル: \(dl.currentModel.name)" : "モデル未ダウンロード")
                    .font(.caption)
            }

            // Model list
            ForEach(ModelDownloader.availableModels, id: \.id) { model in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(model.name).font(.system(size: 12, weight: .medium))
                            if model.id == dl.currentModel.id {
                                Text("使用中")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.2))
                                    .cornerRadius(3)
                            }
                        }
                        Text("\(model.description) — \(model.sizeMB)MB")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if dl.isDownloaded(model) {
                        if model.id != dl.currentModel.id {
                            Button("選択") {
                                dl.selectModel(model)
                                settings.objectWillChange.send()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        Button("削除") {
                            let path = dl.modelDir.appendingPathComponent(model.fileName)
                            try? FileManager.default.removeItem(at: path)
                            settings.objectWillChange.send()
                        }
                        .controlSize(.small)
                        .foregroundColor(.red)
                    } else {
                        Button("DL") {
                            startDownload(model)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(downloading)
                    }
                }
                .padding(.vertical, 2)
            }

            if downloading {
                ProgressView(value: downloadProgress, total: 100)
                Text(downloadDetail).font(.caption2).foregroundColor(.secondary)
            }

            // モデル保存フォルダ
            HStack(spacing: 4) {
                Text("保存先:").font(.caption2).foregroundColor(.secondary)
                Text(dl.modelDir.path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Finderで開く") {
                    NSWorkspace.shared.open(dl.modelDir)
                }
                .font(.caption2)
                .buttonStyle(.link)
            }
        }
    }

    private func startDownload(_ model: WhisperModel) {
        downloading = true
        downloadProgress = 0
        downloadDetail = "準備中..."

        try? FileManager.default.createDirectory(at: dl.modelDir, withIntermediateDirectories: true)
        let url = URL(string: model.url)!
        let session = URLSession(configuration: .default)

        let task = session.downloadTask(with: url) { tempURL, _, error in
            DispatchQueue.main.async {
                if let error {
                    downloadDetail = "失敗: \(error.localizedDescription)"
                    downloading = false
                    return
                }
                guard let tempURL else { downloading = false; return }
                let dest = dl.modelDir.appendingPathComponent(model.fileName)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    dl.selectModel(model)
                    settings.objectWillChange.send()
                } catch {
                    downloadDetail = "保存失敗: \(error.localizedDescription)"
                }
                downloading = false
            }
        }

        let observer = task.progress.observe(\.fractionCompleted, options: [.new]) { (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                downloadProgress = progress.fractionCompleted * 100
                let mb = Double(progress.completedUnitCount) / 1_000_000
                let total = Double(progress.totalUnitCount) / 1_000_000
                if total > 0 {
                    downloadDetail = String(format: "%.0f / %.0f MB", mb, total)
                } else {
                    downloadDetail = String(format: "%.0f MB", mb)
                }
            }
        }
        objc_setAssociatedObject(task, "obs", observer, .OBJC_ASSOCIATION_RETAIN)
        task.resume()
    }
}

// MARK: - LocalLLMSettingsView

struct LocalLLMSettingsView: View {
    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadDetail = ""
    @State private var loading = false
    @State private var loadError = ""

    private let llm = LlamaContext.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Memory status
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .foregroundColor(.secondary)
                Text(MemoryMonitor.statusText)
                    .font(.caption2).foregroundColor(.secondary)
            }

            // Status
            HStack(spacing: 6) {
                if llm.isLoaded {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("ロード中: \(llm.selectedModel?.name ?? "") — Metal GPU")
                        .font(.caption)
                } else if loading {
                    ProgressView().controlSize(.small)
                    Text("モデルをロード中...")
                        .font(.caption).foregroundColor(.orange)
                } else if let model = llm.selectedModel, llm.isDownloaded(model) {
                    Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 6))
                    Text("待機中: \(model.name)" + (AppSettings.shared.llmMemorySaveMode ? "（メモリ省略: 毎回ロード/解放）" : "（使用時に自動ロード・常駐）"))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text("モデル未ダウンロード")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            if !loadError.isEmpty {
                Text(loadError)
                    .font(.caption2).foregroundColor(.red)
            }

            // Recommended model
            if !llm.isLoaded, let recID = MemoryMonitor.recommendedLLMModel() {
                if let rec = LlamaContext.availableModels.first(where: { $0.id == recID }) {
                    Text("推奨: \(rec.name) (空きメモリから判定)")
                        .font(.caption2).foregroundColor(.blue)
                }
            } else if !llm.isLoaded && MemoryMonitor.recommendedLLMModel() == nil {
                Text("⚠ メモリ不足のためローカルLLMは使用できません。クラウドAPIをご利用ください。")
                    .font(.caption2).foregroundColor(.orange)
            }

            // Model list
            ForEach(LlamaContext.availableModels, id: \.id) { model in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(model.name).font(.system(size: 12, weight: .medium))
                            if model.id == llm.selectedModelID && llm.isLoaded {
                                Text("使用中")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.green.opacity(0.2))
                                    .cornerRadius(3)
                            }
                            // Memory warning badge
                            if let warning = MemoryMonitor.warningText(modelSizeMB: model.sizeMB) {
                                let _ = warning  // suppress unused warning
                                Text("⚠")
                                    .font(.system(size: 9))
                                    .help("メモリ不足の可能性があります")
                            }
                        }
                        Text("\(model.description) — \(model.sizeMB)MB")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if llm.isDownloaded(model) {
                        if model.id == llm.selectedModelID && llm.isLoaded {
                            // Already active
                        } else {
                            Button("選択・ロード") {
                                loadModel(model)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(loading)
                        }
                        Button("削除") {
                            deleteModel(model)
                        }
                        .controlSize(.small)
                        .foregroundColor(.red)
                    } else {
                        Button("DL") {
                            startDownload(model)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(downloading)
                    }
                }
                .padding(.vertical, 2)
            }

            if downloading {
                ProgressView(value: downloadProgress, total: 100)
                Text(downloadDetail).font(.caption2).foregroundColor(.secondary)
            }

            if llm.isLoaded {
                Button("アンロード（メモリ解放）") {
                    llm.unload()
                    loadError = ""
                }
                .foregroundColor(.red)
                .buttonStyle(.link)
                .font(.caption)
            }

            Divider()

            // メモリ省略モード
            Toggle("メモリ省略モード（LLMを毎回ロード/解放。遅くなるがメモリ節約）", isOn: Binding(
                get: { AppSettings.shared.llmMemorySaveMode },
                set: { AppSettings.shared.llmMemorySaveMode = $0 }
            ))
            .font(.caption)

            // モデル保存フォルダ
            HStack(spacing: 4) {
                Text("保存先:").font(.caption2).foregroundColor(.secondary)
                Text(llm.modelDir.path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Finderで開く") {
                    NSWorkspace.shared.open(llm.modelDir)
                }
                .font(.caption2)
                .buttonStyle(.link)
            }
        }
    }

    private func loadModel(_ model: LlamaContext.LLMModel) {
        loadError = ""

        // メモリ事前チェック
        if let warning = MemoryMonitor.warningText(modelSizeMB: model.sizeMB) {
            loadError = warning
        }

        if !MemoryMonitor.canLoad(modelSizeMB: model.sizeMB) {
            loadError = "メモリ不足 (空き\(MemoryMonitor.availableMemoryMB)MB)。他のアプリを閉じるか小さいモデルを選んでください。"
            return
        }

        loading = true
        llm.selectedModelID = model.id
        llm.unload()
        llm.loadModel { ok in
            loading = false
            if !ok {
                loadError = "ロード失敗。メモリ不足の可能性があります (空き\(MemoryMonitor.availableMemoryMB)MB)"
            }
        }
    }

    private func deleteModel(_ model: LlamaContext.LLMModel) {
        let path = llm.modelPath(for: model)
        if model.id == llm.selectedModelID && llm.isLoaded {
            llm.unload()
        }
        try? FileManager.default.removeItem(at: path)
        klog("LLM: deleted \(model.name) at \(path.path)")
    }

    private func startDownload(_ model: LlamaContext.LLMModel) {
        downloading = true
        downloadProgress = 0
        downloadDetail = "準備中..."

        llm.downloadModel(model, progress: { pct, detail in
            downloadProgress = pct
            downloadDetail = detail
        }) { ok in
            downloading = false
            if ok {
                loadModel(model)
            }
        }
    }
}

// MARK: - SecureFieldWithReveal

struct SecureFieldWithReveal: View {
    @Binding var text: String
    let placeholder: String
    @State private var revealed = false

    var body: some View {
        HStack {
            if revealed {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Stats Tab (統計ダッシュボード)

struct StatsTab: View {
    @ObservedObject private var stats = VoiceStats.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Today's summary
                HStack(spacing: 12) {
                    StatCard(
                        icon: "character.cursor.ibeam",
                        value: "\(stats.todayCharCount)",
                        label: "今日の文字数",
                        color: Lux.gold
                    )
                    StatCard(
                        icon: "clock",
                        value: stats.savedTimeDisplay,
                        label: "節約時間",
                        color: .green
                    )
                    StatCard(
                        icon: "mic.fill",
                        value: "\(stats.todaySessionCount)",
                        label: "セッション",
                        color: .blue
                    )
                    StatCard(
                        icon: "flame.fill",
                        value: "\(stats.streak)日",
                        label: "連続使用",
                        color: .orange
                    )
                }

                // Weekly chart
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("週間推移")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Lux.gold)

                        WeeklyChart(data: stats.weeklyChars, labels: stats.weeklyLabels)
                            .frame(height: 100)
                    }
                    .padding(4)
                }

                // Totals
                GroupBox {
                    VStack(spacing: 8) {
                        HStack {
                            Text("累計文字数")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(stats.totalCharCount) 文字")
                                .font(.system(size: 11, weight: .medium))
                        }
                        HStack {
                            Text("累計セッション")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(stats.totalSessionCount) 回")
                                .font(.system(size: 11, weight: .medium))
                        }
                        HStack {
                            Text("累計節約時間")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text(stats.totalSavedTimeDisplay)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                        HStack {
                            Text("学習済み修正")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(CorrectionStore.shared.entryCount) 件")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(4)
                } label: {
                    Label("累計", systemImage: "sum")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Lux.gold)
                }

                // Typing speed comparison
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("タイピング比較")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Lux.gold)

                        HStack(spacing: 0) {
                            // 音声入力
                            VStack(spacing: 2) {
                                Text("音声")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text("~150")
                                    .font(.system(size: 16, weight: .light, design: .rounded))
                                Text("文字/分")
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)

                            Text("vs")
                                .font(.system(size: 10)).foregroundColor(.secondary)

                            // タイピング
                            VStack(spacing: 2) {
                                Text("タイピング")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text("~80")
                                    .font(.system(size: 16, weight: .light, design: .rounded))
                                    .foregroundColor(.secondary)
                                Text("文字/分")
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        Text("音声入力はタイピングの約1.9倍の速度")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(4)
                }
            }
            .padding(12)
        }
    }
}

struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 18, weight: .light, design: .rounded))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.2), lineWidth: 0.5)
        )
    }
}

struct WeeklyChart: View {
    let data: [Int]
    let labels: [String]

    private var maxVal: Int { max(data.max() ?? 1, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<data.count, id: \.self) { i in
                VStack(spacing: 2) {
                    if data[i] > 0 {
                        Text("\(data[i])")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Lux.gold.opacity(0.6), Lux.gold],
                                startPoint: .bottom, endPoint: .top
                            )
                        )
                        .frame(height: max(CGFloat(data[i]) / CGFloat(maxVal) * 70, data[i] > 0 ? 4 : 1))

                    Text(labels[i])
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - History Tab

struct HistoryTab: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var searchQuery = ""
    @State private var showFavoritesOnly = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private var filteredEntries: [HistoryEntry] {
        var results = history.search(searchQuery)
        if showFavoritesOnly {
            results = results.filter { $0.isFavorite }
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("検索", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 16)
                Button {
                    showFavoritesOnly.toggle()
                } label: {
                    Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                        .foregroundColor(showFavoritesOnly ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(showFavoritesOnly ? "すべて表示" : "お気に入りのみ")
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // List
            if filteredEntries.isEmpty {
                Spacer()
                Text(history.entries.isEmpty ? "履歴はありません" : "一致する項目がありません")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                history.toggleFavorite(id: entry.id)
                            } label: {
                                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                                    .foregroundColor(entry.isFavorite ? .yellow : .secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            Text(entry.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(dateFormatter.string(from: entry.date))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: {
                                Label("コピー", systemImage: "doc.on.doc")
                            }
                            Button {
                                history.toggleFavorite(id: entry.id)
                            } label: {
                                Label(entry.isFavorite ? "お気に入り解除" : "お気に入り",
                                      systemImage: entry.isFavorite ? "star.slash" : "star.fill")
                            }
                            Divider()
                            Button(role: .destructive) {
                                history.delete(id: entry.id)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Text("\(history.entries.count)件中 \(filteredEntries.count)件表示")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Menu("エクスポート") {
                    Button("テキスト (.txt)") { exportFile(type: .text) }
                    Button("CSV (.csv)") { exportFile(type: .csv) }
                    Button("JSON (.json)") { exportFile(type: .json) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(history.entries.isEmpty)
                Button("すべてクリア") { history.clear() }
                    .foregroundColor(.red)
                    .buttonStyle(.link)
                    .disabled(history.entries.isEmpty)
            }
            .padding(8)
        }
    }

    private enum ExportType { case text, csv, json }

    private func exportFile(type: ExportType) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch type {
        case .text:
            panel.nameFieldStringValue = "koe-history.txt"
            panel.allowedContentTypes = [.plainText]
        case .csv:
            panel.nameFieldStringValue = "koe-history.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        case .json:
            panel.nameFieldStringValue = "koe-history.json"
            panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content: String
        switch type {
        case .text: content = history.exportAsText()
        case .csv:  content = history.exportAsCSV()
        case .json: content = history.exportAsJSON()
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
