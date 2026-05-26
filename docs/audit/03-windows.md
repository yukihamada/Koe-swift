# 03 — Windows app audit

検証対象: `Koe-windows/`
監査日: 2026-05-26
方法: 静的監査 (Explore + 再 grep 検証)

> This is a friendly audit prepared by an external contributor. All suggestions are non-binding; happy to discuss, revise, or drop any item.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| W-01 | P0 | `llm_api_key` が `config.json` に平文保存 | `Koe-windows/src/config.rs:127,201-209` |
| W-02 | P0 | HuggingFace モデル DL に SHA256 検証なし | `Koe-windows/src/model.rs:46-109` |
| W-03 | P0 | NSIS インストーラに SignTool 署名 / 自動更新なし | `Koe-windows/installer/koe-installer.nsi` |
| W-04 | P1 | `paste.rs` で前景ウィンドウ検証なし、クリップボードレース、非テキスト形式破壊 | `Koe-windows/src/paste.rs:8-37` |
| W-05 | P1 | HKCU Run キーで silent auto-start (ユーザー同意なし) | `Koe-windows/installer/koe-installer.nsi:63` |
| W-06 | P2 | グローバルホットキーが UAC 昇格ウィンドウ前面時に動作不可 | `Koe-windows/src/hotkey.rs:18-40` |
| W-07 | P2 | `recognize_and_paste` 内の `Mutex` ロック保持中に Whisper 推論 (UI 反応性) | `Koe-windows/src/hotkey.rs:83-122` |
| W-08 | P3 | Windows Credential Manager / DPAPI のラッパー未導入 | `Koe-windows/src/config.rs` |

## 詳細

### W-01 (P0) — `llm_api_key` が `config.json` に平文保存
**File**: `Koe-windows/src/config.rs:127, 201-209`
**Symptom**: `Config { pub llm_api_key: String, ... }` を `serde_json::to_string_pretty` で `%APPDATA%\Koe\config.json` に書き込み (line 208)。任意のユーザーランドプロセスが読み取れる。マルウェアスキャンの誤検出やトークン流出につながる。
**Repro**: `type %APPDATA%\Koe\config.json` で `llm_api_key` がそのまま見える。
**Suggested fix**: Windows Credential Manager (`windows::Win32::Security::Credentials::CredWriteW`) または DPAPI (`CryptProtectData`) でラップ。`Config` は鍵ハンドル ID のみ保持し、実体は credential vault。
```rust
// 例: keyring crate
use keyring::Entry;
let entry = Entry::new("Koe", "llm_api_key")?;
entry.set_password(&key)?;
let key = entry.get_password()?;
```

### W-02 (P0) — HuggingFace モデル DL に SHA256 検証なし
**File**: `Koe-windows/src/model.rs:46-109`
**Symptom**: `download_model` は `reqwest::blocking` で stream → `.tmp` → `rename` するだけ。HuggingFace 側のブランチ差し替えや CDN 中間者で別バイナリが入り込んでも検出不能。iOS 側 (I-02) と同根。
**Suggested fix**: `WhisperModel` に `expected_sha256: &'static str` を追加。`download_model` 内で `sha2::Sha256` を更新しながら書き込み、rename 直前に検証。失敗時は `.tmp` 削除。

### W-03 (P0) — NSIS インストーラに SignTool 署名 / 自動更新なし
**File**: `Koe-windows/installer/koe-installer.nsi`
**Symptom**: スクリプトに `!finalize 'signtool sign ...'` / `!packhdr` での署名フックなし。配布される `Koe-Setup.exe` は未署名 → SmartScreen が「発行元不明」警告を出し続け、ユーザーの DL 離脱要因。自動アップデート機構 (WinSparkle / squirrel.windows / `winget upgrade` 用 manifest 等) もなし。
**Suggested fix**:
1. EV または OV コード署名証明書を取得し、`build.ps1` で `signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /a koe.exe Koe-Setup.exe`。
2. WinSparkle を `Cargo.toml` の `[features] update = ["winsparkle"]` で組み込み、`https://koe.example.com/appcast.xml` を購読。
3. winget リポジトリへの manifest PR (`Yuki.Koe`)。

### W-04 (P1) — paste.rs の前景ウィンドウ検証 / クリップボードレース / 非テキスト破壊
**File**: `Koe-windows/src/paste.rs:8-55`
**Symptom**:
1. **前景ウィンドウ不確定**: `simulate_paste()` が `SendInput` で Ctrl+V を投げるが、その瞬間にフォーカスが移動していると別ウィンドウに認識結果がペーストされる。パスワード入力欄に音声テキストが流れ込む事故が起き得る。
2. **クリップボードレース**: `clipboard.get_text().ok()` → `clipboard.set_text(text)` → `sleep(30ms)` → `SendInput` → `sleep(120ms)` → 復元、の間に他アプリがクリップボードを更新するとデータが失われる、または `set_text` が `Other application has the clipboard` で失敗する。
3. **非テキスト形式**: 画像 / ファイル / RTF などをコピーしていた場合 `get_text().ok()` で `None` になり、復元時に空クリップボードになる (画像消失)。
**Suggested fix**:
```rust
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
let target_hwnd = unsafe { GetForegroundWindow() };
// 1. SendInput 直前に再取得して同一か確認
// 2. CF_BITMAP / CF_HDROP / CF_UNICODETEXT を全部 enumerate して保存・復元
// 3. WM_DRAWCLIPBOARD で他アプリの上書きを検出
```
あるいは「クリップボード経由ではなく `SendInput` で文字を一文字ずつ Unicode で送る (`KEYEVENTF_UNICODE`)」方式を検討。

### W-05 (P1) — HKCU Run キーで silent auto-start
**File**: `Koe-windows/installer/koe-installer.nsi:63`
**Symptom**: `WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Koe" '"$INSTDIR\koe.exe"'` を install セクションで無条件実行。インストール完了画面に「スタートアップに追加する」チェックボックスなし。ユーザーは設定アプリから手動で外す必要がある。
**Suggested fix**: MUI2 の `MUI_PAGE_COMPONENTS` でオプショナルセクションに分割。あるいは `MUI_PAGE_FINISH` の `MUI_FINISHPAGE_RUN` を使い、自動起動チェックボックスを追加。

### W-06 (P2) — グローバルホットキーが UAC 昇格ウィンドウ前面時に動作不可
**File**: `Koe-windows/src/hotkey.rs:18-40`
**Symptom**: 非昇格プロセスである koe.exe が登録した `Ctrl+Alt+V` は、管理者権限ウィンドウ (タスクマネージャ / レジストリエディタ等) にフォーカスがあるとき UIPI によって遮断される。クラッシュはしないが「特定のアプリだと反応しない」という不可解な UX に。
**Suggested fix**:
1. 公式ドキュメントとして README に明記。
2. オプションで `RequestExecutionLevel admin` (既に NSIS は admin だが exe 自体は非昇格起動) 経由のサービス化、あるいは `ChangeWindowMessageFilterEx(WM_HOTKEY)` 等を検討 (制限あり)。

### W-07 (P2) — `recognize_and_paste` のロック保持中に Whisper 推論
**File**: `Koe-windows/src/hotkey.rs:92-110`
**Symptom**:
```rust
let result = {
    let s = shared.lock().unwrap();      // ロック取得
    let lang = s.config.lang_code();
    ...
    match &s.whisper {
        Some(engine) => engine.transcribe(&wav_path, lang, prompt),  // ← ロック保持中に重い推論
        None => Err("No engine".into())
    }
};
```
Whisper 推論は数百 ms〜数秒。その間 `shared` は他スレッドからロック不能 → トレイメニュー操作などが固まる。
**Suggested fix**: ロックは設定取得まで。エンジン参照は `Arc<WhisperEngine>` にして clone してから lock を drop。
```rust
let (engine, lang, prompt) = {
    let s = shared.lock().unwrap();
    (s.whisper.clone(), s.config.lang_code().to_string(), prompt)
};
let result = engine.map(|e| e.transcribe(&wav_path, &lang, &prompt));
```

### W-08 (P3) — Windows Credential Manager / DPAPI ラッパー未導入
**File**: `Koe-windows/src/config.rs`
**Symptom**: W-01 と同じ根。`keyring` クレート相当の薄いラッパーを 1 モジュール作っておくと、今後 OAuth トークンや別プロバイダの API キーが増えても同じ経路で守れる。
**Suggested fix**: `src/secrets.rs` モジュールを追加し、`store(key) / load(key) / delete(key)` の 3 関数だけ公開。

## Out of scope (this PR)
- `audio.rs` の WASAPI loopback / マイクデバイス選択
- `overlay.rs` の DirectComposition レンダリング最適化
- `transcribe.rs` の whisper.cpp GPU バックエンド (CUDA/Vulkan) 選択ロジック
- MSIX パッケージング (NSIS とは別フォーマット)
