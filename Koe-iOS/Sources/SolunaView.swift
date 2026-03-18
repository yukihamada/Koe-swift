import SwiftUI

struct SolunaView: View {
    @StateObject private var soluna = SolunaManager.shared
    @State private var animationTick: UInt64 = 0
    @State private var timer: Timer?

    // Channel categories
    private let freeChannels = ["soluna", "zamna-hawaii", "stage-a", "stage-b", "vip", "jam"]
    private let genreChannels = ["jazz", "ambient", "lo-fi", "classical", "electronic"]
    private let artistChannels: [(name: String, artist: String)] = [
        ("ed-sheeran", "Ed Sheeran"),
        ("fkj", "FKJ"),
        ("black-coffee", "Black Coffee"),
        ("avicii", "Avicii"),
        ("nora-jones", "Norah Jones"),
        ("bonobo", "Bonobo"),
        ("nujabes", "Nujabes"),
        ("khruangbin", "Khruangbin"),
    ]

    // Pricing: ¥1/分、90%アーティスト直接、上限¥500/月、最初30分/月無料
    @AppStorage("soluna_listen_minutes") private var listenMinutes: Double = 0
    @AppStorage("soluna_month_key") private var monthKey: String = ""
    @State private var showPricing = false

    private var currentMonthKey: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM"
        return df.string(from: Date())
    }

    private var freeMinutesRemaining: Double {
        if monthKey != currentMonthKey { return 30 }
        return max(0, 30 - listenMinutes)
    }

    private var currentCharge: Int {
        if monthKey != currentMonthKey { return 0 }
        let billableMinutes = max(0, listenMinutes - 30)
        return min(500, Int(billableMinutes))
    }

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
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Free channels
                        Text("Live")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(freeChannels, id: \.self) { ch in
                                    channelButton(ch, icon: "dot.radiowaves.left.and.right")
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        // Genre channels
                        Text("Genre")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(genreChannels, id: \.self) { ch in
                                    channelButton(ch, icon: "music.note")
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        // Artist channels (premium)
                        HStack {
                            Text("Artist")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { showPricing = true } label: {
                                Text("¥1/分 · 90%アーティストへ")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.purple)
                            }
                        }
                        .padding(.horizontal, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(artistChannels, id: \.name) { ch in
                                    Button {
                                        soluna.setChannel(ch.name)
                                    } label: {
                                        Text(ch.artist)
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(soluna.channel == ch.name ? Color.purple.opacity(0.2) : Color.white.opacity(0.05))
                                            .foregroundStyle(soluna.channel == ch.name ? .purple : .secondary)
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(soluna.channel == ch.name ? Color.purple.opacity(0.4) : Color.clear))
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .frame(maxHeight: 220)

                // Pricing bar
                if soluna.isActive {
                    pricingBar
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
                    Text("UDP \(soluna.isActive ? "239.42.42.1:4242" : "—")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPricing) { pricingSheet }
    }

    // MARK: - Pricing Bar

    private var pricingBar: some View {
        Button { showPricing = true } label: {
            HStack(spacing: 12) {
                // Free minutes or charge
                if freeMinutesRemaining > 0 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("無料")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Text("残り\(Int(freeMinutesRemaining))分")
                            .font(.system(size: 10))
                            .foregroundStyle(.green.opacity(0.7))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("¥\(currentCharge)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                        Text("/ ¥500上限")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(
                            currentCharge >= 500 ? Color.green :
                            freeMinutesRemaining > 0 ? Color.green :
                            Color.orange
                        )
                        .frame(width: geo.size.width * min(1, Double(currentCharge) / 500))
                    }
                }
                .frame(height: 6)

                // 90% to artist badge
                Text("90%→artist")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.purple)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Pricing Sheet

    private var pricingSheet: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 8)

            Text("Soluna Pricing")
                .font(.title2.weight(.light))

            // The pitch
            VStack(spacing: 8) {
                Text("¥1/分")
                    .font(.system(size: 56, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(.orange)
                Text("90%がアーティストに直接届く")
                    .font(.subheadline)
                    .foregroundStyle(.purple)
            }

            Divider().padding(.horizontal, 40)

            // Comparison
            VStack(alignment: .leading, spacing: 12) {
                pricingRow("最初の30分/月", value: "無料", color: .green)
                pricingRow("31分〜", value: "¥1/分", color: .orange)
                pricingRow("月額上限", value: "¥500", color: .orange)
                pricingRow("アーティスト取り分", value: "90%", color: .purple)

                Divider()

                Text("vs Spotify")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                pricingRow("Spotify月額", value: "¥980", color: .gray)
                pricingRow("Spotifyアーティスト取り分", value: "~¥0.15/曲", color: .red)
                pricingRow("Solunaアーティスト取り分", value: "~¥3.6/曲", color: .green)

                HStack {
                    Spacer()
                    Text("アーティストへの支払い 24倍")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Spacer()
                }
            }
            .padding(.horizontal, 30)

            Spacer()

            // Current usage
            VStack(spacing: 4) {
                Text("今月の利用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("¥\(currentCharge) / ¥500")
                    .font(.title3.weight(.light))
                Text("\(Int(listenMinutes))分 聴取")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 16)
        }
        .presentationDetents([.medium, .large])
    }

    private func pricingRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
        }
    }

    // MARK: - Channel Button

    private func channelButton(_ ch: String, icon: String) -> some View {
        Button {
            soluna.setChannel(ch)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(ch)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(soluna.channel == ch ? Color.orange.opacity(0.2) : Color.white.opacity(0.05))
            .foregroundStyle(soluna.channel == ch ? .orange : .secondary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(soluna.channel == ch ? Color.orange.opacity(0.4) : Color.clear))
        }
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
