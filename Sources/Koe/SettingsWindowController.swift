import AppKit
import SwiftUI

class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Koe 設定"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        self.init(window: window)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("一般", systemImage: "gear") }
            AppProfilesTab()
                .tabItem { Label("アプリ", systemImage: "app.badge") }
            AITab()
                .tabItem { Label("AI", systemImage: "brain.head.profile") }
            TextExpansionsTab()
                .tabItem { Label("展開", systemImage: "text.word.spacing") }
            HistoryTab()
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
        }
        .padding(16)
        .frame(width: 540, height: 520)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isRecordingKey = false
    @State private var keyMonitor: Any?

    let presets: [(String, Int, UInt)] = [
        ("⌘⌥V",  9,  NSEvent.ModifierFlags([.command, .option]).rawValue),
        ("F5",   96, 0),
        ("F6",   97, 0),
        ("⌃Space", 49, NSEvent.ModifierFlags.control.rawValue),
    ]

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("ショートカット")
                    Spacer()
                    Text(settings.shortcutDisplayString)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .font(.system(.body, design: .monospaced))
                }
                HStack(spacing: 8) {
                    Text("プリセット")
                    Spacer()
                    ForEach(presets, id: \.0) { name, code, mods in
                        Button(name) {
                            settings.shortcutKeyCode  = code
                            settings.shortcutModifiers = mods
                            AppDelegate.shared?.reregisterHotkey()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                HStack {
                    Spacer()
                    if isRecordingKey {
                        Text("キーを押してください…")
                            .foregroundColor(.secondary)
                        Button("キャンセル") { stopRecording() }
                    } else {
                        Button("カスタムキーを設定") { startRecording() }
                    }
                }
                Picker("録音モード", selection: $settings.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.recordingMode) { _ in AppDelegate.shared?.reregisterHotkey() }
            } header: { Text("操作") }

            Section {
                Picker("エンジン", selection: $settings.recognitionEngine) {
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

                Picker("認識言語", selection: $settings.language) {
                    Text("自動検出").tag("auto")
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
                    Text("العربية").tag("ar-SA")
                    Text("हिन्दी").tag("hi-IN")
                    Text("ไทย").tag("th-TH")
                    Text("Tiếng Việt").tag("vi-VN")
                    Text("Bahasa Indonesia").tag("id-ID")
                }
                .onChange(of: settings.language) { _ in
                    AppDelegate.shared?.reloadSpeechEngine()
                }

                // Engine badge
                HStack(spacing: 6) {
                    Image(systemName: settings.recognitionEngine.isLocal ? "desktopcomputer" : "cloud")
                        .foregroundColor(settings.recognitionEngine.isLocal ? .green : .blue)
                    Text(settings.recognitionEngine.isLocal ? "ローカル処理 — データ送信なし" : "クラウド処理 — ネットワーク必要")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("音声認識") }

            Section {
                Toggle("ログイン時に自動起動", isOn: $settings.launchAtLogin)
                Toggle("フローティングマイクボタンを表示", isOn: $settings.floatingButtonEnabled)
                if settings.floatingButtonEnabled {
                    Text("画面上のボタンをクリックするだけで録音開始・停止できます。ドラッグで移動可能。")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("一般") }

            Section {
                Toggle("コンテキスト認識を有効にする", isOn: $settings.contextAwareEnabled)
                if settings.contextAwareEnabled {
                    Toggle("アプリ別ヒントワード", isOn: $settings.contextUseAppHint)
                    Text("使用中のアプリに応じた日本語キーワードをプロンプトに追加")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("クリップボードの日本語キーワード", isOn: $settings.contextUseClipboard)
                    Text("クリップ内容から日本語のみ抽出（英語やコードは除外）")
                        .font(.caption2).foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("カスタムプロンプト（常にwhisperに渡す）")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("例: 技術用語、専門用語、固有名詞など", text: $settings.contextCustomPrompt)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                Text("よく使う単語・専門用語を書くと認識精度が向上します。100文字以内推奨。")
                    .font(.caption2).foregroundColor(.secondary)
            } header: { Text("コンテキスト認識") }

            Section {
                Toggle("認識結果をクリップボードにコピー", isOn: $settings.autoCopyToClipboard)
                Toggle("認識完了時に通知を表示", isOn: $settings.notifyOnComplete)
            } header: { Text("出力") }

            Section {
                HStack {
                    Image(systemName: "mic")
                    Text("マイク")
                    Spacer()
                    Button("システム設定を開く") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }.buttonStyle(.link)
                }
                HStack {
                    Image(systemName: "hand.raised")
                    Text("アクセシビリティ")
                    Spacer()
                    Text(AXIsProcessTrusted() ? "✓ 許可済み" : "⚠ 未許可")
                        .foregroundColor(AXIsProcessTrusted() ? .green : .orange)
                    Button("設定を開く") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(.link)
                }
            } header: { Text("権限") }
        }
        .formStyle(.grouped)
    }

    private func startRecording() {
        isRecordingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Require at least one modifier (or pure function key)
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
            GroupBox("LLM後処理指示（空欄 = 後処理なし）") {
                TextEditor(text: $llmInstruction)
                    .font(.system(size: 12))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
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

                    Picker("処理エンジン", selection: $s.llmUseLocal) {
                        Text("ローカル (llama.cpp + Metal GPU)").tag(true)
                        Text("クラウド (API)").tag(false)
                    }

                    if s.llmUseLocal {
                        LocalLLMSettingsView()
                    } else {
                        HStack { Text("ベースURL"); TextField("https://api.chatweb.ai", text: $s.llmBaseURL).textFieldStyle(.roundedBorder) }
                        HStack { Text("APIキー"); SecureFieldWithReveal(text: $s.llmAPIKey, placeholder: "cw_...") }
                        HStack { Text("モデル"); TextField("auto", text: $s.llmModel).textFieldStyle(.roundedBorder) }
                    }

                    // 後処理プロンプト編集
                    VStack(alignment: .leading, spacing: 4) {
                        Text("後処理プロンプト（空欄 = デフォルト）")
                            .font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $s.llmCustomPrompt)
                            .font(.system(size: 11))
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                        if s.llmCustomPrompt.isEmpty {
                            Text("デフォルト: 誤字修正・句読点追加・認識ミス補正")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Button("デフォルトに戻す") {
                            s.llmCustomPrompt = ""
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .disabled(s.llmCustomPrompt.isEmpty)
                    }
                    Text("アプリタブで対象アプリごとに個別の指示も設定できます").font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("LLM後処理") }

            Section {
                Toggle("ウェイクワードで録音開始", isOn: $s.wakeWordEnabled)
                if s.wakeWordEnabled {
                    WakeWordTemplateView()
                }
            } header: { Text("ウェイクワード (MFCC+DTW)") }
        }
        .formStyle(.grouped)
    }
}

struct WakeWordTemplateView: View {
    @State private var templateCount = WakeWordEngine.shared.templates.count
    @State private var countdown: Int? = nil
    @State private var recording = false
    @State private var lastResult: Bool? = nil
    @State private var threshold: Float = WakeWordEngine.shared.distThreshold > 0 ? WakeWordEngine.shared.distThreshold : 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status
            HStack {
                Image(systemName: templateCount == 0 ? "waveform.slash" : "waveform.badge.checkmark")
                    .foregroundColor(templateCount == 0 ? .orange : .green)
                if templateCount == 0 {
                    Text("テンプレート未登録 — 下のボタンで自分の声を録音してください")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("\(templateCount) テンプレート録音済み")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Recording button
            HStack(spacing: 12) {
                Button(action: startRecording) {
                    HStack {
                        Image(systemName: recording ? "stop.circle.fill" : "mic.circle.fill")
                            .foregroundColor(recording ? .red : .accentColor)
                        if let c = countdown {
                            Text(c == 0 ? "録音中..." : "録音開始まで \(c)秒")
                        } else {
                            Text("ウェイクワードを録音する (1.5秒)")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(recording)

                if templateCount > 0 {
                    Button("クリア") {
                        WakeWordEngine.shared.clearTemplates()
                        templateCount = 0
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.link)
                }
            }

            if let ok = lastResult {
                Text(ok ? "✓ 録音完了！ (\(templateCount)個)" : "✗ 録音失敗。もう一度試してください")
                    .font(.caption)
                    .foregroundColor(ok ? .green : .red)
            }

            // Threshold slider
            if templateCount > 0 {
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

            Text("ウェイクワード（例:「ヘイこえ」）を3〜5回録音するほど精度が上がります")
                .font(.caption2).foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.vertical, 4)
    }

    private func startRecording() {
        recording = true
        lastResult = nil
        countdown = 2

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if let c = countdown, c > 0 {
                countdown = c - 1
            } else {
                timer.invalidate()
                countdown = nil
                WakeWordEngine.shared.recordTemplate(duration: 1.5) { ok in
                    recording = false
                    lastResult = ok
                    templateCount = WakeWordEngine.shared.templates.count
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
                                // Force view refresh
                                settings.objectWillChange.send()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
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
                    Text("待機中: \(model.name)（使用時に自動ロード → 30秒後に自動解放）")
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

// MARK: - History Tab

struct HistoryTab: View {
    @ObservedObject private var history = HistoryStore.shared

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                Spacer()
                Text("履歴はありません")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(history.entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(dateFormatter.string(from: entry.date))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(entry.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(history.entries.count) 件")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("すべてクリア") { history.clear() }
                    .foregroundColor(.red)
                    .buttonStyle(.link)
                    .disabled(history.entries.isEmpty)
            }
            .padding(8)
        }
    }
}
