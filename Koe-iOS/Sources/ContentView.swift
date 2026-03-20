import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = RecordingManager()
    @StateObject private var modelManager = ModelManager.shared
    @ObservedObject private var whisper = WhisperContext.shared
    @ObservedObject private var macBridge = MacBridge.shared
    @ObservedObject private var appState = AppState.shared
    @State private var showSettings = false
    @ObservedObject private var appState2 = AppState.shared
    @State private var copiedFeedback = false
    @State private var sentToMac = false
    @State private var trackpadMode = false
    @AppStorage("koe_llm_enabled") private var llmEnabled = false
    @AppStorage("koe_llm_mode") private var llmMode = "correct"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mac connection status
                if macBridge.isConnected {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("Macに接続中")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !macBridge.activeAppName.isEmpty {
                                Text("· \(macBridge.activeAppName)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if llmEnabled && llmMode == "translate" {
                            HStack(spacing: 4) {
                                Text("\u{1f1ef}\u{1f1f5}\u{2192}\u{1f1fa}\u{1f1f8}")
                                    .font(.caption2)
                                Text("翻訳モード")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }

                Spacer()

                // Result text area — swipe left/right to switch Mac tabs
                if !recorder.recognizedText.isEmpty {
                    resultCard
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                // Mac tab switcher (swipe area when connected)
                if macBridge.isConnected {
                    macSwipeArea
                }

                Spacer()

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

                // Record button
                RecordButton(isRecording: recorder.isRecording, level: recorder.audioLevel) {
                    if recorder.isRecording { recorder.stopRecording() }
                    else { recorder.startRecording() }
                }
                .padding(.bottom, 32)
            }
            .contentShape(Rectangle())
            .gesture(
                // Long press → haptic → drag to move mouse (without lifting finger)
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard macBridge.isConnected else { return }
                        switch value {
                        case .first(true):
                            // Long press recognized — enter trackpad
                            if !trackpadMode {
                                trackpadMode = true
                                lastDragPos = nil
                                let gen = UIImpactFeedbackGenerator(style: .medium)
                                gen.impactOccurred()
                            }
                        case .second(true, let drag):
                            // Dragging after long press — move mouse
                            if let drag {
                                if let last = lastDragPos {
                                    let dx = drag.location.x - last.x
                                    let dy = drag.location.y - last.y
                                    MacBridge.shared.sendMouseMove(dx: dx * 2, dy: dy * 2)
                                }
                                lastDragPos = drag.location
                            }
                        default: break
                        }
                    }
                    .onEnded { _ in
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
                    Button { appState2.selectedTab = 1 } label: {
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
                    Text("トラックパッド")
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
                        trackpadBtn("クリック", "hand.tap") { MacBridge.shared.sendCommand("click") }
                        trackpadBtn("右クリック", "hand.tap") { MacBridge.shared.sendCommand("rightClick") }
                        trackpadBtn("ESC", "escape") { MacBridge.shared.sendCommand("escape") }
                    }
                    HStack(spacing: 8) {
                        trackpadBtn("↑スクロール", "chevron.up") { MacBridge.shared.sendCommand("scrollUp") }
                        trackpadBtn("↓スクロール", "chevron.down") { MacBridge.shared.sendCommand("scroll") }
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

    private var macSwipeArea: some View {
        HStack(spacing: 0) {
            // Left tap → previous tab
            Button {
                MacBridge.shared.sendCommand("prevTab")
                withAnimation { swipeFeedback = "← 前のタブ" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation { swipeFeedback = "" }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, height: 44)
                    .contentShape(Rectangle())
            }

            // Center — swipe + label
            Text(swipeFeedback.isEmpty ? "Macタブ切替" : swipeFeedback)
                .font(.caption2)
                .foregroundColor(swipeFeedback.isEmpty ? .gray.opacity(0.5) : .orange)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            if value.translation.width > 40 {
                                MacBridge.shared.sendCommand("nextTab")
                                withAnimation { swipeFeedback = "次のタブ →" }
                            } else if value.translation.width < -40 {
                                MacBridge.shared.sendCommand("prevTab")
                                withAnimation { swipeFeedback = "← 前のタブ" }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                withAnimation { swipeFeedback = "" }
                            }
                        }
                )

            // Right tap → next tab
            Button {
                MacBridge.shared.sendCommand("nextTab")
                withAnimation { swipeFeedback = "次のタブ →" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation { swipeFeedback = "" }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Download

    private var downloadPrompt: some View {
        Button {
            modelManager.download(modelManager.currentModel)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                Text("高精度モデルをダウンロード")
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
                Button("中止") { modelManager.cancelDownload() }
                    .font(.caption)
            }
        }
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
