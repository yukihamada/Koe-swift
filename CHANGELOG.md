# Changelog

このプロジェクトでは [Keep a Changelog](https://keepachangelog.com/) 形式に概ね沿いつつ、
リリースは GitHub Releases にも記録します。

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
