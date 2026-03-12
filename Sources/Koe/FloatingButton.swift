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

        hostView = NSHostingView(rootView: FloatingButtonView(model: model))
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = CGColor.clear
        contentView = hostView
    }

    // MARK: - Drag to move & tap to toggle

    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        isDragging = true
        let loc = event.locationInWindow
        let dx = loc.x - dragOffset.x
        let dy = loc.y - dragOffset.y
        let newOrigin = CGPoint(x: frame.origin.x + dx, y: frame.origin.y + dy)
        setFrameOrigin(newOrigin)
        FloatingButton.saveOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            AppDelegate.shared?.toggleRecording()
        }
        isDragging = false
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

    @State private var hovered = false

    // Luxury palette
    private let goldAccent = Color(red: 0.78, green: 0.68, blue: 0.50)
    private let warmAmber  = Color(red: 0.85, green: 0.55, blue: 0.40)
    private let deepChar   = Color(red: 0.08, green: 0.07, blue: 0.06)

    var body: some View {
        ZStack {
            // Outer shadow ring for depth
            Circle()
                .fill(
                    model.isRecording
                        ? LinearGradient(
                            colors: [warmAmber, Color(red: 0.70, green: 0.40, blue: 0.30)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(
                            colors: [deepChar, Color(red: 0.12, green: 0.11, blue: 0.10)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: model.isRecording
                                ? [warmAmber.opacity(0.6), warmAmber.opacity(0.2)]
                                : [goldAccent.opacity(0.25), goldAccent.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)

            Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(model.isRecording ? .white : goldAccent)
                .scaleEffect(model.isRecording ? 0.85 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: model.isRecording)
        }
        .frame(width: 52, height: 52)
        .scaleEffect(hovered ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: hovered)
        .onHover { hovered = $0 }
        .overlay(
            model.isRecording ? AnyView(PulsingRing()) : AnyView(EmptyView())
        )
    }
}

struct PulsingRing: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.4

    // Warm amber pulse instead of red
    private let pulseColor = Color(red: 0.85, green: 0.55, blue: 0.40)

    var body: some View {
        Circle()
            .strokeBorder(pulseColor.opacity(opacity), lineWidth: 1.5)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    scale = 1.6; opacity = 0
                }
            }
    }
}
