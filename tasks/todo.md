# Koe iOS — 9機能実装計画

## 概要
Koe iOSアプリに9つの新機能を追加する。既存のMacBridge (MultipeerConnectivity)、WhisperContext (whisper.cpp)、RecordingManager、SoundMemory等の基盤を最大限活用する。

## 調査結果

### 既存アーキテクチャ
| コンポーネント | ファイル | 役割 |
|--------------|---------|------|
| `RecordingManager` | `Sources/RecordingManager.swift` | 録音 + Apple Speech/Whisper認識 + LLM後処理 + Handoff |
| `MacBridge` | `Sources/MacBridge.swift` | MultipeerConnectivity (iOS→Mac) テキスト/音声送信 |
| `WhisperContext` | `Sources/WhisperContext.swift` | whisper.cpp C APIラッパー (GPU Metal対応) |
| `ModelManager` | `Sources/ModelManager.swift` | HuggingFaceモデルDL/管理 |
| `SoundMemory` | `Sources/SoundMemory.swift` | 30秒セグメント常時録音 + Whisper文字起こし + 検索 |
| `KoeWidget` | `KoeWidget/KoeWidget.swift` | ホーム画面ウィジェット + Live Activity (Dynamic Island) |
| `KoeShortcuts` | `Sources/KoeShortcuts.swift` | AppIntents (Siri/ショートカット) |
| `KoeRecordingAttributes` | `Sources/KoeRecordingAttributes.swift` | ActivityKit属性定義 |
| `ConversationView` | `Sources/ConversationView.swift` | 対面翻訳 (2言語分割画面) |

### Mac側の参考実装 (既にMacにある機能)
| 機能 | Mac側ファイル | 備考 |
|------|-------------|------|
| テキスト自動入力 | `AutoTyper.swift` | CGEvent Cmd+V ペースト |
| iPhone→Mac受信 | `IPhoneBridge` (AppDelegate.swift内) | MCSession advertiser |
| 音声コマンド | `VoiceCommands.swift` | 改行/削除/取消/全選択 等 |
| 議事録モード | `MeetingMode.swift` | 話者分離 + LLM整形 + SRT出力 |
| アプリ認識 | `ContextCollector.swift` | AXUIElement + バンドルID→ヒント |
| LLM後処理 | `LLMProcessor.swift` | ローカル/リモートLLM切替 |

### ビルド構成
- `project.yml` (XcodeGen) -- iOS 17.0+, Swift 5.9
- 既存targets: `Koe`, `KoeKeyboard`, `KoeShareExt`
- KoeWidget target は project.yml に未定義 (xcodeproj直接編集)
- Info.plist: マイク/音声認識/ローカルネットワーク/Bonjour 許可済み

### 通信プロトコル (MacBridge <-> IPhoneBridge)
- サービスタイプ: `koe-bridge` (MultipeerConnectivity)
- テキスト送信: `{"type": "text", "text": "..."}`
- Whisperリクエスト: `{"type": "whisper_request", ...}` + 0xFFFFFFFF + PCMデータ
- Whisper結果: `{"type": "whisper_result", "text": "...", "translated": "..."}`

---

## 実装ステップ (優先順位順)

### Phase 1: コア体験の強化 (最優先)

#### Feature 1: リアルタイムストリーミングテキスト送信
**概要**: 録音中にApple SpeechのpartialResultsをリアルタイムでMacに送信し、Macのカーソル位置に即座にテキストが表示される。

**現状**: RecordingManagerは認識完了後にMacBridge.sendText()で1回だけ送信。Apple Speechのpartial resultsはrecognizedTextに表示されているがMacには送っていない。

**実装**:
- [ ] Step 1: MacBridgeに `sendStreamingText(_ text: String)` 追加。メッセージtype: `"streaming_text"` (小: 30分)
- [ ] Step 2: RecordingManagerのApple Speech recognitionTask内で、partialResult発生時にMacBridgeへストリーミング送信 (小: 30分)
- [ ] Step 3: Mac側 IPhoneBridge/PhoneBridge で `streaming_text` を受信し、AutoTyper.typeStreaming() で前回分をBackSpaceで消して上書き (中: 1時間)
- [ ] Step 4: Whisper使用時は、録音中に定期的(2秒間隔)にpcmSamplesの途中結果をWhisperContextで認識してストリーミング送信 (中: 1.5時間)

**リスク**: Whisperの途中認識は重い(GPU占有)。Apple Speechのストリーミングで十分かもしれない。
**テスト**: iPhoneで話しながらMacのテキストエディタにリアルタイムで文字が現れることを確認。

---

#### Feature 5: 同時翻訳入力 (日本語→英語)
**概要**: iPhoneに日本語で話すと、Macには英語テキストが入力される。

**現状**: ConversationViewで翻訳は実装済み(whisper translate=true)。RecordingManagerのLLM後処理に"translate"モードあり。MacBridgeにsendAudioForTranscription(translate: true)もある。

**実装**:
- [ ] Step 1: SettingsViewに「同時翻訳モード」トグル追加。ON時の翻訳先言語選択 (小: 30分)
- [ ] Step 2: RecordingManager.publishHandoff()で、翻訳モードON時にwhisper translate=trueで再認識してから送信 (中: 1時間)
- [ ] Step 3: 代替パス: LLM翻訳モード使用時はchatweb.ai APIで翻訳してから送信 (小: 30分)
- [ ] Step 4: ContentViewに翻訳モードインジケータ表示(言語ペア + アイコン) (小: 30分)

**テスト**: 日本語で話してMac上のSlackに英語テキストが入力されることを確認。

---

#### Feature 7: 音声コマンド (改行/送信/取り消し/全選択)
**概要**: 認識テキスト内のキーワードを検出してMacにキーイベントとして送信。

**現状**: Mac側にVoiceCommands.swift(改行/段落/句読点/編集コマンド)が完全実装済み。iOS側にはない。Mac側AutoTyperにpostReturn/postUndo/postSelectAllDeleteあり。

**実装**:
- [ ] Step 1: MacBridgeに `sendCommand(_ command: String)` 追加。メッセージtype: `"command"`, command: `"return"/"undo"/"selectAllDelete"/"tab"` (小: 30分)
- [ ] Step 2: Mac側 IPhoneBridgeで `"command"` メッセージを受信し、AutoTyperの対応メソッドを呼び出す (小: 30分)
- [ ] Step 3: RecordingManager.publishHandoff()の前に、VoiceCommandsのeditCommand検出を追加。検出したらテキスト送信せずcommandを送信 (中: 1時間)
- [ ] Step 4: VoiceCommands.swiftをiOSターゲットにもコピーまたは共有(SPM化は過剰、コピーで十分) (小: 15分)
- [ ] Step 5: 「送信」コマンド追加 -- sendCommand("return")でEnterキー送信 (小: 15分)

**テスト**: 「こんにちは改行お元気ですか送信」と話して、Macで2行入力後にEnterが押されることを確認。

---

### Phase 2: プラットフォーム統合

#### Feature 2: Dynamic Island / Live Activity
**概要**: 録音中にDynamic Islandにリアルタイム表示。

**現状**: KoeRecordingAttributes定義済み、KoeWidgetにActivityConfiguration実装済み(DynamicIsland UI完成)。RecordingManagerからActivityKitを呼んでいない。

**実装**:
- [ ] Step 1: RecordingManager.startRecording()でLive Activity開始 -- `Activity<KoeRecordingAttributes>.request()` (小: 30分)
- [ ] Step 2: RecordingManagerの録音中タイマーで定期的にContentState更新(statusText, audioLevel) (小: 30分)
- [ ] Step 3: RecordingManager.stopRecording()でLive Activity終了 -- `activity.end()` (小: 15分)
- [ ] Step 4: Dynamic Islandタップでアプリに戻るdeeplink対応 (小: 15分)

**注意**: ActivityKit import + `NSSupportsLiveActivities = YES` をInfo.plistに追加必要。
**テスト**: 録音開始→Dynamic Islandに赤マイク+タイマー表示、録音停止→消える。

---

#### Feature 3: ホーム画面ウィジェット
**概要**: ワンタップで録音開始するウィジェット。

**現状**: KoeWidget/KoeWidget.swiftに完全実装済み。KoeLaunchWidget(StaticConfiguration) + KoeRecordingActivityWidget(ActivityConfiguration)。`koe://transcribe` URLスキームでアプリ起動。

**実装**:
- [ ] Step 1: KoeApp.swiftにonOpenURL処理追加 -- `koe://transcribe`で自動録音開始 (小: 30分)
- [ ] Step 2: project.ymlにKoeWidgetターゲット追加(app-extension, WidgetKit依存) (中: 1時間)
- [ ] Step 3: App Groupsでメインアプリ<->Widget間のデータ共有(録音状態等) (中: 1時間)
- [ ] Step 4: ウィジェットに最新の認識結果を表示するアクセサリーバリエーション追加 (小: 30分)

**テスト**: ホーム画面にウィジェットを追加し、タップでアプリが開いて録音が始まることを確認。

---

#### Feature 4: Apple Watch コンパニオンアプリ
**概要**: Apple Watchから録音開始、テキストをiPhoneに転送→Macへ。

**現状**: Apple Watch対応なし。WatchConnectivity未使用。

**実装**:
- [ ] Step 1: `KoeWatch` WatchKit App target作成 (project.ymlまたはxcodeproj) (中: 1時間)
- [ ] Step 2: Watch側UI -- 録音ボタン + 認識結果表示 (SwiftUI) (中: 1.5時間)
- [ ] Step 3: Watch側 Apple Speech認識 (WatchOS版SFSpeechRecognizer) (中: 1時間)
- [ ] Step 4: WatchConnectivityでiPhone側に認識テキスト送信 (中: 1時間)
- [ ] Step 5: iPhone側 WCSession delegate -- 受信テキストをMacBridge経由でMacに転送 (小: 30分)
- [ ] Step 6: Watch側 complication (WidgetKit) -- ワンタップ起動 (小: 30分)

**リスク**: WatchOS版whisper.cppは現実的でない(メモリ/GPU制約)。Apple Speech APIのみ使用。
**テスト**: Apple Watchでボタンタップ→録音→認識→テキストがMacに表示。

---

### Phase 3: インテリジェンス

#### Feature 6: Macアプリ認識 (アクティブアプリでLLMモード自動切替)
**概要**: Macで使用中のアプリ(Slack/Mail/Xcode等)に応じて、LLM後処理モードを自動切替。

**現状**: Mac側ContextCollector.swiftにappHint()でバンドルID→ヒントワード変換あり。iOS側はMacBridge経由でテキスト送信のみ、Mac側のアクティブアプリ情報はiOSに来ていない。

**実装**:
- [ ] Step 1: Mac側 IPhoneBridge -- 接続時/アプリ切替時に `{"type": "active_app", "bundleID": "...", "name": "..."}` を送信 (小: 30分)
- [ ] Step 2: MacBridge (iOS側) -- `active_app` メッセージ受信で `@Published var activeAppBundleID/activeAppName` を更新 (小: 30分)
- [ ] Step 3: RecordingManagerのLLM後処理で、activeAppBundleIDに応じてinstruction自動切替 (中: 1時間)
  - Slack/Discord → チャットモード
  - Mail/Outlook → メールモード
  - Xcode/VSCode → コードコメントモード
  - 不明 → デフォルト(修正)
- [ ] Step 4: ContentViewにアクティブアプリ名表示(接続中のみ) (小: 15分)
- [ ] Step 5: SettingsViewにアプリ別モードのカスタマイズUI (中: 1時間)

**テスト**: MacでSlackを開いた状態でiPhoneから音声入力→チャットモードで処理されることを確認。

---

#### Feature 8: 議事録モード (話者分離 + 要約 + アクションアイテム)
**概要**: 長時間の会議を録音し、話者分離・要約・アクションアイテム抽出を行う。

**現状**: Mac側MeetingMode.swiftに完全実装(話者分離+LLM整形+SRT/VTT出力)。iOS側にはない。SoundMemoryに30秒セグメント録音+Whisper文字起こしの基盤あり。

**実装**:
- [ ] Step 1: `MeetingManager.swift` (iOS版) -- SoundMemoryのセグメント録音パターンを流用 (中: 1.5時間)
  - 30秒ごとにWhisper文字起こし
  - タイムスタンプ付きエントリ蓄積
  - rawEntries配列に保存
- [ ] Step 2: 録音終了時にchatweb.ai APIで要約+アクションアイテム抽出 (中: 1時間)
  - システムプロンプト: 議事録整形+要約+アクション抽出
  - 出力: Markdownフォーマット
- [ ] Step 3: `MeetingView.swift` -- 議事録UI (大: 2時間)
  - リアルタイムエントリ表示(ScrollView + LazyVStack)
  - タイムスタンプラベル
  - 録音/停止ボタン
  - 完了後: 要約+アクションアイテム表示
- [ ] Step 4: 共有機能 -- テキスト/Markdown/PDF出力 (小: 30分)
- [ ] Step 5: SettingsViewに議事録セクション追加 (小: 15分)

**テスト**: 30分の模擬会議を録音し、話者別発言・要約・TODOリストが生成されることを確認。

---

#### Feature 9: 音声メモ検索 (過去の録音をテキスト検索)
**概要**: SoundMemoryの録音セグメントをテキスト検索で発見・再生。

**現状**: SoundMemoryに`search(query:)` メソッド既存(localizedCaseInsensitiveContains)。SoundMemoryView.swiftにUIあり。

**実装**:
- [ ] Step 1: SoundMemoryViewの検索UIを改善 -- 検索バー常時表示 + リアルタイムフィルタリング (小: 30分)
- [ ] Step 2: 検索結果にコンテキストハイライト表示(マッチ部分を太字) (小: 30分)
- [ ] Step 3: 検索結果タップで該当セグメントの音声再生(AVAudioPlayer) (中: 1時間)
- [ ] Step 4: 日付フィルター追加(今日/昨日/今週/カスタム) (小: 30分)
- [ ] Step 5: Spotlight連携 -- CSSearchableIndex にセグメントを登録 (中: 1時間)

**テスト**: SoundMemory有効化→数分録音→検索バーにキーワード入力→該当セグメント表示→タップで再生。

---

## 実装順序とスケジュール

| 順番 | Feature | 推定工数 | 依存関係 | 理由 |
|------|---------|---------|---------|------|
| 1 | F2: Dynamic Island | 1.5h | なし | UI定義済み、Activity開始/終了を繋ぐだけ |
| 2 | F3: ウィジェット | 3h | なし | 実装済み、ビルドターゲット追加 + URL scheme |
| 3 | F7: 音声コマンド | 2.5h | なし | VoiceCommands.swiftコピー + MacBridgeプロトコル拡張 |
| 4 | F1: ストリーミング送信 | 3.5h | なし | MacBridge + Apple Speech partial results |
| 5 | F5: 同時翻訳 | 2.5h | F1(ストリーミング基盤) | whisper translate + LLM翻訳 |
| 6 | F9: 音声メモ検索 | 3.5h | なし | SoundMemory既存、UI改善のみ |
| 7 | F6: アプリ認識 | 3h | なし | Mac<->iOS双方向通信拡張 |
| 8 | F8: 議事録モード | 5h | F9(SoundMemoryパターン) | Mac版MeetingMode移植 |
| 9 | F4: Apple Watch | 5.5h | F1(テキスト転送) | 新ターゲット、WatchConnectivity |

**合計推定工数**: 約30時間

## テスト方針
- [ ] 各Feature単位でビルド確認 (`xcodebuild -scheme Koe -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`)
- [ ] Mac連携Features (F1/F5/F6/F7): Mac側Koeアプリを起動してMacBridge接続テスト
- [ ] Dynamic Island (F2): iPhone実機でLive Activity表示確認
- [ ] ウィジェット (F3): シミュレータでウィジェットギャラリーから追加
- [ ] Apple Watch (F4): watchOSシミュレータでペアリングテスト

## リスク
- **Whisperストリーミング認識 (F1)**: whisper.cppは全バッファ一括認識のため、録音途中での逐次認識はGPU負荷が高い。Apple Speechのストリーミングで代替し、最終結果のみWhisperを使うハイブリッド方式が現実的。
- **Apple Watch Whisper (F4)**: WatchOSでwhisper.cppは非現実的。Apple Speech APIのみで実装し、高精度が必要な場合はiPhone経由でWhisper認識を依頼する。
- **議事録の話者分離 (F8)**: Mac版はWhisperContext.transcribeWithSpeakersを使用しているが、iOS版WhisperContextにはこのメソッドがない。tinydiarizeの移植かギャップベースフォールバックが必要。
- **KoeWidget target (F3)**: project.ymlに未定義のため、XcodeGen対応かxcodeproj直接編集が必要。

## 完了条件
- 9機能すべてが実装され、ビルドエラーゼロ
- Mac連携機能はMac側Koeアプリとの動作確認完了
- Dynamic Island / ウィジェットは実機で表示確認
- 既存機能(録音/認識/翻訳/Soluna/Sound Memory)が破壊されていない
