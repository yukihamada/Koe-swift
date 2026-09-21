import SwiftUI

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var shouldStartRecording = false
    @Published var selectedTab: Int = 0
    /// 📞 CallKitで応答が押された瞬間にroom_idが立つ。非nilの間、着信通話のWebViewを全画面表示する。
    @Published var incomingCallRoomID: String? = nil
    /// チュートリアル等から「つながる」タブで最初に表示したいセクション（一度消費されたらクリア）
    @Published var pendingConnectSection: ConnectSection? = nil
}

@main
struct KoeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    init() {
        // APIキーをUserDefaultsからKeychainに移行（初回のみ）
        KeychainHelper.migrateFromUserDefaults(key: "koe_api_key")
        // ハンズフリーは既定OFF（常時録音を避ける）。使う時だけ More でON。
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onOpenURL { url in
                    if url.scheme == "koe" && url.host == "transcribe" {
                        appState.shouldStartRecording = true
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { appState.incomingCallRoomID != nil },
                    set: { if !$0 { appState.incomingCallRoomID = nil } }
                )) {
                    if let roomId = appState.incomingCallRoomID,
                       let url = URL(string: "https://koe.live/t/\(roomId)?auto=1") {
                        ZStack(alignment: .topTrailing) {
                            WebAppView(url: url).ignoresSafeArea()
                            Button {
                                appState.incomingCallRoomID = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding()
                        }
                    }
                }
        }
    }
}

struct MainTabView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var macBridge = MacBridge.shared
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @StateObject private var sharedRecorder = RecordingManager()

    var body: some View {
        // 🎛 5→3タブに整理(2026-07-25本人指示「よくわかんないアプリに感じる」→ペルソナレビュー)。
        // 「履歴」「通話」は独立タブをやめ、設定タブの中のセクションへ格下げ(機能は削らない)。
        TabView(selection: $appState.selectedTab) {
            ContentView()
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("話す")
                }
                .tag(0)

            if screenContextEnabled && macBridge.isConnected {
                MacScreenView()
                    .tabItem {
                        Image(systemName: "display")
                        Text("Mac")
                    }
                    .tag(10)
            }

            ConnectView()
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                    Text("つながる")
                }
                .tag(4)

            MoreView(recorder: sharedRecorder)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("設定")
                }
                .tag(2)
        }
        .tint(.orange)
    }
}
