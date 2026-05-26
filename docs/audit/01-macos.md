# 01 — macOS app audit

検証対象: `Sources/Koe/`, `Koe-macOS.entitlements`, `Info-macOS.plist`, `Tests/`
監査日: 2026-05-26
方法: 静的監査（grep / Read 再検証）

> This is a friendly audit prepared by an external contributor. All suggestions are non-binding; please feel free to discuss, revise, defer, or drop any item — the project's maintainer knows the trade-offs best.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| M-01 | P0 | Auto-update の `.pkg` 経路に署名検証がない | `Sources/Koe/AutoUpdater.swift:174-196` |
| M-02 | P1 | LLM/API key が UserDefaults 平文に保存される | `Sources/Koe/Settings.swift:314,531` |
| M-03 | P1 | iPhone bridge の 4桁 PIN にレート制限なし＋display name spoofing で auto-pair 突破可 | `Sources/Koe/AppDelegate.swift:2304-2316, 2617-2642` |
| M-04 | P1 | iPhone bridge から auto-Enter 経由で任意キー実行が可能 | `Sources/Koe/AppDelegate.swift:198-204, 211-220, 231-234` |
| M-05 | P1 | `Info-macOS.plist` に Screen Recording / AppleEvents の UsageDescription が無い | `Info-macOS.plist`, `Sources/Koe/AppDelegate.swift:1853-1877, 2524-2546` |
| M-06 | P2 | Carbon HotKey が `applicationWillTerminate` / `deinit` で `UnregisterEventHotKey` されない | `Sources/Koe/AppDelegate.swift:381-385, 2282-2286` |
| M-07 | P2 | `AVAudioEngine.start()` 失敗時に installed tap が解放されない | `Sources/Koe/WakeWordEngine.swift:224-233`, `Sources/Koe/OWWEngine.swift:161-182` |
| M-08 | P2 | `AudioRecorder` が `try?` で recorder 生成エラーを silent drop | `Sources/Koe/AudioRecorder.swift:29-35` |
| M-09 | P2 | `AutoTyper.paste()` のクリップボード復元に 120ms race | `Sources/Koe/AutoTyper.swift:37-57, 115-125` |
| M-10 | P2 | `AutoTyper.deleteBackward(count:)` が最大 500 文字を一気に送信し undo を破壊する | `Sources/Koe/AutoTyper.swift:60-94, 203-218` |
| M-11 | P2 | `koe://` URL scheme が無認証 → 任意アプリから録音発火可能 | `Sources/Koe/AppDelegate.swift:127-132, 2223-2247` |
| M-12 | P2 | Whisper モデル DL に checksum 検証が無い | `Sources/Koe/ModelDownloader.swift:49-141` |
| M-13 | P2 | `LLMProcessor.processRemoteWith` で OpenAI 互換エンドポイントの URL を二重に組み立てて壊す | `Sources/Koe/LLMProcessor.swift:252-269` |
| M-14 | P2 | `app-sandbox=false` + `allow-unsigned-executable-memory=true` の固定組み合わせ | `Koe-macOS.entitlements:5-15` |
| M-15 | P3 | `statusItem: NSStatusItem!` の implicit-unwrap | `Sources/Koe/AppDelegate.swift:11, 390-407, 506-515` |
| M-16 | P3 | `Tests/KoeTests.swift` のカバレッジが極端に狭い | `Tests/KoeTests.swift` |
| M-17 | P3 | `OverlayWindow` の screen 位置決定が `NSScreen.main` 固定 | `Sources/Koe/OverlayWindow.swift:13-19` |

合計 17 件（P0=1, P1=4, P2=9, P3=3）

---

## 詳細

### M-01 (P0) — Auto-updater installs `.pkg` without verifying its signature

**File**: `Sources/Koe/AutoUpdater.swift:174-196`
**Symptom**: GitHub Releases から落とした `.pkg` を `NSWorkspace.shared.open(stablePkg)` で直接 Installer.app に渡しているだけで、`pkgutil --check-signature` も `codesign -dv` も実行していない。`installFromZip` は `codesign --verify --deep --strict` を行いロールバックまで実装している（同ファイル 228-241 行）ので、pkg だけ抜け穴になっている。
**Repro**: MITM、あるいは GitHub Releases asset の差し替えが起きた場合、悪意ある pkg がそのままシステム Installer に渡り `postinstall` script を含めて昇格実行される。
**Suggested fix**:
```swift
// Sources/Koe/AutoUpdater.swift:187 付近
klog("AutoUpdater: verifying pkg signature \(stablePkg.path)")
let check = Process()
check.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
check.arguments = ["--check-signature", stablePkg.path]
let pipe = Pipe()
check.standardOutput = pipe
check.standardError = pipe
try? check.run()
check.waitUntilExit()
guard check.terminationStatus == 0 else {
    klog("AutoUpdater: pkg signature verification FAILED")
    showError("アップデートファイルの署名が確認できませんでした")
    return
}
// 期待する Developer ID チームを README 等にハードコードし grep する形が望ましい
NSWorkspace.shared.open(stablePkg)
```

---

### M-02 (P1) — LLM provider API keys stored in UserDefaults plaintext

**File**: `Sources/Koe/Settings.swift:314, 531`
**Symptom**:
```swift
@Published var llmAPIKey: String  { didSet { ud.set(llmAPIKey, forKey: "llmAPIKey") } }
// ...
llmAPIKey = ud.string(forKey: "llmAPIKey") ?? ""
```
キーは `~/Library/Preferences/com.yuki.koe.plist` に平文で保存される。Keychain ではない。
**Impact**: 他プロセスから普通に読める。Time Machine / iCloud Drive バックアップにも素のまま入る。Sandbox 無効（M-14）なので尚更他アプリから読まれやすい。
**Suggested fix**: `Security` の Keychain Services にラップ。最低限のスケルトン:
```swift
enum Secrets {
    static let service = "com.yuki.koe.llm"
    static func set(_ value: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
```
既存ユーザー向けに「初回起動時に旧 UserDefaults から移行 → 旧キー削除」のワンショット migration を入れると無痛で移行できる。

---

### M-03 (P1) — Multipeer pairing PIN is 4-digit with no rate-limit, and re-pair via display-name spoofing

**File**: `Sources/Koe/AppDelegate.swift:2304-2316, 2617-2642`
**Symptom**:
1. `pairingPIN = String(format: "%04d", Int.random(in: 0...9999))` — 10,000 通り。
2. `advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)` は失敗時に何もペナルティを課さない（連続試行可能）。
3. すでに paired 済みの peer は `pairedPeerNames.contains(peerName)` の display name 一致だけで auto-accept される。`MCPeerID(displayName:)` は任意の文字列を選べるので、一度ターゲットの paired 名（例 "kenny の iPhone"）を観測すれば後日成りすませる。
**Impact**: 同一 Wi-Fi セグメント / Bonjour 圏内で攻撃可能。pairing 完了後は M-04 経由でキー注入されるため、影響は単なる接続ではなく remote keystroke injection。
**Suggested fix**:
- PIN を 6 桁以上、または HKDF ベースのワンタイム鍵に。
- 連続失敗で advertising を 60 秒停止 + 通知。
- paired peer の識別を `displayName` ではなく Curve25519 公開鍵フィンガープリント（初回保存）にする。
- pairing 状態は `~/Library/Application Support/com.yuki.koe/paired.json` 等にハッシュ＋ tag で保存し、UserDefaults より隔離。

---

### M-04 (P1) — Paired iPhone can inject arbitrary keystrokes via `iphoneBridgeAutoEnter`

**File**: `Sources/Koe/AppDelegate.swift:198-204, 211-220, 231-234, 248-289, 2585-2613`
**Symptom**: paired iPhone から `{"type":"text","text":"…"}` を受信すると、Mac は frontmost app に直接 paste → 0.1秒後に Return を `postReturn()` する（`iphoneBridgeAutoEnter` ON 時）。さらに `{"type":"command","command":"..."}` で `selectAll` / `closeWindow` / `escape` 等を投げられる。
**Impact**: pairing が確立すれば、その paired peer（M-03 の合言葉 display name で auto-accept されたもの）から、Terminal や Slack 等で任意のコマンド実行・送信が可能。
**Suggested fix**:
- `iphoneBridgeAutoEnter` のデフォルト OFF を維持しつつ、有効時は frontmost app の bundleID を allow-list 化（例: Notes / Slack のみ）。
- `command` 受信時に NSAlert で「iPhone から `selectAll` を実行しますか？」のような明示同意を要求するモードを設ける。
- 少なくとも `closeWindow` / `escape` / `appSwitch` は voiceControl 設定とは独立に user-confirm 必須に。

---

### M-05 (P1) — Missing `NSScreenCaptureUsageDescription` / `NSAppleEventsUsageDescription`

**File**: `Info-macOS.plist`（NS{Microphone,SpeechRecognition}UsageDescription しか無い）
**Symptom**:
- `CGWindowListCreateImage` (AppDelegate.swift:2546)、`CGWindowListCopyWindowInfo` (同 2525)、ScreenCaptureKit (`SystemAudioCapture.swift`) の利用に対し `NSScreenCaptureUsageDescription` が未定義。macOS 13+ では権限ダイアログが「アプリ名はこのデータを使用したい理由を…」と空欄表示になり、reviewer/end user の不信感を招く。
- `duckSystemVolume()` (AppDelegate.swift:1853-1877) が `/usr/bin/osascript` 経由で `set volume output volume` を実行 → macOS は AppleEvents 権限を要求するが、`NSAppleEventsUsageDescription` が未定義。
**Suggested fix**: `Info-macOS.plist` に下記を追加。
```xml
<key>NSScreenCaptureUsageDescription</key>
<string>Koe captures the active window to show context-aware suggestions in iPhone Bridge.</string>
<key>NSAppleEventsUsageDescription</key>
<string>Koe lowers system volume while recording to reduce mic bleed.</string>
```

---

### M-06 (P2) — Carbon HotKey refs leaked on quit / deinit

**File**: `Sources/Koe/AppDelegate.swift:381-385`, `2282-2286`
**Symptom**: `applicationWillTerminate` は `HistoryStore.flushSync()` / `WhisperServer.stop()` / `WakeWordDetector.stop()` のみ。`deinit` も `eventMonitor` 解除と timer invalidate しかしない。`carbonHotKeyRef` / `carbonTranslateHotKeyRef` / `carbonCmdKHotKeyRef` / `carbonMeetingHotKeyRef` / `carbonRerecognizeHotKeyRef` / `carbonSpaceHotKeyRef` / `carbonEscHotKeyRef` のいずれも `UnregisterEventHotKey` されない。
**Impact**: 終了時には OS が回収するので実害は薄いが、ユニットテストやプロセス長期動作 (re-launch loop) でハンドラ重複・OSStatus エラーの原因になる。`reregisterHotkey()` 経由のクリーンアップは `registerCarbonHotKey(settings:)` 内 614-621 にあるが、quit パスでは呼ばれない。
**Suggested fix**: 専用 cleanup を `applicationWillTerminate` と `deinit` 両方から呼ぶ。
```swift
private func unregisterAllCarbonHotKeys() {
    for ref in [carbonHotKeyRef, carbonTranslateHotKeyRef,
                carbonSpaceHotKeyRef, carbonEscHotKeyRef,
                carbonCmdKHotKeyRef, carbonMeetingHotKeyRef,
                carbonRerecognizeHotKeyRef].compactMap({ $0 }) {
        UnregisterEventHotKey(ref)
    }
    carbonHotKeyRef = nil
    // ...nil 化
}
```

---

### M-07 (P2) — `AVAudioEngine.start()` failure leaks installed tap

**File**: `Sources/Koe/WakeWordEngine.swift:210-234`、`Sources/Koe/OWWEngine.swift:148-183`
**Symptom**:
```swift
node.installTap(onBus: 0, bufferSize: 4096, format: natFmt) { ... }
do {
    engine.prepare()
    try engine.start()
} catch {
    klog("WakeWordEngine: engine error \(error)")
    isRunning = false   // <- tap がアンインストールされない
}
```
次に `start()` が呼ばれると `installTap` が 2 回目で例外 (multiple taps installed) を投げて落ちる。
**Suggested fix**: catch 内で `node.removeTap(onBus: 0)` を実行 → `audioEngine = nil`。OWWEngine 側も同じ修正。

---

### M-08 (P2) — `AudioRecorder.prepare()` silently swallows AVAudioRecorder errors

**File**: `Sources/Koe/AudioRecorder.swift:29-35`
**Symptom**:
```swift
guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
```
`try?` でエラー内容を破棄しているため、マイク権限拒否・format 不一致などの根本原因がログに残らず、後段で `recorder is nil` だけがログされる（同ファイル 39-44, 67-70）。
**Suggested fix**:
```swift
let r: AVAudioRecorder
do {
    r = try AVAudioRecorder(url: url, settings: settings)
} catch {
    klog("AudioRecorder: init failed: \(error.localizedDescription) (file=\(url.lastPathComponent), settings=\(settings))")
    return
}
```

---

### M-09 (P2) — Clipboard restore race in `AutoTyper.paste()`

**File**: `Sources/Koe/AutoTyper.swift:37-57, 115-125`
**Symptom**: paste 後 120ms (`paste`) / 80ms (`pasteStreaming`) で旧クリップボードを書き戻す。その 80–120ms の間にユーザーが ⌘C で別のものをコピーすると、Koe が overwrite してユーザーのコピーを破壊する。
**Repro**: 録音→確定の直後に手動で何かをコピー。
**Suggested fix**: 復元前に `changeCount` を比べる:
```swift
let pb = NSPasteboard.general
let prev = pb.string(forType: .string)
let cntBeforePaste = pb.changeCount
pb.clearContents()
pb.setString(text, forType: .string)
let cntAfterSet = pb.changeCount
postKey(...)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
    // Only restore if no one else touched the pasteboard in the meantime
    guard pb.changeCount == cntAfterSet else { return }
    pb.clearContents()
    if let prev { pb.setString(prev, forType: .string) }
}
```

---

### M-10 (P2) — `deleteBackward(count:)` destroys app-level undo history

**File**: `Sources/Koe/AutoTyper.swift:60-94, 203-218`
**Symptom**: ストリーミング更新で `streamingCharCount` (最大 500) 分の `kVK_Delete` を `sync` で送る。多くの NSText 系で `Delete` 連打 = 各キーが独立した undo record になり、ユーザーが ⌘Z しても整形済み最終テキストの 1 文字前にしか戻れない。
**Suggested fix**:
- 可能なら ⌘Shift+← で範囲選択 → 1 回の delete に置き換える（`selectBackward(count:)` の枠組みは既にある — 184行）。`deleteAndReplace` のパターンを汎用化。
- `NSUndoManager.beginUndoGrouping()` は global では効かないので、せめてストリーミング更新の単位で「全選択置換」方式を default に。

---

### M-11 (P2) — `koe://` URL scheme accepts events from any process without confirmation

**File**: `Sources/Koe/AppDelegate.swift:127-132, 2223-2247`
**Symptom**: `koe://transcribe` / `koe://translate` を投げるだけで録音が開始される。`isRecording` チェックはあるが、悪意あるサイトの `<a href="koe://transcribe">` ワンクリックで録音が始まり、`iphoneBridgeAutoEnter` 等の組合せ次第で意図しない自動入力に繋がる。
**Suggested fix**: URL scheme は user-initiated とは限らない前提に立ち、`startRecording()` 直前にメニューバーアイコンをフラッシュ＋ visual confirmation overlay を出す。または `koe://transcribe?token=…` で localhost に事前発行した shortcut token を要求。

---

### M-12 (P2) — No checksum verification for downloaded Whisper models

**File**: `Sources/Koe/ModelDownloader.swift:49-141`（および ensure/save 経路）
**Symptom**: HuggingFace の `.bin` を URL から直 DL するだけで sha256 を照合していない。Whisper モデルは ggml バイナリで GPU/Metal にロードされ shader まで触るため、悪意あるアセットは RCE の足がかりになり得る。CDN 切替や同名上書き、TLS 終端時の改竄が起きた場合に検出手段がない。
**Suggested fix**: 各 `WhisperModel` に `sha256: String` を持たせ、DL 完了後に `CryptoKit.SHA256.hash(data: ...)` で照合 → 不一致なら削除。ハッシュは公式 release notes か repo に commit。

---

### M-13 (P2) — `LLMProcessor.processRemoteWith` double-appends `/v1/chat/completions`

**File**: `Sources/Koe/LLMProcessor.swift:252-269`
**Symptom**:
```swift
let urlStr = "\(baseURL)/v1/chat/completions"
```
呼び出し元（同ファイル 181-183）は既に `https://chatweb.ai/api/v1/chat/completions` を渡してくる:
```swift
processRemoteWith(text: ..., baseURL: "https://chatweb.ai/api/v1/chat/completions", ...)
```
結果 URL は `https://chatweb.ai/api/v1/chat/completions/v1/chat/completions` になりフォールバックが必ず 404。`processWithVision` (94-145) は逆に `baseURL` を `.../v1/chat/completions` 前提で扱う（98 行）ので、各所で base URL の流儀がぶれている。
**Suggested fix**: `LLMProvider.baseURL` を「`/v1` まで含むのか含まないのか」のどちらかに統一して、`processRemote{,With}` / `processWithVision` で同じ規約を使う。とりあえずの最小 fix は呼び出し側を `baseURL: "https://chatweb.ai/api"` に直すか、`processRemoteWith` 内で `/v1/chat/completions` を append しない分岐を入れる。

---

### M-14 (P2) — Sandbox disabled with `allow-unsigned-executable-memory`

**File**: `Koe-macOS.entitlements:5-15`
**Symptom**:
```xml
<key>com.apple.security.app-sandbox</key>           <false/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>  <true/>
```
whisper.cpp の Metal JIT のためと思われるが、結果として M-02（UserDefaults 平文）/M-04（任意アプリと同等のキー注入権限）の影響範囲が広がる。`#if MAC_APP_STORE` 経路では sandbox=true が必要なので、その build flavor は別 entitlements を持っているはずだが、本ファイルは GitHub 配布版用と読める。
**Suggested fix**: GitHub 版でも `app-sandbox=true` + `com.apple.security.cs.disable-library-validation` (= dylib のみ許容、JIT 不可) で whisper.cpp が動かないか確認。動かない場合、せめて `com.apple.security.cs.allow-jit` の方が `allow-unsigned-executable-memory` より粒度細かい（macOS 11+）。

---

### M-15 (P3) — `statusItem: NSStatusItem!` implicit-unwrap

**File**: `Sources/Koe/AppDelegate.swift:11, 390-407, 506-515`
**Symptom**: `private var statusItem: NSStatusItem!` の宣言と、`setupMenu()` 内の force-bang (`statusItem.button!`, 399行)。`updateStatusItemVisibility()` (407-410) では `guard let item = statusItem` と nil チェックされている — つまり既存コードも「nil 取りうる」前提で書かれている箇所がある。
**Impact**: 通常 launch path では問題ないが、test target で `applicationDidFinishLaunching` を踏まずに `setIcon(recording:)` を呼ぶような将来のテストでクラッシュする。
**Suggested fix**: `private var statusItem: NSStatusItem?` に統一し、`statusItem?.button?.image = img` の形で全箇所書き換え。

---

### M-16 (P3) — `Tests/KoeTests.swift` covers a narrow slice

**File**: `Tests/KoeTests.swift`
**Symptom**: 現状のテストは AgentMode 自然言語マッチ + VoiceCommands filler + Settings 既定値 + L10n smart-quote + LLMProcessor 空入力 + AgentCommand properties のみ。security/IO 層（AudioRecorder, AutoUpdater 署名検証、AutoTyper deleteBackward, WhisperContext loadWAV, OWWEngine start/stop 二重呼び、IPhoneBridge PIN/peerName）が一切カバーされていない。
**Suggested fix**: 段階的に最小ユニットを足す（XCTest 採用しなくても assert ベースで十分）。例:
- `AutoUpdater.isNewer` の semver edge cases (`1.2.3` vs `1.2.3.0`, suffix なし)
- `WhisperContext.findDataChunk` の壊れた WAV ヘッダ入力
- `AutoTyper.deleteBackward(count:)` の 0 / 1 / 500 / 501 境界
- IPhoneBridge `pairedPeerNames` の衝突 (display name spoof)

---

### M-17 (P3) — `OverlayWindow` initial position locked to `NSScreen.main`

**File**: `Sources/Koe/OverlayWindow.swift:13-19`
**Symptom**:
```swift
let screen = NSScreen.main ?? NSScreen.screens[0]
let rect = CGRect(x: screen.frame.midX - w / 2,
                  y: screen.visibleFrame.minY + 32, ...)
```
`NSScreen.main` は「キーウィンドウのある画面」なので、Koe が menu bar app（LSUIElement=true）で起動直後は nil → screens[0] にフォールバック。マルチモニタ環境で常時メインに固定されるため、サブモニタで作業している人にとっては overlay が見えない/邪魔な位置に出る。
**Suggested fix**: `NSWorkspace.shared.frontmostApplication` の window screen を引いてくる、または `show(state:)` 時に毎回 `NSEvent.mouseLocation` に近い screen を選び直す。

---

## Out of scope (this PR)

- 全 force-unwrap の guard 書き換え（広範に渡るためテーマ別に分割）
- `AVAudioEngine` / `AVAudioRecorder` の state machine 全面リファクタ（M-07/M-08 はピンポイント修正のみ）
- whisper.cpp 側 C コードの安全性（本 audit はラッパー Swift 層に限定）
- iOS / Windows / Raycast extension（別 audit）
- パフォーマンス最適化（whisper temperature_inc, best_of などの認識精度トレードオフ）
- 既存ユーザーの UserDefaults → Keychain migration の細かい UX 設計（M-02 の最小骨子のみ提示）
- localized strings（L10n.swift）の文言レビュー
