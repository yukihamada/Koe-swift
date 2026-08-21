import SwiftUI
import WebKit

/// 「つながる」タブ本体(2026-07-25 Fable案2)。
/// 「話す=自分の声を出す道具、設定=道具箱」に対し、つながる=誰かの声が自分に届き、
/// 自分の声を誰かに届ける、人との接点だけを集めた場所。
/// koe.live側の/box・/feed・/liveはそれぞれ独立ページなので、ネイティブ側は
/// セグメント切り替え+WebAppView再利用の薄いハブに留める(中身の再実装はしない)。
enum ConnectSection: String, CaseIterable, Identifiable {
    case box = "届いた声"
    case feed = "みんなの声"
    case live = "ラジオ"
    case messenger = "連絡"
    var id: String { rawValue }
    var url: URL {
        switch self {
        case .box: return URL(string: "https://koe.live/box")!
        case .feed: return URL(string: "https://koe.live/feed")!
        case .live: return URL(string: "https://koe.live/live")!
        case .messenger: return URL(string: "https://mcp.koe.live/messenger")!  // WebView は使わずネイティブで開く
        }
    }
    var isNative: Bool { self == .messenger }
}

private let kBoxClaimedKey = "koe_box_claimed_native"

struct ConnectView: View {
    @State private var selection: ConnectSection

    init() {
        // /boxはkoe.live側のJSがlocalStorage(koe_box_h/koe_box_k)で本人を覚えている
        // (WKWebViewの永続WebsiteDataStoreはアプリ内で共有されるので、これ自体は既存の
        // Web側実装だけで動く)。ここではネイティブ側に「一度でも受信箱を持ったことがある」
        // というフラグだけを保持し、無ければ「届いた声」でなく「ラジオ」を初期表示にする
        // (いきなり空の受信箱・認証UIを見せず、聞くだけで温かい入口から始める)。
        // チュートリアル後に「つながる」を開いた場合は AppState の指示でラジオを強制表示。
        if AppState.shared.pendingConnectSection == .live {
            AppState.shared.pendingConnectSection = nil
            _selection = State(initialValue: .live)
        } else {
            let claimed = KeychainHelper.get(key: kBoxClaimedKey) == "1"
            _selection = State(initialValue: claimed ? .box : .live)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selection) {
                    ForEach(ConnectSection.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ZStack {
                    ForEach(ConnectSection.allCases) { s in
                        if s.isNative {
                            // 💬 メッセンジャーは WebView ではなくネイティブ SwiftUI で開く
                            // (読み上げ・通知・返信を iPhone 側で制御するため)
                            MessengerView(model: MessengerModel())
                                .opacity(selection == s ? 1 : 0)
                                .allowsHitTesting(selection == s)
                        } else {
                            ConnectWebPane(url: s.url, onBoxIdentified: {
                                KeychainHelper.save(key: kBoxClaimedKey, value: "1")
                            })
                            .opacity(selection == s ? 1 : 0)
                            .allowsHitTesting(selection == s)
                        }
                    }
                }

                NavigationLink {
                    WebAppView(url: URL(string: "https://koe.live/call-admin")!)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("安全な通話")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Image(systemName: "phone.badge.waveform")
                        Text("📞 安全な通話を始める")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("つながる")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// /boxだけ、ページ読み込み後にlocalStorageのkoe_box_hを覗いて「受信箱を持っている」判定に使う。
/// 判定だけが目的で、値そのものはネイティブ側に持ち出さない(Web側の既存の鍵管理をそのまま尊重)。
private struct ConnectWebPane: View {
    let url: URL
    var onBoxIdentified: () -> Void = {}

    var body: some View {
        if url.path == "/box" {
            WebAppView(url: url, onNavigationFinished: { webView in
                webView.evaluateJavaScript("window.localStorage.getItem('koe_box_h')") { result, _ in
                    if let h = result as? String, !h.isEmpty {
                        onBoxIdentified()
                    }
                }
            })
            .ignoresSafeArea(edges: .bottom)
        } else {
            WebAppView(url: url)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
