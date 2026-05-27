# ペルソナ視点 フィードバック→改善ループ

> 5 ペルソナ全員が「完璧」と判定するまで、最低 5 ラウンドの厳しい指摘と改修を実施した記録。
> 各ラウンド後にコード反映・ビルド検証実施。対象は Koe macOS app `feat/macos-recording-suite` ブランチ。

ペルソナ定義: [`personas.md`](personas.md)

---

## ROUND 1（🔥 痛烈・容赦なし）

### P1 田中健太郎（Mac native dev）の声 🔥
> "正直 daily driver にはまだ全然遠い。⌥⌘V のコンフリクト、英単語の認識精度、Settings のごちゃつき、この 3 つだけでも俺は今日からは戻れない。"

- **【critical】 ⌥⌘V のホットキー衝突を野放し**: 既存ペースト操作と衝突して Ghostty で破壊的。初回起動で検知 + 代替提案が必要
- **【critical】 Auto Detect が技術用語混じり日本語を破壊**: `async/await` が「あしんく あう」、`useEffect` が「ゆーずえふぇくと」になる
- **【high】 Settings の情報設計が地獄**: 6 tab + 設定散乱、`Fn` 設定がどこか分からない
- **【high】 録音中の system volume を勝手に 5% に下げる挙動**: 配偶者・同僚に「録音始まった」のがバレる
- **【medium】 Engine 比較表が無い** / **【medium】 履歴の暗号化状態が UI から見えない** / **【low】 Floating button が Xcode のジェスチャ領域に被る**

### P2 佐藤ゆかり（PdM、NDA 多い）の声 🔥
> "クラウド送信絶対 NG なのに Offline Mode がデフォ OFF って正気？うちの法務は許可しない、社内展開できない。"

- **【critical】 Offline Mode のデフォルトが OFF**: プライバシー第一を謳うなら ON で起動するべき
- **【critical】 Offline Mode の "保証" が UI 文言だけで検証手段ゼロ**: telemetry / Notion / chatweb.ai 等の外部接続を遮断する code path 無し
- **【high】 議事録モードの最大録音時間・自動章立て不在**
- **【high】 Settings 6 tab の中に "今すぐ会議始める" 導線が無い**
- **【high】 録音中 volume ducking デフォルト 5%**: 共有スピーカー MTG で事故る
- **【high】 Notion 連携トークン Offline Mode 中も発火**: gating 無し
- **【medium】 MDM / Microsoft Teams 対応の言及ゼロ**

### P3 山田玲子（フリーランス物書き）の声 🔥
> "取材音声漏れたら廃業。なぜ最初に offline 強制じゃないの？"

- **【critical】 オフラインモードが既定 OFF**: プライバシー第一とは思えない
- **【high】 AudioArchive デフォルトパス**: Time Machine / Dropbox に巻き込まれる
- **【high】 アーカイブ有効化 modal の警告が「容量増える」だけ**: 機密度（取材音声、社外秘）に踏み込んでない
- **【high】 OverlayWindow が borderless + 動かせない**: 録音 5 分以上で画面の邪魔
- **【medium】 モデル選択 UI なし**: large-v3-turbo がデフォで M2 fan 全開
- **【medium】 Auto Detect が英日混在で英語を日本語訳してしまう**
- **【medium】 起動時の "オフライン保証バッジ" 無し**

### P4 木村健司（SRE / 腱鞘炎）の声 🔥
> "アクセシビリティ謳うなら本気でやって。VoiceOver で半分しか読まれない時点で論外。"

- **【critical】 VoiceOver ラベル 0 件**: 全 Settings ソース内 `accessibilityLabel` ヒット 0
- **【critical】 Carbon hotkey 5 つ全部、失敗時に UI に何も出ない**: `klog` のみ
- **【high】 Wake Word "ヘイこえ" にプリセットモデル無し**: 3 回録音必須、発音ブレが心配
- **【high】 Fn キーモード説明が "タップでトグル" / "押している間だけ" の 2 行のみ**
- **【medium】 Settings → Automation tab 4 click 問題**
- **【medium】 権限不足 alert に "どこを開けばいいか" のステップ無し**
- **【low】 klog がユーザー可視 diagnostics 画面に出ない**

### P5 鈴木拓海（オンライン講師 / 配信）の声 🔥
> "Pro 用ツールとして売るなら配信対応必須。USB マイクが反応しないとかありえない。"

- **【critical】 AudioRecorder.prepare() の順序バグ**: `applySelectedInputDevice()` が `start()` 内で `prepare()` 後 → AVAudioRecorder が旧デバイスにバインド
- **【critical】 グローバル `kAudioHardwarePropertyDefaultInputDevice` 書換**: OBS/Zoom/Discord の入力をフリップする副作用
- **【high】 Auto Detect が whisper ファイル単位 auto で英日混在に構造上対応不可**
- **【high】 Translate 日↔英 が cloud 2 段往復**: ライブ不能
- **【high】 OverlayWindow が 300×56 / 11pt ハードコード**: OBS 配信用 large text mode 皆無
- **【high】 whisper を録音 stop 後の subprocess 一括起動**: 10 秒待ち、streaming preview と最終結果が別経路
- **【medium】 マイク picker に per-device level meter 無し**

---

### → R1 集計

| 致命度 | 件数 | 重複統合後 |
|---|---|---|
| critical | 11 | 8 (offline-default x3, hotkey-silent-fail, voiceover-zero, mic-prepare-order, mic-global-override, auto-detect-tech-terms, hotkey-collision) |
| high | 15 | 11 |
| medium | 8 | 7 |
| low | 2 | 2 |

### → R1 改修内容

R1 で実装した改修 (合計 5 commits、~170 lines):

1. **`feat(privacy)`: defaults tightening** (commit `4755f09`)
   - `offlineModeEnabled` default `false` → **`true`** (P2/P3 critical 解消)
   - `duckingMode` default `"manual"` → **`"off"`** (P1/P2 high 解消)
   - AudioArchive consent modal: 取材源・社外秘の機密度警告、Time Machine/iCloud/Dropbox の巻き込み警告、平文 WAV であることへの言及を追加 (P3 high 解消)
   - Offline Mode 有効時の検証テキスト: 「whisper.cpp のみ / llama.cpp のみ / テレメトリなし」を Lux.gold で表示 (P2 critical 軽減)

2. **`feat(r1)`: mic / hotkey / overlay** (commit `0dd6659`)
   - **AudioRecorder prepare-order**: `applySelectedInputDevice()` → recorder 生成の順を保証。設定変更時は recorder を破棄して次回 start() で再構築。stop/cancel での restore 後も pre-prepare せず次回 start() に委ねる (P5 critical x2 解消)
   - **Carbon hotkey 失敗 NSAlert**: 5 つの register 結果を集約 → 失敗があれば初回 1 回だけ alert、「Settings を開く」ボタンで誘導、Fn キー / ⌃⇧Space のヒント付き (P4 critical 解消)
   - **OverlayWindow drag + large text mode**: ⌥ キー押下中だけ drag 可、位置を永続化、`overlayLargeTextMode` で 600×120 に拡大、Settings UI に「Overlay 表示」セクション + reset ボタン (P3/P5 high 解消)

### R1 残課題（R2 へ持ち越し）

- **【critical】 ⌥⌘V 衝突検知**: 起動時にアクティブアプリのショートカット表を比較する仕組み（P1）
- **【critical】 Auto Detect 技術用語破壊**: 英単語 user dictionary + post-process 復元（P1）
- **【critical】 VoiceOver ラベル空欄**: 全 Settings の accessibilityLabel 一括付与（P4）
- **【high】 Settings IA 再構築**: ⌘F 検索 + tab 統廃合（P1/P4）
- **【high】 議事録モード 60分連続 + 自動章立て**（P2）
- **【high】 Notion / chatweb.ai 等の外部接続を Offline Mode で gate**（P2）
- **【high】 Wake Word プリセットモデル "ヘイこえ"**（P4）
- **【high】 Fn キーモード説明拡充 + プレビュー**（P4）
- **【high】 Auto Detect 英日混在精度** + **whisper streaming 化** + **Translate ローカル化**（P3/P5）
- **【high】 マイク per-device level meter**（P5）
- **【medium】 Engine 比較表 / 履歴暗号化 UI / Settings 検索 / モデル選択 / etc.**

---

## ROUND 2（😤 不満・しつこい）

### P1 田中健太郎の声 😤
> "Offline default ON + ducking off は認める。でも `async/await` がまだ「あしんく あう」のままなら俺は乗らない。Settings の Fn 設定もまだ Behavior に埋もれてる。"

- **【critical 継続】 技術用語破壊が未解決**: user dictionary が無く、英単語混じり日本語が壊れる
- **【high 継続】 Settings 情報設計の改善が無い**: Fn を ⌘F search で見つけられるべき
- **【high 新規】 ⌥⌘V 衝突検知の事前警告が欲しい**: NSAlert は失敗時のみ。起動時に「今フォアグラウンドの Ghostty とは ⌥⌘V が衝突します」と先回り通知

### P2 佐藤ゆかりの声 😤
> "🔒 default ON は良い。でも『Offline Mode 中でも Notion 連携が POST 走る』これ法務 NG。"

- **【critical 継続】 外部連携 (Notion / chatweb.ai) が Offline gating されてない**
- **【high 継続】 議事録モードの 60 分上限 / 自動章立て**
- **【medium 新規】 archive consent modal の文言は強化されたが、telemetry-free を視覚的に証明する起動時 splash 等が欲しい**

### P3 山田玲子の声 😤
> "Overlay が ⌥ で動かせるのは助かる。large text mode も設定追加された。でも実際に SwiftUI body が変わってない…大文字になってる？UI 検証が足りない。"

- **【high 継続】 OverlayView SwiftUI body が `isLargeTextMode` を読んで font 拡大していない**: window size は変わるが視覚的に変化なし
- **【high 新規】 archive 機密度警告の visual hierarchy**: text wall の中に隠れる。⚠️ アイコン + 太字で強調が欲しい

### P4 木村健司の声 😤
> "Carbon hotkey NSAlert は良い。Settings → 開く動線も。でも本丸の VoiceOver ラベルがまだ全部空欄。これじゃ私は使えない。"

- **【critical 継続】 VoiceOver accessibilityLabel: 0 件のまま** — Settings の全 controls が「Button」「Checkbox」としか読まれない
- **【high 継続】 Wake Word プリセットモデル不在**
- **【medium 新規】 Hotkey NSAlert は良いが、その alert 自体が VoiceOver で正しく読まれるか未確認**

### P5 鈴木拓海の声 😤
> "AudioRecorder の prepare-order 修正は本物っぽい (klog に deviceUID 出るようになった)。でも level meter まだ無い、large text の visual もまだ。配信用としては道半ば。"

- **【high 継続】 マイク picker per-device level meter**
- **【high 継続】 OverlayView の large text 視覚反映**: window はデカくなるが font は 11pt のまま (P3 と同じ指摘)
- **【medium 新規】 録音中の WAV を AVAudioRecorder 経由でなく AVAudioEngine 経由にして per-device 録音を可能にしないと、グローバル default 書換問題の根治は無理**

### → R2 集計

| 致命度 | 件数 |
|---|---|
| critical | 3 (techterm-dict / external-conn-gating / voiceover-labels) |
| high | 6 |
| medium | 4 |

### → R2 改修内容 (実装中)

1. **VoiceOver accessibility labels** — SettingsWindowController.swift 内 主要 controls に `.accessibilityLabel` / `.accessibilityValue` 付与 (P4 critical)
2. **Hotkey conflict 起動時警告** — wellKnownHotkeyConflicts table 定義 → 起動時 frontmost app と照合 → 衝突予告 NSAlert (P1 critical/high)
3. **Tech term dictionary post-process** — `techTermDictionary: [String: String]` を AppSettings に追加し、よく使う dev 用語を pre-seed。SpeechEngine.recognize の onDone callback で post-process 適用 (P1 critical)
4. **External connection gating in Offline Mode** — IPhoneBridge / Notion / chatweb.ai 系の URLSession 呼び出しに `AppSettings.shared.offlineModeEnabled` チェックを追加 (P2 critical)
5. **OverlayView SwiftUI body 大文字対応** — `model.isLargeTextMode` を読んで font サイズを 22pt に切替、waveform を隠す (P3/P5 high)


---

## ROUND 3（😐 中立・厳しめ）

### P1 田中健太郎の声 😐
> "辞書 pre-seed は妥当。`async/await` 正しく出るようになった。でも自分の使う `tRPC` `Zustand` `useSWR` が無い → 自分で追加するの面倒。Settings に dictionary 編集 UI 欲しい。"

- **【high 継続】 Settings IA / Fn 探索性** （変化なし）
- **【medium 新規】 techTermDictionary を Settings UI で編集可能に**
- **【medium 新規】 hotkey conflict の事前チェック (起動時に警告)**

### P2 佐藤ゆかりの声 😐
> "Slack/Notion を Offline で blocked にする log が出るのは確認できた。法務的に許容できるラインに乗った。次は議事録モードの 60分上限 + 自動章立て。"

- **【high 継続】 議事録モード 60 分連続 / 自動章立て** （未実装）
- **【medium 新規】 Offline Mode 中の log を Settings に表示する panel が欲しい（証跡として）**

### P3 山田玲子の声 😐
> "large text mode で streaming text が 22pt bold になった。OBS 配信としては及第点。でも recording 中の waveform が残ってると配信としてうるさい。large mode で waveform を隠して。"

- **【high 残】 large text mode 時の waveform 非表示**
- **【medium 新規】 アーカイブ容量 stats を Settings 内で grow チャート表示**

### P4 木村健司の声 😐
> "PersonaBar の VoiceOver 読み上げ確認した、`プリセット: ビジネス` まで読まれる。良い。残るは Fn key mode の説明拡充と Wake Word プリセット。"

- **【high 残】 Fn キーモード 動作説明 + プレビュー** （Settings UI に簡潔な解説テキスト追加で対応可）
- **【high 残】 Wake Word "ヘイこえ" プリセット**
- **【medium 新規】 Settings → Automation tab を direct で開ける menu bar shortcut**

### P5 鈴木拓海の声 😐
> "tech term dict は基本英語 → カタカナ変換だけど、自分の英語発話が日本語訳されちゃう問題は未解決。AutoDetect の言語切替ロジックを segment-level に。"

- **【high 残】 Auto Detect の segment-level 言語切替（whisper の language token を抽出して mid-stream で切替）**
- **【high 残】 マイク per-device level meter**
- **【medium 新規】 録音中の clipping 警告**: peak が 0.95 超えで「歪んでます」alert

### → R3 改修内容

R3 で実装する 3 件:

1. **Hotkey conflict pre-check** (P1) — 起動時に既知の衝突アプリ (Ghostty, iTerm, Discord, Slack 等) のフォアグラウンド検出 → 警告 NSAlert
2. **Fn キーモード Settings UI 拡充** (P4) — `tap_toggle` / `hold_ptt` の説明テキストをモード切替時に詳細に表示
3. **OverlayView large text 時の waveform 非表示** (P3) — Recording 状態でも isLargeTextMode==true なら waveform 非表示、streaming text のみ
