import AppKit
import SwiftUI

enum OverlayState {
    case recording
    case recognizing
}

class OverlayWindow: NSPanel {
    private var stateModel = OverlayStateModel()
    private var tipTimer: Timer?
    private var tipIndex = 0

    init() {
        let w: CGFloat = 340, h: CGFloat = 80
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let rect = CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.midY - h / 2,
            width: w, height: h
        )
        super.init(contentRect: rect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: OverlayView(model: stateModel))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        hosting.layer?.cornerRadius = 16
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    func setTranslateMode(_ on: Bool) {
        stateModel.isTranslateMode = on
    }

    func show(state: OverlayState) {
        stateModel.state = state
        stateModel.visible = false
        // 翻訳モード中はモード名を上書き
        if stateModel.isTranslateMode && state == .recording {
            stateModel.modeName = "翻訳中..."
        } else {
            // モード名を更新（none/correct以外の場合のみ表示）
            let mode = AppSettings.shared.llmMode
            let showMode = state == .recording && mode != .none && mode != .correct
            stateModel.modeName = showMode ? mode.displayName : ""
        }

        // 認識中はヒントのローテーション開始
        if state == .recognizing {
            startTipRotation()
        } else {
            stopTipRotation()
        }

        orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                self.stateModel.visible = true
            }
        }
    }


    private func startTipRotation() {
        tipTimer?.invalidate()
        let tips = OverlayStateModel.localizedTips()
        tipIndex = Int.random(in: 0..<tips.count)
        withAnimation(.easeInOut(duration: 0.3)) {
            stateModel.tipText = tips[tipIndex]
        }
        tipTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let tips = OverlayStateModel.localizedTips()
            self.tipIndex = (self.tipIndex + 1) % tips.count
            withAnimation(.easeInOut(duration: 0.3)) {
                self.stateModel.tipText = tips[self.tipIndex]
            }
        }
    }

    private func stopTipRotation() {
        tipTimer?.invalidate()
        tipTimer = nil
        if !stateModel.tipText.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { stateModel.tipText = "" }
        }
    }


    func hide() {
        stopTipRotation()
        withAnimation(.easeIn(duration: 0.15)) { stateModel.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.orderOut(nil) }
    }

    func updateLevel(_ level: Float) {
        stateModel.audioLevel = level
        stateModel.pushLevel(level)
    }

    func showHint(_ text: String) {
        guard stateModel.hint != text else { return }
        withAnimation(.easeIn(duration: 0.3)) { stateModel.hint = text }
    }

    func clearHint() {
        guard !stateModel.hint.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { stateModel.hint = "" }
    }

    /// ストリーミング認識のプレビューテキストを更新。
    /// 末尾100文字にトランケートし、ウィンドウ高さを自動調整する。
    func updateStreamingText(_ text: String) {
        let truncated = text.count > 150 ? "..." + String(text.suffix(147)) : text
        guard stateModel.streamingText != truncated else { return }
        stateModel.streamingText = truncated
    }

    func clearStreamingText() {
        guard !stateModel.streamingText.isEmpty else { return }
        stateModel.streamingText = ""
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
    @Published var tipText: String = ""
    /// 直近のレベル履歴（波形描画用）
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 40)
    var engineBadge: String { AppSettings.shared.recognitionEngine.badgeText }

    func pushLevel(_ level: Float) {
        levelHistory.append(level)
        if levelHistory.count > 40 {
            levelHistory.removeFirst(levelHistory.count - 40)
        }
    }

    static func localizedTips() -> [String] {
        let lang = AppSettings.shared.language
        if lang.hasPrefix("en") {
            return [
                "💡 Hold ⌥⌘V to record, release to convert",
                "💡 Press Space to extend recording",
                "💡 Punctuation is added automatically",
                "💡 Switch languages from the menu bar",
                "💡 ⌘⌥T toggles translation mode",
                "💡 Search & export history in Settings",
                "💡 LLM modes: email, meeting notes, code...",
                "💡 Transcribe audio/video files too",
                "💡 Wake word for hands-free input",
                "💡 Clipboard content used as context",
            ]
        } else if lang.hasPrefix("zh") {
            return [
                "💡 按住 ⌥⌘V 录音，松开即转换",
                "💡 按 Space 延长录音",
                "💡 标点符号自动添加",
                "💡 从菜单栏切换语言",
                "💡 ⌘⌥T 切换翻译模式",
                "💡 在设置中搜索和导出历史",
                "💡 LLM模式：邮件/会议纪要/代码…",
                "💡 支持音视频文件转录",
                "💡 唤醒词免手动输入",
                "💡 剪贴板内容可作为上下文",
            ]
        } else if lang.hasPrefix("ko") {
            return [
                "💡 ⌥⌘V 길게 눌러 녹음, 놓으면 변환",
                "💡 Space로 녹음 연장 가능",
                "💡 문장부호 자동 추가",
                "💡 메뉴바에서 언어 전환 가능",
                "💡 ⌘⌥T로 번역 모드 전환",
                "💡 설정에서 기록 검색 및 내보내기",
                "💡 LLM 모드: 이메일/회의록/코드…",
                "💡 오디오/비디오 파일 전사 지원",
                "💡 웨이크워드로 핸즈프리 입력",
                "💡 클립보드 내용을 컨텍스트로 활용",
            ]
        } else {
            // Japanese (default)
            return [
                "💡 ⌥⌘V 長押しで録音、離すと変換",
                "💡 Space で録音を延長できます",
                "💡 句読点は自動で追加されます",
                "💡 メニューバーから言語を切替可能",
                "💡 ⌘⌥T で翻訳モードに切替",
                "💡 履歴は設定画面から検索・エクスポート",
                "💡 LLMモードでメール/議事録/コード向けに変換",
                "💡 ファイルの文字起こしにも対応",
                "💡 ウェイクワードで手ぶら音声入力",
                "💡 クリップボードの内容をコンテキストに活用",
            ]
        }
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    @ObservedObject var model: OverlayStateModel

    var body: some View {
        VStack(spacing: 6) {
            // ステータスバー: ドット + 波形/ドット + バッジ
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(0.9), radius: 6)
                    .modifier(DotPulse(active: model.state == .recording))

                ZStack {
                    WaveformView(levels: model.levelHistory)
                        .opacity(model.state == .recording ? 1 : 0)
                    ThreeDotsView()
                        .opacity(model.state == .recording ? 0 : 1)
                }
                .frame(width: 180, height: 22)

                Text(model.modeName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(model.modeName.isEmpty ? 0 : 0.5))

                Spacer()

                Text(model.engineBadge)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(badgeColor.opacity(0.8))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 20)
            .frame(height: 36)

            // テキスト表示エリア（完全固定高さ、ZStackで重ねて切替）
            ZStack {
                Text(model.streamingText.isEmpty ? " " : model.streamingText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
                    .opacity(!model.streamingText.isEmpty && model.state == .recording ? 1 : 0)

                Text(model.tipText.isEmpty ? " " : model.tipText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .opacity(!model.tipText.isEmpty && model.streamingText.isEmpty ? 1 : 0)

                Text(model.state == .recording ? "話してください..." : "認識中...")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.2))
                    .opacity(model.streamingText.isEmpty && model.tipText.isEmpty ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
        }
        .padding(.vertical, 6)
        .frame(width: 340, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.07, opacity: 0.93))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(dotColor.opacity(0.3), lineWidth: 0.7))
        )
        .opacity(model.visible ? 1 : 0)
    }

    private var dotColor: Color {
        if model.isTranslateMode {
            return Color(red: 0.30, green: 0.60, blue: 1.0)  // blue tint for translate
        }
        return model.state == .recording
            ? Color(red: 1.0, green: 0.27, blue: 0.30)
            : Color(red: 0.40, green: 0.74, blue: 1.0)
    }

    private var badgeColor: Color {
        AppSettings.shared.recognitionEngine.isLocal
            ? Color(red: 0.3, green: 0.85, blue: 0.5)
            : Color(red: 0.5, green: 0.7, blue: 1.0)
    }
}

// MARK: - Dot pulse modifier

struct DotPulse: AnimatableModifier {
    var active: Bool
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    scale = 1.4
                }
            }
            .onChange(of: active) { on in
                if on {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { scale = 1.4 }
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { scale = 1 }
                }
            }
    }
    func animateableData_ignored() {}
}

// MARK: - Waveform (recording)

struct WaveformView: View {
    let levels: [Float]
    private let barCount = 40

    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 2.5, gap: CGFloat = 2.0
            let totalW = CGFloat(barCount) * (barW + gap) - gap
            let sx = (size.width - totalW) / 2
            let midY = size.height / 2

            for i in 0..<barCount {
                let lvl = Double(i < levels.count ? max(0.02, levels[i]) : 0.02)
                let h = max(2.5, CGFloat(2 + lvl * 20))
                let rect = CGRect(x: sx + CGFloat(i) * (barW + gap), y: midY - h / 2, width: barW, height: h)
                let alpha = 0.4 + lvl * 0.6
                let r = Double(i) / Double(barCount - 1)
                let g = 0.15 + abs(r - 0.5) * 0.55
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                         with: .color(Color(red: 1, green: g, blue: 0.22).opacity(alpha)))
            }
        }
    }
}

// MARK: - Three dots (recognizing)

struct ThreeDotsView: View {
    private let colors: [Color] = [
        Color(red: 0.40, green: 0.74, blue: 1.0),
        Color(red: 0.55, green: 0.62, blue: 1.0),
        Color(red: 0.70, green: 0.50, blue: 1.0),
    ]

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    let phase = Double(i) * 0.22
                    let v = (sin(t * 4.5 + phase * .pi * 2) + 1) / 2  // 0…1
                    Circle()
                        .fill(colors[i])
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.55 + v * 0.6)
                        .opacity(0.4 + v * 0.6)
                        .offset(y: CGFloat(-v * 5))
                }
            }
        }
    }
}
