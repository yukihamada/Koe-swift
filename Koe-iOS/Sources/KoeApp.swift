import SwiftUI

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var shouldStartRecording = false
    @Published var selectedTab: Int = 0
}

@main
struct KoeApp: App {
    @StateObject private var appState = AppState.shared

    init() {
        // APIキーをUserDefaultsからKeychainに移行（初回のみ）
        KeychainHelper.migrateFromUserDefaults(key: "koe_api_key")
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onOpenURL { url in
                    if url.scheme == "koe" && url.host == "transcribe" {
                        appState.shouldStartRecording = true
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
        TabView(selection: $appState.selectedTab) {
            ContentView()
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("Koe")
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

            HistoryView(recorder: sharedRecorder)
                .tabItem {
                    Image(systemName: "clock")
                    Text("履歴")
                }
                .tag(1)

            MoreView()
                .tabItem {
                    Image(systemName: "ellipsis.circle")
                    Text("More")
                }
                .tag(2)
        }
        .tint(.orange)
    }
}
