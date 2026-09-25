import Foundation

/// Koe の音声入力（fn PTT 等）の開始/終了を `DistributedNotificationCenter` 経由で
/// 他アプリへ伝える。現在の購読者は Second (`~/work/dev/10-product/second-macos`) の
/// `VoiceArbiter` — 口述中は Second 自身の音声操作ホットキー(⌃⌥V)がマイクを取り合わない
/// よう即座にセッションを譲るために使う（`VoiceArbiter.staleDictationTimeout` により
/// `began` 送信後 120 秒 `ended` が来なければ自動失効する安全弁もある）。
///
/// 通知名は Second 側の `VoiceArbiter.dictationBeganNotification` /
/// `.dictationEndedNotification` と一字一句一致させること。互いのリポジトリを import
/// しないので、この文字列がその契約そのもの。
protocol DictationLifecycleNotifying {
    func postDictationBegan()
    func postDictationEnded()
}

/// 実装本体。テスト以外では `AppDelegate.dictationNotifier` にこれだけが刺さる。
final class DictationNotificationPoster: DictationLifecycleNotifying {
    static let shared = DictationNotificationPoster()

    static let beganNotificationName = "io.atsume.voice.dictation.began"
    static let endedNotificationName = "io.atsume.voice.dictation.ended"

    func postDictationBegan() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.beganNotificationName),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    func postDictationEnded() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.endedNotificationName),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
