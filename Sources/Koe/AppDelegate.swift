import AppKit
import Speech

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var overlay: OverlayWindow?
    private var settingsWC: SettingsWindowController?
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
    private var spaceHeld    = false  // 現在スペース長押し中
    private var spacePressed = false  // 今回の録音でスペースを1回押した

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMenu()
        speech.requestPermissions()
        checkAccessibility()
        reregisterHotkey()
        recorder.prepare()
        WhisperServer.shared.start()

        WakeWordDetector.shared.onDetected = { [weak self] in self?.startRecording() }
        if AppSettings.shared.wakeWordEnabled { WakeWordDetector.shared.start() }
        if AppSettings.shared.floatingButtonEnabled { FloatingButton.shared.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperServer.shared.stop()
        WakeWordDetector.shared.stop()
    }

    // MARK: - Status Bar

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Koe — \(AppSettings.shared.shortcutDisplayString) で録音", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        let meetingTitle = MeetingMode.shared.isActive
            ? "🔴 議事録停止 (\(MeetingMode.shared.entryCount)件)"
            : "⚫ 議事録開始"
        menu.addItem(withTitle: meetingTitle, action: #selector(toggleMeetingMode), keyEquivalent: "m")
        menu.addItem(.separator())
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",")
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
        spaceHeld      = false
        spacePressed   = false
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
        overlay?.clearHint()
        overlay?.show(state: .recognizing)

        let profile = AppSettings.shared.profile(for: activeAppBundleID)
        speech.recognize(url: audioURL,
                         prompt: profile?.prompt ?? "",
                         languageOverride: profile?.language ?? "") { [weak self] raw in
            guard let self else { return }
            let expanded = AppSettings.shared.expand(raw)
            let instruction = profile?.llmInstruction ?? ""
            LLMProcessor.shared.process(text: expanded, instruction: instruction) { final in
                DispatchQueue.main.async {
                    self.overlay?.hide()
                    klog("final: '\(final)'")
                    if !final.isEmpty {
                        HistoryStore.shared.add(final)
                        MeetingMode.shared.append(text: final)
                        self.typer.type(final)
                    }
                    self.rebuildMenu()
                    // Restart wake word after done
                    if AppSettings.shared.wakeWordEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            WakeWordDetector.shared.start()
                        }
                    }
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
            silenceStart = nil
        } else if speechDetected && level < silenceThreshold {
            if silenceStart == nil { silenceStart = Date() }
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        levelTimer?.invalidate()
    }
}
