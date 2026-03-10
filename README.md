<div align="center">

# 声 Koe

**声で入力。ローカルで完結。**
*Voice input. Fully local. Zero cloud.*

![macOS](https://img.shields.io/badge/macOS_13%2B-Apple_Silicon_%26_Intel-black?style=flat-square&logo=apple)
![Windows](https://img.shields.io/badge/Windows_10%2B-x64-blue?style=flat-square&logo=windows)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

**[koe.elio.love](https://koe.elio.love)** — 公式サイト

[![Download macOS](https://img.shields.io/github/v/release/yukihamada/Koe-swift?label=macOS&style=for-the-badge&color=ff3b30)](https://github.com/yukihamada/Koe-swift/releases/latest)
[![Download Windows](https://img.shields.io/badge/Windows-Download-0078D6?style=for-the-badge&logo=windows)](https://github.com/yukihamada/Koe-swift/releases/latest)

</div>

---

## なにができる？

| 機能 | 説明 |
|------|------|
| ⚡ **超高速音声入力** | whisper.cpp (Metal/CUDA GPU) で 0.5秒以内に認識 |
| 🔒 **完全ローカル** | 音声データは一切クラウドへ送信しない |
| 🌐 **20言語対応** | 日英中韓 + スペイン語・フランス語・ドイツ語ほか |
| 🖥️ **macOS & Windows** | 両プラットフォームでネイティブ動作 |
| 🎯 **ウェイクワード** `Beta` | 「ヘイこえ」で完全ハンズフリー (macOS) |
| 🤖 **LLM後処理** | chatweb.ai / OpenAI 互換 API でテキスト加工 |
| 📝 **議事録モード** | 録音を自動でタイムスタンプ付きテキストに保存 (macOS) |
| 🔤 **テキスト展開** | 「メアド」→ 「yuki@example.com」などの辞書 |
| 🎛️ **アプリ別プロファイル** | VS Code ではコード、ターミナルではコマンドに最適化 |
| 🔄 **オートアップデート** | GitHub Releases から自動更新 |

## インストール

### macOS

#### PKG版 (推奨)

1. **[Koe.pkg をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest/download/Koe.pkg)**
2. ダブルクリックしてガイドに従うだけ。Applications に自動配置されます。
3. 起動してマイク・アクセシビリティ権限を許可
4. 初回起動時に音声認識モデル (Kotoba Whisper v2.0) が自動ダウンロード

#### DMG版

1. **[Koe-Installer.dmg をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest/download/Koe-Installer.dmg)**
2. DMGを開いて `Koe.app` を Applications にドラッグ

> whisper.cpp + Metal GPU はアプリに内蔵済み。brew install は不要です。

### Windows

#### インストーラー (推奨)

1. **[Koe-Setup.exe をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest)**
2. 実行してガイドに従うだけ
3. 初回起動時に音声認識モデルを自動ダウンロード (538MB)

#### ポータブル版

1. **[koe.exe をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest)**
2. そのまま実行（インストール不要）

> NVIDIA GPU があれば CUDA で高速化。CPU でも動作します。

### ソースからビルド

```bash
# macOS
brew install whisper-cpp llama.cpp
git clone https://github.com/yukihamada/Koe-swift
cd Koe-swift && bash build.sh

# Windows
cd Koe-windows
cargo build --release              # CPU版
cargo build --release --features cuda  # CUDA GPU版
```

## 使い方

| OS | ショートカット | 動作 |
|----|--------------|------|
| macOS | **⌥⌘V** | 押している間録音 (ホールド) / 押して切替 (トグル) |
| Windows | **Ctrl+Alt+V** | トグル方式（押して開始・もう一度で停止） |

- 話し終わると **0.85秒の無音** で自動変換
- 結果はアクティブウィンドウに自動貼り付け

### 対応言語

🇯🇵 日本語 · 🇺🇸 English · 🇨🇳 中文 · 🇰🇷 한국어 · 🇪🇸 Español · 🇫🇷 Français · 🇩🇪 Deutsch · 🇮🇹 Italiano · 🇵🇹 Português · 🇷🇺 Русский · 🇮🇳 हिन्दी · 🇹🇭 ไทย · 🇻🇳 Tiếng Việt · 🇮🇩 Indonesia · 🇳🇱 Nederlands · 🇵🇱 Polski · 🇹🇷 Türkçe · 🇸🇦 العربية · 🌐 Auto

## アーキテクチャ

```
マイク → 16kHz WAV録音
  ↓
DSP前処理 (プリエンファシス + 正規化 + VAD)
  ↓
whisper.cpp (Metal GPU / CUDA GPU)
  ↓  ~0.5秒
LLM後処理 (任意: 修正/翻訳/メール文体)
  ↓
Ctrl+V / ⌘V → テキスト入力
```

---

<div align="center">

**[koe.elio.love](https://koe.elio.love)**

<sub>Built with ♥ in Tokyo · Fully local · No subscription</sub>
</div>
