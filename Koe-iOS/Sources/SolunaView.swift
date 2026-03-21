import SwiftUI

struct SolunaView: View {
    @StateObject private var soluna = SolunaSDKPlayer.shared
    @State private var animationTick: UInt64 = 0
    @State private var timer: Timer?
    @State private var showDebug = false

    // ── Channel categories ──

    private let liveChannels: [(id: String, label: String, emoji: String)] = [
        ("soluna", "Soluna HQ", "🌀"),
        ("zamna-hawaii", "ZAMNA HAWAII", "🌺"),
        ("stage-a", "Main Stage", "🔥"),
        ("stage-b", "Sub Stage", "⚡"),
        ("vip", "VIP Lounge", "🥂"),
        ("jam", "Open Jam", "🎸"),
    ]

    private let vibeChannels: [(id: String, label: String, emoji: String, color: Color)] = [
        ("sunset-chill", "Sunset Chill", "🌅", .orange),
        ("deep-focus", "Deep Focus", "🧠", .cyan),
        ("tokyo-nights", "Tokyo Nights", "🗼", .purple),
        ("ocean-waves", "Ocean Waves", "🌊", .blue),
        ("morning-yoga", "Morning Yoga", "🧘", .green),
        ("late-night", "Late Night", "🌙", .indigo),
        ("coffee-shop", "Coffee Shop", "☕", .brown),
        ("rain-sounds", "Rain + Lo-fi", "🌧️", .gray),
        ("festival-heat", "Festival Heat", "🎪", .red),
        ("space-ambient", "Space Ambient", "🪐", .purple),
    ]

    private let artistChannels: [(id: String, label: String, emoji: String, tier: String)] = [
        ("avicii", "Avicii", "◆", "LEGEND"),
        ("nujabes", "Nujabes", "◆", "LEGEND"),
        ("daft-punk", "Daft Punk", "◆", "LEGEND"),
        ("fkj", "FKJ", "♦", "ICON"),
        ("black-coffee", "Black Coffee", "♦", "ICON"),
        ("bonobo", "Bonobo", "♦", "ICON"),
        ("four-tet", "Four Tet", "♦", "ICON"),
        ("kaytranada", "KAYTRANADA", "♦", "ICON"),
        ("khruangbin", "Khruangbin", "♦", "ICON"),
        ("norah-jones", "Norah Jones", "♦", "ICON"),
        ("tycho", "Tycho", "♦", "ICON"),
        ("fred-again", "Fred Again..", "▸", "RISING"),
        ("peggy-gou", "Peggy Gou", "▸", "RISING"),
        ("channel-tres", "Channel Tres", "▸", "RISING"),
        ("jamie-xx", "Jamie xx", "▸", "RISING"),
        ("toro-y-moi", "Toro y Moi", "▸", "RISING"),
    ]

    private let djMixChannels: [(id: String, label: String, emoji: String)] = [
        ("solomun-live", "Solomun Live", "🎧"),
        ("tale-of-us", "Tale Of Us", "🎧"),
        ("amelie-lens", "Amelie Lens", "🎧"),
        ("fisher-mix", "FISHER", "🎧"),
        ("rufus-dj-set", "RÜFÜS DJ Set", "🎧"),
    ]

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
            ledBackground
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Status — triple-tap to toggle debug
                VStack(spacing: 8) {
                    Text(soluna.isActive ? "SOLUNA" : "OFFLINE")
                        .font(.system(size: 40, weight: .ultraLight, design: .rounded))
                        .foregroundStyle(soluna.isActive ? .orange : .gray)
                        .onTapGesture(count: 3) { showDebug.toggle() }

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
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("🔴 LIVE NOW", subtitle: nil)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(liveChannels, id: \.id) { ch in
                                    emojiChip(ch.id, emoji: ch.emoji, label: ch.label, active: .orange)
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        sectionHeader("🎵 VIBE", subtitle: "雰囲気で選ぶ")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(vibeChannels, id: \.id) { ch in
                                    emojiChip(ch.id, emoji: ch.emoji, label: ch.label, active: ch.color)
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        sectionHeader("🎧 DJ MIX", subtitle: "ノンストップ")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(djMixChannels, id: \.id) { ch in
                                    emojiChip(ch.id, emoji: ch.emoji, label: ch.label, active: .pink)
                                }
                            }
                            .padding(.horizontal, 20)
                        }

                        HStack {
                            Text("◆ ARTIST")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Button { showPricing = true } label: {
                                Text("¥1/分 · 90%直接 · 上限¥500")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.purple)
                            }
                        }
                        .padding(.horizontal, 20)

                        ForEach(["LEGEND", "ICON", "RISING"], id: \.self) { tier in
                            let tierArtists = artistChannels.filter { $0.tier == tier }
                            let tierColor: Color = tier == "LEGEND" ? .yellow : tier == "ICON" ? .purple : .cyan

                            HStack(spacing: 4) {
                                Text(tier)
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .foregroundStyle(tierColor.opacity(0.6))
                                    .padding(.leading, 24)
                                Rectangle().fill(tierColor.opacity(0.1)).frame(height: 1)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(tierArtists, id: \.id) { ch in
                                        Button { soluna.setChannel(ch.id) } label: {
                                            HStack(spacing: 4) {
                                                Text(ch.emoji).font(.system(size: 8))
                                                Text(ch.label).font(.caption.weight(.medium))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(soluna.channel == ch.id ? tierColor.opacity(0.2) : Color.white.opacity(0.04))
                                            .foregroundStyle(soluna.channel == ch.id ? tierColor : .secondary)
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(soluna.channel == ch.id ? tierColor.opacity(0.4) : Color.clear))
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)

                // Pricing bar
                if soluna.isActive { pricingBar }

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

                // Footer — debug (hidden by default, triple-tap SOLUNA to show)
                VStack(spacing: 4) {
                    if showDebug && !soluna.debugInfo.isEmpty {
                        Text(soluna.debugInfo)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.6))
                        Text("relay.solun.art:5100")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    } else {
                        Text("ch: \(soluna.channel)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }
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
                if freeMinutesRemaining > 0 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("無料").font(.caption.bold()).foregroundStyle(.green)
                        Text("残り\(Int(freeMinutesRemaining))分")
                            .font(.system(size: 10)).foregroundStyle(.green.opacity(0.7))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("¥\(currentCharge)").font(.caption.bold()).foregroundStyle(.white)
                        Text("/ ¥500上限").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(
                            currentCharge >= 500 ? Color.green :
                            freeMinutesRemaining > 0 ? Color.green : Color.orange
                        )
                        .frame(width: geo.size.width * min(1, Double(currentCharge) / 500))
                    }
                }
                .frame(height: 6)

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
            Text("Soluna Pricing").font(.title2.weight(.light))

            VStack(spacing: 8) {
                Text("¥1/分")
                    .font(.system(size: 56, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(.orange)
                Text("90%がアーティストに直接届く")
                    .font(.subheadline).foregroundStyle(.purple)
            }

            Divider().padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                pricingRow("最初の30分/月", value: "無料", color: .green)
                pricingRow("31分〜", value: "¥1/分", color: .orange)
                pricingRow("月額上限", value: "¥500", color: .orange)
                pricingRow("アーティスト取り分", value: "90%", color: .purple)
                Divider()
                Text("vs Spotify").font(.caption.bold()).foregroundStyle(.secondary)
                pricingRow("Spotify月額", value: "¥980", color: .gray)
                pricingRow("Spotifyアーティスト取り分", value: "~¥0.15/曲", color: .red)
                pricingRow("Solunaアーティスト取り分", value: "~¥3.6/曲", color: .green)
                HStack {
                    Spacer()
                    Text("アーティストへの支払い 24倍").font(.caption.bold()).foregroundStyle(.green)
                    Spacer()
                }
            }
            .padding(.horizontal, 30)

            Spacer()

            VStack(spacing: 4) {
                Text("今月の利用").font(.caption).foregroundStyle(.secondary)
                Text("¥\(currentCharge) / ¥500").font(.title3.weight(.light))
                Text("\(Int(listenMinutes))分 聴取").font(.caption2).foregroundStyle(.secondary)
            }

            Spacer().frame(height: 16)
        }
        .presentationDetents([.medium, .large])
    }

    private func pricingRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(color)
        }
    }

    // MARK: - UI Helpers

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            if let sub = subtitle {
                Text(sub).font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func emojiChip(_ id: String, emoji: String, label: String, active: Color) -> some View {
        Button { soluna.setChannel(id) } label: {
            HStack(spacing: 5) {
                Text(emoji).font(.system(size: 14))
                Text(label).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(soluna.channel == id ? active.opacity(0.2) : Color.white.opacity(0.04))
            .foregroundStyle(soluna.channel == id ? active : .secondary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(soluna.channel == id ? active.opacity(0.4) : Color.clear))
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
        case 0: Color.black
        case 1: Color(red: r * inten, green: g * inten, blue: b * inten)
        case 2:
            let t = Double(animationTick % 120) / 120.0
            let bright = abs(sin(t * .pi))
            Color(red: r * bright * inten, green: g * bright * inten, blue: b * bright * inten)
        case 3:
            let hue = Double(animationTick % 360) / 360.0
            Color(hue: hue, saturation: 1.0, brightness: inten)
        case 6:
            let on = animationTick % UInt64(max(2, 20 - Int(speed * 18))) < UInt64(max(1, 10 - Int(speed * 9)))
            on ? Color(red: r * inten, green: g * inten, blue: b * inten) : Color.black
        case 7:
            let t = Double(animationTick % 180) / 180.0
            let bright = (sin(t * .pi * 2) + 1) / 2
            Color(red: r * bright * inten, green: g * bright * inten, blue: b * bright * inten)
        default:
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
