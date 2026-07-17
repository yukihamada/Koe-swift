import AppKit
import SwiftUI
import AVFoundation

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settingsTitle
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

/// Settings tab 列挙: SettingsRootView でカスタムタブバーに使う。
/// 順番・ラベル・アイコンは旧 TabView と完全一致 (構成変更なし、UI のみ刷新)。
private enum KoeSettingsTab: String, CaseIterable, Identifiable {
    case general, voice, ai, automation, stats, history
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:    return L10n.tabGeneral
        case .voice:      return L10n.tabVoice
        case .ai:         return L10n.tabAI
        case .automation: return L10n.tabAutomation
        case .stats:      return L10n.tabStats
        case .history:    return L10n.tabHistory
        }
    }
    var systemImage: String {
        switch self {
        case .general:    return "gear"
        case .voice:      return "waveform"
        case .ai:         return "brain.head.profile"
        case .automation: return "bolt.fill"
        case .stats:      return "chart.bar.fill"
        case .history:    return "clock.arrow.circlepath"
        }
    }
}

struct SettingsRootView: View {
    @State private var selectedTab: KoeSettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // P1/P4 指摘 (Settings IA): >> 隠しポップアップを廃止し、6 タブを常時表示の
            // 水平タブストリップに置換。順番・ラベル・アイコンは旧 TabView と同じ。
            HStack(spacing: 4) {
                ForEach(KoeSettingsTab.allCases) { tab in
                    SettingsTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
            )
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .padding(.bottom, 8)

            // タブ内容: 旧 TabView と同じ 6 View をそのまま差し替え (構成不変)
            Group {
                switch selectedTab {
                case .general:    GeneralTab()
                case .voice:      VoiceTab()
                case .ai:         AITab()
                case .automation: AutomationTab()
                case .stats:      StatsTab()
                case .history:    HistoryTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(width: 720, height: 640)  // タブ常時表示で横幅を少し広げ、6 タブが余裕で並ぶ
    }
}

/// 1 タブボタン: アイコン上 + ラベル下、選択中は gold ハイライト。
/// accessibilityLabel 必須 (P4 critical 対策)。
private struct SettingsTabButton: View {
    let tab: KoeSettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Lux.gold : .secondary)
                Text(tab.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Lux.gold.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Lux.gold.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.label))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
                Picker(L10n.labelLanguage, selection: $settings.language) {
                    ForEach(AppSettings.quickLanguages, id: \.code) { lang in
                        Text("\(lang.flag) \(lang.name)").tag(lang.code)
                    }
                }

                // Shortcut
                HStack {
                    Text(L10n.labelShortcut)
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
                        Text(L10n.labelPressKey).foregroundColor(.secondary).font(.caption)
                        Button("×") { stopRecording() }.controlSize(.small)
                    } else {
                        Button(L10n.labelCustom) { startRecording() }.controlSize(.small)
                    }
                }

                Picker(L10n.labelRecordingMode, selection: $settings.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: settings.recordingMode) { _ in AppDelegate.shared?.reregisterHotkey() }
            } header: {
                Label(L10n.sectionBasic, systemImage: "keyboard")
                    .foregroundColor(Lux.gold)
            }

            // オフラインモード: クラウドへの音声送信を一切行わない
            Section {
                Toggle(isOn: $settings.offlineModeEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(settings.offlineModeEnabled ? Lux.gold : .secondary)
                        Text("オフラインモード")
                    }
                }
                Text("クラウドへの音声送信を一切行いません / Never send audio to the cloud")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                if settings.offlineModeEnabled {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("✅ クラウドへの送信は一切ブロックされます")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(Lux.gold)
                        Text("• 音声認識: ローカル whisper.cpp のみ")
                            .font(.system(size: 10)).foregroundColor(Lux.gold)
                        Text("• LLM: ローカル llama.cpp のみ（クラウド API は無効化）")
                            .font(.system(size: 10)).foregroundColor(Lux.gold)
                        Text("• テレメトリ / クラッシュレポート送信なし")
                            .font(.system(size: 10)).foregroundColor(Lux.gold)
                    }
                }
            } header: {
                Label("プライバシー", systemImage: "lock.shield")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle(L10n.toggleLaunchAtLogin, isOn: $settings.launchAtLogin)
                Toggle(L10n.toggleCopyToClipboard, isOn: $settings.autoCopyToClipboard)
                Toggle(L10n.toggleNotifyOnComplete, isOn: $settings.notifyOnComplete)
                Toggle(L10n.toggleFloatingButton, isOn: $settings.floatingButtonEnabled)

                HStack {
                    Text(L10n.labelInputMode)
                    Spacer()
                    Picker("", selection: $settings.streamingPreviewEnabled) {
                        Text(L10n.inputModeVoice).tag(true)
                        Text(L10n.inputModeDirect).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Toggle(L10n.toggleCmdIMESwitch, isOn: $settings.cmdIMESwitchEnabled)

                // Fn キーで録音 (CGEventTap 経由 — アクセシビリティ必須)
                let axGranted = AXIsProcessTrusted()
                Toggle("Fn キーで録音", isOn: $settings.fnKeyEnabled)
                    .disabled(!axGranted)
                    .onChange(of: settings.fnKeyEnabled) { _ in
                        AppDelegate.shared?.reregisterHotkey()
                    }
                if settings.fnKeyEnabled {
                    HStack {
                        Text("Fn キーの動作")
                        Spacer()
                        Picker("", selection: $settings.fnKeyMode) {
                            Text("タップでトグル").tag("tap_toggle")
                            Text("押している間だけ").tag("hold_ptt")
                        }
                        .frame(width: 200)
                        .onChange(of: settings.fnKeyMode) { _ in
                            AppDelegate.shared?.reregisterHotkey()
                        }
                        .accessibilityLabel(Text("Fn キーの動作モード"))
                    }
                    // P4 指摘: 説明 2 行のみだったので詳細解説を追加
                    Text(settings.fnKeyMode == "tap_toggle"
                         ? "✦ Fn を**短く 1 回押して離す** → 録音開始 / もう 1 回タップ → 録音終了。0.6 秒以内のタップだけ反応するので、他のキーと組み合わせた使用には影響しません。"
                         : "✦ Fn を**押している間だけ** 録音 (Push-to-Talk)。指を離した瞬間に文字起こし開始。短い発話のサクサク連発に最適。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    Text(settings.fnKeyMode == "tap_toggle"
                         ? "ヒント: Fn + 別キー (例: Fn+V) の通常用途には影響しません。"
                         : "ヒント: 長押し中に他のキーを押すと record cancel されます。")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .italic()
                }
                if !axGranted {
                    Text("Fn キーの利用にはアクセシビリティ権限が必要です")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }

                Toggle(L10n.toggleShowNoiseLevel, isOn: $settings.showNoiseLevel)
                Toggle("メニューバーにマイクアイコンを表示", isOn: $settings.menuBarIconVisible)

                // 録音中の音量ダッキング: モード選択 + （manual時のみ）スライダー
                HStack {
                    Text("録音中の音量")
                    Spacer()
                    Picker("", selection: $settings.duckingMode) {
                        Text("OFF").tag("off")
                        Text("手動").tag("manual")
                        Text("自動").tag("auto")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .accessibilityLabel(Text("録音中の音量ダッキングモード"))
                    .accessibilityValue(Text(settings.duckingMode == "off" ? "OFF" : settings.duckingMode == "auto" ? "自動" : "手動"))
                }
                .help("OFF=ダッキングしない / 手動=常に下げる / 自動=音が鳴っている時だけ下げる")

                if settings.duckingMode != "off" {
                    HStack {
                        Text("下げる音量")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Slider(value: Binding(
                            get: { Double(settings.duckingVolume) },
                            set: { settings.duckingVolume = Int($0) }
                        ), in: 0...50, step: 5)
                        Text(settings.duckingVolume == 0 ? "OFF" : "\(settings.duckingVolume)%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } header: {
                Label(L10n.sectionBehavior, systemImage: "slider.horizontal.3")
                    .foregroundColor(Lux.gold)
            }

            // Overlay / 配信表示
            Section {
                Toggle("配信モード（大文字表示）", isOn: $settings.overlayLargeTextMode)
                Text("OBS 等の配信ソースで読みやすい大きな文字で表示します。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text("⌥ キーを押しながらドラッグで Overlay の位置を移動・保存できます。")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                if settings.overlayHasCustomOrigin {
                    Button("Overlay 位置をリセット") {
                        settings.overlayHasCustomOrigin = false
                    }
                }
            } header: {
                Label("Overlay 表示", systemImage: "rectangle.on.rectangle")
                    .foregroundColor(Lux.gold)
            }

            // 音声アーカイブ（プライバシー機微: 同意付きトグル + 自動 prune）
            AudioArchiveSection()

            Section {
                DisclosureGroup(L10n.labelMenuBarLanguages) {
                    Text(L10n.labelMenuBarLanguagesDesc).font(.system(size: 10)).foregroundColor(.secondary)
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

                DisclosureGroup(L10n.labelPermissions) {
                    HStack {
                        Image(systemName: "mic").font(.caption)
                        Text(L10n.labelMicrophone).font(.caption)
                        Spacer()
                        Button(L10n.labelOpen) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }.buttonStyle(.link).font(.caption)
                    }
                    HStack {
                        Image(systemName: "hand.raised").font(.caption)
                        Text(L10n.labelAccessibility).font(.caption)
                        Spacer()
                        Text(AXIsProcessTrusted() ? "OK" : L10n.labelNotAuthorized).foregroundColor(AXIsProcessTrusted() ? Lux.gold : .orange)
                            .font(.caption)
                        Button(L10n.labelOpen) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }.buttonStyle(.link).font(.caption)
                    }
                }

                // Version
                HStack {
                    Text(L10n.labelVersion).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Label(L10n.sectionOther, systemImage: "ellipsis.circle")
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

// MARK: - Audio Archive Section (録音音声のローカル蓄積 + 自動 prune)

struct AudioArchiveSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Section {
            // 同意トグル: ON 時にプライバシー確認モーダルを出す
            Toggle("録音音声をローカルに保存", isOn: Binding(
                get: { settings.audioArchiveEnabled },
                set: { newValue in
                    if newValue && !settings.audioArchiveEnabled {
                        // OFF → ON: 同意モーダルを表示し、Cancel ならロールバック
                        if confirmEnableArchive() {
                            settings.audioArchiveEnabled = true
                        } else {
                            // SwiftUI の Binding を即座に反転するため明示代入（UI が一度 true を反映するため）
                            settings.audioArchiveEnabled = false
                        }
                    } else {
                        settings.audioArchiveEnabled = newValue
                    }
                }
            ))
            .help("録音した音声 WAV をローカルに蓄積します（プライバシーに関わるため既定で OFF）")

            if settings.audioArchiveEnabled {
                // 保存先パス
                HStack {
                    Text("保存先")
                    Spacer()
                    Text(settings.audioArchiveResolvedPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("選択…") { chooseFolder() }
                        .controlSize(.small)
                        .accessibilityLabel(Text("音声アーカイブの保存先フォルダを選択"))
                    Button("Finder で開く") { revealInFinder() }
                        .controlSize(.small)
                        .accessibilityLabel(Text("音声アーカイブを Finder で表示"))
                }

                // 容量上限
                HStack {
                    Text("容量上限")
                    Spacer()
                    TextField("", value: $settings.audioArchiveMaxGB, formatter: Self.gbFormatter)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("GB").foregroundColor(.secondary)
                }

                // 日数上限
                HStack {
                    Text("保存日数")
                    Spacer()
                    TextField("", value: $settings.audioArchiveMaxDays, formatter: Self.daysFormatter)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("日").foregroundColor(.secondary)
                }

                Toggle("上限超過時は自動削除（古い順）", isOn: $settings.audioArchiveAutoPrune)
                    .help("OFF の場合、上限超過しても削除しません")

                // 統計
                let stats = AudioArchive.shared.stats()
                Text("保存済み: \(stats.count) ファイル / \(String(format: "%.1f", stats.totalMB)) MB")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Label("音声アーカイブ", systemImage: "waveform.circle")
                .foregroundColor(Lux.gold)
        }
    }

    // MARK: Number formatters
    private static let gbFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 0.1
        f.maximum = 500
        f.maximumFractionDigits = 1
        return f
    }()

    private static let daysFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 3650
        return f
    }()

    /// 有効化確認モーダル。ユーザーが「有効化」を押したら true を返す。
    private func confirmEnableArchive() -> Bool {
        let alert = NSAlert()
        alert.messageText = "音声アーカイブを有効化しますか？"
        alert.informativeText = """
        録音音声をローカルに蓄積します。

        ⚠️ これは取材源、会議内容、個人情報等、あなたのプライバシーに関わるデータです:
        • ディスク内に平文 WAV として保存されます（暗号化なし）
        • Time Machine / iCloud Drive / Dropbox 等の自動バックアップ対象になる可能性があります
        • 同じ Mac の他ユーザーや、フルディスクアクセス権を持つアプリから読まれる可能性があります
        • ディスク容量が継続的に増え続けます

        保存先: \(settings.audioArchiveResolvedPath)

        本当に有効化しますか？
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "有効化")
        // .alertFirstButtonReturn = Cancel, .alertSecondButtonReturn = 有効化
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        panel.message = "音声アーカイブの保存先フォルダを選んでください"
        if panel.runModal() == .OK, let url = panel.url {
            settings.audioArchivePath = url.path
        }
    }

    private func revealInFinder() {
        let path = settings.audioArchiveResolvedPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Voice Tab (音声: エンジン、モデル、認識パラメータ)

struct VoiceTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var inputDevices: [AudioDeviceEnumerator.InputDevice] = []
    @State private var deviceObserverRegistered = false

    var body: some View {
        Form {
            Section {
                Picker("入力デバイス", selection: $settings.audioInputDeviceUID) {
                    Text("システムデフォルト").tag("")
                    ForEach(inputDevices, id: \.uid) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
                if !settings.audioInputDeviceUID.isEmpty
                    && !inputDevices.contains(where: { $0.uid == settings.audioInputDeviceUID }) {
                    Text("選択中のデバイスが見つかりません（切断中？）")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
            } header: {
                Label("マイク", systemImage: "mic")
                    .foregroundColor(Lux.gold)
            }
            .onAppear {
                inputDevices = AudioDeviceEnumerator.listInputDevices()
                if !deviceObserverRegistered {
                    deviceObserverRegistered = true
                    AudioDeviceEnumerator.observeDeviceChanges {
                        inputDevices = AudioDeviceEnumerator.listInputDevices()
                    }
                }
            }

            Section {
                // オフラインモード時はクラウド系エンジンを除外
                let availableEngines: [RecognitionEngine] = settings.offlineModeEnabled
                    ? RecognitionEngine.allCases.filter { $0.isLocal }
                    : RecognitionEngine.allCases
                Picker(L10n.labelRecognitionEngine, selection: $settings.recognitionEngine) {
                    ForEach(availableEngines, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: settings.recognitionEngine) { _ in
                    AppDelegate.shared?.reloadSpeechEngine()
                }
                if settings.offlineModeEnabled {
                    Text("オフラインモード中: ローカルエンジンのみ選択可能")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                if settings.recognitionEngine == .whisperCpp {
                    WhisperCppSettingsView()
                }
                if settings.recognitionEngine == .whisper {
                    HStack {
                        Text(L10n.labelOpenAIAPIKey)
                        SecureFieldWithReveal(text: $settings.whisperAPIKey, placeholder: "sk-...")
                    }
                }
            } header: {
                Label(L10n.sectionEngine, systemImage: "waveform")
                    .foregroundColor(Lux.gold)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L10n.toggleBeamSearch, isOn: $settings.whisperBeamSearch)
                    Text(L10n.beamSearchDesc)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L10n.toggleUseContext, isOn: $settings.whisperUseContext)
                    Text(L10n.useContextDesc)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                HStack {
                    Text(L10n.labelSilenceWait)
                    Spacer()
                    Picker("", selection: $settings.silenceAutoStopSeconds) {
                        Text(L10n.silenceFast).tag(1.0); Text(L10n.silenceNormal).tag(1.5); Text(L10n.silenceSlow).tag(2.0)
                        Text(L10n.silenceLong).tag(3.0); Text(L10n.silenceLongest).tag(5.0)
                    }.frame(width: 160)
                }
                HStack {
                    Text(L10n.labelRecognitionVariance)
                        .help("0で最も確実な結果、高いと多様な候補から選びます")
                    Spacer()
                    Picker("", selection: $settings.whisperTemperature) {
                        Text(L10n.varianceSure).tag(0.0); Text(L10n.varianceFlexible).tag(0.2); Text(L10n.varianceVeryFlexible).tag(0.4)
                    }.frame(width: 160)
                }
                HStack {
                    Text(L10n.labelAmbiguity)
                        .help("低いと不確かな認識結果を棄却します")
                    Spacer()
                    Picker("", selection: $settings.whisperEntropyThreshold) {
                        Text(L10n.ambiguityStrict).tag(2.0); Text(L10n.ambiguityNormal).tag(2.4); Text(L10n.ambiguityLoose).tag(3.0)
                    }.frame(width: 160)
                }
            } header: {
                Label(L10n.sectionRecognitionTuning, systemImage: "tuningfork")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle(L10n.toggleFillerRemoval, isOn: $settings.fillerRemovalEnabled)
                Text(L10n.fillerRemovalDesc)
                    .font(.system(size: 10)).foregroundColor(.secondary)

                Picker(L10n.labelPunctuationStyle, selection: $settings.punctuationStyle) {
                    ForEach(VoiceCommands.PunctuationStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }

                Toggle(L10n.toggleCommandMode, isOn: $settings.commandModeEnabled)
                Text(L10n.commandModeDesc)
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } header: {
                Label(L10n.sectionTextProcessing, systemImage: "text.badge.checkmark")
                    .foregroundColor(Lux.gold)
            }

            // P1 R3/R4 medium: 技術用語辞書 (音声誤認識の英単語復元) を Settings で編集可能に
            TechTermDictionarySection()

            Section {
                Toggle(L10n.toggleContextAware, isOn: $settings.contextAwareEnabled)
                if settings.contextAwareEnabled {
                    Toggle(L10n.toggleAppHint, isOn: $settings.contextUseAppHint)
                    Toggle(L10n.toggleClipboardContext, isOn: $settings.contextUseClipboard)
                }
                TextField(L10n.labelCustomPrompt, text: $settings.contextCustomPrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            } header: {
                Label(L10n.sectionContext, systemImage: "text.viewfinder")
                    .foregroundColor(Lux.gold)
            }

            Section {
                LearningDictionaryView()
            } header: {
                Label(L10n.sectionLearningDictionary, systemImage: "book.closed")
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
                Text(L10n.learningCount(entries.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !keywords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.labelLearnedKeywords)
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
                Text(L10n.learningEmptyDesc)
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            if !entries.isEmpty {
                DisclosureGroup(L10n.recentCorrections(min(entries.count, 5))) {
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
                    Text(L10n.labelNoAppProfiles)
                        .foregroundColor(.secondary)
                    Text(L10n.labelAppProfilesDesc)
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
                Text("\(settings.appProfiles.count)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L10n.buttonAdd) { showAdd = true }
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
                Text(profile.prompt.isEmpty ? L10n.labelNoPrompt : profile.prompt)
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
            Text(profile == nil ? L10n.labelAddProfile : L10n.labelEditProfile)
                .font(.headline)

            // App picker
            GroupBox(L10n.labelTargetApp) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L10n.labelRunningApps, selection: $selectedApp) {
                        Text(L10n.labelSelectApp).tag(Optional<RunningAppInfo>.none)
                        ForEach(runningApps) { app in
                            Text(app.name).tag(Optional(app))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedApp) { app in
                        if let app { manualBundle = app.bundleID }
                    }
                    TextField(L10n.labelBundleIDInput, text: $manualBundle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(4)
            }

            // Language override
            GroupBox(L10n.labelLanguageOverride) {
                Picker("", selection: $language) {
                    Text(L10n.labelGlobalSetting).tag("")
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
            GroupBox(L10n.labelPromptWhisperHint) {
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            }

            // LLM instruction
            GroupBox(L10n.labelLLMInstruction) {
                TextEditor(text: $llmInstruction)
                    .font(.system(size: 12))
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                if llmInstruction.isEmpty {
                    Text(L10n.labelLLMInstructionEmpty)
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack {
                Button(L10n.buttonCancel) { dismiss() }
                Spacer()
                Button(L10n.buttonSave) {
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

// MARK: - Tech Term Dictionary editor (P1 R4)

/// 認識結果の英単語復元辞書を Settings から編集できる簡易テーブル。
/// pre-seed されたエントリ + ユーザー追加分を view・追加・削除できる。
struct TechTermDictionarySection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newKey: String = ""
    @State private var newValue: String = ""

    var body: some View {
        Section {
            Text("音声認識後に置換される英単語辞書。例: 「あしんく あう」→「async/await」。")
                .font(.system(size: 10)).foregroundColor(.secondary)

            // 新規追加 row
            HStack {
                TextField("ひらがな（例: ゆーず すてーと）", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                Text("→")
                TextField("英単語（例: useState）", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                Button("追加") {
                    let k = newKey.trimmingCharacters(in: .whitespaces).lowercased()
                    let v = newValue.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty, !v.isEmpty else { return }
                    var dict = settings.techTermDictionary
                    dict[k] = v
                    settings.techTermDictionary = dict
                    newKey = ""; newValue = ""
                }
                .disabled(newKey.isEmpty || newValue.isEmpty)
            }

            // 既存エントリ list (key 昇順)
            let pairs = settings.techTermDictionary.sorted { $0.key < $1.key }
            if pairs.isEmpty {
                Text("辞書は空です").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(pairs, id: \.key) { pair in
                    HStack {
                        Text(pair.key)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(minWidth: 140, alignment: .leading)
                        Text("→")
                            .foregroundColor(.secondary)
                        Text(pair.value)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: {
                            var dict = settings.techTermDictionary
                            dict.removeValue(forKey: pair.key)
                            settings.techTermDictionary = dict
                        }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("「\(pair.key)」のエントリを削除"))
                    }
                }
            }

            Button("デフォルトに戻す") {
                settings.techTermDictionary = AppSettings.defaultTechTermDictionary()
            }
            .controlSize(.small)
            .padding(.top, 4)
        } header: {
            Label("技術用語辞書", systemImage: "character.book.closed")
                .foregroundColor(Lux.gold)
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
                Toggle(L10n.toggleLLMEnabled, isOn: $s.llmEnabled)
                if s.llmEnabled {
                    Text(L10n.llmEnabledDesc)
                        .font(.caption).foregroundColor(.secondary)

                    Picker(L10n.labelProcessingMode, selection: $s.llmMode) {
                        ForEach(LLMMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    // オフラインモード中はクラウド LLM を選択不可（ローカル固定）
                    if !s.offlineModeEnabled {
                        Picker(L10n.labelProcessingEngine, selection: $s.llmUseLocal) {
                            Text(L10n.engineLocal).tag(true)
                            Text(L10n.engineCloud).tag(false)
                        }
                    } else {
                        HStack {
                            Image(systemName: "lock.fill").foregroundColor(.secondary)
                            Text("オフラインモード: ローカル LLM 固定")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }

                    if s.llmUseLocal || s.offlineModeEnabled {
                        LocalLLMSettingsView()
                    } else {
                        Picker(L10n.labelProvider, selection: $s.llmProvider) {
                            ForEach(LLMProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }

                        if s.llmProvider.requiresAPIKey {
                            HStack {
                                Text(L10n.labelAPIKey)
                                SecureFieldWithReveal(
                                    text: $s.llmAPIKey,
                                    placeholder: s.llmProvider == .anthropic ? "sk-ant-..." : "sk-..."
                                )
                            }
                        }

                        HStack {
                            Text(L10n.labelModel)
                            TextField(s.llmProvider.defaultModel, text: $s.llmModel)
                                .textFieldStyle(.roundedBorder)
                        }

                        if s.llmProvider == .custom {
                            HStack {
                                Text(L10n.labelBaseURL)
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
                            Text(L10n.labelCustomPrompt)
                                .font(.caption).foregroundColor(.secondary)
                            TextEditor(text: $s.llmCustomPrompt)
                                .font(.system(size: 11))
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                            if s.llmCustomPrompt.isEmpty {
                                Text(L10n.llmCustomPromptEmpty)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Button(L10n.labelClear) { s.llmCustomPrompt = "" }
                                .buttonStyle(.link).font(.caption2)
                                .disabled(s.llmCustomPrompt.isEmpty)
                        }
                    }
                }
            } header: {
                Label(L10n.sectionLLMPostProcessing, systemImage: "brain.head.profile")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle(L10n.toggleSuperMode, isOn: $s.superModeEnabled)
                if s.superModeEnabled {
                    Text(L10n.superModeEnabledDesc)
                        .font(.caption).foregroundColor(.secondary)
                    if !AXIsProcessTrusted() {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(L10n.accessibilityNotAuthorizedWarning)
                                .font(.caption).foregroundColor(.orange)
                            Button(L10n.openSystemSettings) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }.buttonStyle(.link).font(.caption)
                        }
                    }
                } else {
                    Text(L10n.superModeDisabledDesc)
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
                Toggle(L10n.toggleWakeWord, isOn: $s.wakeWordEnabled)
                if s.wakeWordEnabled {
                    // エンジン選択
                    #if MAC_APP_STORE
                    Text("MFCC+DTW（内蔵・テンプレート学習）").font(.caption).foregroundColor(.secondary)
                    WakeWordTemplateView()
                    #else
                    Picker("エンジン", selection: $s.wakeWordEngineType) {
                        ForEach(WakeWordEngineType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch s.wakeWordEngineType {
                    case .appleSpeech:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Apple のオンデバイス音声認識を常時走らせ、合言葉を検出します。話者非依存・雑音に強く、録音は不要。音声は端末外に出ません。")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                Text("合言葉").font(.caption)
                                TextField("ヘイこえ", text: Binding(
                                    get: { s.wakeWords.first ?? "" },
                                    set: { s.wakeWords = [$0] + s.wakeWords.dropFirst() }
                                ))
                            }
                        }
                    case .mfccDTW:
                        WakeWordTemplateView()
                    case .openWakeWord:
                        OWWSettingsView()
                    }
                    #endif
                }
            } header: {
                Label(L10n.sectionWakeWord, systemImage: "ear")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle(L10n.toggleAgentMode, isOn: $s.agentModeEnabled)
                Text(L10n.agentModeDesc)
                    .font(.caption).foregroundColor(.secondary)
                if s.agentModeEnabled {
                    DisclosureGroup(L10n.labelSupportedCommands) {
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
                Label(L10n.sectionAgent, systemImage: "bolt.fill")
                    .foregroundColor(Lux.gold)
            }

            // MARK: - Voice Cockpit（ハンズフリー操作）
            #if !MAC_APP_STORE
            Section {
                Toggle("継続会話セッション", isOn: $s.conversationModeEnabled)
                Text("ウェイクワードで一度起こすと会話モードに入り、沈黙でターン確定→自動実行を繰り返します。停止語（おわり等）で終了。")
                    .font(.caption).foregroundColor(.secondary)
                if s.conversationModeEnabled {
                    Toggle("非コマンド発話も口述入力する", isOn: $s.conversationDictationFallback)
                    Toggle("結果を音声で読み上げる", isOn: $s.conversationTTSResponses)
                    Toggle("効果音（earcon）", isOn: $s.conversationEarconEnabled)
                    HStack {
                        Text("ターン確定の無音長").font(.caption)
                        Slider(value: $s.conversationTurnSilenceMs, in: 300...2000, step: 100)
                        Text("\(Int(s.conversationTurnSilenceMs))ms").font(.caption).monospacedDigit()
                    }
                }
            } header: {
                Label("継続会話セッション", systemImage: "bubble.left.and.bubble.right")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("番号オーバーレイ（声でクリック）", isOn: $s.numberOverlayEnabled)
                Text("「番号出して」で画面のボタン/リンクに番号を重ね、「2番」でクリックします。")
                    .font(.caption).foregroundColor(.secondary)
                if s.numberOverlayEnabled {
                    Toggle("セッション中は常時表示", isOn: $s.numberOverlayAlwaysOn)
                    Toggle("クリック後に自動で消す", isOn: $s.numberOverlayAutoHideAfterClick)
                    Picker("要素列挙", selection: $s.elementScanMode) {
                        Text("アクセシビリティ優先").tag("a11yFirst")
                        Text("OCR優先").tag("ocrFirst")
                        Text("アクセシビリティのみ").tag("a11yOnly")
                    }
                }
            } header: {
                Label("番号オーバーレイ", systemImage: "number.square")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle("カメラ・ジェスチャー", isOn: $s.gestureEnabled)
                Text("セッション中のみカメラ ON。👍 OK / 👎 やめて / ✋ 停止 / ↑↓ スクロール / 指 N 本で番号 #N をクリック。映像は端末外に出ません。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Label("カメラ・ジェスチャー", systemImage: "hand.raised")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Picker("読み上げエンジン", selection: $s.ttsBackend) {
                    Text("macOS（オフライン）").tag("say")
                    Text("ElevenLabs").tag("elevenLabs")
                }
                Picker("読み上げ詳細度", selection: $s.ttsVerbosity) {
                    Text("完了通知のみ").tag("completionOnly")
                    Text("完了通知＋要約").tag("completionPlusSummary")
                    Text("全文").tag("full")
                }
                if s.ttsBackend == "elevenLabs" {
                    SecureField("ElevenLabs API キー", text: $s.elevenLabsAPIKey)
                    TextField("Voice ID", text: $s.elevenLabsVoiceID)
                }
            } header: {
                Label("読み上げ（TTS）", systemImage: "speaker.wave.2")
                    .foregroundColor(Lux.gold)
            }
            #else
            Section {
                Text("ハンズフリー操作（継続会話セッション・番号オーバーレイ・カメラジェスチャー）は、システム制御の制約により GitHub 配布版でご利用いただけます。")
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Label("ハンズフリー操作", systemImage: "hand.raised")
                    .foregroundColor(Lux.gold)
            }
            #endif

            Section {
                DisclosureGroup(L10n.appProfilesCount(s.appProfiles.count)) {
                    AppProfilesInlineView()
                }
            } header: {
                Label(L10n.sectionAppIntegration, systemImage: "app.badge")
                    .foregroundColor(Lux.gold)
            }

            Section {
                Toggle(L10n.toggleIPhoneLLM, isOn: $s.iphoneBridgeLLM)
                    .font(.system(size: 12))
                if s.iphoneBridgeLLM {
                    HStack {
                        Text(L10n.labelMode).font(.system(size: 11)).foregroundColor(.secondary)
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
                Toggle(L10n.toggleAutoEnter, isOn: $s.iphoneBridgeAutoEnter)
                    .font(.system(size: 12))
            } header: {
                Label(L10n.sectionIPhoneIntegration, systemImage: "iphone.and.arrow.forward")
                    .foregroundColor(Lux.gold)
            }

            Section {
                DisclosureGroup(L10n.textExpansionCount(s.textExpansions.count)) {
                    TextExpansionsInlineView()
                }
            } header: {
                Label(L10n.sectionTextExpansion, systemImage: "text.word.spacing")
                    .foregroundColor(Lux.gold)
            }

            #if !MAC_APP_STORE
            Section {
                OWWCloudTrainView()
            } header: {
                Label("カスタムウェイクワード学習（クラウド）", systemImage: "waveform.badge.plus")
                    .foregroundColor(Lux.gold)
            }
            #endif
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
        Button(L10n.labelEditAppProfiles) {
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
            Text(L10n.labelNoTextExpansionRules)
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
                    Text(L10n.wakeWordTemplatesReady(templateCount))
                        .font(.caption).foregroundColor(.secondary)
                } else if templateCount > 0 {
                    Image(systemName: "waveform").foregroundColor(.orange)
                    Text(L10n.wakeWordTemplatesProgress(templateCount, minRequired))
                        .font(.caption).foregroundColor(.orange)
                } else {
                    Image(systemName: "waveform.slash").foregroundColor(.orange)
                    Text(L10n.wakeWordTemplatesEmpty(minRequired))
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Recording button
            HStack(spacing: 12) {
                if recording {
                    HStack {
                        Image(systemName: "stop.circle.fill").foregroundColor(.red)
                        if let c = countdown, c > 0 {
                            Text(L10n.wakeWordCountdownLabel(currentRound, minRequired, c))
                        } else {
                            Text(L10n.wakeWordRecordingLabel(currentRound, max(minRequired, currentRound)))
                        }
                    }
                } else if templateCount < minRequired {
                    Button(action: { startMultiRecording() }) {
                        HStack {
                            Image(systemName: "mic.circle.fill").foregroundColor(.accentColor)
                            Text(L10n.wakeWordRecordButton(minRequired))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: { startSingleRecording() }) {
                        HStack {
                            Image(systemName: "mic.circle.fill").foregroundColor(.accentColor)
                            Text(L10n.wakeWordRecordMore)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if templateCount > 0 && !recording {
                    Button(L10n.labelClearAll) {
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
                Text(ok ? "✓ \(L10n.wakeWordDone(templateCount))" : "")
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
                        Text(L10n.labelSensitivity).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("現在: \(String(format: "%.1f", threshold))").font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Text(L10n.sensitivityStrict).font(.caption2).foregroundColor(.secondary)
                        Slider(value: $threshold, in: 1.0...5.0, step: 0.1)
                            .onChange(of: threshold) { v in WakeWordEngine.shared.distThreshold = v }
                        Text(L10n.sensitivityLoose).font(.caption2).foregroundColor(.secondary)
                    }
                    Text(L10n.sensitivityDesc).font(.caption2).foregroundColor(.secondary)
                }
            }

            Text(L10n.wakeWordHelpText)
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
                        lastError = "✗ \(L10n.wakeWordNoVoice)"
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

// MARK: - OWW Settings View

#if !MAC_APP_STORE
struct OWWSettingsView: View {
    @ObservedObject private var s     = AppSettings.shared
    @ObservedObject private var setup = OWWSetupManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            setupStatusSection
            if setup.state.isReady {
                Divider()
                modelSection
                thresholdSection
                customModelSection
            }
        }
        .onAppear { setup.checkInstallation() }
    }

    // MARK: セットアップ状態

    @ViewBuilder
    private var setupStatusSection: some View {
        switch setup.state {
        case .unknown:
            HStack { ProgressView().scaleEffect(0.7); Text("確認中…").font(.caption).foregroundColor(.secondary) }

        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
                    Text("openWakeWord は未インストールです").font(.caption)
                }
                Text("「自動インストール」をタップするとバックグラウンドでセットアップします（初回のみ数分）。")
                    .font(.caption2).foregroundColor(.secondary)
                Button("自動インストール") { setup.install() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }

        case .installing:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("インストール中…").font(.caption) }
                Text(setup.progressMessage).font(.caption2).foregroundColor(.secondary)
            }

        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("openWakeWord 準備完了 ✓").font(.caption).foregroundColor(.secondary)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("インストール失敗").font(.caption)
                }
                Text(msg).font(.caption2).foregroundColor(.red)
                Button("再試行") { setup.install() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    // MARK: モデル選択

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ウェイクワード（プリセット）").font(.caption).foregroundColor(.secondary)
            Picker("", selection: $s.owwModelName) {
                ForEach(OWWEngine.pretrainedModels, id: \.id) { m in
                    Text("\(m.label)  (\(m.id))").tag(m.id)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity)
            Text("日本語ウェイクワードはカスタムモデル学習が必要です")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 感度

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("感度（threshold）").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2f", s.owwThreshold)).font(.caption.monospacedDigit())
            }
            HStack {
                Text("低").font(.caption2).foregroundColor(.secondary)
                Slider(value: $s.owwThreshold, in: 0.1...0.9, step: 0.05)
                Text("高").font(.caption2).foregroundColor(.secondary)
            }
            Text("低いほど反応しやすい（誤検知も増える）").font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: カスタムモデルパス

    private var customModelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("カスタムモデル（.onnx、省略可）").font(.caption).foregroundColor(.secondary)
            HStack {
                TextField("/Users/you/models/hey_koe.onnx", text: $s.owwCustomModelPath)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("…") { pickModel() }.controlSize(.small)
            }
        }
    }

    private func pickModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { s.owwCustomModelPath = panel.url?.path ?? "" }
    }
}

// MARK: - OWW Cloud Train View (standalone, always visible regardless of wake word toggle)

struct OWWCloudTrainView: View {
    @ObservedObject private var s     = AppSettings.shared
    @ObservedObject private var setup = OWWSetupManager.shared
    @State private var trainText: String = "hey koe"
    @State private var trainName: String = "hey_koe"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("学習サーバー URL").font(.caption2).foregroundColor(.secondary)
                TextField("https://koe-wake-train.fly.dev", text: $s.wakeTrainEndpoint)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Text("空欄だとカスタム学習は無効。自前サーバーを立てる場合は URL を差し替え")
                    .font(.caption2).foregroundColor(.secondary)

                Text("発音テキスト").font(.caption2).foregroundColor(.secondary).padding(.top, 4)
                TextField("例: hey koe / ヘイこえ", text: $trainText)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Text("モデル名（半角英数とアンダースコア）").font(.caption2).foregroundColor(.secondary)
                TextField("例: hey_koe", text: $trainName)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
            }

            switch setup.trainState {
            case .idle, .failed:
                HStack(spacing: 8) {
                    Button("学習開始") {
                        setup.trainModel(wakeWordText: trainText, modelName: trainName)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(trainText.isEmpty || trainName.isEmpty)

                    if case .failed(let msg) = setup.trainState {
                        Text(msg).font(.caption2).foregroundColor(.red)
                    }
                }
                Text("※ クラウド学習には5〜15分かかります")
                    .font(.caption2).foregroundColor(.secondary)

            case .training:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(setup.trainProgress).font(.caption2).foregroundColor(.secondary)
                }

            case .done(let path):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("学習完了 ✓ カスタムモデルに自動設定されました").font(.caption2)
                        Text(path).font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    Button("別のワードを学習") { setup.trainState = .idle }
                        .buttonStyle(.link).controlSize(.mini)
                }
            }
        }
    }
}
#endif

// MARK: - Text Expansions Tab

struct TextExpansionsTab: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        VStack(spacing: 0) {
            if s.textExpansions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.word.spacing").font(.system(size: 32)).foregroundColor(.secondary)
                    Text(L10n.labelNoTextExpansions).foregroundColor(.secondary)
                    Text(L10n.labelTextExpansionDesc).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach($s.textExpansions) { $exp in
                        HStack(spacing: 8) {
                            TextField(L10n.labelTrigger, text: $exp.trigger).textFieldStyle(.roundedBorder).frame(width: 120)
                            Text("→")
                            TextField(L10n.labelExpansionText, text: $exp.expansion).textFieldStyle(.roundedBorder)
                        }
                    }
                    .onDelete { s.textExpansions.remove(atOffsets: $0) }
                }
            }
            Divider()
            HStack {
                Text("\(s.textExpansions.count)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L10n.buttonAdd) { s.textExpansions.append(TextExpansion(trigger: "", expansion: "")) }
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
                Text(dl.isModelAvailable ? "\(L10n.labelModel): \(dl.currentModel.name)" : L10n.labelNotDownloaded)
                    .font(.caption)
            }

            // Model list
            ForEach(ModelDownloader.availableModels, id: \.id) { model in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(model.name).font(.system(size: 12, weight: .medium))
                            if model.id == dl.currentModel.id {
                                Text(L10n.labelInUse)
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
                            Button(L10n.buttonSelect) {
                                dl.selectModel(model)
                                settings.objectWillChange.send()
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        Button(L10n.labelDelete) {
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
                Text(L10n.labelSaveLocation).font(.caption2).foregroundColor(.secondary)
                Text(dl.modelDir.path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.buttonOpenInFinder) {
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
                    Text("\(llm.selectedModel?.name ?? "") — Metal GPU")
                        .font(.caption)
                } else if loading {
                    ProgressView().controlSize(.small)
                    Text(L10n.preparing)
                        .font(.caption).foregroundColor(.orange)
                } else if let model = llm.selectedModel, llm.isDownloaded(model) {
                    Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 6))
                    Text("待機中: \(model.name)" + (AppSettings.shared.llmMemorySaveMode ? "（メモリ省略: 毎回ロード/解放）" : "（使用時に自動ロード・常駐）"))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(L10n.labelNotDownloaded)
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
                                Text(L10n.labelInUse)
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
                            Button(L10n.buttonSelectAndLoad) {
                                loadModel(model)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(loading)
                        }
                        Button(L10n.labelDelete) {
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
                Button(L10n.buttonUnload) {
                    llm.unload()
                    loadError = ""
                }
                .foregroundColor(.red)
                .buttonStyle(.link)
                .font(.caption)
            }

            Divider()

            // メモリ省略モード
            Toggle(L10n.toggleMemorySaveMode, isOn: Binding(
                get: { AppSettings.shared.llmMemorySaveMode },
                set: { AppSettings.shared.llmMemorySaveMode = $0 }
            ))
            .font(.caption)

            // モデル保存フォルダ
            HStack(spacing: 4) {
                Text(L10n.labelSaveLocation).font(.caption2).foregroundColor(.secondary)
                Text(llm.modelDir.path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.buttonOpenInFinder) {
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
                        label: L10n.labelTodayChars,
                        color: Lux.gold
                    )
                    StatCard(
                        icon: "clock",
                        value: stats.savedTimeDisplay,
                        label: L10n.labelTimeSaved,
                        color: .green
                    )
                    StatCard(
                        icon: "mic.fill",
                        value: "\(stats.todaySessionCount)",
                        label: L10n.labelSession,
                        color: .blue
                    )
                    StatCard(
                        icon: "flame.fill",
                        value: "\(stats.streak)",
                        label: L10n.labelStreak,
                        color: .orange
                    )
                }

                // Weekly chart
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.labelWeeklyTrend)
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
                            Text(L10n.labelTotalChars)
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(stats.totalCharCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        HStack {
                            Text(L10n.labelTotalSessions)
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(stats.totalSessionCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        HStack {
                            Text(L10n.labelTotalTimeSaved)
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text(stats.totalSavedTimeDisplay)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                        HStack {
                            Text(L10n.labelLearnedCorrections)
                                .font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(CorrectionStore.shared.entryCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(4)
                } label: {
                    Label(L10n.labelTotal, systemImage: "sum")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Lux.gold)
                }

                // Typing speed comparison
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.labelTypingComparison)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Lux.gold)

                        HStack(spacing: 0) {
                            // 音声入力
                            VStack(spacing: 2) {
                                Text(L10n.labelVoice)
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text("~150")
                                    .font(.system(size: 16, weight: .light, design: .rounded))
                                Text(L10n.labelCharsPerMin)
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)

                            Text("vs")
                                .font(.system(size: 10)).foregroundColor(.secondary)

                            VStack(spacing: 2) {
                                Text(L10n.labelTyping)
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text("~80")
                                    .font(.system(size: 16, weight: .light, design: .rounded))
                                    .foregroundColor(.secondary)
                                Text(L10n.labelCharsPerMin)
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        Text(L10n.voiceVsTypingDesc)
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
    @State private var playingID: UUID?
    @State private var rerecognizingID: UUID?
    @State private var batchRerecognizing = false
    @State private var batchProgress = 0
    @State private var batchTotal = 0
    @State private var selectedWaveformID: UUID?
    @State private var waveformSamples: [Float] = []
    @State private var copiedID: UUID?
    @StateObject private var audioPlayer = HistoryAudioPlayer()

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
                TextField(L10n.labelSearch, text: $searchQuery)
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
                .help(showFavoritesOnly ? L10n.helpShowAll : L10n.helpFavoritesOnly)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // List
            if filteredEntries.isEmpty {
                Spacer()
                Text(history.entries.isEmpty ? L10n.labelNoHistory : L10n.labelNoMatch)
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                                HStack(spacing: 6) {
                                    if let time = entry.recognitionTime {
                                        Text(String(format: "%.1fs", time))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                    if let model = entry.modelName {
                                        Text(model)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                    if entry.originalText != nil {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 8))
                                            .foregroundColor(.orange.opacity(0.6))
                                            .help("再認識済み（元: \(entry.originalText ?? "")）")
                                    }
                                    if rerecognizingID == entry.id {
                                        Text("再認識中...")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                                // 波形プレビュー
                                if selectedWaveformID == entry.id && !waveformSamples.isEmpty {
                                    WaveformPreviewView(samples: waveformSamples)
                                        .frame(height: 30)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if entry.audioFileID != nil {
                                Button {
                                    if audioPlayer.isPlaying && playingID == entry.id {
                                        audioPlayer.stop()
                                        playingID = nil
                                    } else if let fid = entry.audioFileID,
                                              let url = AudioArchive.shared.url(for: fid) {
                                        audioPlayer.play(url: url)
                                        playingID = entry.id
                                    }
                                } label: {
                                    Image(systemName: (audioPlayer.isPlaying && playingID == entry.id) ? "stop.fill" : "play.fill")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("音声を再生")
                            }
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)
                                HStack(spacing: 6) {
                                    // 再認識ボタン（音声ファイルがある場合のみ）
                                    if entry.audioFileID != nil {
                                        if rerecognizingID == entry.id {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                                .frame(width: 14, height: 14)
                                        } else {
                                            Button {
                                                if let model = downloadedModels().first {
                                                    rerecognizeEntry(entry, model: model)
                                                }
                                            } label: {
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                            }
                                            .buttonStyle(.plain)
                                            .help("再認識")
                                        }
                                    }
                                    // コピーボタン
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.text, forType: .string)
                                        copiedID = entry.id
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            if copiedID == entry.id { copiedID = nil }
                                        }
                                    } label: {
                                        Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                                            .font(.caption)
                                            .foregroundColor(copiedID == entry.id ? .green : .accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L10n.labelCopy)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                                copiedID = entry.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedID == entry.id { copiedID = nil }
                                }
                            } label: {
                                Label(L10n.labelCopy, systemImage: "doc.on.doc")
                            }
                            if let fid = entry.audioFileID, AudioArchive.shared.url(for: fid) != nil {
                                Button {
                                    if let url = AudioArchive.shared.url(for: fid) {
                                        audioPlayer.play(url: url)
                                        playingID = entry.id
                                    }
                                } label: {
                                    Label("音声を再生", systemImage: "play.fill")
                                }
                                Button {
                                    loadWaveform(for: entry)
                                } label: {
                                    Label("波形を表示", systemImage: "waveform")
                                }
                                Menu {
                                    ForEach(downloadedModels(), id: \.id) { model in
                                        Button(model.name) {
                                            rerecognizeEntry(entry, model: model)
                                        }
                                    }
                                } label: {
                                    Label("再認識", systemImage: "arrow.clockwise")
                                }
                            }
                            Button {
                                history.toggleFavorite(id: entry.id)
                            } label: {
                                Label(entry.isFavorite ? L10n.labelUnfavorite : L10n.labelFavorite,
                                      systemImage: entry.isFavorite ? "star.slash" : "star.fill")
                            }
                            Divider()
                            Button(role: .destructive) {
                                history.delete(id: entry.id)
                            } label: {
                                Label(L10n.labelDelete, systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Text(L10n.showingCount(total: history.entries.count, filtered: filteredEntries.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if batchRerecognizing {
                    ProgressView(value: Double(batchProgress), total: Double(max(batchTotal, 1)))
                        .frame(width: 60)
                    Text("\(batchProgress)/\(batchTotal)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Menu("一括再認識") {
                        ForEach(downloadedModels(), id: \.id) { model in
                            Button(model.name) { batchRerecognize(model: model) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(history.entries.filter { $0.audioFileID != nil }.isEmpty)
                }
                Menu(L10n.labelExport) {
                    Button("テキスト (.txt)") { exportFile(type: .text) }
                    Button("CSV (.csv)") { exportFile(type: .csv) }
                    Button("JSON (.json)") { exportFile(type: .json) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(history.entries.isEmpty)
                Button(L10n.labelClearAll) { history.clear() }
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

    private func downloadedModels() -> [WhisperModel] {
        ModelDownloader.availableModels.filter { ModelDownloader.shared.isDownloaded($0) }
    }

    private func rerecognizeEntry(_ entry: HistoryEntry, model: WhisperModel) {
        guard let fid = entry.audioFileID,
              let url = AudioArchive.shared.url(for: fid) else { return }
        rerecognizingID = entry.id
        let lang = AppSettings.shared.language == "auto" ? "auto" : (AppSettings.shared.language.components(separatedBy: "-").first ?? "en")
        let modelPath = ModelDownloader.shared.path(for: model)

        klog("Re-recognize: loading \(model.name) for entry \(entry.id)")
        let ctx = WhisperContext()
        ctx.loadModel(path: modelPath) { ok in
            guard ok else {
                klog("Re-recognize: failed to load \(model.name)")
                self.rerecognizingID = nil
                return
            }
            ctx.transcribe(url: url, language: lang) { text in
                self.rerecognizingID = nil
                let time = ctx.lastTranscriptionTime
                ctx.unload()
                guard let text, !text.isEmpty else { return }
                klog("Re-recognize (\(model.name)): '\(text)' in \(String(format: "%.2f", time))s")
                self.history.updateText(id: entry.id, newText: text, modelName: model.name, recognitionTime: time)
            }
        }
    }

    private func batchRerecognize(model: WhisperModel) {
        let targets = history.entries.filter { $0.audioFileID != nil }
        guard !targets.isEmpty else { return }
        batchRerecognizing = true
        batchTotal = targets.count
        batchProgress = 0

        let lang = AppSettings.shared.language == "auto" ? "auto" : (AppSettings.shared.language.components(separatedBy: "-").first ?? "en")
        let modelPath = ModelDownloader.shared.path(for: model)
        let ctx = WhisperContext()

        klog("Batch re-recognize: \(targets.count) entries with \(model.name)")
        ctx.loadModel(path: modelPath) { ok in
            guard ok else {
                klog("Batch re-recognize: failed to load \(model.name)")
                self.batchRerecognizing = false
                return
            }
            self.processNext(targets: targets, index: 0, ctx: ctx, lang: lang, model: model)
        }
    }

    private func processNext(targets: [HistoryEntry], index: Int, ctx: WhisperContext, lang: String, model: WhisperModel) {
        guard index < targets.count else {
            ctx.unload()
            batchRerecognizing = false
            klog("Batch re-recognize: complete (\(targets.count) entries)")
            return
        }
        let entry = targets[index]
        guard let fid = entry.audioFileID,
              let url = AudioArchive.shared.url(for: fid) else {
            batchProgress = index + 1
            processNext(targets: targets, index: index + 1, ctx: ctx, lang: lang, model: model)
            return
        }
        rerecognizingID = entry.id
        ctx.transcribe(url: url, language: lang) { [self] text in
            rerecognizingID = nil
            let time = ctx.lastTranscriptionTime
            if let text, !text.isEmpty {
                history.updateText(id: entry.id, newText: text, modelName: model.name, recognitionTime: time)
            }
            batchProgress = index + 1
            processNext(targets: targets, index: index + 1, ctx: ctx, lang: lang, model: model)
        }
    }

    private func loadWaveform(for entry: HistoryEntry) {
        if selectedWaveformID == entry.id {
            selectedWaveformID = nil
            waveformSamples = []
            return
        }
        guard let fid = entry.audioFileID,
              let url = AudioArchive.shared.url(for: fid) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let samples = WhisperContext.loadWAVPublic(url: url) else { return }
            // ダウンサンプリング（表示用に200点に間引き）
            let targetCount = 200
            let step = max(1, samples.count / targetCount)
            var downsampled: [Float] = []
            for i in stride(from: 0, to: samples.count, by: step) {
                let end = min(i + step, samples.count)
                let chunk = samples[i..<end]
                downsampled.append(chunk.map { abs($0) }.max() ?? 0)
            }
            DispatchQueue.main.async {
                self.waveformSamples = downsampled
                self.selectedWaveformID = entry.id
            }
        }
    }
}

/// 履歴タブ用の音声再生ヘルパー
class HistoryAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false }
    }
}

/// 音声波形プレビュー
struct WaveformPreviewView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1
            let totalBars = min(samples.count, Int(size.width / (barWidth + gap)))
            let step = max(1, samples.count / totalBars)
            let midY = size.height / 2

            for i in 0..<totalBars {
                let idx = i * step
                guard idx < samples.count else { break }
                let level = CGFloat(min(samples[idx] * 8, 1.0))  // 増幅 + クランプ
                let barH = max(1, level * (size.height - 2))
                let x = CGFloat(i) * (barWidth + gap)

                let color: Color = level > 0.7 ? .orange : (level > 0.3 ? .yellow : .green)
                let rect = CGRect(x: x, y: midY - barH / 2, width: barWidth, height: barH)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(0.7)))
            }
        }
    }
}
