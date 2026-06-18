# Koe — release notes draft（koe.live/app 統合）

## 日本語
**ひとつの Koe に。** ネイティブアプリから、Web版の Koe（koe.live/app）をそのまま使えるようになりました。

- 📱 **iOS**：「メッセージ」タブを追加。声メッセージの送受信・受信箱・焚き火・通話、そして**自分の ElevenLabs キー登録（BYOK）**まで、アプリ内で完結。
- 🖥 **Mac**：メニューに「💬 メッセージ (Web)」。同じ統合Webアプリをウィンドウで。
- 既存のディクテーション・Whisper・常時録音・MacBridge は**そのまま**。
- Web側の更新は自動で反映（再ダウンロード不要）。

## English
**One Koe.** The native apps now open the web Koe (koe.live/app) right inside the app.

- 📱 **iOS**: new "Messages" tab — send/receive voice messages, inbox, campfire, calls, and **bring your own ElevenLabs key (BYOK)**, all in-app.
- 🖥 **Mac**: "💬 Messages (Web)" menu item opens the same unified web app in a window.
- Your existing dictation, Whisper, always-on recording and MacBridge are unchanged.
- Web updates roll out automatically (no re-download needed).

---
内部メモ（公開しない）:
- 変更コミット: 8459d05（Koe-swift・私の4ファイルのみ）
- 検証: Koe-iOS arm64 ビルド成功 / macOS ビルド成功（Debug・Release）
- リリース前に working tree の他WIP（LLMProcessor/Settings/SettingsWindowController/MyVoiceTTS）の扱いを確定すること
