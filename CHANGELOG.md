# Changelog

このプロジェクトでは [Keep a Changelog](https://keepachangelog.com/) 形式に概ね沿いつつ、
リリースは GitHub Releases にも記録します。

## [2.11.0] — 2026-06-12 録音時間無制限 + データを絶対に失わない

### Added (macOS)

- **クラッシュ復旧 (CrashRecovery)** — 強制終了・クラッシュで中断した録音 (`rec_*.wav`) と
  認識途中テキストを次回起動時に自動回収。履歴に `[復旧]` エントリとして登録し、
  whisper でバックグラウンド再認識して実テキストに更新 (途中テキストは originalText に保持)
- **認識途中結果の逐次永続化 (PartialTranscriptStore)** — Apple Speech ストリーミングの
  途中結果をセッション毎ファイルへ 0.5 秒間隔で atomic 書込。強制終了しても直前までの認識が残る
- **履歴アーカイブ** — 履歴 2000 件の上限超過分は削除せず `history_archive.jsonl` へ追記退避
- **常時録音モード (opt-in)** — メニュー「入力モード → ⏺ 常時録音」。ホットキーを押した時以外も
  マイク音声をバックグラウンドで録音し続け、10分チャンクで音声アーカイブへ保存。完全ローカル・
  文字入力なし。終了時は現在チャンクを確定保存、クラッシュ時も次回起動で回収 (本人指示)

### Changed (macOS)

- **録音時間の上限 (5分) を撤廃** — 録音時間は無制限に。whisper.cpp は内部 30 秒分割のため長尺も認識可能
- **Apple Speech ストリーミングのセグメント自動再開** — OS 側の約1分制限をセグメント結合で突破し、
  リアルタイムプレビューも録音時間無制限に追従
- **録音先を tmp → Application Support へ移動** — OS の tmp パージ・再起動で録音が消えない。
  停止時のファイル移動は copy → rename (巨大 WAV でも瞬時)
- **ストリーミングプレビューの差分読み** — 全ファイル再読込 (O(録音長)) を FileHandle 差分読みに。
  長時間録音でも CPU コスト一定
- **認識タイムアウトを録音長に比例** (最低60秒、録音長×1.5)。HTTP 認識系 (NOU/OpenAI/ローカルサーバー)
  のタイムアウトも音声長スケールに
- **history.json の保存を堅牢化** — atomic 書込・認識結果は即時保存 (3秒デバウンス廃止)・
  破損時は `history.json.corrupt-*` にバックアップしてから空で開始 (silent data loss 根絶)
- **音声アーカイブの opt-in 後の既定値** — 日数 prune 無効 (無期限保持)・サイズ上限 50GB
  (opt-in が必要な点は従来どおり)
- **認識スピード改善: 投機実行の修復** — 録音中 WAV (ヘッダー未確定) を AVAudioFile が読めず
  投機認識が全敗していた問題を生 PCM パースのフォールバックで根治。話し終わりの無音 0.1 秒で
  先行認識が始まり、停止後はキャッシュ命中で即結果が出る。長尺 (>15分) は投機をスキップ
- **ストリーミングプレビューは常に on-device 認識のみ** — `requiresOnDeviceRecognition` を必須化。
  非対応環境ではプレビュー自体を無効化し、音声がこの Mac から出ない (最終認識はローカル whisper)
- **終了時に録音中ファイルを削除しない** — `applicationWillTerminate` が `cancel()` (ファイル削除) を
  呼んでいたのを `shutdown()` (停止+保全) に変更。録音中に終了しても次回起動で復旧される

### Removed (macOS)

- **設定のプリセット (Persona) バー** — 設定画面上部のビジネス/エンジニア/クリエイター/学生/多言語
  プリセットと詳細シートを削除 (本人指示)

## [Unreleased] — feat/macos-recording-suite

macOS app に 5 新機能 + 5 ラウンドのペルソナ駆動 UX 改修。詳細は PR #13。

### Added (macOS)

- **マイク入力デバイス選択** — システムデフォルトに加え、USB I/F・外部マイクを直接指定可能 (Voice tab)
- **録音中音量 auto-duck** — OFF / 手動 / 自動 (出力 vol > 0 のときだけ) の 3 mode
- **音声アーカイブ (consent + auto-prune)** — 明示的 opt-in、機密度警告 modal、GB/日数 上限、auto-prune
- **完全オフラインモード (Toggle)** — Settings から 1 click で全 cloud 通信 block。Slack/Notion/AutoUpdater/cloud LLM/CloudWakeTrainer/VLM/screen context 全 gate。menu に 🔒 badge 表示
- **Fn キー対応** — CGEventTap 経由で Fn 単独タップ (toggle) or 押している間 (push-to-talk)、Fn+letter 組合せも可
- **技術用語辞書** — `あしんく あう` → `async/await` 等の音声誤認識を post-process で復元。`~30` 項目 pre-seed + ユーザー編集可
- **OverlayWindow 拡張** — ⌥ 押下中だけドラッグで位置移動 (永続化)、配信用 large text mode (waveform 非表示 + 22pt bold)
- **クリッピング警告** — peak > 0.95 で「音量が歪んでいます」hint 表示
- **ホットキー衝突事前警告** — 起動時にフォアグラウンド app (Ghostty/iTerm/Discord/etc.) との衝突を検出して NSAlert

### Changed (macOS)

- **Privacy 既定値強化**: Offline Mode default `false` → **`true`**、ducking mode default `"manual"` → **`"off"`** (P2/P3 critical 対応)
- **AudioArchive consent modal**: 「容量が増える」だけだった警告を機密度 (取材源/社外秘/個人情報) + Time Machine/iCloud/Dropbox 巻き込み + 平文 WAV であることへの言及まで強化
- **Settings UI 刷新**: 隠れた `>>` Navigation Tab Bar popup を廃止し、6 タブを常時表示の水平タブストリップに置換。同じラベル/アイコン/順番、UI のみ刷新
- **VoiceOver アクセシビリティ**: PersonaBar 5 preset buttons、AudioArchive 操作 buttons、ducking mode picker に `accessibilityLabel` / `accessibilityHint` / `accessibilityValue` 付与

### Fixed (macOS)

- **AudioRecorder mic device prepare-order バグ**: `applySelectedInputDevice()` が `prepare()` 後に呼ばれていたため AVAudioRecorder が旧デバイスにバインドされていた問題を修正
- **Carbon hotkey 登録失敗が UI に出ない**: 5 つの `RegisterEventHotKey` 結果を集約して NSAlert で通知、Settings 起動導線付き
- **Fn キーモード説明不足**: Settings で `tap_toggle` / `hold_ptt` の動作詳細を 2-3 行解説 + ヒント表示

### Build / CI

- **arm64 + x86_64-only-brew 環境対応**: `build.sh` / `Tests/run_tests.sh` に `/tmp/whisper.cpp/build` + `/tmp/llama.cpp/build` の source-build fallback を追加。詳細は `docs/build-arm64.md`

### Docs

- `docs/personas.md` — 5 ペルソナ定義 (Mac dev / PdM / writer / SRE 腱鞘炎 / 配信講師)
- `docs/personas-feedback-loop.md` — 5 ラウンドのフィードバック・改修・最終承認 (全員 😊 完璧判定、平均 9.26/10)
- `docs/build-arm64.md` — arm64 + x86_64-brew 環境ビルド手順

### Tests

- `Tests/run_tests.sh` host runner: **38 passed, 0 failed**

### Hamada-san タスク (リリース時)

1. PR #13 を review + merge
2. `git checkout master && git pull`
3. **`bash release.sh`** — これで version bump + PKG/DMG ビルド + Developer ID 署名 + Apple Notarization + git tag/push + GitHub Release 全自動

それ以外の運用タスクはすべてこの PR に同梱済み。
