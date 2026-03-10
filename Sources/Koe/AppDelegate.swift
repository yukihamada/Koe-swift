import AppKit
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
    private var levelTimer: Timer?
    private var isRecording      = false
    private var recordingStart:  Date?
    private var activeAppBundleID = ""

    // Silence-based auto-stop
    private let voiceThreshold: Float   = 0.12  // この音量以上で「発話中」
    private let silenceThreshold: Float = 0.07  // この音量以下で「無音」
    private let maxRecordDuration: TimeInterval = 60
    /// 適応的無音閾値: 短い発話ほど速く打ち切る
    private var silenceAutoStop: TimeInterval {
        guard let start = recordingStart else { return 0.85 }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 2.0 { return 0.6 }   // 2秒以下: 0.6秒で打ち切り
        if elapsed < 5.0 { return 0.7 }   // 5秒以下: 0.7秒
        return 0.85                         // 5秒以上: 標準
    }
    private var speechDetected = false
    private var silenceStart: Date?

    // Space key extension
    private var spaceHeld    = false
    private var spacePressed = false

    // Speculative execution
    private var speculativeResult: String? = nil
    private var speculationID = 0

    // Streaming preview
    private var streamingTimer: Timer?
    private var isStreamingInFlight = false

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

        // アクセシビリティ権限がない場合はバックグラウンドで許可を要求
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
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
        let engine = AppSettings.shared.recognitionEngine
        let badge = engine.isLocal ? "LOCAL" : "CLOUD"
        let langFlag = AppSettings.shared.languageFlag
        let wakeLabel = AppSettings.shared.wakeWordEnabled ? " [WakeWord Beta]" : ""
        let header = NSMenuItem(title: "Koe — \(AppSettings.shared.shortcutDisplayString) で録音 [\(badge)] [\(langFlag)]\(wakeLabel)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let meetingTitle = MeetingMode.shared.isActive
            ? "🔴 議事録停止 (\(MeetingMode.shared.entryCount)件)"
            : "⚫ 議事録開始"
        menu.addItem(withTitle: meetingTitle, action: #selector(toggleMeetingMode), keyEquivalent: "m")
        menu.addItem(withTitle: "ファイルを文字起こし…", action: #selector(openFileTranscription), keyEquivalent: "t")

        // 言語切替サブメニュー
        let langMenu = NSMenu()
        for lang in AppSettings.quickLanguages {
            let item = NSMenuItem(title: "\(lang.flag) \(lang.name) (\(lang.code))", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            item.state = (AppSettings.shared.language == lang.code) ? .on : .off
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "言語: \(langFlag) \(AppSettings.shared.language)", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // LLMモード切替サブメニュー (β)
        let modeMenu = NSMenu()
        for mode in LLMMode.allCases {
            let beta = (mode != .none) ? " β" : ""
            let item = NSMenuItem(title: mode.displayName + beta, action: #selector(selectLLMMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (AppSettings.shared.llmMode == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        let modeLabel = AppSettings.shared.llmMode == .none ? "LLM修正: オフ" : "LLM修正: \(AppSettings.shared.llmMode.displayName) β"
        let modeItem = NSMenuItem(title: modeLabel, action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // エージェントモード (β)
        let agentItem = NSMenuItem(title: "エージェントモード β", action: #selector(toggleAgentMode(_:)), keyEquivalent: "")
        agentItem.state = AppSettings.shared.agentModeEnabled ? .on : .off
        menu.addItem(agentItem)

        // 翻訳ショートカット表示
        let transDisplay = AppSettings.shared.translateShortcutDisplayString
        let transItem = NSMenuItem(title: "翻訳: \(transDisplay)", action: nil, keyEquivalent: "")
        transItem.isEnabled = false
        menu.addItem(transItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "アップデートを確認…", action: #selector(checkUpdate), keyEquivalent: "")
        menu.addItem(withTitle: "Koe について", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
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
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleEvent(event, settings: settings)
        }
        rebuildMenu()
        klog("Hotkey registered: \(settings.shortcutDisplayString)")
    }

    private func handleEvent(_ event: NSEvent, settings: AppSettings) {
        let targetCode = UInt16(settings.shortcutKeyCode)
        let targetMods = NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers)
        let isToggle = settings.recordingMode == .toggle

        // Translation hotkey detection
        let transCode = UInt16(settings.translateHotkeyCode)
        let transMods = NSEvent.ModifierFlags(rawValue: settings.translateHotkeyModifiers)

        switch event.type {
        case .keyDown:
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

    // MARK: - Recording

    private func startRecording() {
        // Stop wake word detector before AVAudioRecorder starts to avoid conflicts
        WakeWordDetector.shared.stop()

        // Capture frontmost app BEFORE recording starts
        activeAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        klog("startRecording from app: \(activeAppBundleID)")
        isRecording    = true
        recordingStart = Date()
        speechDetected = false
        silenceStart   = nil
        spaceHeld        = false
        spacePressed     = false
        speculativeResult = nil
        speculationID    += 1  // 前回の投機を無効化
        setIcon(recording: true)
        if overlay == nil { overlay = OverlayWindow() }
        overlay?.show(state: .recording)
        recorder.start()
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
        levelTimer?.invalidate(); levelTimer = nil
        streamingTimer?.invalidate(); streamingTimer = nil
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
           !AudioDSP.hasVoice(wavSamples) {
            klog("stopAndRecognize: no voice detected, skipping recognition")
            overlay?.hide()
            if AppSettings.shared.wakeWordEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WakeWordDetector.shared.start() }
            }
            return
        }

        lastAudioURL = audioURL
        overlay?.clearHint()
        overlay?.show(state: .recognizing)
        isRecognizing = true

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
            let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "ja")
            WhisperContext.shared.transcribeWithSpeakers(url: audioURL, language: lang, prompt: contextPrompt) { [weak self] segments in
                guard let self else { return }
                self.isRecognizing = false
                self.overlay?.hide()
                if !segments.isEmpty {
                    let fullText = segments.map { $0.text }.joined()
                    klog("diarize result: \(segments.count) segments, \(Set(segments.map { $0.speaker }).count) speakers")
                    HistoryStore.shared.add(fullText)
                    MeetingMode.shared.appendSpeakerSegments(segments, audioURL: self.lastAudioURL)
                    self.typer.type(fullText)
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
                self.rebuildMenu()
                if AppSettings.shared.wakeWordEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WakeWordDetector.shared.start() }
                }
            }
            return
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
        // Whisperが返す改行を除去（明示的に指示がない限り改行なし）
        let cleaned = raw.replacingOccurrences(of: "\n", with: " ")
                         .replacingOccurrences(of: "\r", with: "")
                         .trimmingCharacters(in: .whitespaces)
        let expanded = AppSettings.shared.expand(cleaned)

        // Agent mode: detect and execute voice commands instead of typing
        if AppSettings.shared.agentModeEnabled, let command = AgentMode.shared.detectCommand(expanded) {
            klog("Agent: detected command — \(command.description)")
            overlay?.show(state: .recognizing)
            AgentMode.shared.execute(command) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.overlay?.hide()
                    klog("Agent result: '\(result)'")
                    HistoryStore.shared.add("[\(command.description)] \(result)")
                    self.sendNotification(text: result)
                    self.rebuildMenu()
                    if AppSettings.shared.wakeWordEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WakeWordDetector.shared.start() }
                    }
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
        LLMProcessor.shared.process(text: expanded, instruction: instruction, appBundleID: activeAppBundleID) { [weak self] final in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overlay?.hide()
                klog("final: '\(final)'")
                if !final.isEmpty {
                    HistoryStore.shared.add(final)
                    MeetingMode.shared.append(text: final, audioURL: self.lastAudioURL)
                    self.typer.type(final)
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
                self.rebuildMenu()
                if AppSettings.shared.wakeWordEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        WakeWordDetector.shared.start()
                    }
                }
            }
        }
    }

    private func startSpeculation() {
        guard AppSettings.shared.recognitionEngine == .whisperCpp,
              let srcURL = recorder.tempURL else { return }

        let myID = speculationID
        let profile = AppSettings.shared.profile(for: activeAppBundleID)
        let rawLang = (profile?.language.isEmpty == false ? profile!.language : AppSettings.shared.language)
        let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "ja")

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

    /// 録音中に定期的に中間認識を実行してオーバーレイに表示する。
    /// whisper.cpp のみ対応。1.5秒ごとに現在のバッファで推論する。
    private func startStreamingPreview() {
        guard AppSettings.shared.streamingPreviewEnabled,
              AppSettings.shared.recognitionEngine == .whisperCpp,
              WhisperContext.shared.isLoaded else { return }

        let profile = AppSettings.shared.profile(for: activeAppBundleID)
        let rawLang = (profile?.language.isEmpty == false ? profile!.language : AppSettings.shared.language)
        let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "ja")

        streamingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            // 前回のストリーミング推論がまだ進行中ならスキップ
            guard !self.isStreamingInFlight else { return }
            // 録音開始から1秒未満はスキップ（音声が短すぎる）
            guard let start = self.recordingStart, Date().timeIntervalSince(start) >= 1.0 else { return }

            guard let samples = self.recorder.currentSamples(), samples.count > 8000 else { return }

            self.isStreamingInFlight = true
            WhisperContext.shared.transcribeBuffer(samples: samples, language: lang) { [weak self] text in
                guard let self, self.isRecording else {
                    self?.isStreamingInFlight = false
                    return
                }
                self.isStreamingInFlight = false
                if let text, !text.isEmpty {
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
                // 無音検知開始と同時に投機実行を起動
                startSpeculation()
            }
            if let s = silenceStart, Date().timeIntervalSince(s) >= silenceAutoStop {
                klog("Auto-stop: silence detected after speech")
                stopAndRecognize()
            }
        }
    }

    private func cancelRecording() {
        klog("cancelRecording (recording=\(isRecording) recognizing=\(isRecognizing))")
        levelTimer?.invalidate(); levelTimer = nil
        streamingTimer?.invalidate(); streamingTimer = nil
        overlay?.updateLevel(0)
        overlay?.clearStreamingText()
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
    }

    // フローティングボタンから呼ばれる
    func toggleRecording() {
        if isRecording { stopAndRecognize() } else { startRecording() }
    }

    // MARK: - Settings

    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.show()
    }

    @objc private func toggleMeetingMode() {
        MeetingMode.shared.toggle()
        rebuildMenu()
    }

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
