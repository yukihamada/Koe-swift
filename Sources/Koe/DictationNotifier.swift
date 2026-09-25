import Foundation

/// Koe の音声入力の開始/終了を `DistributedNotificationCenter` 経由で他アプリへ伝える。
/// 現在の購読者は Second (`~/work/dev/10-product/second-macos`) の `VoiceArbiter` —
/// 口述中は Second 自身の音声操作ホットキー(⌃⌥V)がマイクを取り合わないよう即座に
/// セッションを譲るために使う（`VoiceArbiter.staleDictationTimeout` により `began`
/// 送信後 120 秒 `ended` が来なければ自動失効する安全弁もある）。
///
/// **契約は「Koe がマイクを握っている間ずっと」** — fn PTT に限らない。
/// `AppDelegate.startRecording()`/`stopAndRecognize()`/`cancelRecording()` は
/// fn 押し下げ PTT・fn タップトグル・メインホットキー(⌥⌘V)・議事録モードの自動録音・
/// シームレスモード・翻訳モード・URL scheme (`koe://transcribe`)・フローティングボタン
/// 等、Koe がマイクを掴むあらゆる経路が最終的に通る共通の入口/出口であり、意図的に
/// ここで一括して通知する（「今 Koe がマイクを握っているか」だけが Second にとって
/// 重要で、どの UI から録音を始めたかは関係ない）。ウェイクワード検出
/// (`WakeWordDetector`/`AlwaysOnRecorder`) はこの `startRecording()` を経由しない別経路
/// なので対象外 — 常時待受は「口述中」ではない。
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
