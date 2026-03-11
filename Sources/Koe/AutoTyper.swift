import AppKit
import Carbon.HIToolbox

class AutoTyper {
    /// 直接入力モード: 前回ストリーミングで入力した文字数
    private var streamingCharCount = 0

    func type(_ text: String) {
        typeInto(text, bundleID: nil)
    }

    /// 指定アプリをアクティブにしてからペースト。bundleID が nil なら現在のアプリに。
    func typeInto(_ text: String, bundleID: String?) {
        if let bundleID, !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           !app.isActive {
            app.activate()
            // アプリがフォーカスを受け取るまで少し待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.paste(text)
            }
        } else {
            paste(text)
        }
    }

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let prev = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            pb.clearContents()
            if let prev { pb.setString(prev, forType: .string) }
        }
    }

    /// ストリーミング認識テキストを直接入力（前回分を削除して上書き）
    func typeStreaming(_ text: String, bundleID: String?) {
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
    }

    /// ストリーミング入力を確定（最終結果で上書き）
    func finalizeStreaming(_ text: String, bundleID: String?) {
        if streamingCharCount > 0 {
            deleteBackward(count: streamingCharCount)
            Thread.sleep(forTimeInterval: 0.02)
        }
        streamingCharCount = 0
        typeInto(text, bundleID: bundleID)
    }

    /// ストリーミング入力をキャンセル（入力済みテキストを削除）
    func cancelStreaming() {
        if streamingCharCount > 0 {
            deleteBackward(count: streamingCharCount)
            streamingCharCount = 0
        }
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
        Thread.sleep(forTimeInterval: 0.012)  // 12ms: アプリが認識できる最短時間
        up.post(tap: .cghidEventTap)
    }
}
