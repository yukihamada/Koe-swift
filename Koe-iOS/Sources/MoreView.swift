import SwiftUI
import UIKit

// MARK: - Modern colored icon tile (App Store / Settings style)
private struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(colors: [color, color.opacity(0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 29, height: 29)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: color.opacity(0.30), radius: 2, y: 1)
    }
}

// MARK: - A titled row with subtitle + colored tile
private struct MenuRow<Destination: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct MoreView: View {
    @StateObject private var modelManager = ModelManager.shared
    @ObservedObject private var macBridge = MacBridge.shared
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @AppStorage("koe_phrase_palette") private var phrasePaletteEnabled = false
    @AppStorage("koe_watch_enabled") private var watchEnabled = false
    @AppStorage("koe_always_listening") private var alwaysListening = false
    @AppStorage("koe_tts_use_network") private var ttsUseNetwork = false
    @AppStorage("koe_tts_prefer_node") private var ttsPreferNode = ""
    @AppStorage("koe_handsfree") private var handsFree = false
    @AppStorage("koe_handsfree_speakback") private var handsFreeSpeakback = false
    @StateObject private var tts = KoeTTS.shared

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Hero header
                Section {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.45, blue: 0.25)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 56, height: 56)
                            .overlay(
                                Image(systemName: "waveform")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: .orange.opacity(0.35), radius: 6, y: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Koe")
                                .font(.title2.weight(.bold))
                            Text("声で、もっと速く。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("v\(appVersion)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .padding(.top, 2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                // MARK: - 音声アシスタント
                Section {
                    Toggle(isOn: $handsFree) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "hand.wave.fill", color: .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("ハンズフリー（話すだけ）")
                                Text("話し出すと自動録音→無音で停止")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if handsFree {
                        Toggle(isOn: $handsFreeSpeakback) {
                            HStack(spacing: 12) {
                                IconTile(symbol: "person.wave.2.fill", color: .pink)
                                Text("結果を本人声で読み返す")
                            }
                        }
                    }
                    Toggle(isOn: $alwaysListening) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "ear.fill", color: .teal)
                            Text(L10n.alwaysListening)
                        }
                    }
                } header: {
                    Text(L10n.voiceAssistant)
                } footer: {
                    Text("ハンズフリー＝ウェイクワード不要。マイクの常時聴取で声を検知します。" + L10n.alwaysListeningFooter)
                }

                // MARK: - 本人声（合成先）
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: "creditcard.fill", color: .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Koeクレジット")
                            if let c = tts.credits {
                                Text("無料 \(c.freeRemaining)/\(c.freeDaily)（本日）・残高 \(c.balance)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("自分のMacなら無料・他の人のMacは消費")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    if tts.purchaseEnabled {
                        Button {
                            Task {
                                if let url = await tts.checkoutURL(credits: 100) {
                                    await UIApplication.shared.open(url)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: "cart.fill", color: .blue)
                                Text("クレジットを購入（100 = ¥\(100 * tts.jpyPerCredit)）")
                            }
                        }
                    }
                    Toggle(isOn: $ttsUseNetwork) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "point.3.connected.trianglepath.dotted", color: .teal)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("ネットワークで合成")
                                Text("自分のMac優先・無ければ他の人のMac")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if ttsUseNetwork {
                        HStack(spacing: 12) {
                            IconTile(symbol: "desktopcomputer", color: .gray)
                            TextField("自分のMacのノードID（任意）", text: $ttsPreferNode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.callout)
                        }
                    }
                } header: {
                    Text("本人声")
                } footer: {
                    Text("オフ＝共有(中央)で合成。Macを持っていなくても本人声を使えます。オン＝声の分散ネットワークへ。自分のMacをノードにすると自分の端末で合成されます（voice.koe.live/node から参加）。")
                }

                // MARK: - Mac連携
                if macBridge.isConnected {
                    Section {
                        Toggle(isOn: $screenContextEnabled) {
                            HStack(spacing: 12) {
                                IconTile(symbol: "desktopcomputer", color: .indigo)
                                Text(L10n.macScreenContext)
                            }
                        }
                    } header: {
                        Text(L10n.macLink)
                    } footer: {
                        Text(L10n.macScreenContextFooter)
                    }
                }

                // MARK: - 定型文パレット
                Section {
                    Toggle(isOn: $phrasePaletteEnabled) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "text.bubble.fill", color: .orange)
                            Text(L10n.phrasePalette)
                        }
                    }
                    if phrasePaletteEnabled {
                        MenuRow(symbol: "slider.horizontal.3", color: .orange,
                                title: L10n.managePhrases, subtitle: L10n.managePhrasesSubtitle) {
                            PhrasePaletteView()
                        }
                    }
                } header: {
                    Text(L10n.phrases)
                } footer: {
                    Text(L10n.phraseFooter)
                }

                // MARK: - デバイス
                Section {
                    MenuRow(symbol: "wave.3.right", color: .blue,
                            title: "Koe Device", subtitle: "ESP32デバイスのセットアップ") {
                        DeviceSetupView()
                    }
                } header: {
                    Text("デバイス")
                }

                // MARK: - 機能
                Section {
                    MenuRow(symbol: "doc.text.fill", color: .orange,
                            title: L10n.meetingNotes, subtitle: L10n.meetingNotesSubtitle) {
                        MeetingView()
                    }
                    MenuRow(symbol: "bubble.left.and.bubble.right.fill", color: .blue,
                            title: L10n.faceToFaceTranslation, subtitle: L10n.faceToFaceSubtitle) {
                        ConversationView()
                    }
                    MenuRow(symbol: "waveform", color: .purple,
                            title: L10n.audioTools, subtitle: L10n.audioToolsSubtitle) {
                        AudioToolsView()
                    }
                } header: {
                    Text(L10n.features)
                }

                // MARK: - Apple Watch
                Section {
                    Toggle(isOn: $watchEnabled) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "applewatch", color: .pink)
                            Text(L10n.appleWatch)
                        }
                    }
                    .onChange(of: watchEnabled) { _, enabled in
                        if enabled { WatchRelay.shared.start() }
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text(L10n.appleWatchFooter)
                }

                // MARK: - 実験的
                Section {
                    MenuRow(symbol: "dot.radiowaves.left.and.right", color: .cyan,
                            title: "Soluna", subtitle: L10n.p2pAudioNetwork) {
                        SolunaView()
                    }
                    MenuRow(symbol: "brain.head.profile", color: .pink,
                            title: "Sound Memory", subtitle: L10n.soundPatternRecognition) {
                        SoundMemoryView()
                    }
                } header: {
                    Text(L10n.experimental)
                }

                // MARK: - Feedback
                Section {
                    MenuRow(symbol: "exclamationmark.bubble.fill", color: .orange,
                            title: "Feedback", subtitle: "\(FeedbackManager.shared.entries.count) entries") {
                        FeedbackHistoryView()
                    }
                } header: {
                    Text("Feedback")
                }

                // MARK: - About
                Section {
                    LabeledContent(L10n.version, value: appVersion)
                    Link(destination: URL(string: "https://app.koe.live")!) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "globe", color: .blue)
                            Text(L10n.website)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await tts.loadConfig()
                await tts.refreshBalance()
            }
        }
    }
}
