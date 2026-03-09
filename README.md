<div align="center">

# 声 Koe

**声で入力。ローカルで完結。**
*Voice input. Fully local. Zero cloud.*

![macOS](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

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

## セットアップ

```bash
# 1. whisper.cpp をインストール
brew install whisper-cpp

# 2. 日本語特化モデルをダウンロード (513MB)
whisper-download-ggml-model kotoba-whisper-v2.0-q5_0

# 3. Koe をビルド＆起動
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
  ↓  ~0.5秒
LLM後処理 (任意)
  ↓
CGEvent Cmd+V → テキスト入力
```

---

<div align="center">
<sub>Built with ♥ in Tokyo · Fully local · No subscription</sub>
</div>
