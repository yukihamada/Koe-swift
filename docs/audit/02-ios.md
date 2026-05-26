# 02 — iOS app audit

検証対象: `Koe-iOS/`
監査日: 2026-05-26
方法: 静的監査 (Explore + 再 grep 検証)

> This is a friendly audit prepared by an external contributor. All suggestions are non-binding; happy to discuss, revise, or drop any item.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| I-01 | P0 | App Groups 未設定で extension とのデータ共有不可 | `Koe-iOS/Koe.entitlements` |
| I-02 | P0 | HuggingFace モデル DL に SHA256 検証なし | `Koe-iOS/Sources/ModelManager.swift:103` |
| I-03 | P0 | MultipeerConnectivity の discoveryInfo に PIN を平文ブロードキャスト | `Koe-iOS/Sources/MacBridge.swift:270` |
| I-04 | P1 | UIBackgroundModes=audio で SoundMemory 24/7 録音 — App Review / プライバシー透明性 | `Koe-iOS/Info.plist:59`, `Koe-iOS/Sources/SoundMemory.swift:38` |
| I-05 | P1 | RecordingManager と WakeWordDetector で AVAudioSession カテゴリ不整合 | `Koe-iOS/Sources/RecordingManager.swift:100`, `Koe-iOS/Sources/WakeWordDetector.swift:71` |
| I-06 | P1 | KoeKeyboard の RequestsOpenAccess=true が機能上不要 | `Koe-iOS/KoeKeyboard/Info.plist:37` |
| I-07 | P1 | URLSession.shared で chatweb.ai に通信、cert pinning なし | `Koe-iOS/Sources/BLEAudioBridge.swift:152`, `Koe-iOS/Sources/RecordingManager.swift:723` |
| I-08 | P1 | MacBridge ペアリングが displayName で識別 (スプーフ可能) | `Koe-iOS/Sources/MacBridge.swift:32-35` |
| I-09 | P2 | SoundMemory が低電力/熱状態に未対応 | `Koe-iOS/Sources/SoundMemory.swift:79` |
| I-10 | P2 | Apple Speech denied/restricted のメッセージ重複 | `Koe-iOS/Sources/RecordingManager.swift:86-88` |
| I-11 | P2 | KoeWatch ターゲットが project.yml 未登録 (dead code 疑い) | `Koe-iOS/project.yml`, `Koe-iOS/KoeWatch/` |
| I-12 | P3 | KoeShareExt / KoeKeyboard のコード重複 (3 つの SFSpeechRecognizer 設定が散在) | `Koe-iOS/KoeShareExt/ShareViewController.swift`, `Koe-iOS/KoeKeyboard/KeyboardViewController.swift` |

## 詳細

### I-01 (P0) — App Groups 未設定で extension とのデータ共有不可
**File**: `Koe-iOS/Koe.entitlements:1-5`
**Symptom**: `Koe.entitlements` の中身が `<dict/>` で空。`grep -rn "group.com.yuki\|UserDefaults(suiteName" Koe-iOS/` も 0 hits。一方で本体・キーボード・共有拡張・Widget・Watch のすべてが `koe_language`, `koe_history`, `koe_quick_phrases` などの `UserDefaults.standard` を共有しているつもりの実装になっている。
**Repro**: ホストアプリで言語を ja→en に切り替えても、`KoeKeyboard` / `KoeShareExt` の `UserDefaults.standard.string(forKey: "koe_language")` は古い値を返す（拡張は独立サンドボックスなため）。
**Suggested fix**:
```xml
<!-- Koe.entitlements / KoeKeyboard/*.entitlements / KoeShareExt/*.entitlements -->
<key>com.apple.security.application-groups</key>
<array>
  <string>group.com.yuki.koe</string>
</array>
```
```swift
// 共通アクセサに集約
extension UserDefaults {
    static let shared = UserDefaults(suiteName: "group.com.yuki.koe") ?? .standard
}
```

### I-02 (P0) — HuggingFace モデル DL に SHA256 検証なし
**File**: `Koe-iOS/Sources/ModelManager.swift:103-155`
**Symptom**: `URLSession.shared.downloadTask(with: url)` の完了ハンドラで `moveItem` するだけ。改ざん検出なし。HuggingFace の `resolve/main/...` URL は branch tip なのでサーバー側で差し替えられる可能性がある。
**Suggested fix**: `WhisperModel` に `expectedSHA256: String` を追加し、DL 後に `CryptoKit.SHA256` で検証して不一致なら破棄。
```swift
import CryptoKit
let digest = SHA256.hash(data: try Data(contentsOf: tempURL))
let hex = digest.map { String(format: "%02x", $0) }.joined()
guard hex == model.expectedSHA256 else {
    try? FileManager.default.removeItem(at: tempURL)
    downloadStatus = "改ざんを検出しました"
    return
}
```

### I-03 (P0) — MultipeerConnectivity の discoveryInfo に PIN を平文ブロードキャスト
**File**: `Koe-iOS/Sources/MacBridge.swift:267-296`
**Symptom**: Mac 側が `MCNearbyServiceAdvertiser` の `discoveryInfo: ["pin": "1234"]` を Bonjour TXT で配信し、iOS は `info?["pin"]` をそのまま読んで自動ペアリング (`browser:foundPeer:withDiscoveryInfo:` 270 行目)。同一 Wi-Fi 上の任意の端末から `dns-sd -B _koe-bridge._tcp` で PIN が読める。
**Repro**: `dns-sd -L "Mac名" _koe-bridge._tcp local` を実行すると TXT レコードの中に PIN が見える。
**Suggested fix**: discoveryInfo には `salt` のみ載せ、PIN は Mac 画面に表示してユーザーが iOS で入力 → iOS から `invitePeer(..., withContext: HMAC(pin, salt))` で送る。Mac 側で同じ計算をして一致確認。

### I-04 (P1) — UIBackgroundModes=audio + SoundMemory 24/7 録音 (App Review / 透明性)
**File**: `Koe-iOS/Info.plist:59-62`, `Koe-iOS/Sources/SoundMemory.swift:38,79-158`
**Symptom**: `UIBackgroundModes = [audio]` だけで `segmentDuration = 30` 秒ループの常時録音を駆動。UI に録音中インジケータ (オレンジドット以外) なし、データ保持期間 7 日の説明 UI も最低限。iOS 17+ では「マイクが常にオンになっています」という App Review 指摘および GDPR/個人情報保護法上の透明性要件に抵触しやすい。
**Suggested fix**:
1. オンボーディングで「24 時間録音 → 端末内で 7 日保持 → 任意削除」を明示する画面を追加。
2. `NSMicrophoneUsageDescription` を SoundMemory 用に具体化。
3. ロック画面表示インジケータ、`UIApplication.willResignActiveNotification` でユーザー設定どおりに pause/continue を選ばせる。

### I-05 (P1) — AVAudioSession カテゴリ不整合
**File**: `Koe-iOS/Sources/RecordingManager.swift:100`, `Koe-iOS/Sources/WakeWordDetector.swift:71`
**Symptom**: `RecordingManager` は `.record` / `.measurement` / `.duckOthers`、`WakeWordDetector` は `.playAndRecord` / `.measurement` / `[.duckOthers, .defaultToSpeaker]`。ウェイクワード起動 → 録音遷移時にカテゴリが切り替わり、`AVAudioEngine` の inputNode フォーマットが再ネゴシエートされて 100〜300 ms のドロップアウトが起こる。`SoundMemory` (line 84 `.record`) と並列起動した場合は engine 競合で `installTap` が `kAudioUnitErr_TooManyFramesToProcess` を投げる可能性。
**Suggested fix**: シングルトン `AudioSessionCoordinator` を作って、起動中の機能 (wake / record / soundMemory / bleBridge) のセットに応じて常に最広カテゴリ (`.playAndRecord`, `.measurement`, `[.duckOthers, .allowBluetooth, .defaultToSpeaker]`) を一度だけ設定する。

### I-06 (P1) — KoeKeyboard の RequestsOpenAccess=true が機能上不要
**File**: `Koe-iOS/KoeKeyboard/Info.plist:37-38`
**Symptom**: `RequestsOpenAccess = true` が設定されているが、`KoeKeyboard/KeyboardViewController.swift` の実装は `textDocumentProxy.insertText` (line 202) と on-device `SFSpeechRecognizer` のみ。`UIPasteboard` / `NSURLSession` / `sharedContainerURL` の使用なし。Open Access はユーザーへの権限要求としては最も重く、Apple のキーボード拡張審査でも指摘されやすい。
**Suggested fix**: Open Access に依存する機能 (App Group 経由の履歴共有 etc.) を入れない限り `false` に。あるいは I-01 を実施したうえで「履歴共有のため」と説明 UI を出す。

### I-07 (P1) — URLSession.shared で chatweb.ai 通信、証明書ピンニングなし
**File**: `Koe-iOS/Sources/BLEAudioBridge.swift:127,152`, `Koe-iOS/Sources/RecordingManager.swift:707,723`
**Symptom**: 認識テキストや LLM プロンプトを `https://api.chatweb.ai/v1/chat/completions` に POST するが、`URLSession.shared` を直に使い `URLSessionDelegate` での `urlSession:didReceiveChallenge:` 実装なし。MITM (社内プロキシ・偽 CA) でユーザーの音声認識結果が抜かれる経路がある。Info.plist にも ATS exception はない (good) が、信頼チェーンは OS のシステムルートに完全依存。
**Suggested fix**: SPKI ピンニング (chatweb.ai のリーフまたは中間 CA の public key hash 配列) を `URLSessionDelegate` で実装。`URLSession(configuration: .default, delegate: PinningDelegate(), delegateQueue: nil)` をシングルトンに格納。

### I-08 (P1) — MacBridge ペアリングが displayName で識別 (スプーフ可能)
**File**: `Koe-iOS/Sources/MacBridge.swift:32-35, 80-86, 286`
**Symptom**: `pairedMacNames: Set<String>` は `peerID.displayName` (= Mac の `UIDevice.current.name` 相当) で記録され、`pairedMacNames.contains(peerID.displayName)` で PIN なし自動接続を許可する。同じ Wi-Fi 上で同名の `MCPeerID` を advertise すれば、ユーザー操作なしに iOS が接続しテキスト送信を受け付ける（受信側 = Mac だが、iOS 側は `connect(to: peerID, pin: pin)` で discoveryInfo の `pin` をそのまま渡してしまう）。
**Suggested fix**: ペアリング成功時に Mac から長期トークン (Curve25519 公開鍵) を発行 → iOS Keychain に保存。次回以降は `invitePeer(..., withContext:)` でその公開鍵で署名した challenge を送信し、Mac 側で検証。

### I-09 (P2) — SoundMemory が低電力/熱状態に未対応
**File**: `Koe-iOS/Sources/SoundMemory.swift:79-158`
**Symptom**: `ProcessInfo.processInfo.isLowPowerModeEnabled` / `thermalState` の observer なし。低電力モードでも 30 秒ごとに Whisper 推論を走らせる (`finalizeCurrentSegment` line 293)。バッテリー減と熱問題の苦情につながる。
**Suggested fix**:
```swift
NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, ...) { _ in
    if ProcessInfo.processInfo.isLowPowerModeEnabled { self.stopCapture() }
}
NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, ...) { _ in
    if [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) { self.stopCapture() }
}
```

### I-10 (P2) — Apple Speech denied/restricted のメッセージ重複
**File**: `Koe-iOS/Sources/RecordingManager.swift:86-88`
**Symptom**: `if case .denied` と `if case .restricted` で同じ statusText を 2 行で設定。`switch` 1 個にできる。
**Suggested fix**:
```swift
SFSpeechRecognizer.requestAuthorization { status in
    DispatchQueue.main.async {
        switch status {
        case .denied, .restricted: self.statusText = "音声認識の権限がありません"
        case .notDetermined: self.statusText = "音声認識の権限待ち"
        case .authorized: break
        @unknown default: break
        }
    }
}
```

### I-11 (P2) — KoeWatch ターゲットが project.yml 未登録
**File**: `Koe-iOS/project.yml:14-99`, `Koe-iOS/KoeWatch/`
**Symptom**: `project.yml` の targets は `Koe / KoeKeyboard / KoeShareExt / KoeWidget` のみ。`KoeWatch/` ディレクトリには 3 ファイル (`KoeWatchApp.swift`, `WatchContentView.swift`, `WatchSessionManager.swift`) があるが、xcodegen 経由ではビルドされない。一方 `Koe-iOS/Sources/WatchRelay.swift` がペアリング相手として参照しているように見える。
**Suggested fix**: 意図して残してあるなら `project.yml` に `KoeWatch` ターゲットを追加。実装途中で凍結したなら `KoeWatch/` を `.docs/` か別ブランチに退避してリポジトリから外す。

### I-12 (P3) — KoeShareExt / KoeKeyboard で SFSpeechRecognizer 設定が散在
**File**: `Koe-iOS/KoeShareExt/ShareViewController.swift:142-194`, `Koe-iOS/KoeKeyboard/KeyboardViewController.swift:142-199`, `Koe-iOS/Sources/RecordingManager.swift:255-348`
**Symptom**: 同じ `SFSpeechAudioBufferRecognitionRequest` セットアップ (partial results / onDevice / installTap) が 3 か所にコピペ。1 箇所修正すると 3 箇所追従が必要。
**Suggested fix**: `SpeechRecognitionSession` という構造体に切り出して 3 ターゲット共通の Swift Package もしくは `Sources/Shared/` に置く (App Group とは別レイヤ)。

## Out of scope (this PR)
- `MeetingManager.swift` / `CallTranscriber.swift` の細部 (別 PR)
- whisper.cpp ggml ライブラリ自体の脆弱性スキャン
- Live Activity / Dynamic Island の UX
- ローカライズ (L10n.swift は別 PR で集約済み)
