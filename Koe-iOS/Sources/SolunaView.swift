import SwiftUI

struct SolunaView: View {
    @StateObject private var soluna = SolunaManager.shared
    @State private var animationTick: UInt64 = 0
    @State private var timer: Timer?

    private let channels = ["default", "stage-a", "stage-b", "vip", "jam"]

    var body: some View {
        ZStack {
            // Background: LED sync (full screen)
            ledBackground
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Status
                VStack(spacing: 8) {
                    Text(soluna.isActive ? "SOLUNA" : "OFFLINE")
                        .font(.system(size: 40, weight: .ultraLight, design: .rounded))
                        .foregroundStyle(soluna.isActive ? .orange : .gray)

                    if soluna.isActive {
                        HStack(spacing: 16) {
                            Label("\(soluna.peerCount)", systemImage: "person.2.wave.2")
                            if soluna.isReceivingAudio {
                                Label("Streaming", systemImage: "waveform")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                // Channel picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(channels, id: \.self) { ch in
                            Button {
                                soluna.setChannel(ch)
                            } label: {
                                Text(ch)
                                    .font(.caption)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(soluna.channel == ch ? Color.orange.opacity(0.2) : Color.white.opacity(0.05))
                                    .foregroundStyle(soluna.channel == ch ? .orange : .secondary)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(soluna.channel == ch ? Color.orange.opacity(0.4) : Color.clear))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                // Big toggle button
                Button {
                    if soluna.isActive {
                        soluna.stop()
                        stopAnimation()
                    } else {
                        soluna.start(channel: soluna.channel)
                        startAnimation()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(soluna.isActive ? Color.orange : Color.white.opacity(0.08))
                            .frame(width: 100, height: 100)
                            .shadow(color: soluna.isActive ? .orange.opacity(0.4) : .clear, radius: 20)

                        Image(systemName: soluna.isActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(soluna.isActive ? .black : .orange)
                    }
                }

                Spacer()

                // Info
                VStack(spacing: 4) {
                    Text("同じWiFi上のデバイスと自動接続")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("UDP \(soluna.isActive ? "239.69.0.1:5004" : "—")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - LED Background

    @ViewBuilder
    private var ledBackground: some View {
        let pattern = soluna.ledPattern
        let r = Double(soluna.ledR) / 255.0
        let g = Double(soluna.ledG) / 255.0
        let b = Double(soluna.ledB) / 255.0
        let inten = Double(soluna.ledIntensity) / 255.0
        let speed = Double(soluna.ledSpeed) / 255.0

        switch pattern {
        case 0: // off
            Color.black
        case 1: // solid
            Color(red: r * inten, green: g * inten, blue: b * inten)
        case 2: // pulse
            let t = Double(animationTick % 120) / 120.0
            let bright = abs(sin(t * .pi))
            Color(red: r * bright * inten, green: g * bright * inten, blue: b * bright * inten)
        case 3: // rainbow
            let hue = Double(animationTick % 360) / 360.0
            Color(hue: hue, saturation: 1.0, brightness: inten)
        case 6: // strobe
            let on = animationTick % UInt64(max(2, 20 - Int(speed * 18))) < UInt64(max(1, 10 - Int(speed * 9)))
            on ? Color(red: r * inten, green: g * inten, blue: b * inten) : Color.black
        case 7: // breathe
            let t = Double(animationTick % 180) / 180.0
            let bright = (sin(t * .pi * 2) + 1) / 2
            Color(red: r * bright * inten, green: g * bright * inten, blue: b * bright * inten)
        default: // wave etc
            let t = Double(animationTick % 100) / 100.0
            let bright = max(0, 1 - abs(t - 0.5) * 4)
            Color(red: r * bright * inten, green: g * bright * inten, blue: b * bright * inten)
        }
    }

    private func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in animationTick += 1 }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        animationTick = 0
    }
}
