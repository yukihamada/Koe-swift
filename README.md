<div align="center">

# 声 Koe

**声で入力。ローカルで完結。**
*Voice input. Fully local. Zero cloud.*

![macOS](https://img.shields.io/badge/macOS_13%2B-Apple_Silicon_%26_Intel-black?style=flat-square&logo=apple)
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
| 🎯 **ウェイクワード** `Beta` | 「ヘイこえ」で完全ハンズフリー (自製 MFCC+DTW エンジン) |
| 🖥️ **どこでも入力** | グローバルホットキー、フローティングボタン |
| 🤖 **LLM後処理** | chatweb.ai / OpenAI 互換 API でテキスト加工 |
| 📝 **議事録モード** | 録音を自動でタイムスタンプ付きテキストに保存 |
| 🔤 **テキスト展開** | 「メアド」→ 「yuki@example.com」などの辞書 |
| 🎛️ **アプリ別プロファイル** | VS Code ではコード、ターミナルではコマンドに最適化 |
| 🔄 **オートアップデート** | GitHub Releases から自動更新 |

## インストール

### PKG版 (推奨)

1. **[Koe.pkg をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest/download/Koe.pkg)**
2. ダブルクリックしてガイドに従うだけ。Applications に自動配置されます。
3. 起動してマイク・アクセシビリティ権限を許可
4. 初回起動時に音声認識モデル (Kotoba Whisper v2.0) が自動ダウンロード

### DMG版

1. **[Koe-Installer.dmg をダウンロード](https://github.com/yukihamada/Koe-swift/releases/latest/download/Koe-Installer.dmg)**
2. DMGを開いて `Koe.app` を Applications にドラッグ
3. 起動してマイク・アクセシビリティ権限を許可

> whisper.cpp + Metal GPU はアプリに内蔵済み。brew install は不要です。

### ソースからビルド

```bash
brew install whisper-cpp llama.cpp  # ソースビルド時のみ必要
git clone https://github.com/yukihamada/Koe-swift
cd Koe-swift
bash build.sh
```

## 使い方

- **⌥⌘V** を押している間 → 録音（ホールドモード）
- **⌥⌘V** → 話す → **⌥⌘V** → 変換（トグルモード）
- **「ヘイこえ」** → ハンズフリーで録音開始（ウェイクワード `Beta`）
- 話し終わると **0.85秒の無音** で自動変換
- **Space** 長押しで延長、もう一度で即変換

## 注意事項

### ウェイクワード (`Beta`) とマイクインジケータ

ウェイクワード機能を有効にすると、「ヘイこえ」を検出するためにマイクを常時監視します。そのため **macOS のオレンジ色のマイクインジケータが常に点灯** します。これは macOS の仕様であり、Koe が正常にマイクを使用している状態です。

- マイクインジケータが気になる場合は、設定 > AI > ウェイクワードを **OFF** にしてください
- OFF にすると、マイクは録音中 (⌘⌥V) のみ有効になります
- ウェイクワードは Beta 機能です。今後のアップデートで改善予定

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
