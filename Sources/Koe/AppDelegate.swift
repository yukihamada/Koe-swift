import AppKit
import Carbon.HIToolbox
import Speech
import UniformTypeIdentifiers
import UserNotifications

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
    private var meetingOverlay: MeetingOverlayWindow?
    private var levelTimer: Timer?
    private var isRecording      = false
    private var recordingStart:  Date?
    private var activeAppBundleID = ""

    // Silence-based auto-stop
    private let voiceThreshold: Float   = 0.08  // この音量以上で「発話中」（低めで敏感に検出）
    private let silenceThreshold: Float = 0.04  // この音量以下で「無音」
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

        // アクセシビリティ権限がない場合 — 基本機能は動作するが自動ペーストにはアクセシビリティが必要
        if !AXIsProcessTrusted() {
            klog("Accessibility not granted — clipboard-only mode (auto-paste disabled)")
            // システム環境設定のアクセシビリティ画面を開く
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func finishLaunch() {
        speech.requestPermissions()
        loadEmbeddedWhisper()

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
            let otherItem = NSMenuItem(title: "その他の言語…", action: nil, keyEquivalent: "")
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
        let modeLabel = s.llmMode == .none ? "LLM: オフ" : "LLM: \(s.llmMode.displayName)"
        let modeItem = NSMenuItem(title: modeLabel, action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let transItem = NSMenuItem(title: "翻訳 \(s.translateShortcutDisplayString)", action: nil, keyEquivalent: "")
        transItem.isEnabled = false
        menu.addItem(transItem)
        menu.addItem(.separator())

        // ツール
        let meetingTitle = MeetingMode.shared.isActive
            ? "議事録停止 (\(MeetingMode.shared.entryCount)件)"
            : "議事録開始"
        menu.addItem(withTitle: meetingTitle, action: #selector(toggleMeetingMode), keyEquivalent: "m")
        menu.addItem(withTitle: "ファイル文字起こし…", action: #selector(openFileTranscription), keyEquivalent: "t")
        menu.addItem(.separator())

        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q")
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
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        klog("Accessibility trusted: \(trusted)")
        if !trusted {
            DispatchQueue.global().async {
                while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
                klog("Accessibility granted")
                DispatchQueue.main.async { self.reregisterHotkey() }
            }
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
                if pressed == 55 {
                    // 左⌘ → 英語
                    switchInputSource(toJapanese: false)
                } else {
                    // 右⌘ → 日本語
                    switchInputSource(toJapanese: true)
                }
            }
            cmdUsedAsModifier = false
        }
    }

    private func switchInputSource(toJapanese: Bool) {
        let filter = [kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        for source in sources {
            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String

            if toJapanese {
                if sourceID.contains("Japanese") && sourceID.contains("Hiragana") {
                    TISSelectInputSource(source)
                    return
                }
            } else {
                if sourceID.contains("ABC") || sourceID == "com.apple.keylayout.US" {
                    TISSelectInputSource(source)
                    return
                }
            }
        }
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

        // 議事録モード + 話者分離が有効な場合、speaker-aware transcription を使用
        if MeetingMode.shared.isActive,
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
                    HistoryStore.shared.add(fullText)
                    MeetingMode.shared.appendSpeakerSegments(segments, audioURL: self.lastAudioURL)
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
        if AppSettings.shared.agentModeEnabled, let command = AgentMode.shared.detectCommand(formatted) {
            klog("Agent: detected command — \(command.description)")
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
                    HistoryStore.shared.add(final)
                    VoiceStats.shared.recordSession(charCount: final.count, durationSeconds: recordingDuration)
                    MeetingMode.shared.append(text: final, audioURL: self.lastAudioURL)
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
            sendNotification(text: "テキストを選択してからコマンドを使ってください")
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
        guard AppSettings.shared.streamingPreviewEnabled else { return }

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
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
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
                }
            }
        }
    }

    private func updateSilenceDetection(level: Float) {
        guard isRecording else { return }

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

        if level >= voiceThreshold {
            speechDetected = true
            // 発話再開 → 投機結果を無効化
            if silenceStart != nil {
                silenceStart = nil
                speculationID += 1
                speculativeResult = nil
                klog("Speculation: invalidated (speech resumed)")
            }
        } else if speechDetected && level < silenceThreshold {
            if silenceStart == nil {
                silenceStart = Date()
            }
            if let s = silenceStart, Date().timeIntervalSince(s) >= silenceAutoStop {
                klog("Auto-stop: silence detected after speech")
                stopAndRecognize()
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
            // 議事録開始時に自動で最初の録音を開始
            if !isRecording {
                klog("MeetingMode: auto-starting first recording")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, MeetingMode.shared.isActive, !self.isRecording else { return }
                    self.isMeetingAutoRecording = true
                    self.startRecording()
                }
            }
        } else if wasActive {
            // 議事録オーバーレイ非表示
            meetingOverlay?.hideMeeting()
            // 議事録停止時に録音中なら停止
            if isRecording {
                klog("MeetingMode: stopping recording")
                cancelRecording()
            }
            if isRecognizing {
                overlay?.hide()
                isRecognizing = false
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
        rebuildMenu()
    }

    @objc private func toggleAgentMode(_ sender: NSMenuItem) {
        AppSettings.shared.agentModeEnabled.toggle()
        klog("Agent mode: \(AppSettings.shared.agentModeEnabled ? "ON" : "OFF")")
        rebuildMenu()
    }

    @objc private func openFileTranscription() {
        let panel = NSOpenPanel()
        panel.title = "文字起こしするファイルを選択"
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
        Mac で最も速い日本語音声入力

        バージョン \(version) (Build \(build))
        エンジン: \(engine.displayName)
        モデル: \(model)

        whisper.cpp + Metal GPU
        完全ローカル処理

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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        levelTimer?.invalidate()
        streamingTimer?.invalidate()
    }
}
