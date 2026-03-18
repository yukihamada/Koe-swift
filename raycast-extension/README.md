# Koe for Raycast

Control [Koe](https://koe.voice/) voice input from Raycast.

## Commands

| Command | Description |
|---------|-------------|
| **Start Voice Input** | Start Koe voice recognition and type result into current app |
| **Start Voice Translation** | Start Koe in translate mode (Japanese ↔ English) |
| **Stop Recording** | Stop current recording |
| **Open Koe Settings** | Open Koe preferences |

## Requirements

- [Koe](https://koe.voice/) installed and running on macOS

## How it works

Each command opens `koe://` URL scheme, which Koe handles to start/stop recording.
Results are typed automatically into whichever app was active when you triggered the command.

## URL Scheme Reference

You can also trigger Koe from Terminal, Shortcuts.app, or any script:

```bash
open koe://transcribe   # start voice input
open koe://translate    # start translation mode
open koe://stop         # stop recording
open koe://settings     # open settings
```
