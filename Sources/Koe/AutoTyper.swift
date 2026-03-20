import AppKit
import Carbon.HIToolbox
import UserNotifications

class AutoTyper {
    /// 直接入力モード: 前回ストリーミングで入力した文字数
    private var streamingCharCount = 0

    /// アクセシビリティ権限があるか（CGEvent でキー送信可能か）
    private var canUseCGEvent: Bool { AXIsProcessTrusted() }

    func type(_ text: String) {
        typeInto(text, bundleID: nil)
    }

    /// 指定アプリをアクティブにしてからペースト。bundleID が nil なら現在のアプリに。
    func typeInto(_ text: String, bundleID: String?) {
        if let bundleID, !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           !app.isActive {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.paste(text)
            }
        } else {
            paste(text)
        }
    }

    func paste(_ text: String) {
        let pb = NSPasteboard.general
        let prev = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let trusted = canUseCGEvent
        klog("AutoTyper: paste '\(text.prefix(40))' canUseCGEvent=\(trusted)")

        if trusted {
            postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                pb.clearContents()
                if let prev { pb.setString(prev, forType: .string) }
            }
        } else {
            // アクセシビリティなし: クリップボードに置くだけ（復元しない）
            klog("AutoTyper: no accessibility — clipboard only")
            showClipboardHint()
        }
    }

    /// ストリーミング認識テキストを直接入力（前回分を削除して上書き）
    func typeStreaming(_ text: String, bundleID: String?) {
        if canUseCGEvent {
            // 前回入力分をバックスペースで削除
            if streamingCharCount > 0 {
                deleteBackward(count: streamingCharCount)
                Thread.sleep(forTimeInterval: 0.02)
            }
            streamingCharCount = text.count
            if let bundleID, !bundleID.isEmpty,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               !app.isActive {
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.pasteStreaming(text)
                }
            } else {
                pasteStreaming(text)
            }
        } else {
            // アクセシビリティなし: クリップボードを更新するだけ
            streamingCharCount = 0
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// ストリーミング入力を確定（最終結果で上書き）
    func finalizeStreaming(_ text: String, bundleID: String?) {
        if canUseCGEvent && streamingCharCount > 0 {
            deleteBackward(count: streamingCharCount)
            Thread.sleep(forTimeInterval: 0.02)
        }
        streamingCharCount = 0
        typeInto(text, bundleID: bundleID)
    }

    /// Apple Speech先行入力をwhisper結果で置換
    func deleteAndReplace(oldText: String, newText: String, bundleID: String?) {
        if canUseCGEvent {
            // 先行入力分をBackSpaceで削除
            deleteBackward(count: oldText.count)
            Thread.sleep(forTimeInterval: 0.03)
        }
        // whisper結果をペースト
        typeInto(newText, bundleID: bundleID)
    }

    /// ストリーミング入力をキャンセル（入力済みテキストを削除）
    func cancelStreaming() {
        if canUseCGEvent && streamingCharCount > 0 {
            deleteBackward(count: streamingCharCount)
        }
        streamingCharCount = 0
    }

    private func pasteStreaming(_ text: String) {
        let pb = NSPasteboard.general
        let prev = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            pb.clearContents()
            if let prev { pb.setString(prev, forType: .string) }
        }
    }

    // MARK: - Clipboard Hint (アクセシビリティ不要モード)

    /// 「⌘V でペースト」の一時通知を表示
    private func showClipboardHint() {
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = "Koe"
            content.body = "⌘V でペースト"
            let request = UNNotificationRequest(identifier: "koe-paste-hint", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            // 2秒後に自動消去
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["koe-paste-hint"])
            }
        }
    }

    // MARK: - Voice Edit Commands

    /// Return/Enterキー送信
    func postReturn() {
        guard canUseCGEvent else { return }
        postKey(keyCode: CGKeyCode(kVK_Return), flags: [])
    }

    /// Cmd+Z (元に戻す)
    func postUndo() {
        guard canUseCGEvent else { return }
        postKey(keyCode: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
    }

    /// Tabキーを送信
    func postTab() {
        guard canUseCGEvent else { return }
        postKey(keyCode: CGKeyCode(kVK_Tab), flags: [])
    }

    /// Cmd+A → Delete (全選択して削除)
    func postSelectAllDelete() {
        guard canUseCGEvent else { return }
        postKey(keyCode: CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.05)
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
           let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) {
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - CGEvent Key Simulation (アクセシビリティ必要)

    private func deleteBackward(count: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard
                let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                let up   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else { continue }
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.003)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.003)
        }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
            let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags   = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        up.post(tap: .cghidEventTap)
    }
}
