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
    @AppStorage("koe_llm_enabled") private var llmEnabled = false
    @AppStorage("koe_llm_mode") private var llmMode = "correct"
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @AppStorage("koe_streaming_preview") private var streamingPreview = false
    @AppStorage("koe_phrase_palette") private var phrasePaletteEnabled = false
    @AppStorage("koe_watch_enabled") private var watchEnabled = false
    @AppStorage("koe_always_listening") private var alwaysListening = false
    @ObservedObject private var phraseManager = PhraseManager.shared
    @StateObject private var wakeDetector = WakeWordDetector.shared

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

                Spacer()

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
                if alwaysListening && !recorder.isRecording {
                    wakeDetector.start()
                }
            }
            .onChange(of: alwaysListening) { _, enabled in
                if enabled && !recorder.isRecording {
                    wakeDetector.start()
                } else if !enabled {
                    wakeDetector.stop()
                }
            }
            .onChange(of: recorder.isRecording) { _, isRecording in
                // Stop wake word detector when recording starts,
                // restart when recording finishes (if always-listening is on)
                if isRecording {
                    wakeDetector.stop()
                } else if alwaysListening {
                    // Short delay to allow audio session to settle
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

    var body: some View {
        Button(action: action) {
            ZStack {
                // Pulse ring
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.08))
                        .frame(width: 100 + CGFloat(level) * 50,
                               height: 100 + CGFloat(level) * 50)
                        .animation(.easeOut(duration: 0.08), value: level)
                }

                // Outer ring
                Circle()
                    .stroke(isRecording ? Color.red.opacity(0.4) : Color.orange.opacity(0.3), lineWidth: 2)
                    .frame(width: 80, height: 80)

                // Inner circle
                if isRecording {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.orange, Color.orange.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.white)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact, trigger: isRecording)
    }
}
