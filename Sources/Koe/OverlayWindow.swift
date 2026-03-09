import AppKit
import SwiftUI

enum OverlayState {
    case recording
    case recognizing
}

class OverlayWindow: NSPanel {
    private var stateModel = OverlayStateModel()

    init() {
        let w: CGFloat = 200, h: CGFloat = 56
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let rect = CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.midY - h / 2 + 60,
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
        hosting.layer?.cornerRadius = 28
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    func show(state: OverlayState) {
        stateModel.state = state
        stateModel.visible = false
        orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                self.stateModel.visible = true
            }
        }
    }

    func hide() {
        withAnimation(.easeIn(duration: 0.15)) { stateModel.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.orderOut(nil) }
    }

    func updateLevel(_ level: Float) { stateModel.audioLevel = level }

    func showHint(_ text: String) {
        guard stateModel.hint != text else { return }
        withAnimation(.easeIn(duration: 0.3)) { stateModel.hint = text }
        // ウィンドウを縦に伸ばす
        var f = frame
        let newH: CGFloat = 76
        f.origin.y -= (newH - f.height)
        f.size.height = newH
        setFrame(f, display: true, animate: true)
    }

    func clearHint() {
        guard !stateModel.hint.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { stateModel.hint = "" }
        var f = frame
        let newH: CGFloat = 56
        f.origin.y += (f.height - newH)
        f.size.height = newH
        setFrame(f, display: true, animate: true)
    }
}

class OverlayStateModel: ObservableObject {
    @Published var state: OverlayState = .recording
    @Published var audioLevel: Float = 0
    @Published var visible: Bool = false
    @Published var hint: String = ""
}

// MARK: - Overlay View

struct OverlayView: View {
    @ObservedObject var model: OverlayStateModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(0.9), radius: 6)
                    .modifier(DotPulse(active: model.state == .recording))

                Group {
                    if model.state == .recording {
                        WaveformView(level: model.audioLevel)
                            .frame(width: 110, height: 26)
                    } else {
                        ThreeDotsView()
                            .frame(width: 110, height: 26)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(width: 200, height: 56)

            if !model.hint.isEmpty {
                Text(model.hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 200, height: 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(white: 0.07, opacity: 0.93))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(dotColor.opacity(0.3), lineWidth: 0.7))
        )
        .scaleEffect(model.visible ? 1 : 0.82)
        .opacity(model.visible ? 1 : 0)
    }

    private var dotColor: Color {
        model.state == .recording
            ? Color(red: 1.0, green: 0.27, blue: 0.30)
            : Color(red: 0.40, green: 0.74, blue: 1.0)
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
    let level: Float
    private let barCount = 24

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let barW: CGFloat = 2.5, gap: CGFloat = 2.0
                let totalW = CGFloat(barCount) * (barW + gap) - gap
                let sx = (size.width - totalW) / 2
                let midY = size.height / 2
                let lvl = Double(max(0.03, level))

                for i in 0..<barCount {
                    let r = Double(i) / Double(barCount - 1)
                    let phase = r * .pi * 3.2
                    let env = 1.0 - pow(abs(r - 0.5) * 2, 1.5)
                    let j = (sin(t * 20 + phase) * 0.5 + 0.5)
                    let s = (sin(t *  6 + phase) * 0.5 + 0.5)
                    let h = max(2.5, CGFloat(3 + lvl * 18 * env * (j * 0.6 + s * 0.4) + lvl * 4))
                    let rect = CGRect(x: sx + CGFloat(i) * (barW + gap), y: midY - h / 2, width: barW, height: h)
                    let alpha = 0.35 + lvl * 0.65
                    let g = 0.15 + abs(r - 0.5) * 0.55
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                             with: .color(Color(red: 1, green: g, blue: 0.22).opacity(alpha)))
                }
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
