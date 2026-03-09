import AppKit
import SwiftUI

class FloatingButton: NSPanel {
    static let shared = FloatingButton()

    private var hostView: NSHostingView<FloatingButtonView>!
    private var dragOffset: CGPoint = .zero
    private let model = FloatingButtonModel()

    private init() {
        let size: CGFloat = 52
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let saved = FloatingButton.savedOrigin(screen: screen, size: size)

        super.init(
            contentRect: NSRect(x: saved.x, y: saved.y, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel    = true
        level              = .floating
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false

        hostView = NSHostingView(rootView: FloatingButtonView(model: model) {
            AppDelegate.shared?.toggleRecording()
        })
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = CGColor.clear
        contentView = hostView
    }

    // MARK: - Drag to move

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = event.locationInWindow
        let dx = loc.x - dragOffset.x
        let dy = loc.y - dragOffset.y
        let newOrigin = CGPoint(x: frame.origin.x + dx, y: frame.origin.y + dy)
        setFrameOrigin(newOrigin)
        FloatingButton.saveOrigin(newOrigin)
    }

    // MARK: - Show / Hide

    func show() { orderFrontRegardless() }
    func hide() { orderOut(nil) }

    func setRecording(_ on: Bool) {
        model.isRecording = on
    }

    // MARK: - Position persistence

    private static func savedOrigin(screen: NSScreen, size: CGFloat) -> CGPoint {
        if let arr = UserDefaults.standard.array(forKey: "floatingButtonOrigin") as? [CGFloat],
           arr.count == 2 {
            return CGPoint(x: arr[0], y: arr[1])
        }
        // Default: bottom-right
        return CGPoint(x: screen.visibleFrame.maxX - size - 20,
                       y: screen.visibleFrame.minY + 20)
    }

    private static func saveOrigin(_ pt: CGPoint) {
        UserDefaults.standard.set([pt.x, pt.y], forKey: "floatingButtonOrigin")
    }
}

// MARK: - Model

class FloatingButtonModel: ObservableObject {
    @Published var isRecording = false
}

// MARK: - View

struct FloatingButtonView: View {
    @ObservedObject var model: FloatingButtonModel
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack {
            Circle()
                .fill(bgColor)
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 1.2))
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)

            Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(iconColor)
                .scaleEffect(model.isRecording ? 0.85 : 1.0)
                .animation(.spring(response: 0.25), value: model.isRecording)
        }
        .frame(width: 52, height: 52)
        .scaleEffect(hovered ? 1.08 : 1.0)
        .animation(.spring(response: 0.2), value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture { onTap() }
        .overlay(
            // 録音中: 赤いリングアニメ
            model.isRecording ? AnyView(PulsingRing()) : AnyView(EmptyView())
        )
    }

    private var bgColor: Color {
        model.isRecording
            ? Color(red: 0.95, green: 0.18, blue: 0.18)
            : Color(white: 0.12, opacity: 0.92)
    }
    private var borderColor: Color {
        model.isRecording ? .red.opacity(0.6) : .white.opacity(0.15)
    }
    private var iconColor: Color { .white }
}

struct PulsingRing: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.6

    var body: some View {
        Circle()
            .strokeBorder(Color.red.opacity(opacity), lineWidth: 2.5)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    scale = 1.6; opacity = 0
                }
            }
    }
}
