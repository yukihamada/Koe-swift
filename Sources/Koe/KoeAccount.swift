import Foundation
import AppKit

/// Koe アカウント接続の単一の入口。
///
/// これまで M5SpeakClient/VoiceMemoShare/VoiceMessageWindow/RadioUploader が各々別の
/// Keychain キー("m5SpeakKey"/"takibiApiKey"/"voiceSendKey")に同じ koe_… キーを別々に
/// コピペ保存させていた(1機能ごとに1回ペーストが要る導線だった)。ここで1つの鍵に統合し、
/// 「設定 → Koe アカウントを接続」1回で全機能が使えるようにする。
/// 接続は mcp.koe.live/login?redirect=mac をブラウザで開き、メールのログインリンクから
/// koe://connect?key=koe_… で自動的にアプリへ戻ってくる(コピペ不要)。
enum KoeAccount {
    /// 接続/解除のたびに投げる。Settings 画面がブラウザ往復の完了をリアルタイムに反映するため。
    static let connectionChangedNotification = Notification.Name("koeAccountConnectionChanged")

    private static let key = "koeApiKey"
    /// 旧キー。既存ユーザーが再接続せずに済むよう、初回参照時にここから統合キーへ移行する。
    /// (takibiApiKey は別サービス takibi.wtf の api_token なので対象外)
    private static let legacyKeys = ["m5SpeakKey", "voiceSendKey"]

    static var current: String? {
        if let k = KeychainHelper.get(key), !k.isEmpty { return k }
        for legacy in legacyKeys {
            if let k = KeychainHelper.get(legacy), !k.isEmpty {
                KeychainHelper.set(k, for: key)
                return k
            }
        }
        return nil
    }

    static var isConnected: Bool { current != nil }

    @discardableResult
    static func save(_ rawKey: String) -> Bool {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = KeychainHelper.set(trimmed, for: key)
        if ok { NotificationCenter.default.post(name: connectionChangedNotification, object: nil) }
        return ok
    }

    static func disconnect() {
        KeychainHelper.delete(key)
        legacyKeys.forEach { KeychainHelper.delete($0) }
        NotificationCenter.default.post(name: connectionChangedNotification, object: nil)
    }

    /// mcp.koe.live/login をブラウザで開く。ログイン完了後は koe://connect?key=... で
    /// AppDelegate.handleURLEvent に戻ってくる(コピペ不要の一発接続)。
    static func openConnectFlow() {
        guard let url = URL(string: "https://mcp.koe.live/login?redirect=mac") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 未接続時のフォールバック: 従来通り貼り付けダイアログも残す(ブラウザ導線が使えない環境向け)。
    static func resolveWithPasteFallback(promptTitle: String, promptBody: String) -> String? {
        if let k = current { return k }
        let alert = NSAlert()
        alert.messageText = promptTitle
        alert.informativeText = promptBody
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "koe_…"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "ブラウザで接続")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            save(trimmed)
            return trimmed
        case .alertSecondButtonReturn:
            openConnectFlow()
            return nil
        default:
            return nil
        }
    }
}
