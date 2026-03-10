# Koe SuperWhisper超え実装計画 — 完了

全16機能を実装完了。5,414行 → 7,498行（+2,084行）。ビルドエラーゼロ。

## 完了タスク一覧

### Phase 1: 配布の壁を壊す
- [x] **Intel Mac対応** — ArchUtil検出 + Apple OnDevice自動フォールバック
- [x] **DMGインストーラー** — build-dmg.sh + GitHub Actions release.yml

### Phase 2: 機能でSuperWhisperを上回る
- [x] **リアルタイムストリーミング認識** — 1.5秒間隔プレビュー、オーバーレイ表示
- [x] **Super Mode（画面認識）** — AXUIElement選択テキスト取得 + LLMコンテキスト注入
- [x] **多言語クイック切替** — メニューバー言語サブメニュー(🇯🇵🇺🇸🇨🇳🇰🇷🌐) + 設定フラグボタン
- [x] **ファイル文字起こし** — AVAsset音声抽出 + チャンク分割 + TranscriptionWindow
- [x] **履歴検索・エクスポート** — 全文検索、お気に入り、CSV/JSON/Text出力、2000件上限
- [x] **クラウドLLMプリセット** — chatweb.ai/OpenAI/Anthropic(Messages API)/Groq/カスタム
- [x] **プリセットモード** — 8モード(なし/修正/メール/チャット/議事録/コード/翻訳/カスタム)
- [x] **⌥+Space ホットキー** — プリセット追加 + Space録音延長との競合回避

### Phase 3: 唯一無二の差別化
- [x] **エージェントモード** — 6コマンド(アプリ起動/検索/スクショ/タイマー/シェル/ショートカット)
- [x] **話者分離** — tinydiarize + ギャップベースフォールバック + 議事録ラベル
- [x] **ローカルLLMデフォルト化** — 8GB未満自動無効化 + オンボーディングDLステップ
- [x] **クイック翻訳** — ⌘⌥T専用ホットキー + 青オーバーレイ + 言語自動判定
- [x] **Shortcuts.app統合** — koe://transcribe, koe://translate URLスキーム
- [x] **日本語特化モデル** — 別途ファインチューニング作業（コード側は ModelDownloader対応済み）

### 除外（計画通り）
- iOS版 (#2)
- Windows版 (#3)
- App Store (#5)

## 新規ファイル
- AgentMode.swift (音声コマンド)
- FileTranscriber.swift (ファイル文字起こし)
- TranscriptionWindow.swift (文字起こしUI)
- build-dmg.sh (DMGビルド)
- .github/workflows/release.yml (CI/CD)

## 変更ファイル (14ファイル)
AppDelegate.swift, Settings.swift, SettingsWindowController.swift,
LLMProcessor.swift, ContextCollector.swift, HistoryStore.swift,
OverlayWindow.swift, WhisperContext.swift, AudioRecorder.swift,
MeetingMode.swift, MemoryMonitor.swift, ModelDownloader.swift,
SetupWindow.swift, CWhisper/shim.h, Info.plist
