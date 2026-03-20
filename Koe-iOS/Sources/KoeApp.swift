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
    @AppStorage("koe_screen_context") private var screenContextEnabled = false

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            ContentView()
                .tabItem {
                    Image(systemName: "mic.fill")
                    Text("Koe")
                }
                .tag(0)

            if screenContextEnabled {
                MacScreenView()
                    .tabItem {
                        Image(systemName: "display")
                        Text("Screen")
                    }
                    .tag(10)
            }

            SolunaView()
                .tabItem {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Soluna")
                }
                .tag(1)

            SoundMemoryView()
                .tabItem {
                    Image(systemName: "brain")
                    Text("Memory")
                }
                .tag(2)

            ConversationView()
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("翻訳")
                }
                .tag(3)

            AudioToolsView()
                .tabItem {
                    Image(systemName: "waveform")
                    Text("Tools")
                }
                .tag(4)
        }
        .tint(.orange)
    }
}
