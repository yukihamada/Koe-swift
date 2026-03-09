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
                }
                .onChange(of: settings.language) { _ in
                    AppDelegate.shared?.reloadSpeechEngine()
                }
            } header: { Text("音声認識") }

            Section {
                Toggle("フローティングマイクボタンを表示", isOn: $settings.floatingButtonEnabled)
                if settings.floatingButtonEnabled {
                    Text("画面上のボタンをクリックするだけで録音開始・停止できます。ドラッグで移動可能。")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("ワンクリック録音") }

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
                    HStack { Text("ベースURL"); TextField("https://api.chatweb.ai", text: $s.llmBaseURL).textFieldStyle(.roundedBorder) }
                    HStack { Text("APIキー"); SecureFieldWithReveal(text: $s.llmAPIKey, placeholder: "cw_...") }
                    HStack { Text("モデル"); TextField("auto", text: $s.llmModel).textFieldStyle(.roundedBorder) }
                    Text("アプリタブで対象アプリごとに後処理の指示を設定できます").font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("LLM後処理（chatweb.ai / OpenAI互換）") }

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

    private var binaryFound: Bool {
        let p = settings.whisperCppBinaryPath
        if !p.isEmpty { return FileManager.default.fileExists(atPath: p) }
        return ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
                "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
    private var modelFound: Bool {
        !settings.whisperCppModelPath.isEmpty &&
        FileManager.default.fileExists(atPath: settings.whisperCppModelPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Binary status
            HStack(spacing: 6) {
                Image(systemName: binaryFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(binaryFound ? .green : .red)
                Text(binaryFound ? "whisper-cli 検出済み" : "whisper-cli が見つかりません")
                    .font(.caption).foregroundColor(.secondary)
                if !binaryFound {
                    Button("インストール方法") {
                        NSWorkspace.shared.open(URL(string: "https://formulae.brew.sh/formula/whisper-cpp")!)
                    }.buttonStyle(.link).font(.caption)
                }
            }

            // Model path
            HStack {
                Text("モデル")
                TextField("/path/to/ggml-model.bin", text: $settings.whisperCppModelPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("…") { pickModelFile() }
                    .controlSize(.small)
            }
            if !settings.whisperCppModelPath.isEmpty && !modelFound {
                Text("⚠ ファイルが見つかりません").font(.caption).foregroundColor(.orange)
            }

            // Setup hint
            if !binaryFound || !modelFound {
                VStack(alignment: .leading, spacing: 2) {
                    Text("セットアップ手順").font(.caption).bold().foregroundColor(.secondary)
                    Text("brew install whisper-cpp").font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("whisper-download-ggml-model large-v3-turbo-q5_0")
                        .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                    Text("→ モデルパスを上に設定してください").font(.caption).foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private func pickModelFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.message = "whisper.cpp モデルファイル (.bin) を選択"
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            settings.whisperCppModelPath = url.path
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
