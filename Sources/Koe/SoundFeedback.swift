import AppKit

/// ハンズフリー継続セッションの状態遷移を耳で伝える短い効果音（earcon）。
///
/// マイクへの回り込みを避けるため、どれも短く・小音量。macOS の組み込みシステムサウンド
/// （/System/Library/Sounds）を使うので追加アセット不要。`conversationEarconEnabled` が
/// false の時は鳴らさない。
final class SoundFeedback {
    static let shared = SoundFeedback()

    enum Cue {
        case wake        // wake 検出直後（録音開始前）— 「反応した」合図
        case turnEnd     // ターン確定（無音検出）— 控えめ
        case sessionEnd  // セッション終了
        case confirm     // 確認待ち（はい/いいえ）
        case error       // 失敗

        /// 組み込みシステムサウンド名。
        var systemSoundName: String {
            switch self {
            case .wake:       return "Pop"
            case .turnEnd:    return "Tink"
            case .sessionEnd: return "Bottle"
            case .confirm:    return "Ping"
            case .error:      return "Basso"
            }
        }

        /// 小音量に抑える（マイク回り込み対策）。
        var volume: Float {
            switch self {
            case .wake:       return 0.35
            case .turnEnd:    return 0.20
            case .sessionEnd: return 0.30
            case .confirm:    return 0.40
            case .error:      return 0.40
            }
        }
    }

    /// 連続再生で前の音が残らないよう保持。
    private var current: NSSound?

    private init() {}

    func play(_ cue: Cue) {
        guard AppSettings.shared.conversationEarconEnabled else { return }
        DispatchQueue.main.async {
            guard let sound = NSSound(named: NSSound.Name(cue.systemSoundName)) else {
                klog("SoundFeedback: missing system sound '\(cue.systemSoundName)'")
                return
            }
            sound.volume = cue.volume
            self.current?.stop()
            self.current = sound
            sound.play()
        }
    }
}
