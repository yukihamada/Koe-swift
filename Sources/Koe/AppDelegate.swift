import AppKit
import Speech
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var overlay: OverlayWindow?
    private var settingsWC: SettingsWindowController?
    private var setupWindow: SetupWindow?
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
    private let silenceAutoStop: TimeInterval = 0.85  // 発話後N秒無音で自動停止
    private let maxRecordDuration: TimeInterval = 60
    private var speechDetected = false
    private var silenceStart: Date?

    // Space key extension
    private var spaceHeld    = false
    private var spacePressed = false

    // Speculative execution
    private var speculativeResult: String? = nil
    private var speculationID = 0

    // 議事録用: 最後の録音ファイル
    private var lastAudioURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenu()
        reregisterHotkey()
        recorder.prepare()

        // インストール/アップデート後に必ずオンボーディングを表示
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let lastSeenVersion = UserDefaults.standard.string(forKey: "lastOnboardingVersion") ?? ""
        let isNewVersion = lastSeenVersion != currentVersion
        let needsSetup = !ModelDownloader.shared.isModelAvailable || !AXIsProcessTrusted() || isNewVersion

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
    private func loadEmbeddedWhisper() {
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
        let header = NSMenuItem(title: "Koe — \(AppSettings.shared.shortcutDisplayString) で録音 [\(badge)]", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let meetingTitle = MeetingMode.shared.isActive
            ? "🔴 議事録停止 (\(MeetingMode.shared.entryCount)件)"
            : "⚫ 議事録開始"
        menu.addItem(withTitle: meetingTitle, action: #selector(toggleMeetingMode), keyEquivalent: "m")
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

        switch event.type {
        case .keyDown:
            // ESC → キャンセル
            if event.keyCode == 53, isRecording {
                DispatchQueue.main.async { self.cancelRecording() }; return
            }
            // Space → 録音延長 or 2回目で変換
            if event.keyCode == 49, isRecording, !event.isARepeat {
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
            // Space 離した → 変換
            if event.keyCode == 49, isRecording, spaceHeld {
                spaceHeld = false
                DispatchQueue.main.async { self.stopAndRecognize() }
                return
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
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let lvl = self.recorder.currentLevel()
            self.overlay?.updateLevel(lvl)
            self.updateSilenceDetection(level: lvl)
        }
    }

    private func stopAndRecognize() {
        levelTimer?.invalidate(); levelTimer = nil
        overlay?.updateLevel(0)
        klog("stopAndRecognize")
        isRecording = false
        setIcon(recording: false)

        guard let audioURL = recorder.stop() else {
            overlay?.hide(); return
        }
        lastAudioURL = audioURL
        overlay?.clearHint()
        overlay?.show(state: .recognizing)

        let profile = AppSettings.shared.profile(for: activeAppBundleID)

        // コンテキスト収集（アプリ名・ウィンドウ・クリップボード・選択テキスト）
        let contextPrompt = ContextCollector.collect(
            appBundleID: activeAppBundleID,
            profilePrompt: profile?.prompt ?? ""
        )
        klog("Context prompt: '\(String(contextPrompt.prefix(100)))'")

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
        // Whisperが返す改行を除去（明示的に指示がない限り改行なし）
        let cleaned = raw.replacingOccurrences(of: "\n", with: " ")
                         .replacingOccurrences(of: "\r", with: "")
                         .trimmingCharacters(in: .whitespaces)
        let expanded = AppSettings.shared.expand(cleaned)
        let instruction = profile?.llmInstruction ?? ""
        LLMProcessor.shared.process(text: expanded, instruction: instruction) { [weak self] final in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overlay?.hide()
                klog("final: '\(final)'")
                if !final.isEmpty {
                    HistoryStore.shared.add(final)
                    MeetingMode.shared.append(text: final, audioURL: self.lastAudioURL)
                    self.typer.type(final)
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
        klog("cancelRecording")
        levelTimer?.invalidate(); levelTimer = nil
        overlay?.updateLevel(0)
        isRecording = false
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        levelTimer?.invalidate()
    }
}
