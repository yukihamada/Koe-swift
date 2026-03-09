import Foundation

// HTTP サーバー方式は廃止。whisper.cpp 直接呼び出しに移行。

extension Notification.Name {
    static let localWhisperStatusChanged = Notification.Name("localWhisperStatusChanged")
}
