import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = RecordingManager()
    @StateObject private var modelManager = ModelManager.shared
    @ObservedObject private var whisper = WhisperContext.shared
    @ObservedObject private var macBridge = MacBridge.shared
    @ObservedObject private var appState = AppState.shared
    @State private var showSettings = false
    // appState removed — use appState instead
    @State private var copiedFeedback = false
    @State private var sentToMac = false
    @State private var trackpadMode = false
    @State private var pinInput = ""
    @AppStorage("koe_dismissed_mac_promo") private var dismissedMacPromo = false
    @AppStorage("koe_agent_mode") private var agentModeEnabled = false
    @State private var showFeedbackSheet = false
    @State private var longPressStart: Date?
    @State private var longPressTimer: Timer?
    @AppStorage("koe_llm_enabled", store: .koeShared) private var llmEnabled = false
    @AppStorage("koe_llm_mode", store: .koeShared) private var llmMode = "correct"
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @AppStorage("koe_streaming_preview", store: .koeShared) private var streamingPreview = false
    @AppStorage("koe_phrase_palette") private var phrasePaletteEnabled = false
    @AppStorage("koe_watch_enabled") private var watchEnabled = false
    @AppStorage("koe_always_listening") private var alwaysListening = false
    @ObservedObject private var phraseManager = PhraseManager.shared
    @StateObject private var wakeDetector = WakeWordDetector.shared
    @StateObject private var tts = KoeTTS.shared
    @AppStorage("koe_handsfree") private var handsFree = false
    @AppStorage("koe_handsfree_speakback") private var handsFreeSpeakback = false
    @State private var speakWork: DispatchWorkItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Minimal status bar
                if macBridge.isConnected {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(macBridge.activeAppName.isEmpty ? "Mac" : macBridge.activeAppName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if agentModeEnabled {
                            Button {
                                agentModeEnabled.toggle()
                                MacBridge.shared.sendToggleAgent(enabled: agentModeEnabled)
                            } label: {
                                Text("Agent")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                // ハンズフリー状態インジケータ（聞いてます/考え中/返答中）
                if handsFree {
                    handsFreeIndicator
                        .padding(.top, 6)
                }

                Spacer()

                // Idle hero — modern wordmark on the empty home screen
                if recorder.recognizedText.isEmpty && !recorder.isRecording && !handsFree {
                    idleHero
                        .padding(.bottom, 8)
                }

                // Result — the only thing that matters
                if !recorder.recognizedText.isEmpty {
                    resultCard
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                // Quick actions (only when Mac connected + result exists)
                if macBridge.isConnected && !recorder.recognizedText.isEmpty {
                    macSwipeArea
                }

                // Phrase chips (compact, only when enabled + connected)
                if phrasePaletteEnabled && macBridge.isConnected && !phraseManager.phrases.isEmpty {
                    phraseChips
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }

                Spacer()

                // Wake word listening indicator
                if wakeDetector.isListening {
                    HStack(spacing: 6) {
                        Image(systemName: "ear")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(L10n.wakeWordHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }

                // Status
                Text(recorder.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .animation(.easeInOut, value: recorder.statusText)

                // Model download (compact, only when needed)
                if !modelManager.isModelReady && !modelManager.isDownloading {
                    downloadPrompt
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }

                if modelManager.isDownloading {
                    downloadProgress
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }

                // Streaming preview (real-time Apple Speech during Whisper recording)
                if streamingPreview && recorder.isRecording && !recorder.streamingText.isEmpty {
                    streamingPreviewView
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                // Record button
                RecordButton(isRecording: recorder.isRecording, level: recorder.audioLevel) {
                    if recorder.isRecording { recorder.stopRecording() }
                    else { recorder.startRecording() }
                }
                .padding(.bottom, 32)
            }
            .background(ambientBackground)
            .contentShape(Rectangle())
            .gesture(
                // Hold 0.8s → haptic → drag to move mouse
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard macBridge.isConnected else { return }
                        if longPressStart == nil {
                            // Finger just touched — start timer
                            longPressStart = Date()
                            longPressTimer?.invalidate()
                            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
                                DispatchQueue.main.async {
                                    if !trackpadMode {
                                        trackpadMode = true
                                        lastDragPos = drag.location
                                        let gen = UIImpactFeedbackGenerator(style: .medium)
                                        gen.impactOccurred()
                                    }
                                }
                            }
                        } else if trackpadMode {
                            // Already in trackpad mode — move mouse
                            if let last = lastDragPos {
                                let dx = drag.location.x - last.x
                                let dy = drag.location.y - last.y
                                if abs(dx) > 0.5 || abs(dy) > 0.5 {
                                    MacBridge.shared.sendMouseMove(dx: dx * 2, dy: dy * 2)
                                }
                            }
                            lastDragPos = drag.location
                        }
                    }
                    .onEnded { _ in
                        longPressTimer?.invalidate()
                        longPressTimer = nil
                        longPressStart = nil
                        lastDragPos = nil
                    }
            )
            .overlay {
                if trackpadMode {
                    trackpadOverlay
                        .transition(.opacity)
                }
            }
            .navigationTitle("Koe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { appState.selectedTab = 1 } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.subheadline)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showFeedbackSheet = true
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.orange.opacity(0.85), in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 100)
            }
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackView(screenName: "Koe")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(recorder: recorder)
            }
            .alert("本人声", isPresented: Binding(
                get: { if case .error = tts.state { return true } else { return false } },
                set: { if !$0 { tts.state = .idle } }
            )) {
                Button("閉じる", role: .cancel) {}
            } message: {
                if case let .error(msg) = tts.state { Text(msg) }
            }
            .onChange(of: appState.shouldStartRecording) { _, shouldStart in
                if shouldStart && !recorder.isRecording {
                    recorder.startRecording()
                    appState.shouldStartRecording = false
                }
            }
            .onAppear {
                recorder.requestPermissions()
                if modelManager.isModelReady && !whisper.isLoaded && !whisper.isLoading {
                    modelManager.loadWhisperModel { _ in }
                }
                MacBridge.shared.startBrowsing()
                if watchEnabled { WatchRelay.shared.start() }

                // Wake word detector setup
                wakeDetector.onWakeWordDetected = { [weak recorder] in
                    guard let recorder, !recorder.isRecording else { return }
                    recorder.startRecording()
                }
                if alwaysListening && !handsFree && !recorder.isRecording {
                    wakeDetector.start()
                }

                // ハンズフリー: 開いたらすぐ聴き取り開始（録音→無音で区切り→自動再開）
                if handsFree && !recorder.isRecording {
                    startHandsFree()
                }
            }
            .onChange(of: handsFree) { _, on in
                if on {
                    startHandsFree()
                } else {
                    recorder.continuousMode = false
                    if recorder.isRecording { recorder.stopRecording() }
                }
            }
            .onChange(of: handsFreeSpeakback) { _, _ in
                // 読み返しON/OFFで自動再開の担当が変わる（素=continuous / 読み返し=自前ループ）
                if handsFree { recorder.continuousMode = !handsFreeSpeakback }
            }
            .onChange(of: tts.state) { _, st in
                // ハンズフリー＋読み返し: 再生が終わったら録音を再開
                if handsFree, handsFreeSpeakback, st == .idle, !recorder.isRecording {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if handsFree && handsFreeSpeakback && !recorder.isRecording && tts.state == .idle {
                            recorder.startRecording()
                        }
                    }
                }
            }
            .onChange(of: alwaysListening) { _, enabled in
                if enabled && !recorder.isRecording {
                    wakeDetector.start()
                } else if !enabled {
                    wakeDetector.stop()
                }
            }
            .onChange(of: recorder.recognizedText) { _, text in
                // 文字化は録音停止より後に非同期(partial→final)で来る。最終結果が落ち着くまで
                // デバウンスしてから本人声で読み返す（途中結果で喋らない）。
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if handsFree, handsFreeSpeakback, !t.isEmpty, !recorder.isRecording, tts.state == .idle {
                    speakWork?.cancel()
                    let work = DispatchWorkItem {
                        let cur = recorder.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if handsFree, handsFreeSpeakback, !cur.isEmpty, !recorder.isRecording, tts.state == .idle {
                            Task { await tts.speakInMyVoice(cur) }
                        }
                    }
                    speakWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                }
            }
            .onChange(of: recorder.isRecording) { _, isRecording in
                if isRecording {
                    wakeDetector.stop()
                } else if handsFree && handsFreeSpeakback {
                    // 安全網: 無音で結果が来なかった時だけ少し後に再開（結果が来れば読み返し→tts idleで再開）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        let empty = recorder.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if handsFree && handsFreeSpeakback && !recorder.isRecording && tts.state == .idle && empty {
                            recorder.startRecording()
                        }
                    }
                } else if alwaysListening {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if alwaysListening && !recorder.isRecording {
                            wakeDetector.start()
                        }
                    }
                }
            }
            .alert(L10n.connectToMac, isPresented: Binding(
                get: { macBridge.pendingPINPeer != nil },
                set: { if !$0 { macBridge.cancelPINEntry() } }
            )) {
                TextField(L10n.enterPIN, text: $pinInput)
                    .keyboardType(.numberPad)
                Button(L10n.connect) {
                    macBridge.submitPIN(pinInput)
                    pinInput = ""
                }
                Button(L10n.cancelAction, role: .cancel) {
                    macBridge.cancelPINEntry()
                    pinInput = ""
                }
            } message: {
                Text(L10n.pinPrompt)
            }
        }
    }

    private func speak(lang: String) {
        switch tts.state {
        case .loading, .playing: break
        default: Task { await tts.speakInMyVoice(recorder.recognizedText, lang: lang) }
        }
    }

    // ハンズフリー時、自動停止が無効なら無音1.5秒で止まるようにする
    private func ensureSilenceAutoStop() {
        let cur = UserDefaults.koeShared.object(forKey: "koe_silence_duration") as? Double ?? 0
        if cur == 0 {
            UserDefaults.koeShared.set(1.5, forKey: "koe_silence_duration")
        }
    }

    /// ハンズフリー開始：無音停止を確保し、素モードはcontinuousで自動再開、読み返しモードは自前ループ。
    private func startHandsFree() {
        ensureSilenceAutoStop()
        wakeDetector.stop()
        recorder.continuousMode = !handsFreeSpeakback
        if !recorder.isRecording { recorder.startRecording() }
    }

    // MARK: - Ambient Background

    private var ambientBackground: some View {
        ZStack {
            Color(.systemBackground)
            // Warm glow drifting from the record button area
            RadialGradient(
                colors: [Color.orange.opacity(recorder.isRecording ? 0.0 : 0.22), .clear],
                center: .bottom, startRadius: 40, endRadius: 460
            )
            RadialGradient(
                colors: [Color.red.opacity(recorder.isRecording ? 0.22 : 0.0), .clear],
                center: .bottom, startRadius: 40, endRadius: 500
            )
            .animation(.easeInOut(duration: 0.4), value: recorder.isRecording)
            // Cool tint at top for depth
            RadialGradient(
                colors: [Color.blue.opacity(0.10), .clear],
                center: .topTrailing, startRadius: 20, endRadius: 420
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.07), .clear],
                center: .topLeading, startRadius: 20, endRadius: 360
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Hands-free status indicator

    private var handsFreeIndicator: some View {
        let (icon, label, color): (String, String, Color) = {
            if tts.state == .playing { return ("speaker.wave.2.fill", "本人声で返答中…", .pink) }
            if tts.state == .loading { return ("ellipsis", "考え中…", .blue) }
            if recorder.isRecording { return ("waveform", "聞いています…話してください", .orange) }
            return ("hand.wave.fill", "話しかけてください", .secondary)
        }()
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: recorder.isRecording || tts.state == .playing)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            if recorder.isRecording {
                // 簡易レベルメーター
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 4 + CGFloat(recorder.audioLevel) * 40, height: 4)
                    .animation(.easeOut(duration: 0.1), value: recorder.audioLevel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Idle Hero (shown on the home screen when there's no result)

    private var idleHero: some View {
        VStack(spacing: 10) {
            Text("Koe")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.42, blue: 0.22)],
                                   startPoint: .leading, endPoint: .trailing)
                )
            Text("話すだけで、文字になる。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .transition(.opacity)
    }

    // MARK: - Result Card

    @State private var lastSentText = ""

    private var resultCard: some View {
        VStack(spacing: 0) {
            // Editable text — syncs to Mac in real-time when autoSendMac is on
            TextEditor(text: $recorder.recognizedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: 200)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .onChange(of: recorder.recognizedText) { _, newText in
                    // Real-time sync: if auto-send on and Mac connected
                    if recorder.autoSendMac && macBridge.isConnected && sentToMac {
                        // Send backspace for removed chars, then new text
                        if newText.count < lastSentText.count {
                            let diff = lastSentText.count - newText.count
                            MacBridge.shared.sendBackspace(count: diff)
                        } else if newText != lastSentText {
                            // Incremental: send only the new part
                            let newPart = String(newText.dropFirst(lastSentText.count))
                            if !newPart.isEmpty {
                                MacBridge.shared.sendText(newPart)
                            }
                        }
                        lastSentText = newText
                    }
                }

            // Action bar
            HStack(spacing: 16) {
                // Copy
                Button {
                    UIPasteboard.general.string = recorder.recognizedText
                    withAnimation { copiedFeedback = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        withAnimation { copiedFeedback = false }
                    }
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 18))
                        .foregroundStyle(copiedFeedback ? .green : .secondary)
                }

                // 本人の声で再生（話す→本人クローン声で読み上げ）
                Button {
                    switch tts.state {
                    case .loading, .playing:
                        break
                    default:
                        Task { await tts.speakInMyVoice(recorder.recognizedText) }
                    }
                } label: {
                    Group {
                        switch tts.state {
                        case .loading:
                            ProgressView().controlSize(.small)
                        case .playing:
                            Image(systemName: "waveform.circle.fill")
                                .symbolEffect(.variableColor.iterative, options: .repeating)
                        default:
                            Image(systemName: "person.wave.2.fill")
                        }
                    }
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                }
                .contextMenu {
                    Section("翻訳して本人声で") {
                        Button { speak(lang: "en") } label: { Label("English", systemImage: "globe") }
                        Button { speak(lang: "zh") } label: { Label("中文", systemImage: "globe") }
                        Button { speak(lang: "es") } label: { Label("Español", systemImage: "globe") }
                        Button { speak(lang: "ko") } label: { Label("한국어", systemImage: "globe") }
                    }
                }

                // Backspace (delete last on Mac)
                if macBridge.isConnected {
                    Button {
                        MacBridge.shared.sendBackspace(count: 1)
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Mac send / Enter
                if macBridge.isConnected {
                    if recorder.autoSendMac {
                        Button {
                            MacBridge.shared.sendEnter()
                            recorder.recognizedText = ""
                            lastSentText = ""
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "return")
                                Text("Enter")
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.orange, in: Capsule())
                            .foregroundStyle(.white)
                        }
                    } else {
                        Button {
                            if sentToMac {
                                MacBridge.shared.sendEnter()
                                recorder.recognizedText = ""
                                lastSentText = ""
                                withAnimation { sentToMac = false }
                            } else {
                                MacBridge.shared.sendText(recorder.recognizedText)
                                lastSentText = recorder.recognizedText
                                withAnimation { sentToMac = true }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: sentToMac ? "return" : "paperplane.fill")
                                Text(sentToMac ? "Enter" : "Mac")
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(sentToMac ? .orange : .blue, in: Capsule())
                            .foregroundStyle(.white)
                        }
                    }
                }

                // Agent: send recognized text as agent command
                if macBridge.isConnected && agentModeEnabled {
                    Button {
                        MacBridge.shared.sendText(recorder.recognizedText)
                        let gen = UIImpactFeedbackGenerator(style: .medium)
                        gen.impactOccurred()
                        recorder.recognizedText = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "brain.filled.head.profile")
                            Text("Agent")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.purple, in: Capsule())
                        .foregroundStyle(.white)
                    }
                }

                // Share
                ShareLink(item: recorder.recognizedText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    // MARK: - Mac Promo Banner

    private var macPromoBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.macPromoTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.macPromoSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismissedMacPromo = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Link(destination: URL(string: "https://app.koe.live")!) {
                Text(L10n.downloadMacFree)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Suggestion Chips

    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(L10n.nextAction)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(macBridge.suggestions, id: \.self) { suggestion in
                        Button {
                            MacBridge.shared.sendText(suggestion)
                            let gen = UIImpactFeedbackGenerator(style: .light)
                            gen.impactOccurred()
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Phrase Chips

    private var phraseChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(L10n.phrases)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(phraseManager.phrases, id: \.self) { phrase in
                        Button {
                            MacBridge.shared.sendText(phrase)
                            let gen = UIImpactFeedbackGenerator(style: .light)
                            gen.impactOccurred()
                        } label: {
                            Text(phrase)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Trackpad

    @State private var lastDragPos: CGPoint?

    private var trackpadOverlay: some View {
        ZStack {
            // Background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "hand.point.up.left")
                        .foregroundStyle(.orange)
                    Text(L10n.trackpad)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        withAnimation { trackpadMode = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Trackpad area
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if let last = lastDragPos {
                                    let dx = value.location.x - last.x
                                    let dy = value.location.y - last.y
                                    MacBridge.shared.sendMouseMove(dx: dx * 2, dy: dy * 2)
                                }
                                lastDragPos = value.location
                            }
                            .onEnded { _ in
                                lastDragPos = nil
                            }
                    )
                    .onTapGesture {
                        MacBridge.shared.sendCommand("click")
                    }

                // Bottom buttons
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        trackpadBtn(L10n.click, "hand.tap") { MacBridge.shared.sendCommand("click") }
                        trackpadBtn(L10n.rightClick, "hand.tap") { MacBridge.shared.sendCommand("rightClick") }
                        trackpadBtn("ESC", "escape") { MacBridge.shared.sendCommand("escape") }
                    }
                    HStack(spacing: 8) {
                        trackpadBtn(L10n.scrollUp, "chevron.up") { MacBridge.shared.sendCommand("scrollUp") }
                        trackpadBtn(L10n.scrollDown, "chevron.down") { MacBridge.shared.sendCommand("scroll") }
                        trackpadBtn("Space", "space") { MacBridge.shared.sendCommand("space") }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .buttonStyle(.plain)
            }
        }
    }

    private func trackpadBtn(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
    }

    // MARK: - Mac Swipe Control

    @State private var swipeFeedback = ""
    @State private var showAllControls = false

    private var macSwipeArea: some View {
        VStack(spacing: 6) {
            // Primary controls: Tab + Enter only
            HStack(spacing: 12) {
                // Prev Tab
                Button {
                    MacBridge.shared.sendCommand("prevTab")
                    showFeedback("← Tab")
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }

                // Next Tab
                Button {
                    MacBridge.shared.sendCommand("nextTab")
                    showFeedback("Tab →")
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 36)
                        .contentShape(Rectangle())
                }

                Spacer()

                // Enter button
                Button {
                    MacBridge.shared.sendEnter()
                    showFeedback("Enter ⏎")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 12, weight: .medium))
                        Text("Enter")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange, in: Capsule())
                }

                // Expand button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllControls.toggle()
                    }
                } label: {
                    Image(systemName: showAllControls ? "chevron.up" : "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color.secondary.opacity(0.1), in: Circle())
                }
            }
            .padding(.horizontal, 8)

            // Feedback text
            if !swipeFeedback.isEmpty {
                Text(swipeFeedback)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            // Expanded: all Mac controls
            if showAllControls {
                VStack(spacing: 8) {
                    // Row 1: Navigation
                    HStack(spacing: 8) {
                        macControlBtn("⌘Tab", icon: "rectangle.on.rectangle", command: "appSwitch")
                        macControlBtn("Mission", icon: "rectangle.3.group", command: "missionControl")
                        macControlBtn("ESC", icon: "escape", command: "escape")
                        macControlBtn("Space", icon: "space", command: "space")
                    }
                    // Row 2: Edit
                    HStack(spacing: 8) {
                        macControlBtn("⌘Z", icon: "arrow.uturn.backward", command: "undo")
                        macControlBtn("⌘C", icon: "doc.on.doc", command: "copy")
                        macControlBtn("⌘V", icon: "doc.on.clipboard", command: "paste")
                        macControlBtn("⌘W", icon: "xmark.square", command: "closeWindow")
                    }
                    // Row 3: Media + System
                    HStack(spacing: 8) {
                        macControlBtn("⏯", icon: "playpause", command: "space")
                        macControlBtn("🔊+", icon: "speaker.plus", command: "volumeUp")
                        macControlBtn("🔊-", icon: "speaker.minus", command: "volumeDown")
                        macControlBtn("Click", icon: "hand.tap", command: "click")
                    }
                    // Row 4: Scroll
                    HStack(spacing: 8) {
                        macControlBtn("↑ Scroll", icon: "chevron.up", command: "scrollUp")
                        macControlBtn("↓ Scroll", icon: "chevron.down", command: "scroll")
                        macControlBtn("R-Click", icon: "hand.tap", command: "rightClick")
                        macControlBtn("Tab", icon: "arrow.right.to.line", command: "tab")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .buttonStyle(.plain)
    }

    private func macControlBtn(_ title: String, icon: String, command: String) -> some View {
        Button {
            MacBridge.shared.sendCommand(command)
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred()
            showFeedback(title)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func showFeedback(_ text: String) {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        withAnimation { swipeFeedback = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation { swipeFeedback = "" }
        }
    }

    // MARK: - Download

    private var downloadPrompt: some View {
        Button {
            modelManager.download(modelManager.currentModel)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                Text(L10n.downloadHighAccuracyModel)
                    .font(.subheadline)
                Spacer()
                Text("\(modelManager.currentModel.sizeMB)MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var downloadProgress: some View {
        VStack(spacing: 6) {
            ProgressView(value: modelManager.downloadProgress)
                .tint(.orange)
            HStack {
                Text(modelManager.downloadStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.cancel) { modelManager.cancelDownload() }
                    .font(.caption)
            }
        }
    }

    // MARK: - Streaming Preview

    @State private var streamingDotOpacity: Double = 0.3

    private var streamingPreviewView: some View {
        HStack(alignment: .top, spacing: 6) {
            // Pulsing dot indicator
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .opacity(streamingDotOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        streamingDotOpacity = 1.0
                    }
                }
                .onDisappear {
                    streamingDotOpacity = 0.3
                }
                .padding(.top, 5)

            Text(recorder.streamingText)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.6))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Record Button

struct RecordButton: View {
    let isRecording: Bool
    let level: Float
    let action: () -> Void

    @State private var breathe = false

    private var accent: Color { isRecording ? .red : .orange }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Audio-reactive halo (recording)
                if isRecording {
                    Circle()
                        .fill(
                            RadialGradient(colors: [Color.red.opacity(0.30), .clear],
                                           center: .center, startRadius: 10, endRadius: 90)
                        )
                        .frame(width: 150 + CGFloat(level) * 90,
                               height: 150 + CGFloat(level) * 90)
                        .animation(.easeOut(duration: 0.10), value: level)
                }

                // Ambient glow (idle breathing)
                Circle()
                    .fill(
                        RadialGradient(colors: [accent.opacity(0.22), .clear],
                                       center: .center, startRadius: 5, endRadius: 70)
                    )
                    .frame(width: 130, height: 130)
                    .scaleEffect(breathe ? 1.08 : 0.94)
                    .opacity(isRecording ? 0 : 1)

                // Outer ring
                Circle()
                    .stroke(
                        AngularGradient(colors: [accent.opacity(0.5), accent.opacity(0.15), accent.opacity(0.5)],
                                        center: .center),
                        lineWidth: 2.5
                    )
                    .frame(width: 86, height: 86)

                // Core
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isRecording
                                    ? [Color(red: 1.0, green: 0.30, blue: 0.30), Color(red: 0.85, green: 0.12, blue: 0.18)]
                                    : [Color.orange, Color(red: 1.0, green: 0.42, blue: 0.22)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 70, height: 70)
                        .shadow(color: accent.opacity(0.45), radius: 12, y: 5)

                    if isRecording {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white)
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact, trigger: isRecording)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
