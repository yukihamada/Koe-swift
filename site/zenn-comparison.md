---
title: "Koe vs SuperWhisper vs Aqua Voice — 音声入力ツール2026年版 徹底比較"
emoji: "🎙️"
type: "tech"
topics: ["whisper", "音声入力", "macos", "ios", "llm"]
published: false
---

# Koe vs SuperWhisper vs Aqua Voice — 音声入力ツール2026年版 徹底比較

音声入力ツール市場が急速に成熟しつつある2026年、主要3プロダクトを**開発者目線**で徹底比較します。

比較対象:
- **[Koe](https://koe.elio.love)** — オープンソース・完全ローカル
- **[SuperWhisper](https://superwhisper.com)** — Mac/iOS/Windows対応の老舗
- **[Aqua Voice](https://aquavoice.com)** — YC出身・独自モデル搭載

---

## TL;DR

| 項目 | Koe | SuperWhisper | Aqua Voice |
|------|-----|-------------|-----------|
| **価格** | 🟢 無料・MIT | 🟡 $8.49/月 or 買い切り | 🔴 $8-10/月 |
| **Mac** | ✅ | ✅ | ✅ |
| **iOS** | ✅ | ✅ | ✅ (2026/3〜) |
| **Windows** | ✅ (Rust) | ✅ (2025/12〜) | ✅ |
| **Android** | ❌ | ❌ | ✅ (2026/3〜) |
| **オフライン** | ✅ 完全 | ✅ 完全 | ✅ 完全 |
| **ローカルLLM** | ✅ llama.cpp内蔵 | ✅ Ollama連携 | ❓ 不明 |
| **ウェイクワード** | ✅ カスタム学習 | ❌ | ❌ |
| **会議モード** | ✅ 話者分離+議事録 | ✅ | ❌ |
| **エージェント機能** | ✅ 音声コマンド実行 | ❌ | ❌ |
| **Mac↔iOS連携** | ✅ MultipeerConnectivity | ❌ | ❌ |
| **Apple Intelligence** | ✅ (macOS 15.1+) | ❌ | ❌ |
| **言語数** | 20言語 | 100言語以上 | 49言語 |
| **ライセンス** | MIT OSS | プロプライエタリ | プロプライエタリ |

**一言まとめ**:
- プライバシー重視 + 無料 + 拡張性 → **Koe**
- 言語の多さ + Ollama連携 + 安定性 → **SuperWhisper**
- Android対応 + 技術用語精度 → **Aqua Voice**

---

## 1. 価格・ライセンス

### Koe
**完全無料・MITライセンス**。GitHubで公開されており、自分でビルドすることも、フォークしてカスタマイズすることも自由。

### SuperWhisper
| プラン | 料金 | 内容 |
|-------|------|------|
| Free | ¥0 | 基本機能、15分トライアル |
| Pro | $8.49/月 | カスタムAIキー、ファイル文字起こし |
| Lifetime | 一括払い | Pro機能を永続利用 |
| Enterprise | カスタム | SOC 2 Type II対応 |

長期利用ならLifetime購入が圧倒的にお得。

### Aqua Voice
| プラン | 料金 | 内容 |
|-------|------|------|
| Starter | ¥0 | 1,000語まで（リセットなし） |
| Pro | $10/月 ($8/月 年払い) | 無制限、カスタム辞書800語 |
| Team | $12/月/人 | 複数ユーザー |

無料プランは実質お試し程度。

**勝者: Koe** — 無料かつオープンソースという選択肢は他にない。

---

## 2. 音声認識エンジン

### Koe
**whisper.cpp** をコアに採用。Metal GPU加速（Apple Silicon）で平均**0.5秒以内**の認識を実現。

対応Whisperモデルが充実:

| モデル | サイズ | 特徴 |
|-------|--------|------|
| Kotoba v2.0 Q5 | 538MB | **日本語最高精度**（推奨） |
| Kotoba v2.0 Full | 1.52GB | さらに高精度 |
| Large V3 Turbo Q5 | 547MB | 多言語標準 |
| Belle 中文 Turbo | 1.62GB | 中国語特化 |
| Korean Medium | 1.5GB | 韓国語特化 |

### SuperWhisper
同じく**whisper.cpp**ベース。100言語以上に対応し、モデルライブラリは業界最大級。

### Aqua Voice
**独自モデル「Avalon」**を採用。YCバッチで開発された技術で、開発者向けワークフロー（CLIセッション、IDEコンテキスト）で学習。

技術用語精度のベンチマーク（AISpeak benchmark）:
- Avalon: **97.3%**
- Whisper Large v3: 〜94%
- ElevenLabs Scribe: 〜94%

**勝者**: 日本語なら**Koe (Kotoba v2)**、技術英語精度なら**Aqua Voice**、多言語なら**SuperWhisper**

---

## 3. ローカルLLM後処理

音声認識後のテキストをLLMで加工する機能。ここがKoeの最大の差別化ポイント。

### Koe — llama.cpp内蔵
外部サーバー不要でアプリ内にLLMエンジンを直接統合。

**対応モデル**:
| モデル | サイズ | メモリ推奨 | 特徴 |
|--------|--------|-----------|------|
| Qwen3 0.6B Q8 | 750MB | 8GB | 最軽量・即応答 |
| Qwen3 1.7B Q4 | 1.28GB | 16GB | バランス型 |
| Gemma2 2B JP | 1.6GB | 16GB | **日本語最適化** |
| Qwen3.5 4B | 2.74GB | 32GB | 高精度 |
| Llama3.1 Swallow 8B | 4.92GB | 32GB+ | **日本語最高精度** |

**後処理モード**:
- 誤字修正 / 句読点追加
- ビジネスメール変換
- カジュアルチャット変換
- 議事録形式（箇条書き）
- コードコメント形式
- 翻訳（日英相互）
- カスタムプロンプト（ユーザー定義）

さらに**アプリ別最適化**が可能。VS Codeなら「コード向け」、ターミナルなら「コマンド向け」と、起動中のアプリによって自動でプロンプトを切り替える。

**メモリ管理**も巧み。使用後3秒でLLMを自動アンロードし、WhisperとLLMが同じメモリプールで効率的に共存する。

**Apple Intelligence対応** (macOS 15.1+): ローカルLLMのさらに上の選択肢として、Appleのオンデバイスモデルも使用可能。

### SuperWhisper — Ollama連携
Ollama経由でLlamaやMistral等のローカルモデルを利用可能。ただしOllamaの別途インストールが必要。

**対応クラウドLLM**:
- OpenAI: GPT-4o, GPT-5
- Anthropic: Claude Haiku 4.5, Sonnet 3.5
- Google: Gemini 3.0 Flash
- Groq: Llama 70b, Mixtral
- Ollama: ローカルモデル全般

### Aqua Voice
LLM後処理の詳細は非公開。内部実装と思われるが、Ollamaやローカルモデルへの対応は確認できない。

**勝者: Koe** — インストール不要でllama.cppが内蔵され、日本語特化モデル含む6モデルをアプリ内で完結できる点が群を抜く。

---

## 4. ウェイクワード

「ヘイ Siri」のような、キーを押さず声だけで録音開始できる機能。

### Koe — 完全カスタム実装
**外部SDKに依存しない独自ウェイクワードエンジン**を実装。ユーザー自身の声でカスタムウェイクワードを学習できる唯一の製品。

技術的な実装:
```
マイク入力
  ↓ 16kHz monoへリサンプリング
  ↓ プリエンファシス (α=0.97)
  ↓ Hannウィンドウ (25ms, 10ms hopsize)
  ↓ FFT → Mel filterbank (26フィルタ)
  ↓ MFCC (13次元)
  ↓ CMVN正規化
  ↓ DTW距離マッチング (Sakoe-Chibaバンド)
  → ウェイクワード検出
```

- 最低3回の発声でテンプレート登録
- 250ms毎にリアルタイム検出
- VADで無音をスキップ（CPU効率化）
- 「エコー」「こえ」「ねえ」など何でも設定可能

### SuperWhisper / Aqua Voice
ウェイクワード非対応。ショートカットキー（⌥Space等）のみ。

**勝者: Koe** — 完全ハンズフリー運用が可能なのはKoeのみ。

---

## 5. エージェントモード（音声コマンド実行）

### Koe — AgentMode
認識テキストから意図を検出し、実際にシステム操作を実行。

| 発話例 | 実行内容 |
|--------|---------|
| 「VS Codeを開いて」 | `/usr/bin/open -a "Visual Studio Code"` |
| 「GitHubを検索して」 | ブラウザでGoogle検索を開く |
| 「スクショ撮って」 | `screencapture -i` でスクリーンショット |
| 「ショートカット Timer を実行」 | Shortcuts.appのオートメーションを起動 |
| 「ターミナルで date」 | ホワイトリスト内のコマンドを実行 |

**セキュリティ設計**が優れており、`rm`, `sudo`, `chmod`, パイプ(`|`), リダイレクト(`>`)は完全ブロック。許可されるのは読み取り系・安全なコマンドのみ。

### SuperWhisper / Aqua Voice
エージェント機能なし。テキスト変換に特化。

**勝者: Koe** — 競合2製品には存在しない機能。

---

## 6. 会議モード・議事録

### Koe — MeetingMode
リアルタイム議事録自動作成:
- 5秒の無音を話者交代と判定（ヒューリスティック話者分離）
- デスクトップに自動でフォルダ作成 (`~/Desktop/Koe_議事録_YYYYMMdd_HHmmss/`)
  - `議事録.txt` (タイムスタンプ付き全文)
  - `audio/` (個別WAVファイル)
- SRT・VTT形式の字幕ファイルを自動出力
- ローカルLLMで要点抽出・誤字修正（リモート送信なし）
- **VoiceProcessingIO** (Apple Audio Unit) によるハードウェアレベルのエコーキャンセリング (AEC/NS/AGC) — オンライン会議で相手の声を誤認識しない

### SuperWhisper
会議トランスクリプション機能あり。AIベースの議事録作成対応。

### Aqua Voice
会議機能なし。

**勝者: Koe / SuperWhisper** — 両者対応。Koeはオフライン完結・エコーキャンセリングが強み。

---

## 7. Mac ↔ iOS 連携

### Koe — PhoneBridge
**MultipeerConnectivity** (Bonjour) によるシームレス連携。

- MacがローカルネットワークにBonjour (`koe-bridge`) を告知
- iPhoneが自動検出・接続
- iPhoneで認識 → JSON送信 → MacのAutoTyperが自動ペースト
- 音声ストリーミングも対応（PCMをunreliableモードで転送）
- 通信は暗号化必須 (`.required`)

**ユースケース**: iPhoneを音声入力リモコンとして使い、Macのテキストフィールドに直接入力する。

### SuperWhisper / Aqua Voice
デバイス間連携機能なし。

**勝者: Koe** — 独自機能。

---

## 8. iOS固有機能

| 機能 | Koe | SuperWhisper | Aqua Voice |
|------|-----|-------------|-----------|
| キーボード拡張 | ✅ | ✅ | 不明 |
| Live Activity | ✅ Dynamic Island対応 | 記載なし | 記載なし |
| ウィジェット | ✅ ロック画面・スタンバイ | 不明 | 不明 |
| 共有拡張 | ✅ | 不明 | 不明 |
| オフラインWhisper | ✅ | ✅ | ❌ |

### Koe iOS — 詳細
- **キーボード拡張 (KoeKeyboard)**: LINEでもSlackでもNotionでも、どのアプリからでもキーボード上の録音ボタンで音声入力
- **Live Activity**: 長時間録音中もDynamic Islandで状態確認
- **WidgetKit**: ロック画面ウィジェットからワンタップ録音
- **Share Extension**: 共有メニューから音声テキストを他アプリに送信

---

## 9. 技術的アーキテクチャ比較

### 処理パイプライン

**Koe** (多段階):
```
音声
  → AudioDSP (プリエンファシス・VAD・正規化)
  → WhisperContext (whisper.cpp + Metal GPU)
  → VoiceCommands (フィラー除去・辞書展開)
  → LLMProcessor (ローカル / Apple Intelligence / クラウド)
  → AutoTyper (CGEvent自動入力 or クリップボード)
  → AgentMode (コマンド実行 ※オプション)
```

**SuperWhisper**:
```
音声 → Whisper → LLM後処理 → 自動タイピング
```

**Aqua Voice**:
```
音声 → Avalon (独自モデル) → 自動タイピング
```

Koeは各段階でカスタマイズ可能な**モジュラー設計**。

### コンテキスト自動生成
Koeの`ContextCollector`は認識精度向上のためにWhisperの`initial_prompt`を自動生成:
- Accessibility APIで現在選択しているテキストを取得
- 修正履歴から頻出単語を自動学習
- 起動中アプリに応じたプロンプト切り替え（VS Code → コード文体、Terminal → コマンド文体）

---

## 10. プライバシー・セキュリティ

| 観点 | Koe | SuperWhisper | Aqua Voice |
|------|-----|-------------|-----------|
| 音声のクラウド送信 | ❌ 完全ローカル | ❌ ローカルモード時 | ❌ ローカル処理 |
| LLMのクラウド送信 | ❌ ローカルLLM | △ クラウドLLM使用時は送信 | 不明 |
| OSSによる検証 | ✅ コード公開 | ❌ | ❌ |
| SOC 2 | ❌ | ✅ Enterprise | 不明 |

**Koeが最もプライバシーフレンドリー**。コードが公開されているため、何が起きているかをユーザー自身が検証できる。

---

## 11. 対応言語数

| 製品 | 言語数 |
|------|--------|
| SuperWhisper | **100言語以上** |
| Aqua Voice | 49言語 |
| Koe | 20言語 |

多言語対応ではSuperWhisperが圧倒的。Koeは主要20言語に絞っているが、日本語・英語・中国語・韓国語など実用的な言語はカバーしている。

---

## 12. 開発活発度・エコシステム

### Koe
- MIT OSSとして公開
- Raycast拡張、ブラウザ拡張も同梱
- Windows版はRustで実装（Tauri的アーキテクチャ）

### SuperWhisper
- 2025年12月にWindows版正式リリース
- 2026年3月にGPT-5.1、Opus 4.5対応
- 定期的なアップデートで最新LLMモデルに追随

### Aqua Voice
- 2026年3月にiOS・Android同時リリース（最新の動き）
- YC出資で資金力あり
- Avalon APIを$0.39/時間で外部提供開始

---

## どれを選ぶべきか

### Koe を選ぶべき人
- **コストをかけたくない** — 完全無料
- **プライバシーを最優先** — コードを自分で検証したい
- **ウェイクワードで完全ハンズフリー** にしたい
- **音声でシステム操作**（アプリ起動・検索）をしたい
- **日本語精度を最大化**したい (Kotoba + Llama Swallow)
- **Mac↔iPhone連携**を活用したい
- **Apple Intelligence**と連携したい
- **エンジニアで、カスタマイズしたい** — フォーク・改変自由

### SuperWhisper を選ぶべき人
- **100言語以上**必要
- **Ollamaですでに動かしているモデル**と連携したい
- **Lifetime購入**で長期的にコストを下げたい
- **安定した製品**を使いたい（実績3年以上）
- **Windowsでも同じ体験**が必要

### Aqua Voice を選ぶべき人
- **Android端末でも**使いたい
- **開発者向け技術用語の精度**を最優先（英語）
- **iOSとAndroid統一環境**が必要
- YC出資製品の最新テクノロジーを試したい

---

## まとめ

```
コスト・プライバシー・日本語・拡張性  → Koe
多言語・Ollama・安定性・買い切り     → SuperWhisper
技術英語・Android・新技術            → Aqua Voice
```

Koeは**無料・オープンソース**でありながら、競合有料製品にない**ウェイクワード、エージェントモード、Mac↔iOS連携、llama.cpp内蔵ローカルLLM**を実装しており、特に日本語環境の開発者にとって最有力候補。

一方でSuperWhisperの**100言語対応**とOllama連携の実績は無視できない強みであり、英語メインのグローバルチームやWindowsユーザーにはSuperWhisperが現実的な選択。

Aqua VoiceはAndroid対応と独自Avalonモデルという明確な差別化があり、クロスプラットフォームのモバイルワーカーに刺さるポジション。

---

## 参考リンク

- [Koe 公式サイト](https://koe.elio.love)
- [Koe GitHub](https://github.com/yukihamada/Koe-swift)
- [SuperWhisper](https://superwhisper.com)
- [Aqua Voice](https://aquavoice.com)
