import AppIntents
import SwiftUI
import UIKit

// MARK: - Start Recording Intent
struct StartVoiceInputIntent: AppIntent {
    static let title: LocalizedStringResource = "音声入力を開始"
    static let description = IntentDescription("Koeで音声入力を開始します")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "koe://transcribe") {
            await UIApplication.shared.open(url)
        }
        return .result()
    }
}

struct StopVoiceInputIntent: AppIntent {
    static let title: LocalizedStringResource = "音声入力を停止"
    static let description = IntentDescription("Koeの音声入力を停止します")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - App Shortcuts Provider
struct KoeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceInputIntent(),
            phrases: [
                "Start voice input with \(.applicationName)",
                "\(.applicationName)で音声入力",
                "\(.applicationName)を起動",
                "声でメモ"
            ],
            shortTitle: "音声入力を開始",
            systemImageName: "mic.fill"
        )
    }
}
