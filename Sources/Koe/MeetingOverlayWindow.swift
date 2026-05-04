import AppKit
import SwiftUI
import Combine

/// 議事録モード中に右上に表示するフローティングインジケーター（リアルタイムプレビュー付き）
class MeetingOverlayWindow: NSPanel {
    private let model = MeetingOverlayModel()
    private var cancellables: [AnyCancellable] = []

    init() {
        let w: CGFloat = 280
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let h: CGFloat = 100
        let rect = CGRect(
            x: screen.visibleFrame.maxX - w - 16,
            y: screen.visibleFrame.maxY - h - 8,
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
        ignoresMouseEvents = false

        let hosting = NSHostingView(rootView: MeetingOverlayView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        contentView = hosting

        // MeetingMode の状態を監視
        MeetingMode.shared.$charCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.model.charCount = count }
            .store(in: &cancellables)
        MeetingMode.shared.$entryCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.model.entryCount = count }
            .store(in: &cancellables)
        MeetingMode.shared.$isFormatting
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.model.isFormatting = on }
            .store(in: &cancellables)

        // isExpanded の変化に応じてウィンドウサイズを更新
        model.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.updateWindowSize(expanded: expanded)
            }
            .store(in: &cancellables)
    }

    override func mouseUp(with event: NSEvent) {
        // ボタンは SwiftUI 側で処理するため、パネル自体のクリックは何もしない
    }

    func showMeeting() {
        model.charCount = MeetingMode.shared.charCount
        model.entryCount = MeetingMode.shared.entryCount
        model.startDate = Date()
        model.lastText = ""
        model.transcriptLines = []
        updateWindowSize(expanded: model.isExpanded)
        orderFrontRegardless()
    }

    func updateLastText(_ text: String) {
        model.lastText = text
    }

    /// 確定したテキストをトランスクリプトリストに追加する
    func appendTranscriptLine(_ text: String, speaker: Int? = nil, isImportant: Bool = false) {
        let line = TranscriptLine(text: text, speaker: speaker, timestamp: Date(), isImportant: isImportant)
        model.transcriptLines.append(line)
        model.lastText = text
        if model.transcriptLines.count > 100 {
            model.transcriptLines.removeFirst(model.transcriptLines.count - 100)
        }
        model.scrollToBottom += 1
    }

    func hideMeeting() {
        if MeetingMode.shared.isFormatting {
            MeetingMode.shared.$isFormatting
                .receive(on: RunLoop.main)
                .filter { !$0 }
                .first()
                .sink { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.orderOut(nil)
                    }
                }
                .store(in: &cancellables)
        } else {
            orderOut(nil)
        }
    }

    private func updateWindowSize(expanded: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let w: CGFloat = 280
        let h: CGFloat = expanded ? 320 : 100
        let x = screen.visibleFrame.maxX - w - 16
        let y = screen.visibleFrame.maxY - h - 8
        setFrame(CGRect(x: x, y: y, width: w, height: h), display: true, animate: true)
    }
}

// MARK: - TranscriptLine

struct TranscriptLine: Identifiable {
    let id = UUID()
    let text: String
    let speaker: Int?
    let timestamp: Date
    var isImportant: Bool
}

// MARK: - Model

class MeetingOverlayModel: ObservableObject {
    @Published var charCount = 0
    @Published var entryCount = 0
    @Published var isFormatting = false
    @Published var lastText = ""
    @Published var isExpanded = false
    @Published var transcriptLines: [TranscriptLine] = []
    @Published var scrollToBottom = 0
    var startDate: Date?
}

// MARK: - View

struct MeetingOverlayView: View {
    @ObservedObject var model: MeetingOverlayModel
    @State private var pulse = false
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let goldAccent = Color(red: 0.78, green: 0.68, blue: 0.50)
    private let warmAmber  = Color(red: 0.85, green: 0.55, blue: 0.40)
    private let champagne  = Color(red: 0.90, green: 0.84, blue: 0.72)

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー: 録音インジケーター + タイマー + 展開/停止ボタン
            HStack(spacing: 6) {
                if model.isFormatting {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("整形中...")
                        .font(.system(size: 11, weight: .light, design: .rounded))
                        .foregroundColor(champagne.opacity(0.8))
                } else {
                    Circle()
                        .fill(warmAmber)
                        .frame(width: 5, height: 5)
                        .scaleEffect(pulse ? 1.3 : 1.0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }

                    Text("議事録")
                        .font(.system(size: 11, weight: .light, design: .rounded))
                        .tracking(1.0)
                        .foregroundColor(champagne.opacity(0.8))

                    Spacer()

                    Text(formatDuration(elapsed))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(goldAccent.opacity(0.6))

                    // コンパクト/展開トグル
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: model.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(goldAccent.opacity(0.5))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)

                    // 停止ボタン
                    Button {
                        AppDelegate.shared?.toggleMeetingMode()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(goldAccent.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 統計行
            if !model.isFormatting {
                HStack(spacing: 8) {
                    Label("\(model.entryCount)", systemImage: "waveform")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(goldAccent.opacity(0.4))
                    Label("\(model.charCount)文字", systemImage: "text.alignleft")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(goldAccent.opacity(0.4))
                }

                if model.isExpanded {
                    // 展開モード: スクロール可能なトランスクリプトリスト
                    transcriptListView
                        .frame(height: 220)
                } else {
                    // コンパクトモード: 直近テキスト2行
                    if !model.lastText.isEmpty {
                        Text(model.lastText)
                            .font(.system(size: 10))
                            .foregroundColor(champagne.opacity(0.5))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.06, green: 0.05, blue: 0.05, opacity: 0.95))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        LinearGradient(
                            colors: model.isFormatting
                                ? [goldAccent.opacity(0.2), goldAccent.opacity(0.05)]
                                : [warmAmber.opacity(0.2), warmAmber.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 0.5
                    )
            }
        )
        .onReceive(timer) { _ in
            if let start = model.startDate {
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - トランスクリプトリスト（展開モード）

    private var transcriptListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if model.transcriptLines.isEmpty {
                        Text("認識待ち...")
                            .font(.system(size: 10))
                            .foregroundColor(champagne.opacity(0.25))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    } else {
                        ForEach(model.transcriptLines) { line in
                            transcriptRow(line)
                                .id(line.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.3))
            )
            .onChange(of: model.scrollToBottom) { _ in
                if let last = model.transcriptLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func transcriptRow(_ line: TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(timeFormatter.string(from: line.timestamp))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(goldAccent.opacity(0.35))
                .frame(width: 30, alignment: .leading)

            if let sp = line.speaker {
                Text("S\(sp + 1)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(speakerColor(sp).opacity(0.7))
                    .frame(width: 16)
            }

            Text(line.text)
                .font(.system(size: 10))
                .foregroundColor(
                    line.isImportant
                        ? Color(red: 0.95, green: 0.80, blue: 0.30)
                        : champagne.opacity(0.65)
                )
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if line.isImportant {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color(red: 0.95, green: 0.80, blue: 0.30))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            line.isImportant
                ? Color(red: 0.95, green: 0.80, blue: 0.10).opacity(0.07)
                : Color.clear
        )
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func speakerColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        return colors[index % colors.count]
    }
}
