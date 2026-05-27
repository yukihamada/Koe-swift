import AppKit
import SwiftUI

enum OverlayState {
    case recording
    case recognizing
}

class OverlayWindow: NSPanel {
    private var stateModel = OverlayStateModel()
    /// ⌥ キー押下中だけ drag を許可するため flagsChanged をリッスン
    private var flagsMonitor: Any?

    init() {
        let isLarge = AppSettings.shared.overlayLargeTextMode
        let w: CGFloat = isLarge ? 600 : 300
        let h: CGFloat = isLarge ? 120 : 56
        // ヘッドレス / Screen Sharing 切断時に NSScreen.screens が空になり得るので
        // どちらも nil なら 0,0 origin にフォールバック（直後の show() で再配置される）
        let screen = NSScreen.main ?? NSScreen.screens.first
        let rect: CGRect
        // 保存されたユーザー位置があれば優先
        let settings = AppSettings.shared
        if settings.overlayHasCustomOrigin {
            rect = CGRect(x: settings.overlayOriginX, y: settings.overlayOriginY, width: w, height: h)
        } else if let screen = screen {
            rect = CGRect(
                x: screen.frame.midX - w / 2,
                y: screen.visibleFrame.minY + 32,
                width: w, height: h
            )
        } else {
            rect = CGRect(x: 0, y: 32, width: w, height: h)
        }
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // デフォルトは clickthrough。⌥ 押下中だけ drag のため flagsChanged で切替
        ignoresMouseEvents = true
        isMovable = false  // ⌥ で許可するまで動かせない
        stateModel.isLargeTextMode = isLarge
        let hosting = NSHostingView(rootView: OverlayView(model: stateModel))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        contentView = hosting

        // ⌥ で drag enable / 離して disable
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self else { return }
            let optDown = event.modifierFlags.contains(.option)
            DispatchQueue.main.async {
                self.ignoresMouseEvents = !optDown
                self.isMovable = optDown
                self.isMovableByWindowBackground = optDown
            }
        }
    }

    deinit {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }

    /// drag で動かしたあと位置を AppSettings に保存
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        if isMovable {
            // ユーザーが意図的に動かした (⌥ 押下中) ときだけ保存
            let s = AppSettings.shared
            s.overlayOriginX = Double(point.x)
            s.overlayOriginY = Double(point.y)
            s.overlayHasCustomOrigin = true
        }
    }

    /// 配信モード / 通常モード切替時に位置情報をリセット
    func resetCustomOrigin() {
        AppSettings.shared.overlayHasCustomOrigin = false
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let w = frame.width
            setFrameOrigin(NSPoint(x: screen.frame.midX - w / 2, y: screen.visibleFrame.minY + 32))
        }
    }

    func setTranslateMode(_ on: Bool) {
        stateModel.isTranslateMode = on
        if !on { stateModel.modeName = "" }
    }

    func show(state: OverlayState) {
        klog("OverlayWindow.show state=\(state) frame=\(frame) visible=\(stateModel.visible)")
        stateModel.state = state
        stateModel.hint = ""  // always clear hint on show

        let mode = AppSettings.shared.llmMode
        let showMode = state == .recording && !stateModel.isTranslateMode && mode != .none
        stateModel.modeName = showMode ? mode.displayName : ""

        stateModel.visible = true
        alphaValue = 1.0
        klog("OverlayWindow orderFrontRegardless frame=\(frame)")
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard !stateModel.isSeamless else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.stateModel.visible = false
            self.stateModel.hint = ""
            self.orderOut(nil)
        })
    }

    func forceHide() {
        klog("OverlayWindow.forceHide visible=\(stateModel.visible)")
        stateModel.isSeamless = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: {
            guard !self.stateModel.visible else {
                klog("OverlayWindow.forceHide completion: skipped (re-shown)")
                return
            }
            self.stateModel.hint = ""
            self.orderOut(nil)
        })
    }

    func setSeamless(_ on: Bool) {
        klog("OverlayWindow.setSeamless \(on) visible=\(stateModel.visible)")
        stateModel.isSeamless = on
        if !on && stateModel.visible { forceHide() }  // 表示中のみ非表示化（hidden時はスキップ）
    }

    func updateLevel(_ level: Float) {
        stateModel.audioLevel = level
        stateModel.pushLevel(level)

        let mode = AppSettings.shared.llmMode
        let showMode = stateModel.state == .recording && !stateModel.isTranslateMode
            && mode != .none && mode != .correct
        let name = showMode ? mode.displayName : ""
        if stateModel.modeName != name { stateModel.modeName = name }

        if AppSettings.shared.showNoiseLevel {
            let avg = stateModel.levelHistory.suffix(20).reduce(0, +) / 20
            stateModel.noiseLevel = avg > 0.06 ? .poor : avg > 0.03 ? .fair : .good
        }

        // P5 R4 medium: クリッピング警告。peak が連続フレームで 0.95 超なら hint で通知
        if level > 0.95 && stateModel.state == .recording {
            // hint がまだクリッピング系でない場合のみ表示（毎フレーム上書きは避ける）
            if !stateModel.hint.contains("歪") {
                showHint("⚠️ 音量が歪んでいます — マイクから離れるか入力ゲインを下げてください")
            }
        }
    }

    func showHint(_ text: String) {
        guard stateModel.hint != text else { return }
        withAnimation(.easeIn(duration: 0.3)) { stateModel.hint = text }
    }

    func clearHint() {
        guard !stateModel.hint.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { stateModel.hint = "" }
    }

    func updateStreamingText(_ text: String) {
        let truncated = text.count > 150 ? "..." + String(text.suffix(147)) : text
        guard stateModel.streamingText != truncated else { return }
        let wasEmpty = stateModel.streamingText.isEmpty
        withAnimation(.easeInOut(duration: 0.2)) {
            stateModel.streamingText = truncated
        }
        if wasEmpty { resizeWindow(expanded: true) }
    }

    func clearStreamingText() {
        guard !stateModel.streamingText.isEmpty else { return }
        stateModel.streamingText = ""
        resizeWindow(expanded: false)
    }

    private func resizeWindow(expanded: Bool) {
        let w: CGFloat = 300
        let compact: CGFloat = 56
        let full: CGFloat = 116  // 56 main + 10 padding + ~50 for 2 text lines
        let targetH = expanded ? full : compact
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let baseY = screen.visibleFrame.minY + 32
        var f = frame
        f.origin.y = baseY
        f.size = CGSize(width: w, height: targetH)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(f, display: true)
        }
    }
}

class OverlayStateModel: ObservableObject {
    @Published var state: OverlayState = .recording
    @Published var audioLevel: Float = 0
    @Published var visible: Bool = false
    @Published var hint: String = ""
    @Published var modeName: String = ""
    @Published var streamingText: String = ""
    @Published var isTranslateMode: Bool = false
    @Published var noiseLevel: NoiseQuality = .good
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 36)
    @Published var isSeamless: Bool = false
    /// 配信用大文字モード: OBS source 化想定で waveform を隠し、text を 22pt に拡大
    @Published var isLargeTextMode: Bool = false
    var engineBadge: String { AppSettings.shared.recognitionEngine.badgeText }

    enum NoiseQuality { case good, fair, poor }

    func pushLevel(_ level: Float) {
        levelHistory.append(level)
        if levelHistory.count > 36 { levelHistory.removeFirst(levelHistory.count - 36) }
    }
}

// MARK: - Main overlay view

struct OverlayView: View {
    @ObservedObject var model: OverlayStateModel

    private let bg        = Color(red: 0.07, green: 0.07, blue: 0.08)
    private let gold      = Color(red: 0.82, green: 0.72, blue: 0.52)
    private let recRed    = Color(red: 0.95, green: 0.42, blue: 0.34)
    private let blueAcc   = Color(red: 0.45, green: 0.72, blue: 0.95)

    private var hasText: Bool { !model.streamingText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if hasText {
                streamingRow
            }
        }
        .frame(width: 300)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(bg.opacity(0.96))
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(borderGradient, lineWidth: model.isSeamless ? 1.0 : 0.6)
                if model.isSeamless {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(gold.opacity(0.18), lineWidth: 3)
                        .blur(radius: 4)
                        .modifier(SeamlessPulse())
                }
            }
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 6)
        .scaleEffect(model.visible ? 1 : 0.94)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.visible)
    }

    // MARK: Main row

    private var mainRow: some View {
        HStack(spacing: 10) {
            stateIndicator
                .frame(width: 32, height: 32)

            centerContent

            trailingBadge
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if model.state == .recording {
            MicPulseView(color: model.isTranslateMode ? blueAcc : recRed)
        } else {
            SpinnerArcView(color: gold)
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if !model.hint.isEmpty {
            // Hint overrides other content (error/warning message)
            Text(model.hint)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.orange.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if model.state == .recording {
            // 配信モード時は waveform を隠す (P3 指摘: OBS 配信ソースとして "うるさい")
            if !model.isLargeTextMode {
                WaveformView(levels: model.levelHistory, accentColor: model.isTranslateMode ? blueAcc : recRed)
                    .frame(maxWidth: .infinity, maxHeight: 28)
            } else {
                // large mode は単純な録音中インジケータだけにする
                HStack(spacing: 8) {
                    Circle().fill(recRed).frame(width: 10, height: 10)
                    Text("録音中")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.leading, 24)
            }
        } else {
            // Recognizing: show "認識中" label — streaming text appears in streamingRow below
            HStack(spacing: 6) {
                Text("認識中")
                    .font(.system(size: 11, weight: .light, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(1.2)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if model.isSeamless {
                Text("∞")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(gold.opacity(0.9))
                    .modifier(SeamlessPulse())
            } else if !model.modeName.isEmpty {
                Text(model.modeName)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundColor(gold.opacity(0.75))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(gold.opacity(0.10))
                    .cornerRadius(4)
            }
            Text(model.engineBadge)
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // MARK: Streaming text row

    private var streamingRow: some View {
        // P3/P5 指摘: 配信モード時は 22pt まで拡大 + 行数を 3 行に
        let isLarge = model.isLargeTextMode
        return Text(model.streamingText)
            .font(.system(size: isLarge ? 22 : 11, weight: isLarge ? .bold : .regular, design: .rounded))
            .foregroundColor(.white.opacity(isLarge ? 0.95 : 0.55))
            .lineLimit(isLarge ? 3 : 2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isLarge ? 24 : 16)
            .padding(.bottom, isLarge ? 18 : 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Helpers

    private var borderGradient: LinearGradient {
        let c = model.state == .recording
            ? (model.isTranslateMode ? blueAcc : recRed)
            : gold
        return LinearGradient(
            colors: [c.opacity(0.35), c.opacity(0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - Seamless pulse modifier (breathing animation)

struct SeamlessPulse: ViewModifier {
    @State private var phase = false
    func body(content: Content) -> some View {
        content
            .opacity(phase ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

// MARK: - Mic pulse (recording indicator)

struct MicPulseView: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            // outer ring pulse
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 1.5)
                .scaleEffect(pulse ? 1.6 : 1.0)
                .opacity(pulse ? 0 : 0.6)
                .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: pulse)

            Circle()
                .fill(color.opacity(0.12))
                .frame(width: 28, height: 28)

            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Arc spinner (recognizing indicator)

struct SpinnerArcView: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.12), lineWidth: 2)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    AngularGradient(colors: [color, color.opacity(0)], center: .center),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: rotation)
        }
        .onAppear { rotation = 360 }
    }
}

// MARK: - Waveform (recording)

struct WaveformView: View {
    let levels: [Float]
    let accentColor: Color
    private let barCount = 36

    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 3.0, gap: CGFloat = 2.5
            let totalW = CGFloat(barCount) * (barW + gap) - gap
            let sx = (size.width - totalW) / 2
            let midY = size.height / 2

            for i in 0..<barCount {
                let raw = i < levels.count ? levels[i] : 0
                let lvl = Double(max(0.04, raw))
                let h = max(3.0, CGFloat(3 + lvl * 22))
                let rect = CGRect(x: sx + CGFloat(i) * (barW + gap),
                                  y: midY - h / 2, width: barW, height: h)
                // Fade to sides
                let dist = abs(Double(i) - Double(barCount - 1) / 2) / (Double(barCount) / 2)
                let alpha = (0.55 + lvl * 0.45) * (1.0 - dist * 0.4)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                         with: .color(accentColor.opacity(alpha)))
            }
        }
    }
}
