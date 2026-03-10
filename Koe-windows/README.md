# Koe for Windows 🎙️

超高速オンデバイス音声入力アプリ。whisper.cpp + CUDA GPUで0.5秒以下のレイテンシ。

## 特徴

- **超高速**: whisper.cpp + CUDA GPU → 0.5秒以下で文字起こし
- **完全プライベート**: 全てローカル処理。クラウド不要
- **20言語対応**: 日本語・英語・中国語・韓国語・スペイン語ほか
- **グローバルホットキー**: `Ctrl+Alt+V` でどこでも音声入力
- **システムトレイ常駐**: 軽量でバックグラウンド動作

## 必要環境

- Windows 10/11 (64-bit)
- [Rust](https://rustup.rs) (ビルド用)
- [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads) (GPU高速化、推奨)
- NVIDIA GPU (CUDA対応、推奨。なくてもCPUで動作)

## ビルド & 実行

```bash
# ビルド
build.bat
# または
cargo build --release

# 実行
target\release\koe.exe
```

## 使い方

1. 起動するとシステムトレイにアイコンが表示
2. `Ctrl+Alt+V` を押して録音開始
3. 話し終えたらもう一度 `Ctrl+Alt+V`
4. 自動で文字起こし → アクティブウィンドウに貼り付け

## 初回起動

初回起動時に音声認識モデル（約540MB）を自動ダウンロードします。

## 設定

設定ファイル: `%APPDATA%\Koe\config.json`

```json
{
  "language": "ja",
  "model_id": "kotoba-v2-q5",
  "hotkey_modifiers": 3,
  "hotkey_vk": 86,
  "recording_mode": "Hold",
  "llm_enabled": true,
  "llm_provider": "chatweb",
  "llm_base_url": "https://api.chatweb.ai"
}
```

## モデル

| モデル | サイズ | 特徴 |
|--------|--------|------|
| Kotoba v2.0 Q5 (デフォルト) | 538MB | 日本語特化・高精度 |
| Large V3 Turbo Q5 | 547MB | 多言語対応・軽量 |
| Large V3 Turbo | 1.5GB | 多言語対応・高速 |
| Medium | 1.5GB | 多言語対応・バランス |

## ライセンス

MIT
