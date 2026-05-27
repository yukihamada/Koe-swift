import Foundation

// HTTP サーバー方式は廃止。whisper.cpp 直接呼び出しに移行。

extension Notification.Name {
    static let localWhisperStatusChanged = Notification.Name("localWhisperStatusChanged")
    /// Posted when the user picks a new value for `AppSettings.language`.
    /// AppDelegate observes this to reload SpeechEngine / WhisperContext.
    static let koeLanguageDidChange = Notification.Name("koeLanguageDidChange")
    /// Posted by WakeWordEngine when 3 consecutive AVAudioEngine rebuilds fail.
    static let koeWakeWordEngineFailed = Notification.Name("koeWakeWordEngineFailed")
}
