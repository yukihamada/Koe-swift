<div align="center">

# 声 Koe

**声で入力。ローカルで完結。**
*Voice input. Fully local. Zero cloud.*

![macOS](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

**[koe.elio.love](https://koe.elio.love)** — 公式サイト

[![Download](https://img.shields.io/github/v/release/yukihamada/Koe-swift?label=Download&style=for-the-badge&color=ff3b30)](https://github.com/yukihamada/Koe-swift/releases/latest)

</div>

---

## なにができる？

| 機能 | 説明 |
|------|------|
| ⚡ **超高速音声入力** | whisper.cpp (Metal GPU) で 0.5秒以内に認識 |
| 🔒 **完全ローカル** | 音声データは一切クラウドへ送信しない |
| 🎯 **ウェイクワード** | 「ヘイこえ」で完全ハンズフリー (自製 MFCC+DTW エンジン) |
| 🖥️ **どこでも入力** | グローバルホットキー、フローティングボタン |
| 🤖 **LLM後処理** | chatweb.ai / OpenAI 互換 API でテキスト加工 |
| 📝 **議事録モード** | 録音を自動でタイムスタンプ付きテキストに保存 |
| 🔤 **テキスト展開** | 「メアド」→ 「yuki@example.com」などの辞書 |
| 🎛️ **アプリ別プロファイル** | VS Code ではコード、ターミナルではコマンドに最適化 |
| 🔄 **オートアップデート** | GitHub Releases から自動更新 |

## インストール

### ワンライナー (推奨)

```bash
# 1. whisper.cpp + llama.cpp をインストール
brew install whisper-cpp llama.cpp

# 2. Koe をダウンロード & 起動（モデルはアプリ内で自動ダウンロード）
curl -L -o /tmp/Koe.zip https://github.com/yukihamada/Koe-swift/releases/latest/download/Koe.app.zip && \
unzip -o /tmp/Koe.zip -d /Applications && open /Applications/Koe.app
# デフォルト: Kotoba Whisper v2.0（日本語特化）、設定から他モデルにも切替可能
```

### 手動インストール

1. [Koe.app.zip をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest)
2. `Koe.app` を `/Applications` に移動
3. 起動してマイク・アクセシビリティ権限を許可
4. 設定画面でモデルパスを指定

### ソースからビルド

```bash
git clone https://github.com/yukihamada/Koe-swift
cd Koe-swift
bash build.sh
```

## 使い方

- **⌥⌘V** を押している間 → 録音（ホールドモード）
- **⌥⌘V** → 話す → **⌥⌘V** → 変換（トグルモード）
- **「ヘイこえ」** → ハンズフリーで録音開始（ウェイクワードモード）
- 話し終わると **0.85秒の無音** で自動変換
- **Space** 長押しで延長、もう一度で即変換

## アーキテクチャ

```
マイク → AVAudioRecorder (16kHz WAV)
  ↓
whisper-server (Metal GPU, オンメモリ)
  ↓  ~0.5秒 (投機的実行で更に短縮)
LLM後処理 (任意)
  ↓
CGEvent Cmd+V → テキスト入力
```

---

<div align="center">

**[koe.elio.love](https://koe.elio.love)**

<sub>Built with ♥ in Tokyo · Fully local · No subscription</sub>
</div>
