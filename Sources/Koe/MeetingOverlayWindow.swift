import AppKit
import SwiftUI
import Combine

/// 議事録モード中に右上に表示するフローティングインジケーター（リアルタイムプレビュー付き）
class MeetingOverlayWindow: NSPanel {
    private let model = MeetingOverlayModel()
    private var cancellables: [AnyCancellable] = []

    init() {
        let w: CGFloat = 280, h: CGFloat = 100
        let screen = NSScreen.main ?? NSScreen.screens[0]
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
    }

    override func mouseUp(with event: NSEvent) {
        // クリックで議事録停止
        AppDelegate.shared?.toggleMeetingMode()
    }

    func showMeeting() {
        model.charCount = MeetingMode.shared.charCount
        model.entryCount = MeetingMode.shared.entryCount
        model.startDate = Date()
        model.lastText = ""
        orderFrontRegardless()
    }

    func updateLastText(_ text: String) {
        model.lastText = text
    }

    func hideMeeting() {
        // 整形中は非表示にしない
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
}

// MARK: - Model

class MeetingOverlayModel: ObservableObject {
    @Published var charCount = 0
    @Published var entryCount = 0
    @Published var isFormatting = false
    @Published var lastText = ""
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー: 録音インジケーター + タイマー
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

                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(goldAccent.opacity(0.3))
                }
            }

            // 統計
            if !model.isFormatting {
                HStack(spacing: 8) {
                    Label("\(model.entryCount)", systemImage: "waveform")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(goldAccent.opacity(0.4))
                    Label("\(model.charCount)文字", systemImage: "text.alignleft")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(goldAccent.opacity(0.4))
                }

                // 直近の認識テキスト
                if !model.lastText.isEmpty {
                    Text(model.lastText)
                        .font(.system(size: 10))
                        .foregroundColor(champagne.opacity(0.5))
                        .lineLimit(2)
                        .truncationMode(.tail)
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

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
