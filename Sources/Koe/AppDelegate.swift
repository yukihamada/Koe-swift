import AppKit
import Carbon.HIToolbox
import Speech
import UniformTypeIdentifiers
import UserNotifications
import Vision

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var overlay: OverlayWindow?
    private var settingsWC: SettingsWindowController?
    private var setupWindow: SetupWindow?
    private var transcriptionWindow: TranscriptionWindow?
    private let recorder  = AudioRecorder()
    private var speech    = SpeechEngine()
    private let typer     = AutoTyper()
    private var eventMonitor: Any?
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonTranslateHotKeyRef: EventHotKeyRef?
    private var carbonSpaceHotKeyRef: EventHotKeyRef?
    private var carbonEscHotKeyRef: EventHotKeyRef?
    private var carbonCmdKHotKeyRef: EventHotKeyRef?
    private var carbonMeetingHotKeyRef: EventHotKeyRef?
    private var carbonRerecognizeHotKeyRef: EventHotKeyRef?
    private var meetingOverlay: MeetingOverlayWindow?
    private var meetingLiveWindow: MeetingLiveWindow?
    private var meetingChatWindow: MeetingChatWindow?
    private var levelTimer: Timer?
    private var isRecording      = false
    private var recordingStart:  Date?
    private var activeAppBundleID = ""

    // Silence-based auto-stop (VAD: 直近フレームの平滑化で誤検出を低減)
    private let voiceThreshold: Float   = 0.06  // この音量以上で「発話中」（敏感に検出）
    private let silenceThreshold: Float = 0.03  // この音量以下で「無音」
    private var levelHistory: [Float] = []      // 直近フレームの音量履歴
    private let levelHistorySize = 4            // 4フレーム ≈ 133ms @ 30Hz
    private let maxRecordDuration: TimeInterval = 300  // 5分（whisper.cppは内部で30秒セグメントに分割処理）
    /// 無音閾値: 最初から設定値をそのまま使用（後半の言葉を拾い損ねない）
    private var silenceAutoStop: TimeInterval {
        return AppSettings.shared.silenceAutoStopSeconds
    }
    private var speechDetected = false
    private var silenceStart: Date?
    /// 議事録の自動録音かどうか（手動録音ならfalse → テキスト入力する）
    private var isMeetingAutoRecording = false

    // Space key extension
    private var spaceHeld    = false
    private var spacePressed = false

    // Speculative execution
    private var speculativeResult: String? = nil
    private var speculationID = 0
    // ストリーミング中の最新認識結果（投機とは独立）
    private var lastStreamingResult: String? = nil
    private var lastStreamingSampleCount = 0
    // Apple Speechで先行入力したテキスト（whisper結果で置換用）
    private var appleSpechPreliminary: String? = nil

    // Streaming preview
    private var streamingTimer: Timer?
    private var isStreamingInFlight = false

    // IME switch (left⌘→英語, right⌘→日本語)
    private var cmdPressedKeyCode: UInt16? = nil  // 押されたCmdのkeyCode (55=左, 54=右)
    private var cmdUsedAsModifier = false          // Cmd+他キーが押されたらtrue

    // 認識中フラグ（ESCでキャンセル用）
    private var isRecognizing = false

    // 議事録用: 最後の録音ファイル
    private var lastAudioURL: URL?
    private var lastArchiveID: String?

    // Quick Translation mode
    private var isTranslateMode = false

    // Shortcuts.app integration (URL scheme callback)
    private var urlSchemeCompletion: ((String) -> Void)?

    // Handoff
    private var currentActivity: NSUserActivity?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenu()
        reregisterHotkey()
        recorder.prepare()

        // マイク指向性を前方に設定 (ビームフォーミング)
        MicrophoneConfig.setFrontFacing()

        // 古い音声アーカイブを自動クリーンアップ（30日超）
        AudioArchive.shared.cleanOldFiles()

        // クラッシュで中断した議事録を復旧
        MeetingMode.shared.recoverIfNeeded()

        // カレンダー監視: 会議の1分前に自動で議事録開始
        if AppSettings.shared.calendarAutoStart {
            MeetingIntegrations.shared.startCalendarMonitoring { [weak self] event in
                guard let self, !MeetingMode.shared.isActive else { return }
                klog("Calendar: auto-starting meeting mode for '\(event.title ?? "?")'")
                DispatchQueue.main.async { self.toggleMeetingMode() }
            }
        }

        // Register URL scheme handler for Shortcuts.app integration (koe://transcribe)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // 8GB未満のMacではローカルLLMを自動無効化
        MemoryMonitor.autoDisableLocalLLMIfNeeded()

        // インストール/アップデート後に必ずオンボーディングを表示
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let lastSeenVersion = UserDefaults.standard.string(forKey: "lastOnboardingVersion") ?? ""
        let isNewVersion = lastSeenVersion != currentVersion
        let needsSetup = !ModelDownloader.shared.isModelAvailable || isNewVersion

        if needsSetup {
            UserDefaults.standard.set(currentVersion, forKey: "lastOnboardingVersion")
            setupWindow = SetupWindow()
            setupWindow?.show { [weak self] in
                self?.setupWindow = nil
                self?.finishLaunch()
            }
        } else {
            finishLaunch()
        }

        // アクセシビリティ権限がない場合のログ（設定画面は checkAccessibility() で処理）
        if !AXIsProcessTrusted() {
            klog("Accessibility not granted — clipboard-only mode (auto-paste disabled)")
        }
    }

    private func finishLaunch() {
        speech.requestPermissions()
        loadEmbeddedWhisper()

        // iPhone連携: AgentMode判定 → 画面AI or テキスト入力
        IPhoneBridge.shared.start { [weak self] text in
            guard let self else { return }
            klog("IPhoneBridge: received from iPhone: '\(String(text.prefix(60)))'")
            let settings = AppSettings.shared

            // AgentMode: 音声コマンド判定（高速マッチ → LLMフォールバック）
            if settings.agentModeEnabled {
                let executeCommand = { (command: AgentCommand) in
                    klog("IPhoneBridge: agent command — \(command.description)")
                    self.overlay?.show(state: .recognizing)
                    AgentMode.shared.execute(command) { [weak self] result in
                        DispatchQueue.main.async {
                            self?.overlay?.hide()
                            klog("IPhoneBridge: agent result — \(result.prefix(60))")
                            self?.sendNotification(text: "📱🤖 \(result.prefix(50))")
                        }
                    }
                }

                // 高速マッチ
                if let command = AgentMode.shared.detectCommand(text) {
                    executeCommand(command)
                    return
                }

                // LLMインテント判定
                if settings.voiceControlEnabled {
                    AgentMode.shared.detectCommandAsync(text) { command in
                        if let command {
                            executeCommand(command)
                        } else {
                            // コマンドではない → 通常テキスト入力
                            let typeAndEnter = { (finalText: String) in
                                self.typer.typeInto(finalText, bundleID: "")
                                if settings.iphoneBridgeAutoEnter {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.typer.postReturn() }
                                }
                                self.sendNotification(text: "📱→ \(String(finalText.prefix(30)))")
                            }
                            typeAndEnter(text)
                        }
                    }
                    return
                }
            }

            // 通常テキスト入力
            let typeAndEnter = { (finalText: String) in
                self.typer.typeInto(finalText, bundleID: "")
                if settings.iphoneBridgeAutoEnter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.typer.postReturn()
                    }
                }
                self.sendNotification(text: "📱→ \(String(finalText.prefix(30)))")
            }

            if settings.iphoneBridgeLLM && settings.llmEnabled {
                let instruction = settings.llmMode == .none ? "" : settings.llmMode.instruction
                LLMProcessor.shared.process(text: text, instruction: instruction, appBundleID: "") { processed in
                    typeAndEnter(processed)
                }
            } else {
                typeAndEnter(text)
            }
        }
        IPhoneBridge.shared.onEnter = { [weak self] in
            klog("IPhoneBridge: Enter key from iPhone")
            self?.typer.postReturn()
        }
        IPhoneBridge.shared.onBackspace = { [weak self] count in
            guard let self else { return }
            let clamped = min(max(count, 0), 500) // セキュリティ: 最大500文字に制限
            for _ in 0..<clamped {
                self.postKeyCombo(key: 0x33, modifiers: []) // 0x33 = Delete/Backspace
            }
        }
        IPhoneBridge.shared.onStreamingText = { [weak self] text in
            self?.typer.typeStreaming(text, bundleID: "")
        }
        IPhoneBridge.shared.onCommand = { [weak self] command in
            klog("IPhoneBridge: command from iPhone: \(command)")
            guard let self else { return }
            switch command {
            case "undo":
                self.typer.postUndo()
            case "selectAll":
                self.typer.postSelectAllDelete()
            case "tab":
                self.typer.postTab()
            case "backspace":
                break // Handled separately via onBackspace
            case "nextTab":
                self.postKeyCombo(key: 0x30, modifiers: .maskControl)
            case "prevTab":
                self.postKeyCombo(key: 0x30, modifiers: [.maskControl, .maskShift])
            case "copy":
                self.postKeyCombo(key: 0x08, modifiers: .maskCommand) // ⌘C
            case "paste":
                self.postKeyCombo(key: 0x09, modifiers: .maskCommand) // ⌘V
            case "closeWindow":
                self.postKeyCombo(key: 0x0D, modifiers: .maskCommand) // ⌘W
            case "space":
                self.postKeyCombo(key: 0x31, modifiers: [])
            case "click":
                IPhoneBridge.shared.postMouseClick(button: .left)
            case "rightClick":
                IPhoneBridge.shared.postMouseClick(button: .right)
            case "scroll":
                IPhoneBridge.shared.postScroll(dy: -3)
            case "scrollUp":
                IPhoneBridge.shared.postScroll(dy: 3)
            case "escape":
                self.postKeyCombo(key: 0x35, modifiers: []) // ESC
            case "appSwitch":
                self.postKeyCombo(key: 0x30, modifiers: .maskCommand) // ⌘Tab
            case "missionControl":
                self.postKeyCombo(key: 0x7E, modifiers: .maskControl) // ⌃↑
            case "volumeUp":
                AgentMode.shared.execute(.volumeUp) { _ in }
            case "volumeDown":
                AgentMode.shared.execute(.volumeDown) { _ in }
            default:
                klog("IPhoneBridge: unknown command '\(command)'")
            }
        }

        // Send active Mac app info to iPhone
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                IPhoneBridge.shared.sendActiveApp(
                    bundleID: app.bundleIdentifier ?? "",
                    name: app.localizedName ?? ""
                )
            }
        }

        WakeWordDetector.shared.onDetected = { [weak self] in self?.startRecording() }
        if AppSettings.shared.wakeWordEnabled { WakeWordDetector.shared.start() }
        if AppSettings.shared.floatingButtonEnabled { FloatingButton.shared.show() }

        // ログイン時自動起動を設定に従って登録
        if AppSettings.shared.launchAtLogin {
            LoginItemManager.setEnabled(true)
        }

        // 起動後3秒でアップデート確認（サイレント）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AutoUpdater.shared.checkForUpdates(silent: true)
        }

        // 4時間ごとに定期アップデート確認
        Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in
            AutoUpdater.shared.checkForUpdates(silent: true)
        }

        // アクセシビリティ権限の確認・プロンプト（IME切替・自動入力に必要）
        checkAccessibility()
    }

    /// 組み込み whisper.cpp モデルのロード。モデルがなければダウンロード。
    /// Intel Mac では whisper.cpp (Metal) が使えないため、Apple オンデバイス認識にフォールバック。
    private func loadEmbeddedWhisper() {
        // Intel Mac: whisper.cpp (Metal GPU) は非対応 → オンデバイス認識にフォールバック
        if !ArchUtil.isAppleSilicon {
            let settings = AppSettings.shared
            if settings.recognitionEngine == .whisperCpp {
                klog("Intel Mac detected — switching from whisper.cpp to Apple on-device recognition")
                settings.recognitionEngine = .appleOnDevice
            }
            // 通知でユーザーに知らせる
            let content = UNMutableNotificationContent()
            content.title = "Koe"
            content.body = "Intel Mac ではクラウドまたはオンデバイス認識を使用します（whisper.cpp Metal は Apple Silicon 専用です）"
            let request = UNNotificationRequest(identifier: "intel-fallback", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            return
        }

        // 設定にパスがあればそちらを使う、なければデフォルトパス
        let settings = AppSettings.shared
        let modelPath: String
        if !settings.whisperCppModelPath.isEmpty,
           FileManager.default.fileExists(atPath: settings.whisperCppModelPath) {
            modelPath = settings.whisperCppModelPath
        } else if ModelDownloader.shared.isModelAvailable {
            modelPath = ModelDownloader.shared.modelPath
            // 設定にも保存しておく
            settings.whisperCppModelPath = modelPath
        } else {
            // モデルが無い → ダウンロード提案（バックグラウンドでサーバーも起動）
            WhisperServer.shared.start()
            ModelDownloader.shared.ensureModel { [weak self] ok in
                guard ok else { return }
                settings.whisperCppModelPath = ModelDownloader.shared.modelPath
                self?.loadEmbeddedWhisper()  // 再帰して読み込み
            }
            return
        }

        klog("Loading embedded whisper model: \(modelPath)")
        WhisperContext.shared.loadModel(path: modelPath) { ok in
            if ok {
                klog("Embedded whisper ready — HTTP server not needed")
                // サーバーは不要になったので起動しない
            } else {
                klog("Embedded whisper failed, falling back to server")
                WhisperServer.shared.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperServer.shared.stop()
        WakeWordDetector.shared.stop()
    }

    // MARK: - Status Bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "Koe — 声で入力"
        setIcon(recording: false)
        rebuildMenu()

        // ドラッグ&ドロップ: 音声ファイルをメニューバーアイコンにドロップで文字起こし
        statusItem.button?.registerForDraggedTypes([.fileURL])
        let dropDelegate = StatusBarDropDelegate(appDelegate: self)
        // DropDelegateをretainしておく
        objc_setAssociatedObject(statusItem.button!, "dropDelegate", dropDelegate, .OBJC_ASSOCIATION_RETAIN)
        statusItem.button?.wantsLayer = true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let s = AppSettings.shared
        let badge = s.recognitionEngine.isLocal ? "LOCAL" : "CLOUD"

        // ステータスヘッダー (コンパクト)
        let header = NSMenuItem(title: "\(s.languageFlag) \(s.shortcutDisplayString) · \(badge)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // 言語切替 (メニューバー用: よく使う言語のみ)
        for lang in s.menuBarLanguages {
            let item = NSMenuItem(title: "\(lang.flag) \(lang.name)", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            item.state = (s.language == lang.code) ? .on : .off
            menu.addItem(item)
        }
        // その他の言語 (サブメニュー)
        let others = s.otherLanguages
        if !others.isEmpty {
            let otherMenu = NSMenu()
            for lang in others {
                let item = NSMenuItem(title: "\(lang.flag) \(lang.name)", action: #selector(selectLanguage(_:)), keyEquivalent: "")
                item.representedObject = lang.code
                item.state = (s.language == lang.code) ? .on : .off
                otherMenu.addItem(item)
            }
            let otherItem = NSMenuItem(title: L10n.menuOtherLanguages, action: nil, keyEquivalent: "")
            otherItem.submenu = otherMenu
            menu.addItem(otherItem)
        }
        menu.addItem(.separator())

        // LLMモード
        let modeMenu = NSMenu()
        for mode in LLMMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectLLMMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (s.llmMode == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeLabel = L10n.menuLLMLabel(mode: s.llmMode.displayName, isOff: s.llmMode == .none)
        let modeItem = NSMenuItem(title: modeLabel, action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let transItem = NSMenuItem(title: "\(L10n.menuTranslation) \(s.translateShortcutDisplayString)", action: nil, keyEquivalent: "")
        transItem.isEnabled = false
        menu.addItem(transItem)
        menu.addItem(.separator())

        // ツール
        let meetingTitle = MeetingMode.shared.isActive
            ? L10n.menuMeetingStop(count: MeetingMode.shared.entryCount)
            : L10n.menuMeetingStart
        menu.addItem(withTitle: meetingTitle, action: #selector(toggleMeetingMode), keyEquivalent: "m")
        menu.addItem(withTitle: L10n.menuFileTranscription, action: #selector(openFileTranscription), keyEquivalent: "t")
        menu.addItem(.separator())

        menu.addItem(withTitle: "📱 iPhone版を入手 (TestFlight)", action: #selector(openTestFlight), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        statusItem.button?.contentTintColor = recording ? .systemRed : .labelColor
        if AppSettings.shared.floatingButtonEnabled {
            FloatingButton.shared.setRecording(recording)
        }
    }

    // MARK: - Accessibility check

    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        klog("Accessibility trusted: \(trusted)")
        if trusted { return }

        // システムのアクセシビリティプロンプトを1回だけ表示（kAXTrustedCheckOptionPrompt）
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        // カスタムアラートは初回インストール時のみ（UserDefaultsで制御）
        let key = "koe_accessibility_alert_shown"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = L10n.accessibilityAlertTitle
                alert.informativeText = L10n.accessibilityRequiredAlert
                alert.alertStyle = .informational
                alert.addButton(withTitle: L10n.openSystemSettings)
                alert.addButton(withTitle: L10n.later)
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // バックグラウンドで権限付与を待つ（max 5分）
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<300 {
                if AXIsProcessTrusted() {
                    klog("Accessibility granted")
                    DispatchQueue.main.async { self?.reregisterHotkey() }
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            klog("Accessibility polling timed out (5min)")
        }
    }

    // MARK: - Hotkey

    func reregisterHotkey() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        let settings = AppSettings.shared

        // Carbon Hot Key API でメインホットキーを登録（アクセシビリティ不要）
        registerCarbonHotKey(settings: settings)

        // Global monitor は補助機能用 (IME切替, modifier release) — アクセシビリティ必要
        // Space/ESC は Carbon Hot Key で処理するため monitor がなくても基本機能は動作
        if AXIsProcessTrusted() {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged]
            ) { [weak self] event in
                self?.handleEvent(event, settings: settings)
            }
        } else {
            klog("Skipping global event monitor (no accessibility)")
        }
        rebuildMenu()
        klog("Hotkey registered: \(settings.shortcutDisplayString)")
    }

    // MARK: - Carbon Hot Key (アクセシビリティ不要)

    private func registerCarbonHotKey(settings: AppSettings) {
        // 既存のCarbon Hot Keyを解除
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
        if let ref = carbonTranslateHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonTranslateHotKeyRef = nil
        }

        // Carbon modifier変換
        func carbonMods(_ nsMods: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if nsMods.contains(.command) { m |= UInt32(cmdKey) }
            if nsMods.contains(.option)  { m |= UInt32(optionKey) }
            if nsMods.contains(.control) { m |= UInt32(controlKey) }
            if nsMods.contains(.shift)   { m |= UInt32(shiftKey) }
            return m
        }

        // イベントハンドラをインストール（初回のみ）
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let delegate = AppDelegate.shared else { return noErr }
            let settings = AppSettings.shared
            let isToggle = settings.recordingMode == .toggle

            if hotKeyID.id == 1 || hotKeyID.id == 5 {
                // メインホットキー or ⌘K pressed
                DispatchQueue.main.async {
                    // 議事録自動録音中にホットキー → 自動録音を中断して手動録音に切替
                    if delegate.isRecording && delegate.isMeetingAutoRecording && MeetingMode.shared.isActive {
                        delegate.cancelRecording()
                        delegate.isMeetingAutoRecording = false
                        delegate.startRecording()
                    } else if isToggle {
                        delegate.isRecording ? delegate.stopAndRecognize() : delegate.startRecording()
                    } else if !delegate.isRecording {
                        delegate.isMeetingAutoRecording = false
                        delegate.startRecording()
                    }
                }
            } else if hotKeyID.id == 2 {
                // 翻訳ホットキー pressed
                DispatchQueue.main.async {
                    if delegate.isRecording && delegate.isTranslateMode {
                        delegate.stopAndRecognize()
                    } else if !delegate.isRecording {
                        delegate.isTranslateMode = true
                        delegate.overlay?.setTranslateMode(true)
                        klog("Translate mode: ON")
                        delegate.startRecording()
                    }
                }
            } else if hotKeyID.id == 3 {
                // Space pressed (録音中のみ登録される)
                DispatchQueue.main.async {
                    guard delegate.isRecording else { return }
                    if delegate.spacePressed {
                        // 2回目のスペース → 変換
                        delegate.stopAndRecognize()
                    } else {
                        // 1回目 → 延長
                        delegate.spacePressed = true
                        delegate.spaceHeld = true
                        delegate.silenceStart = nil
                        klog("Space: recording extended (Carbon)")
                    }
                }
            } else if hotKeyID.id == 6 {
                // ⌥⌘M pressed → 議事録トグル
                DispatchQueue.main.async { delegate.toggleMeetingMode() }
            } else if hotKeyID.id == 7 {
                // ⌃⌥R pressed → 直前の認識をやり直す
                DispatchQueue.main.async { delegate.rerecognizeLast() }
            } else if hotKeyID.id == 4 {
                // ESC pressed → キャンセル
                DispatchQueue.main.async {
                    if delegate.isRecording || delegate.isRecognizing {
                        delegate.cancelRecording()
                    }
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        // keyUp用ハンドラも追加（hold mode用）
        var eventTypeUp = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let delegate = AppDelegate.shared else { return noErr }
            let isToggle = AppSettings.shared.recordingMode == .toggle

            if (hotKeyID.id == 1 || hotKeyID.id == 5) && !isToggle && delegate.isRecording {
                delegate.stopAndRecognize()
            } else if hotKeyID.id == 2 && !isToggle && delegate.isRecording && delegate.isTranslateMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
                    guard delegate.isRecording else { return }
                    delegate.stopAndRecognize()
                }
            } else if hotKeyID.id == 3 && delegate.isRecording && delegate.spaceHeld {
                // Space released → 変換
                DispatchQueue.main.async {
                    delegate.spaceHeld = false
                    delegate.stopAndRecognize()
                }
            }
            return noErr
        }, 1, &eventTypeUp, nil, nil)

        // メインホットキー登録
        let mainMods = carbonMods(NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers))
        var mainID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 1) // "Koe\0"
        let mainStatus = RegisterEventHotKey(UInt32(settings.shortcutKeyCode), mainMods,
                                              mainID, GetApplicationEventTarget(), 0, &carbonHotKeyRef)
        klog("Carbon hotkey main: status=\(mainStatus)")

        // 翻訳ホットキー登録
        let transMods = carbonMods(NSEvent.ModifierFlags(rawValue: settings.translateHotkeyModifiers))
        var transID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 2)
        let transStatus = RegisterEventHotKey(UInt32(settings.translateHotkeyCode), transMods,
                                               transID, GetApplicationEventTarget(), 0, &carbonTranslateHotKeyRef)
        klog("Carbon hotkey translate: status=\(transStatus)")

        // ⌃K ショートカット（追加のクイック起動キー）
        if let ref = carbonCmdKHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonCmdKHotKeyRef = nil
        }
        var ctrlKID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 5)
        let ctrlKStatus = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey),
                                               ctrlKID, GetApplicationEventTarget(), 0, &carbonCmdKHotKeyRef)
        klog("Carbon hotkey ⌃K: status=\(ctrlKStatus)")

        // ⌥⌘M 議事録トグル
        if let ref = carbonMeetingHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonMeetingHotKeyRef = nil
        }
        var meetingID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 6)
        let meetingStatus = RegisterEventHotKey(UInt32(kVK_ANSI_M),
                                                 UInt32(cmdKey | optionKey),
                                                 meetingID, GetApplicationEventTarget(), 0, &carbonMeetingHotKeyRef)
        klog("Carbon hotkey ⌥⌘M: status=\(meetingStatus)")

        // ⌃⌥R 直前の認識をやり直す
        if let ref = carbonRerecognizeHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonRerecognizeHotKeyRef = nil
        }
        var rerecID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 7)
        let rerecStatus = RegisterEventHotKey(UInt32(kVK_ANSI_R),
                                               UInt32(controlKey | optionKey),
                                               rerecID, GetApplicationEventTarget(), 0, &carbonRerecognizeHotKeyRef)
        klog("Carbon hotkey ⌃⌥R: status=\(rerecStatus)")
    }

    /// 録音中のみ有効な Space/ESC ホットキーを登録
    private func registerRecordingHotKeys() {
        // Space (keyCode=49) — modifier なし
        var spaceID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 3)
        RegisterEventHotKey(UInt32(49), 0, spaceID, GetApplicationEventTarget(), 0, &carbonSpaceHotKeyRef)
        // ESC (keyCode=53) — modifier なし
        var escID = EventHotKeyID(signature: OSType(0x4B6F6500), id: 4)
        RegisterEventHotKey(UInt32(53), 0, escID, GetApplicationEventTarget(), 0, &carbonEscHotKeyRef)
    }

    /// 録音終了時に Space/ESC ホットキーを解除
    private func unregisterRecordingHotKeys() {
        if let ref = carbonSpaceHotKeyRef { UnregisterEventHotKey(ref); carbonSpaceHotKeyRef = nil }
        if let ref = carbonEscHotKeyRef { UnregisterEventHotKey(ref); carbonEscHotKeyRef = nil }
    }

    private func handleEvent(_ event: NSEvent, settings: AppSettings) {
        let targetCode = UInt16(settings.shortcutKeyCode)
        let targetMods = NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers)
        let isToggle = settings.recordingMode == .toggle

        // Translation hotkey detection
        let transCode = UInt16(settings.translateHotkeyCode)
        let transMods = NSEvent.ModifierFlags(rawValue: settings.translateHotkeyModifiers)

        // IME切替: Cmdが押されている間に他キーが押されたらmodifier使用とみなす
        if settings.cmdIMESwitchEnabled {
            handleCmdIME(event)
        }

        switch event.type {
        case .keyDown:
            // Cmd+他キーが押された → modifier使用フラグ
            if cmdPressedKeyCode != nil { cmdUsedAsModifier = true }

            // ESC → キャンセル（録音中 or 認識中）
            if event.keyCode == 53, (isRecording || isRecognizing) {
                DispatchQueue.main.async { self.cancelRecording() }; return
            }
            // Space → 録音延長 or 2回目で変換（ただしSpaceがホットキーの場合は除外）
            if event.keyCode == 49, targetCode != 49, isRecording, !event.isARepeat {
                if spacePressed {
                    // 2回目のスペース → 変換
                    DispatchQueue.main.async { self.stopAndRecognize() }
                } else {
                    // 1回目 → 無音タイマーをリセットして延長開始
                    spacePressed = true
                    spaceHeld    = true
                    silenceStart = nil
                    klog("Space: recording extended")
                }
                return
            }

            // Translation hotkey (toggle mode: press to start, press again to stop)
            if event.keyCode == transCode, !event.isARepeat {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == transMods {
                    DispatchQueue.main.async {
                        if self.isRecording && self.isTranslateMode {
                            self.stopAndRecognize()
                        } else if !self.isRecording {
                            self.isTranslateMode = true
                            self.overlay?.setTranslateMode(true)
                            klog("Translate mode: ON")
                            self.startRecording()
                        }
                    }
                    return
                }
            }

            guard event.keyCode == targetCode, !event.isARepeat else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == targetMods else { return }
            if isToggle {
                DispatchQueue.main.async { self.isRecording ? self.stopAndRecognize() : self.startRecording() }
            } else {
                guard !isRecording else { return }
                DispatchQueue.main.async { self.startRecording() }
            }
        case .keyUp:
            // Space 離した → 変換（ただしSpaceがホットキーの場合は除外）
            if event.keyCode == 49, targetCode != 49, isRecording, spaceHeld {
                spaceHeld = false
                DispatchQueue.main.async { self.stopAndRecognize() }
                return
            }
            // Translation hotkey release (hold mode): stop recording
            if event.keyCode == transCode, isRecording, isTranslateMode {
                // hold mode behavior for translate hotkey
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !flags.contains(transMods) || event.keyCode == transCode {
                    // Only auto-stop on key-up if main recording mode is hold
                    if !isToggle {
                        DispatchQueue.main.async { self.stopAndRecognize() }
                        return
                    }
                }
            }
            guard !isToggle, event.keyCode == targetCode, isRecording else { return }
            DispatchQueue.main.async { self.stopAndRecognize() }
        case .flagsChanged:
            guard !isToggle, isRecording, !targetMods.isEmpty else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(targetMods) { DispatchQueue.main.async { self.stopAndRecognize() } }
        default: break
        }
    }

    // MARK: - IME Switch (左⌘→英語, 右⌘→日本語)

    private func handleCmdIME(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let flags = event.modifierFlags
        let code = event.keyCode

        // keyCode 55 = 左⌘, 54 = 右⌘
        guard code == 55 || code == 54 else { return }

        let cmdDown = flags.contains(.command)

        if cmdDown {
            // Cmd押下開始
            cmdPressedKeyCode = code
            cmdUsedAsModifier = false
        } else if let pressed = cmdPressedKeyCode {
            // Cmd離した
            cmdPressedKeyCode = nil
            if !cmdUsedAsModifier {
                // 単独タップ → IME切替
                let toJapanese = (pressed == 54)
                klog("IME switch: \(toJapanese ? "→日本語 (右⌘)" : "→英語 (左⌘)")")
                switchInputSource(toJapanese: toJapanese)
            }
            cmdUsedAsModifier = false
        }
    }

    private func switchInputSource(toJapanese: Bool) {
        // AppleScript経由でIME切替（TISSelectInputSourceはmacOS 13+で不安定）
        let keyCode = toJapanese ? 104 : 102  // 104=F13(かな), 102=F11 — 実際はAppleScript
        // CGEvent でKeyDown/Upをシミュレート: かなキー=0x68, 英数キー=0x66
        let kanaKeyCode: CGKeyCode = toJapanese ? 0x68 : 0x66
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: kanaKeyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: kanaKeyCode, keyDown: false) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return
        }
        // フォールバック: TIS API
        let filter = [kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        for source in sources {
            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String

            if toJapanese {
                if sourceID.contains("Japanese") || sourceID.contains("Hiragana") || sourceID.contains("Kana") {
                    TISSelectInputSource(source)
                    klog("IME TIS fallback → \(sourceID)")
                    return
                }
            } else {
                if sourceID.contains("ABC") || sourceID.contains(".US") || sourceID.contains("Roman") || sourceID.contains("Alphanumeric") {
                    TISSelectInputSource(source)
                    klog("IME TIS fallback → \(sourceID)")
                    return
                }
            }
        }
        klog("IME switch failed: no matching input source found")
    }

    // MARK: - Recording

    private func startRecording() {
        // Stop wake word detector before AVAudioRecorder starts to avoid conflicts
        WakeWordDetector.shared.stop()

        // Capture frontmost app BEFORE recording starts
        activeAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        klog("startRecording from app: \(activeAppBundleID)")
        isRecording    = true
        lastStreamingResult = nil
        lastStreamingSampleCount = 0
        recordingStart = Date()
        speechDetected = false
        silenceStart   = nil
        levelHistory   = []
        spaceHeld        = false
        spacePressed     = false
        speculativeResult = nil
        speculationID    += 1  // 前回の投機を無効化
        setIcon(recording: true)
        if !isMeetingAutoRecording {
            if overlay == nil { overlay = OverlayWindow() }
            overlay?.show(state: .recording)
        }
        recorder.start()
        registerRecordingHotKeys()  // Space/ESC を Carbon Hot Key で登録
        isStreamingInFlight = false
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let lvl = self.recorder.currentLevel()
            self.overlay?.updateLevel(lvl)
            self.updateSilenceDetection(level: lvl)
        }
        startStreamingPreview()
    }

    private func stopAndRecognize() {
        guard isRecording else { return }  // 二重呼び出し防止
        unregisterRecordingHotKeys()  // Space/ESC 解除
        levelTimer?.invalidate(); levelTimer = nil
        streamingTimer?.invalidate(); streamingTimer = nil
        // Apple Speech ストリーミングを終了
        streamingRecognitionRequest?.endAudio()
        streamingRecognitionTask?.cancel()
        streamingRecognitionRequest = nil
        streamingRecognitionTask = nil
        overlay?.updateLevel(0)
        overlay?.clearStreamingText()
        klog("stopAndRecognize")
        isRecording = false
        setIcon(recording: false)

        guard let audioURL = recorder.stop() else {
            overlay?.hide(); return
        }

        // 音声がなければスキップ（無音録音を認識エンジンに渡さない）
        if let wavSamples = WhisperContext.loadWAVPublic(url: audioURL),
           !AudioDSP.hasVoice(wavSamples, threshold: 0.003, minVoiceFrames: 3) {
            klog("stopAndRecognize: no voice detected, skipping recognition")
            overlay?.hide()
            // 議事録モード中は無音でも自動録音ループを継続
            if MeetingMode.shared.isActive {
                postRecognitionCleanup()
                return
            }
            if AppSettings.shared.wakeWordEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WakeWordDetector.shared.start() }
            }
            return
        }

        lastAudioURL = audioURL
        // 認識前に音声を永続保存（認識失敗しても音声は残る）
        lastArchiveID = AudioArchive.shared.save(tempURL: audioURL)
        if !isMeetingAutoRecording {
            overlay?.clearHint()
            overlay?.show(state: .recognizing)
        }
        isRecognizing = true

        // 議事録自動録音中は認識と並行して即録音再開（音声の取りこぼし防止）
        if isMeetingAutoRecording && MeetingMode.shared.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, MeetingMode.shared.isActive, !self.isRecording else { return }
                klog("MeetingMode: parallel recording start")
                self.startRecording()
            }
        }

        let profile = AppSettings.shared.profile(for: activeAppBundleID)

        // コンテキスト収集（アプリ名・ウィンドウ・クリップボード・選択テキスト）
        let contextPrompt = ContextCollector.collect(
            appBundleID: activeAppBundleID,
            profilePrompt: profile?.prompt ?? ""
        )
        klog("Context prompt: '\(String(contextPrompt.prefix(100)))'")

        // 議事録モード: Apple Speechのストリーミング結果を優先（Whisperより圧倒的に速い）
        if MeetingMode.shared.isActive, let streamingText = lastStreamingResult, !streamingText.isEmpty {
            isRecognizing = false
            overlay?.hide()
            lastStreamingResult = nil
            klog("Meeting: using Apple Speech result '\(streamingText.prefix(40))'")
            HistoryStore.shared.add(streamingText, audioFileID: lastArchiveID,
                                   recognitionTime: 0, modelName: "Apple Speech")
            MeetingMode.shared.append(text: streamingText, audioURL: lastAudioURL)
            meetingOverlay?.updateLastText(streamingText)
            meetingLiveWindow?.appendText(streamingText)
            postRecognitionCleanup()
            return
        }

        // 議事録モード + 話者分離が有効な場合、speaker-aware transcription を使用
        // （議事録モードではApple Speechが優先されるので、ここに来るのはストリーミング結果がない場合のみ）
        if !isMeetingAutoRecording && MeetingMode.shared.isActive,
           AppSettings.shared.diarizationEnabled,
           WhisperContext.shared.isLoaded {
            let rawLang = (profile?.language.isEmpty == false ? profile!.language : AppSettings.shared.language)
            let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "en")
            WhisperContext.shared.transcribeWithSpeakers(url: audioURL, language: lang, prompt: contextPrompt) { [weak self] segments in
                guard let self else { return }
                self.isRecognizing = false
                self.overlay?.hide()
                if !segments.isEmpty {
                    let fullText = segments.map { $0.text }.joined()
                    klog("diarize result: \(segments.count) segments, \(Set(segments.map { $0.speaker }).count) speakers")
                    HistoryStore.shared.add(fullText, audioFileID: self.lastArchiveID,
                                           recognitionTime: WhisperContext.shared.lastTranscriptionTime,
                                           modelName: ModelDownloader.shared.currentModel.name)
                    MeetingMode.shared.appendSpeakerSegments(segments, audioURL: self.lastAudioURL)
                    self.meetingOverlay?.updateLastText(fullText)
                    // リアルタイムウィンドウに話者別で追加
                    for seg in segments {
                        self.meetingLiveWindow?.appendText(seg.text, speaker: seg.speaker)
                    }
                    // 議事録自動録音中はファイル保存のみ（テキスト入力しない）
                    if !self.isMeetingAutoRecording {
                        if AppSettings.shared.streamingPreviewEnabled {
                            self.typer.typeInto(fullText, bundleID: self.activeAppBundleID)
                        } else {
                            self.typer.finalizeStreaming(fullText, bundleID: self.activeAppBundleID)
                        }
                    }
                    CorrectionStore.shared.trackDelivery(original: fullText, appBundleID: self.activeAppBundleID)
                    self.publishHandoffActivity(text: fullText)
                    if AppSettings.shared.autoCopyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullText, forType: .string)
                    }
                    if AppSettings.shared.notifyOnComplete {
                        self.sendNotification(text: fullText)
                    }
                }
                self.postRecognitionCleanup()
            }
            return
        }

        // Apple Speechの結果を先に入力（即時フィードバック）
        if let streaming = lastStreamingResult {
            klog("Apple Speech result: '\(streaming)'")
            lastStreamingResult = nil
            speculativeResult = nil
            // 先にApple Speechの結果を入力
            let streamingExpanded = AppSettings.shared.expand(streaming)
            self.typer.typeInto(streamingExpanded, bundleID: self.activeAppBundleID)
            appleSpechPreliminary = streamingExpanded
        }

        // 投機実行の結果がすでに届いていればそれを使う（whisper呼び出しをスキップ）
        if let cached = speculativeResult {
            klog("Speculation: cache hit '\(cached)'")
            speculativeResult = nil
            handleRecognitionResult(cached, profile: profile)
            return
        }

        // 投機実行が進行中なら完了まで待つ（上書きコールバック方式）
        let myID = speculationID
        speech.recognize(url: audioURL,
                         prompt: contextPrompt,
                         languageOverride: profile?.language ?? "") { [weak self] raw in
            guard let self, self.speculationID == myID else { return }
            self.handleRecognitionResult(raw, profile: profile)
        }
    }

    private func handleRecognitionResult(_ raw: String, profile: AppProfile?) {
        isRecognizing = false
        let recordingDuration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0

        // Whisperが返す改行を除去（音声フォーマットコマンドで明示的に挿入する）
        let cleaned = raw.replacingOccurrences(of: "\n", with: " ")
                         .replacingOccurrences(of: "\r", with: "")
                         .trimmingCharacters(in: .whitespaces)

        // 空や無意味な認識結果はスキップ（ノイズ誤認識防止）
        if cleaned.isEmpty || cleaned.count <= 1 || cleaned.allSatisfy({ $0.isPunctuation || $0.isWhitespace || $0 == "." || $0 == "。" }) {
            klog("handleRecognitionResult: skipping empty/noise result: '\(cleaned)'")
            overlay?.hide()
            postRecognitionCleanup()
            return
        }

        // フィラーワード除去（えー、あの、えっと等）
        let defillered: String
        if AppSettings.shared.fillerRemovalEnabled {
            defillered = VoiceCommands.removeFillers(cleaned, language: AppSettings.shared.language)
            if defillered != cleaned {
                klog("FillerRemoval: '\(cleaned)' → '\(defillered)'")
            }
        } else {
            defillered = cleaned
        }

        let expanded = AppSettings.shared.expand(defillered)
        // 音声フォーマットコマンドを適用（「改行」→\n、「句読点」→。等）
        var formatted = VoiceCommands.applyFormatting(expanded)

        // 句読点スタイル変換
        if let style = VoiceCommands.PunctuationStyle(rawValue: AppSettings.shared.punctuationStyle) {
            formatted = VoiceCommands.applyPunctuationStyle(formatted, style: style)
        }

        // 議事録音声コマンド: 「ここ重要」等
        if MeetingMode.shared.isActive, let meetingCmd = VoiceCommands.detectMeetingCommand(formatted) {
            switch meetingCmd {
            case .markImportant:
                klog("MeetingCommand: mark important")
                meetingLiveWindow?.markImportant()
                // 重要マーク付きで議事録に追記
                MeetingMode.shared.append(text: "★ \(formatted)", audioURL: lastAudioURL)
                meetingOverlay?.updateLastText("★ \(formatted)")
                meetingLiveWindow?.appendText("★ \(formatted)")
            }
            overlay?.hide()
            postRecognitionCleanup()
            return
        }

        // 音声編集コマンド: 「削除」「取り消し」等
        if let editCmd = VoiceCommands.detectEditCommand(formatted) {
            switch editCmd {
            case .undo:
                klog("VoiceCommand: undo")
                typer.postUndo()
            case .deleteAll:
                klog("VoiceCommand: deleteAll")
                typer.postSelectAllDelete()
            }
            overlay?.hide()
            postRecognitionCleanup()
            return
        }

        // Command Mode: 選択テキストの書き換え指示を検出
        if AppSettings.shared.commandModeEnabled,
           let cmdAction = VoiceCommands.detectCommandMode(formatted) {
            switch cmdAction {
            case .rewrite(let prompt):
                klog("CommandMode: rewrite with prompt")
                handleCommandModeRewrite(prompt: prompt)
            }
            return
        }

        // Agent mode: detect and execute voice commands instead of typing
        if AppSettings.shared.agentModeEnabled {
            // まず高速文字列マッチ
            if let command = AgentMode.shared.detectCommand(formatted) {
                klog("Agent: detected command (fast) — \(command.description)")
                if !isMeetingAutoRecording { overlay?.show(state: .recognizing) }
                AgentMode.shared.execute(command) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.overlay?.hide()
                        klog("Agent result: '\(result)'")
                        HistoryStore.shared.add("[\(command.description)] \(result)")
                        self.sendNotification(text: result)
                        self.postRecognitionCleanup()
                    }
                }
                return
            }
            // 文字列マッチで検出できない場合 → テキスト入力を先に行い、LLMインテント判定は裏で実行
            // （LLM判定に5秒以上かかり体感が遅くなるため、入力優先）
            if AppSettings.shared.voiceControlEnabled {
                klog("Agent: fast-path text input, LLM intent check in background")
            }
        }

        handleRecognitionAsText(formatted, profile: profile)
    }

    /// 通常のテキスト入力処理（エージェントモードで非コマンドと判定された場合のフォールバック）
    private func handleRecognitionAsText(_ formatted: String, profile: AppProfile?) {
        let recordingDuration = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        // Quick Translation mode: force LLM to translate regardless of current mode
        let instruction: String
        if isTranslateMode {
            let targetLang = AppSettings.shared.translateTargetLang
            let langName = targetLang.hasPrefix("ja") ? "日本語" : (targetLang.hasPrefix("en") ? "English" : targetLang)
            instruction = """
            音声認識の結果を\(langName)に翻訳してください：
            - 意味を正確に保つ
            - 自然な表現に翻訳
            - 翻訳後のテキストのみを出力（説明不要）
            """
            klog("Translate mode: forcing translation to \(targetLang)")
            isTranslateMode = false
            overlay?.setTranslateMode(false)
        } else {
            instruction = profile?.llmInstruction ?? ""
        }
        LLMProcessor.shared.process(text: formatted, instruction: instruction, appBundleID: activeAppBundleID) { [weak self] final in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overlay?.hide()
                klog("final: '\(final)'")
                if !final.isEmpty {
                    // 議事録自動録音中はファイル保存のみ（テキスト入力しない）
                    if self.isMeetingAutoRecording {
                        self.appleSpechPreliminary = nil
                    } else if let preliminary = self.appleSpechPreliminary {
                        // Apple Speechで先行入力済みなら、BackSpaceで消してwhisper結果に置換
                        klog("Replacing Apple Speech '\(preliminary)' → whisper '\(final)'")
                        if preliminary != final {
                            self.typer.deleteAndReplace(oldText: preliminary, newText: final, bundleID: self.activeAppBundleID)
                        }
                        self.appleSpechPreliminary = nil
                    } else {
                        if AppSettings.shared.streamingPreviewEnabled {
                            self.typer.typeInto(final, bundleID: self.activeAppBundleID)
                        } else {
                            self.typer.finalizeStreaming(final, bundleID: self.activeAppBundleID)
                        }
                    }
                    HistoryStore.shared.add(final, audioFileID: self.lastArchiveID,
                                           recognitionTime: WhisperContext.shared.lastTranscriptionTime,
                                           modelName: ModelDownloader.shared.currentModel.name)
                    VoiceStats.shared.recordSession(charCount: final.count, durationSeconds: recordingDuration)
                    MeetingMode.shared.append(text: final, audioURL: self.lastAudioURL)
                    self.meetingOverlay?.updateLastText(final)
                    self.meetingLiveWindow?.appendText(final)
                    CorrectionStore.shared.trackDelivery(original: final, appBundleID: self.activeAppBundleID)
                    self.publishHandoffActivity(text: final)
                    if AppSettings.shared.autoCopyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(final, forType: .string)
                    }
                    if AppSettings.shared.notifyOnComplete {
                        self.sendNotification(text: final)
                    }
                }
                self.postRecognitionCleanup()
            }
        }
    }

    /// Command Mode: 選択テキストをLLMで書き換える
    private func handleCommandModeRewrite(prompt: String) {
        // アクセシビリティで選択テキストを取得
        guard AXIsProcessTrusted() else {
            klog("CommandMode: no accessibility permission")
            overlay?.hide()
            postRecognitionCleanup()
            return
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard let element = focusedElement else {
            klog("CommandMode: no focused element")
            overlay?.hide()
            postRecognitionCleanup()
            return
        }
        var selectedValue: AnyObject?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedValue)
        let selectedText = (selectedValue as? String) ?? ""
        if selectedText.isEmpty {
            klog("CommandMode: no selected text")
            overlay?.hide()
            sendNotification(text: L10n.selectTextFirst)
            postRecognitionCleanup()
            return
        }
        klog("CommandMode: rewriting '\(selectedText.prefix(40))' with prompt")
        overlay?.show(state: .recognizing)
        let fullPrompt = "\(prompt)\n\n対象テキスト:\n\(selectedText)"
        LLMProcessor.shared.process(text: selectedText, instruction: fullPrompt, appBundleID: activeAppBundleID) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overlay?.hide()
                if !result.isEmpty && result != selectedText {
                    // 選択テキストをペーストで置換
                    self.typer.paste(result)
                    klog("CommandMode: replaced with '\(result.prefix(40))'")
                    HistoryStore.shared.add("[書換] \(result)")
                }
                self.postRecognitionCleanup()
            }
        }
    }

    /// 認識完了後の共通処理: メニュー更新 + ウェイクワード再開 + 議事録自動録音
    private func postRecognitionCleanup() {
        rebuildMenu()
        if MeetingMode.shared.isActive {
            // 議事録モード中は即座に次の録音を開始（認識と並行）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, MeetingMode.shared.isActive, !self.isRecording else { return }
                klog("MeetingMode: auto-starting next recording")
                self.isMeetingAutoRecording = true
                self.startRecording()
            }
        } else if AppSettings.shared.wakeWordEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WakeWordDetector.shared.start() }
        }
    }

    /// ⌃⌥R: 直前の認識を現在のモデルで再認識してテキストを置換
    func rerecognizeLast() {
        guard !isRecording, !isRecognizing else { return }
        guard let entry = HistoryStore.shared.entries.first,
              let fid = entry.audioFileID,
              let url = AudioArchive.shared.url(for: fid) else {
            klog("Re-recognize: no audio available for last entry")
            return
        }
        let lang = AppSettings.shared.language == "auto" ? "auto" : (AppSettings.shared.language.components(separatedBy: "-").first ?? "en")
        let model = ModelDownloader.shared.currentModel
        klog("Re-recognize last: '\(entry.text.prefix(30))' with \(model.name)")

        if overlay == nil { overlay = OverlayWindow() }
        overlay?.show(state: .recognizing)

        WhisperContext.shared.transcribe(url: url, language: lang) { [weak self] text in
            self?.overlay?.hide()
            guard let text, !text.isEmpty else { return }
            let time = WhisperContext.shared.lastTranscriptionTime
            klog("Re-recognize done: '\(text.prefix(40))' in \(String(format: "%.2f", time))s")
            // 入力済みテキストを置換
            if entry.text != text {
                self?.typer.deleteAndReplace(oldText: entry.text, newText: text, bundleID: self?.activeAppBundleID ?? "")
            }
            HistoryStore.shared.updateText(id: entry.id, newText: text, modelName: model.name, recognitionTime: time)
        }
    }

    private func startSpeculation() {
        guard AppSettings.shared.recognitionEngine == .whisperCpp,
              let srcURL = recorder.tempURL else { return }

        let myID = speculationID
        let profile = AppSettings.shared.profile(for: activeAppBundleID)
        let rawLang = (profile?.language.isEmpty == false ? profile!.language : AppSettings.shared.language)
        let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "en")

        // コンテキスト収集（投機実行にも同じコンテキストを使用）
        let contextPrompt = ContextCollector.collect(
            appBundleID: activeAppBundleID,
            profilePrompt: profile?.prompt ?? ""
        )
        klog("Speculation: firing (id=\(myID))")

        // 組み込み whisper が使えるなら直接呼び出し
        if WhisperContext.shared.isLoaded {
            let specURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("com.yuki.koe/spec.wav")
            try? FileManager.default.removeItem(at: specURL)
            guard (try? FileManager.default.copyItem(at: srcURL, to: specURL)) != nil else { return }

            WhisperContext.shared.transcribe(url: specURL, language: lang, prompt: contextPrompt) { [weak self] text in
                guard let self, self.speculationID == myID, let text, !text.isEmpty else { return }
                klog("Speculation: result ready '\(text)'")
                self.speculativeResult = text
            }
            return
        }

        // フォールバック: HTTP サーバー経由
        guard WhisperServer.shared.isAlive() else { return }
        let specURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.yuki.koe/spec.wav")
        try? FileManager.default.removeItem(at: specURL)
        guard (try? FileManager.default.copyItem(at: srcURL, to: specURL)) != nil else { return }

        WhisperServer.shared.transcribe(url: specURL, language: lang, prompt: contextPrompt) { [weak self] text in
            guard let self, self.speculationID == myID, let text, !text.isEmpty else { return }
            klog("Speculation: result ready '\(text)'")
            DispatchQueue.main.async { self.speculativeResult = text }
        }
    }

    // MARK: - Streaming Preview

    /// 録音中にApple Speech APIでリアルタイムプレビューを表示する。
    /// whisper.cppのGPUリソースを消費しないため、最終認識が高速になる。
    private var streamingRecognizer: SFSpeechRecognizer?
    private var streamingRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var streamingRecognitionTask: SFSpeechRecognitionTask?

    private func startStreamingPreview() {
        // 議事録モード中は常にストリーミングを有効化（リアルタイム表示のため）
        guard AppSettings.shared.streamingPreviewEnabled || MeetingMode.shared.isActive else { return }

        // Apple Speech APIでリアルタイムプレビュー（whisperとは独立）
        let lang = AppSettings.shared.language
        let locale = lang == "auto" ? Locale.current : Locale(identifier: lang)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return }
        streamingRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        streamingRecognitionRequest = request

        // 録音バッファをApple Speechに定期的に送る
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording,
                  let samples = self.recorder.currentSamples(), !samples.isEmpty else { return }
            // 前回からの差分だけ送る
            let newCount = samples.count - self.lastStreamingSampleCount
            guard newCount > 0 else { return }
            let newSamples = Array(samples.suffix(newCount))
            self.lastStreamingSampleCount = samples.count

            // Float32 → PCMBuffer
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(newSamples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(newSamples.count)
            let dst = buffer.floatChannelData![0]
            for i in 0..<newSamples.count { dst[i] = newSamples[i] }
            request.append(buffer)
        }

        streamingRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                self.lastStreamingResult = text
                if self.isRecording {
                    self.overlay?.updateStreamingText(text)
                    // 議事録モード: リアルタイムウィンドウにストリーミングテキスト表示
                    if MeetingMode.shared.isActive {
                        self.meetingLiveWindow?.updateStreamingText(text)
                        self.meetingOverlay?.updateLastText(text)
                    }
                }
            }
        }
    }

    private func updateSilenceDetection(level: Float) {
        guard isRecording else { return }

        // VAD: 直近フレームの平滑化（一瞬の音量変動を無視）
        levelHistory.append(level)
        if levelHistory.count > levelHistorySize { levelHistory.removeFirst() }
        let smoothed = levelHistory.reduce(0, +) / Float(levelHistory.count)

        // 最大録音時間チェック
        if let start = recordingStart, Date().timeIntervalSince(start) > maxRecordDuration {
            klog("Auto-stop: max duration reached")
            stopAndRecognize(); return
        }

        // 30秒経過したらスペースヒントを表示
        if let start = recordingStart, Date().timeIntervalSince(start) > 30 {
            overlay?.showHint("Space で延長  ·  もう一回で変換")
        }

        // スペース長押し中は無音検知を一時停止
        if spaceHeld { silenceStart = nil; return }

        if smoothed >= voiceThreshold {
            speechDetected = true
            // 発話再開 → 投機結果を無効化
            if silenceStart != nil {
                silenceStart = nil
                speculationID += 1
                speculativeResult = nil
                klog("Speculation: invalidated (speech resumed)")
            }
        } else if speechDetected && smoothed < silenceThreshold {
            if silenceStart == nil {
                silenceStart = Date()
            }
            if let s = silenceStart {
                let elapsed = Date().timeIntervalSince(s)
                // 無音0.2秒で投機実行を開始（認識を先行させる）
                if elapsed >= 0.2 && speculativeResult == nil {
                    startSpeculation()
                }
                if elapsed >= silenceAutoStop {
                    klog("Auto-stop: silence detected after speech")
                    stopAndRecognize()
                }
            }
        }
    }

    private func cancelRecording() {
        unregisterRecordingHotKeys()  // Space/ESC 解除
        klog("cancelRecording (recording=\(isRecording) recognizing=\(isRecognizing))")
        levelTimer?.invalidate(); levelTimer = nil
        streamingTimer?.invalidate(); streamingTimer = nil
        streamingRecognitionRequest?.endAudio()
        streamingRecognitionTask?.cancel()
        streamingRecognitionRequest = nil
        streamingRecognitionTask = nil
        overlay?.updateLevel(0)
        overlay?.clearStreamingText()
        // 直接入力モードの場合、入力済みストリーミングテキストを削除
        if !AppSettings.shared.streamingPreviewEnabled {
            typer.cancelStreaming()
        }
        isRecording = false
        isRecognizing = false
        isTranslateMode = false
        overlay?.setTranslateMode(false)
        speculationID += 1  // 進行中の認識を無効化
        setIcon(recording: false)
        recorder.cancel()
        speech.cancel()
        overlay?.hide()
        if AppSettings.shared.wakeWordEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WakeWordDetector.shared.start() }
        }
    }

    // MARK: - Notification

    private func sendNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Koe"
        content.body = String(text.prefix(100))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Speech engine reload (on language change)

    func reloadSpeechEngine() {
        speech = SpeechEngine()
        rebuildMenu()

        // 言語変更時にモデルを自動切替
        let rawLang = AppSettings.shared.language
        let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "en")
        guard lang != "auto" else { return }

        let dl = ModelDownloader.shared
        let best = ModelDownloader.bestModel(for: lang)
        guard best.id != dl.currentModel.id else { return }

        if dl.isDownloaded(best) {
            klog("reloadSpeechEngine: switching to \(best.name) for \(lang)")
            dl.selectModel(best)
            WhisperContext.shared.loadModel(path: dl.path(for: best)) { _ in }
        } else {
            klog("reloadSpeechEngine: downloading \(best.name) for \(lang)")
            dl.download(model: best) { success in
                if success {
                    klog("reloadSpeechEngine: downloaded \(best.name), loading")
                    dl.selectModel(best)
                    WhisperContext.shared.loadModel(path: dl.path(for: best)) { _ in }
                }
            }
        }
    }

    // フローティングボタンから呼ばれる
    func toggleRecording() {
        if isRecording { stopAndRecognize() } else { startRecording() }
    }

    // MARK: - Settings

    @objc func openSettings() {
        // 設定画面を開く間はウェイクワードを一時停止（テンプレート録音と干渉しないよう）
        WakeWordDetector.shared.stop()
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.show()
        settingsWC?.onClose = { [weak self] in
            guard let self else { return }
            if AppSettings.shared.wakeWordEnabled && !self.isRecording {
                WakeWordDetector.shared.start()
            }
        }
    }

    @objc func toggleMeetingMode() {
        let wasActive = MeetingMode.shared.isActive
        MeetingMode.shared.toggle()
        rebuildMenu()
        if MeetingMode.shared.isActive {
            // 議事録オーバーレイ表示
            if meetingOverlay == nil {
                meetingOverlay = MeetingOverlayWindow()
            }
            meetingOverlay?.showMeeting()

            // リアルタイム文字起こしウィンドウを表示
            if AppSettings.shared.meetingLiveWindow {
                if meetingLiveWindow == nil { meetingLiveWindow = MeetingLiveWindow() }
                meetingLiveWindow?.show()
            }

            // システム音声キャプチャ（Zoom/Teams音声取得）
            // スクリーン録画権限が必要なため、ユーザーが設定で有効にした場合のみ
            // （毎回ダイアログが出るのを防止）

            // 議事録モードでは話者分離を自動有効化
            if !AppSettings.shared.diarizationEnabled {
                AppSettings.shared.diarizationEnabled = true
                klog("MeetingMode: auto-enabled diarization")
            }

            // 議事録開始時に自動で最初の録音を開始
            if !isRecording {
                klog("MeetingMode: auto-starting first recording")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, MeetingMode.shared.isActive, !self.isRecording else { return }
                    self.isMeetingAutoRecording = true
                    self.startRecording()
                }
            }
        } else if wasActive {
            // システム音声キャプチャ停止（有効な場合のみ）
            if #available(macOS 13.0, *) {
                if let sysURL = SystemAudioCapture.shared.stopCapture(),
                   let dir = MeetingMode.shared.outputURL {
                    let dest = dir.appendingPathComponent("system_audio.wav")
                    try? FileManager.default.copyItem(at: sysURL, to: dest)
                    klog("MeetingMode: saved system audio")
                }
            }

            // 議事録オーバーレイ非表示
            meetingOverlay?.hideMeeting()

            // リアルタイムウィンドウのテキストからAIチャットを開く
            if let entries = meetingLiveWindow?.model.entries, !entries.isEmpty {
                let transcript = entries.map { e in
                    let sp = e.speaker.map { "[話者\($0+1)] " } ?? ""
                    return "\(sp)\(e.text)"
                }.joined(separator: "\n")
                if meetingChatWindow == nil { meetingChatWindow = MeetingChatWindow() }
                meetingChatWindow?.show(transcript: transcript, title: "議事録")
            }
            meetingLiveWindow?.hide()
            // 議事録停止時に録音中なら最後の認識を実行（キャンセルではなく認識）
            if isRecording {
                klog("MeetingMode: final recognition before stop")
                isMeetingAutoRecording = false  // 自動録音ループを停止
                stopAndRecognize()
            } else if isRecognizing {
                // 認識中なら完了を待つ（postRecognitionCleanupで自動停止）
                klog("MeetingMode: waiting for final recognition")
                isMeetingAutoRecording = false
            }
        }
    }

    func rebuildMenuPublic() { rebuildMenu() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        AppSettings.shared.language = code
        klog("Language changed: \(code)")
        rebuildMenu()
    }

    @objc private func selectLLMMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = LLMMode(rawValue: rawValue) else { return }
        AppSettings.shared.llmMode = mode
        klog("LLM mode changed: \(mode.displayName)")
        // オーバーレイのモード表示を即反映（オフにしたら消える）
        overlay?.setTranslateMode(false)
        rebuildMenu()
    }

    @objc private func toggleAgentMode(_ sender: NSMenuItem) {
        AppSettings.shared.agentModeEnabled.toggle()
        klog("Agent mode: \(AppSettings.shared.agentModeEnabled ? "ON" : "OFF")")
        rebuildMenu()
    }

    @objc private func openFileTranscription() {
        let panel = NSOpenPanel()
        panel.title = L10n.fileTranscriptionTitle
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.audio, .movie]
        } else {
            panel.allowedFileTypes = FileTranscriber.supportedTypes
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            klog("FileTranscription: selected \(url.lastPathComponent)")
            self?.transcriptionWindow = TranscriptionWindow()
            self?.transcriptionWindow?.show(fileURL: url)
        }
    }

    @objc private func checkUpdate() {
        AutoUpdater.shared.checkForUpdates(silent: false)
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let engine = AppSettings.shared.recognitionEngine
        let model = ModelDownloader.shared.currentModel.name
        let alert = NSAlert()
        alert.messageText = "声 Koe"
        alert.informativeText = """
        \(L10n.aboutTagline)

        \(L10n.labelVersion) \(version) (Build \(build))
        \(L10n.sectionEngine): \(engine.displayName)
        \(L10n.labelModel): \(model)

        whisper.cpp + Metal GPU
        \(L10n.aboutLocalProcessing)

        © 2026 Yuki Hamada
        """
        alert.alertStyle = .informational
        if let icon = NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) {
            alert.icon = icon
        }
        alert.runModal()
    }

    // MARK: - Handoff (Continuity)

    private static let handoffActivityType = "com.yuki.koe.transcription"

    /// 認識結果を Handoff で他のデバイスに共有する
    private func publishHandoffActivity(text: String) {
        let activity = NSUserActivity(activityType: Self.handoffActivityType)
        activity.title = "Koe 音声入力"
        activity.userInfo = ["text": text, "timestamp": Date().timeIntervalSince1970]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.needsSave = true
        currentActivity = activity
        currentActivity?.becomeCurrent()
        klog("Handoff: published '\(String(text.prefix(40)))'")
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == Self.handoffActivityType,
              let text = userActivity.userInfo?["text"] as? String else { return false }
        klog("Handoff: received '\(String(text.prefix(40)))'")
        // ペーストボードにコピーしてユーザーに通知
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        sendNotification(text: "Handoff: テキストをクリップボードにコピーしました")
        return true
    }

    // MARK: - URL Scheme (Shortcuts.app integration)

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        klog("URL scheme: \(urlString)")

        switch url.host {
        case "transcribe":
            // koe://transcribe — start recording, return transcribed text via pasteboard
            guard !isRecording else { return }
            DispatchQueue.main.async { self.startRecording() }
        case "translate":
            // koe://translate — start recording in translate mode
            guard !isRecording else { return }
            DispatchQueue.main.async {
                self.isTranslateMode = true
                self.overlay?.setTranslateMode(true)
                klog("URL scheme: translate mode ON")
                self.startRecording()
            }
        default:
            klog("URL scheme: unknown host '\(url.host ?? "")'")
        }
    }

    /// CGEventでキーコンビネーションを送信
    private func postKeyCombo(key: CGKeyCode, modifiers: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @objc private func openTestFlight() {
        if let url = URL(string: "https://testflight.apple.com/join/koe-voice") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// ドロップされた音声ファイルを文字起こし
    func transcribeDroppedFile(_ url: URL) {
        klog("Drop transcribe: \(url.lastPathComponent)")
        if transcriptionWindow == nil { transcriptionWindow = TranscriptionWindow() }
        transcriptionWindow?.show(fileURL: url)
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        levelTimer?.invalidate()
        streamingTimer?.invalidate()
    }
}

// MARK: - iPhone Bridge (MultipeerConnectivity)

import MultipeerConnectivity

final class IPhoneBridge: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    static let shared = IPhoneBridge()
    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var onText: ((String) -> Void)?
    var onEnter: (() -> Void)?
    var onStreamingText: ((String) -> Void)?
    var onCommand: ((String) -> Void)?

    /// 4-digit PIN for pairing authentication
    private(set) var pairingPIN: String = ""
    /// Peer display names that have been authenticated via PIN
    private var pairedPeerNames: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "koe_paired_peers") ?? []
        return Set(saved)
    }()

    private func savePairedPeers() {
        UserDefaults.standard.set(Array(pairedPeerNames), forKey: "koe_paired_peers")
    }

    private func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    func start(onTextReceived: @escaping (String) -> Void) {
        self.onText = onTextReceived
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s

        // Generate a new PIN each time advertising starts
        pairingPIN = generatePIN()
        let discoveryInfo = ["pin": pairingPIN]

        let a = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: discoveryInfo, serviceType: "koe-bridge")
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
        klog("IPhoneBridge: advertising with PIN \(pairingPIN)")

        // Show PIN as a user notification
        showPINNotification()
    }

    private func showPINNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Koe ペアリングPIN"
        content.body = "iPhoneから接続するには PIN: \(pairingPIN) を入力してください"
        let request = UNNotificationRequest(identifier: "koe-pairing-pin", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        klog("IPhoneBridge: PIN notification posted")
    }

    func sendActiveApp(bundleID: String, name: String) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: String] = ["type": "active_app", "bundleID": bundleID, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: - Screen Context (OCR + LLM summary)

    var screenSharingEnabled = false
    private var screenTimer: Timer?
    private var isAnalyzing = false
    private var lastOCRText: String = ""
    private var lastSummary: String = ""

    func startScreenSharing() {
        guard !screenSharingEnabled else { return }
        screenSharingEnabled = true
        screenTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.captureAndAnalyzeScreen()
        }
        captureAndAnalyzeScreen()
        klog("IPhoneBridge: screen context started (OCR+LLM)")
    }

    func stopScreenSharing() {
        screenSharingEnabled = false
        screenTimer?.invalidate()
        screenTimer = nil
        klog("IPhoneBridge: screen context stopped")
    }

    private func captureAndAnalyzeScreen() {
        guard let session, !session.connectedPeers.isEmpty, !isAnalyzing else { return }

        // 1. スクリーンショットを取得
        let cgImage = captureScreenImage()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "不明"
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // 即座にウィンドウタイトルベースのコンテキスト + フォールバック提案を送信
        let windowContext = collectWindowContext(appName: appName)
        if !windowContext.isEmpty {
            sendScreenContext("[\(appName)] \(windowContext)")
            sendSuggestions(generateFallbackSuggestions(appName: appName, bundleID: bundleID))
            klog("IPhoneBridge: sent immediate context + suggestions for \(appName)")
        }

        if cgImage == nil {
            klog("IPhoneBridge: screenshot failed, window-title-only mode")
            return
        }

        // 2. Vision OCR でテキスト抽出（LLMで上書き）
        isAnalyzing = true
        performOCR(on: cgImage!) { [weak self] ocrText in
            guard let self else { return }

            // 3. 前回と同じならスキップ
            let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            klog("IPhoneBridge: OCR \(trimmed.count) chars for \(appName)")
            if trimmed.isEmpty {
                self.isAnalyzing = false
                klog("IPhoneBridge: OCR empty, using window titles fallback")
                let context = self.collectWindowContext(appName: appName)
                if !context.isEmpty && context != self.lastOCRText {
                    self.lastOCRText = context
                    DispatchQueue.main.async {
                        self.sendScreenContext("[\(appName)] \(context)")
                        self.sendSuggestions(self.generateFallbackSuggestions(appName: appName, bundleID: bundleID))
                    }
                }
                return
            }
            if trimmed == self.lastOCRText {
                self.isAnalyzing = false
                klog("IPhoneBridge: screen unchanged, skip LLM")
                return
            }
            self.lastOCRText = trimmed
            let ocrSnippet = String(trimmed.prefix(2000))

            // 即座にフォールバック提案を送信（LLM結果は後から上書き）
            DispatchQueue.main.async {
                let quickContext = "[\(appName)] \(String(trimmed.prefix(200)))"
                self.sendScreenContext(quickContext)
                self.sendSuggestions(self.generateFallbackSuggestions(appName: appName, bundleID: bundleID))
                klog("IPhoneBridge: sent quick context + fallback suggestions")
            }

            // 4. LLM で要約 + 提案を同時生成（上書き）
            let prompt = """
            以下はMacの画面「\(appName)」をOCRで読み取ったテキストです。2つの出力をしてください。

            【要約】画面の状況を200文字以内で日本語で簡潔に説明。重要な情報（URL、ファイル名、エラー等）を含む。
            【提案】ユーザーが次にやりそうなこと・入力しそうなテキストを3つ提案。各提案は短い文（タップして即入力できるもの）。

            出力形式（厳守）:
            SUMMARY: （要約テキスト）
            SUGGEST: （提案1）
            SUGGEST: （提案2）
            SUGGEST: （提案3）

            ---
            \(ocrSnippet)
            """

            LLMProcessor.shared.processScreenContext(prompt: prompt) { [weak self] response in
                guard let self else { return }
                self.isAnalyzing = false

                let result = response.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty, result != prompt else {
                    let fallback = "[\(appName)] \(String(trimmed.prefix(200)))"
                    self.sendScreenContext(fallback)
                    self.sendSuggestions(self.generateFallbackSuggestions(appName: appName, bundleID: bundleID))
                    return
                }

                // パース: SUMMARY: と SUGGEST: を分離
                var summary = ""
                var suggestions: [String] = []
                for line in result.components(separatedBy: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("SUMMARY:") {
                        summary = String(l.dropFirst("SUMMARY:".count)).trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "\u{FFFD}", with: "").replacingOccurrences(of: "��", with: "")
                    } else if l.hasPrefix("SUGGEST:") {
                        var s = String(l.dropFirst("SUGGEST:".count)).trimmingCharacters(in: .whitespaces)
                        s = s.replacingOccurrences(of: "\u{FFFD}", with: "").replacingOccurrences(of: "��", with: "")
                        if !s.isEmpty { suggestions.append(s) }
                    }
                }

                // パース失敗時はフォールバック
                if summary.isEmpty { summary = String(result.prefix(200)) }
                if suggestions.isEmpty { suggestions = self.generateFallbackSuggestions(appName: appName, bundleID: bundleID) }

                self.lastSummary = summary
                klog("IPhoneBridge: summary → \(summary.prefix(60)) | \(suggestions.count) suggestions")
                self.sendScreenContext(summary)
                self.sendSuggestions(suggestions)
            }
        }
    }

    /// アプリに応じたフォールバック提案
    private func generateFallbackSuggestions(appName: String, bundleID: String) -> [String] {
        switch bundleID {
        case let b where b.contains("slack"):
            return ["了解です", "確認します", "ありがとうございます"]
        case let b where b.contains("mail"):
            return ["ご確認よろしくお願いいたします", "承知しました", "お忙しいところ恐れ入りますが"]
        case let b where b.contains("terminal") || b.contains("iterm"):
            return ["git status", "git diff", "git log --oneline -10"]
        case let b where b.contains("xcode"):
            return ["// TODO: ", "Command+B でビルド", "Command+R で実行"]
        case let b where b.contains("safari") || b.contains("chrome") || b.contains("firefox"):
            return ["検索する", "新しいタブを開く", "ブックマークに追加"]
        case let b where b.contains("notes"):
            return ["---", "## ", "- [ ] "]
        default:
            return ["了解", "確認します", "ありがとう"]
        }
    }

    private func sendScreenContext(_ text: String) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: String] = ["type": "screen_context", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// ウィンドウタイトルからコンテキスト収集（スクショ取れない場合のフォールバック）
    private func collectWindowContext(appName: String) -> String {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return "" }
        var titles: [String] = []
        for win in windows.prefix(8) {
            if let name = win[kCGWindowName as String] as? String, !name.isEmpty,
               let owner = win[kCGWindowOwnerName as String] as? String {
                titles.append("[\(owner)] \(name)")
            }
        }
        return titles.joined(separator: "\n")
    }

    private func sendSuggestions(_ suggestions: [String]) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: Any] = ["type": "suggestions", "items": suggestions]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// 画面キャプチャ（CGWindowList、権限不要でウィンドウ情報は取得可能）
    /// 画面録画権限がない場合はnilを返す（screencaptureは使わない — プロンプトが出るため）
    private func captureScreenImage() -> CGImage? {
        guard let image = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, [.boundsIgnoreFraming]) else {
            return nil
        }
        // 画面録画権限がないと1x1や空画像が返ることがある
        if image.width <= 1 || image.height <= 1 { return nil }
        return image
    }

    /// Vision Framework でOCR
    private func performOCR(on image: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(""); return
            }
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            completion(text)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja", "en"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .utility).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        klog("IPhoneBridge: \(peer.displayName) \(state == .connected ? "connected" : "disconnected")")
        DispatchQueue.main.async {
            if state == .connected {
                self.startScreenSharing()
            } else if state == .notConnected && s.connectedPeers.isEmpty {
                self.stopScreenSharing()
            }
        }
    }
    var onBackspace: ((Int) -> Void)?

    func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        DispatchQueue.main.async {
            if type == "text", let text = json["text"] as? String {
                self.onText?(text)
            } else if type == "streaming_text", let text = json["text"] as? String {
                self.onStreamingText?(text)
            } else if type == "enter" {
                self.onEnter?()
            } else if type == "backspace", let count = json["count"] as? Int {
                self.onBackspace?(count)
            } else if type == "command", let command = json["command"] as? String {
                self.onCommand?(command)
            } else if type == "mouse_click",
                      let nx = json["x"] as? Double,
                      let ny = json["y"] as? Double {
                self.handleMouseClick(normalizedX: nx, normalizedY: ny)
            } else if type == "mouse_move",
                      let dx = json["dx"] as? Double,
                      let dy = json["dy"] as? Double {
                self.handleMouseMove(dx: dx, dy: dy)
            } else if type == "toggle_agent", let enabled = json["enabled"] as? Bool {
                AppSettings.shared.agentModeEnabled = enabled
                AppSettings.shared.voiceControlEnabled = enabled
                klog("IPhoneBridge: agent mode \(enabled ? "ON" : "OFF") (from iPhone)")
            }
        }
    }
    func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID,
                    withContext: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let peerName = peer.displayName

        // Already paired devices reconnect automatically
        if pairedPeerNames.contains(peerName) {
            klog("IPhoneBridge: auto-accepting previously paired peer '\(peerName)'")
            invitationHandler(true, session)
            return
        }

        // Validate PIN from context data
        if let contextData = withContext,
           let contextJSON = try? JSONSerialization.jsonObject(with: contextData) as? [String: String],
           let receivedPIN = contextJSON["pin"],
           receivedPIN == pairingPIN {
            klog("IPhoneBridge: PIN matched for '\(peerName)', accepting")
            pairedPeerNames.insert(peerName)
            savePairedPeers()
            invitationHandler(true, session)
        } else {
            let receivedPIN = withContext.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["pin"] ?? "(none)"
            klog("IPhoneBridge: PIN mismatch for '\(peerName)' (received: \(receivedPIN), expected: \(pairingPIN)), rejecting")
            invitationHandler(false, nil)
        }
    }
    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}

    /// Handle mouse move delta from iPhone trackpad
    func handleMouseMove(dx: Double, dy: Double) {
        let current = NSEvent.mouseLocation
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // NSEvent.mouseLocation is bottom-left origin, CGEvent is top-left
        let flippedY = screen.frame.height - current.y
        let newX = current.x + CGFloat(dx)
        let newY = flippedY + CGFloat(dy)
        let point = CGPoint(x: newX, y: newY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func postMouseClick(button: CGMouseButton) {
        let pos = NSEvent.mouseLocation
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let flippedY = screen.frame.height - pos.y
        let point = CGPoint(x: pos.x, y: flippedY)
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    func postScroll(dy: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// Handle mouse click from iPhone (normalized coordinates 0-1)
    private func handleMouseClick(normalizedX: Double, normalizedY: Double) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.origin.x + CGFloat(normalizedX) * frame.width
        let y = frame.origin.y + CGFloat(normalizedY) * frame.height
        let point = CGPoint(x: x, y: y)
        klog("IPhoneBridge: mouse click at (\(Int(x)), \(Int(y)))")
        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        mouseUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - Status Bar Drop Delegate

class StatusBarDropDelegate: NSObject {
    weak var appDelegate: AppDelegate?
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }
}

/// NSButton extension for drag & drop on status bar
extension NSButton {
    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
              options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }

    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
              options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else { return false }
        let audioExts = ["wav", "mp3", "m4a", "mp4", "mov", "aac", "flac", "ogg", "caf"]
        guard audioExts.contains(url.pathExtension.lowercased()) else { return false }
        AppDelegate.shared?.transcribeDroppedFile(url)
        return true
    }
}
