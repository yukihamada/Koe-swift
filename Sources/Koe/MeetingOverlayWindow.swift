import AppKit
import SwiftUI
import Combine

/// 議事録モード中に右上に表示するコンパクトなフローティングインジケーター
class MeetingOverlayWindow: NSPanel {
    private let model = MeetingOverlayModel()
    private var cancellables: [AnyCancellable] = []

    init() {
        let w: CGFloat = 160, h: CGFloat = 36
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
        orderFrontRegardless()
    }

    func hideMeeting() {
        // 整形中は非表示にしない
        if MeetingMode.shared.isFormatting {
            // 整形完了を監視して自動で閉じる
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
    @Published var isFormatting = false
}

// MARK: - View

struct MeetingOverlayView: View {
    @ObservedObject var model: MeetingOverlayModel

    @State private var pulse = false

    private let goldAccent = Color(red: 0.78, green: 0.68, blue: 0.50)
    private let warmAmber  = Color(red: 0.85, green: 0.55, blue: 0.40)
    private let champagne  = Color(red: 0.90, green: 0.84, blue: 0.72)

    var body: some View {
        HStack(spacing: 6) {
            if model.isFormatting {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("整形中...")
                    .font(.system(size: 11, weight: .light, design: .rounded))
                    .tracking(0.5)
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

                Text("\(model.charCount)文字")
                    .font(.system(size: 10, weight: .light, design: .monospaced))
                    .foregroundColor(goldAccent.opacity(0.5))

                Spacer()

                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(goldAccent.opacity(0.3))
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 160, height: 36)
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
                        ),
                        lineWidth: 0.5
                    )
            }
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
    }
}
