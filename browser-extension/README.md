# Koe Browser Extension

Chrome/Edge/Safari extension for Koe voice input.

## Installation

### Chrome / Edge
1. Open `chrome://extensions` (or `edge://extensions`)
2. Enable "Developer mode" (top right toggle)
3. Click "Load unpacked" and select this `browser-extension/` folder

### Safari
Use the Xcode Safari Web Extension converter:
```bash
xcrun safari-web-extension-converter browser-extension/ --project-location . --app-name KoeSafariExtension
```

## Usage

Click the Koe 🎙 toolbar icon to open the popup, then choose:
- **音声入力を開始** — Start voice recognition (result typed into active page)
- **翻訳モードで入力** — Start in translation mode (Japanese ↔ English)
- **録音を停止** — Stop recording
- **設定を開く** — Open Koe settings

## Requirements

- [Koe](https://koe.voice/) must be installed and running on macOS
- The extension communicates via `koe://` URL scheme

## Keyboard Shortcut

You can assign a keyboard shortcut in Chrome: `chrome://extensions/shortcuts`
