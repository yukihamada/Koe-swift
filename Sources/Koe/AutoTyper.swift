import AppKit
import Carbon.HIToolbox

class AutoTyper {
    func type(_ text: String) {
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
