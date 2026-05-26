# 04 — Browser & Raycast extensions audit

検証対象: `browser-extension/`, `raycast-extension/`
監査日: 2026-05-26
方法: 静的監査 (Explore + 再 grep 検証)

> This is a friendly audit prepared by an external contributor. All suggestions are non-binding; happy to discuss, revise, or drop any item.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| E-01 | P1 | `manifest.json` の `permissions: []` で `chrome.tabs.query` の URL が取れず cleanup ロジックが silent failure | `browser-extension/manifest.json:19`, `browser-extension/popup.js:4-8` |
| E-02 | P1 | `popup.js` `openKoe(path)` が `path` を sanitize せず `koe://` URL を組み立て | `browser-extension/popup.js:1-12` |
| E-03 | P2 | raycast-extension に lock file がない (build 再現性なし) | `raycast-extension/package.json` |
| E-04 | P2 | `@raycast/api ^1.0.0` のバージョンレンジが広すぎる | `raycast-extension/package.json:37` |
| E-05 | P2 | raycast-extension の `open()` 戻り値検査なし、Koe.app 未インストール時に sliently 失敗 | `raycast-extension/src/*.ts` (4 files) |
| E-06 | P3 | content_scripts 未定義 (今は無害だが将来拡張時に CSP 確認が必要) | `browser-extension/manifest.json` |

## 詳細

### E-01 (P1) — `permissions: []` で `chrome.tabs.query` の URL が取れず cleanup が silent failure
**File**: `browser-extension/manifest.json:19-20`, `browser-extension/popup.js:3-9`
**Symptom**: manifest が `"permissions": []` と `"host_permissions": []`。`popup.js:3` は
```js
chrome.tabs.create({ url: 'koe://' + path, active: false }, () => {
    chrome.tabs.query({}, (tabs) => {
        const newTab = tabs.find(t => t.url && t.url.startsWith('koe://'));
        if (newTab) chrome.tabs.remove(newTab.id);
    });
});
```
を実行するが、`tabs` 権限も該当 host_permission もないため、MV3 では `tabs.query` が返す `Tab` オブジェクトの `url`/`title`/`pendingUrl` フィールドは `undefined`。結果として `tabs.find` は常に `undefined` を返し、`koe://` 用に開いた空タブが残り続ける (= ユーザーがタブを手動で閉じる必要)。
**Repro**: 拡張をロードして action ボタン押下 → `koe://transcribe` 用のタブが空白のまま残る。
**Suggested fix**:
- 推奨: `tabs.create` 自体をやめて、`chrome.action.onClicked` から直接 `chrome.tabs.update(activeTabId, { url: 'koe://...' })` を呼んだ後すぐに `history.back()` 相当に戻す。あるいは新タブを作らず `chrome.windows.create({ url: ..., type: 'popup', state: 'minimized' })` で隠す。
- もしくは manifest に `"permissions": ["tabs"]` を追加 (Chrome Web Store 審査時に説明が必要)。

### E-02 (P1) — `popup.js` `openKoe(path)` が `path` を sanitize せず
**File**: `browser-extension/popup.js:1-12`
**Symptom**: 現状は呼び出し側 (`popup.js:14-17`) で `'transcribe' / 'translate' / 'stop' / 'settings'` の 4 つに限定されているのでリスクは小さい。しかし `openKoe` は popup の global scope に晒されており、popup.html 内で `<script>` が追加される / 動的に input から組み立てるよう拡張された場合に任意の `koe://` パスを叩ける。Koe アプリ側の URL handler が将来 `koe://reset`, `koe://delete-history` などを追加した時に予期せぬ呼び出しが通る。
**Suggested fix**:
```js
const ALLOWED = new Set(['transcribe', 'translate', 'stop', 'settings']);
function openKoe(path) {
  if (!ALLOWED.has(path)) return;
  chrome.tabs.create({ url: 'koe://' + path, active: false });
  ...
}
```

### E-03 (P2) — raycast-extension に lock file がない
**File**: `raycast-extension/`
**Symptom**: ディレクトリ直下に `package.json` / `README.md` / `src/` のみ。`package-lock.json` も `pnpm-lock.yaml` も `yarn.lock` もない。CI / 別マシンで `npm install` するたびに `@raycast/api`, `typescript`, `@raycast/eslint-config` のサブツリーがその時点の最新へ進み、再現ビルドが保証されない。
**Suggested fix**: `npm install --package-lock-only` で生成して commit。Raycast 公式の `ray build` が lock file を要求する場合の備えにもなる。

### E-04 (P2) — `@raycast/api ^1.0.0` のバージョンレンジが広すぎる
**File**: `raycast-extension/package.json:37`
**Symptom**: `^1.0.0` は 1.x 系すべてにマッチするので、breaking change が含まれた 1.x のマイナーアップで突然壊れる可能性。Raycast Store 側は登録時の `@raycast/api` 実バージョンで動作確認するため、開発機との差異が出る。
**Suggested fix**: 現時点で動作確認されている `1.x.y` を `~1.x` または exact 指定にし、依存更新は Dependabot / Renovate で明示的に上げる。lock file (E-03) と合わせて固定。

### E-05 (P2) — raycast-extension の `open()` 戻り値検査なし
**File**: `raycast-extension/src/start-recording.ts`, `start-translate.ts`, `open-settings.ts`, `stop-recording.ts`
**Symptom**: 4 ファイルすべてが
```ts
await open("koe://transcribe");
await showHUD("🎙 Koe: Voice Input Started");
```
の 2 行のみ。Koe.app が未インストールだと macOS は URL handler を解決できず `open` が reject、unhandled rejection が Raycast のログに残るがユーザーには「✓ HUD が出ないまま無反応」となる。
**Suggested fix**:
```ts
import { open, showHUD, showToast, Toast } from "@raycast/api";

export default async function Command() {
  try {
    await open("koe://transcribe");
    await showHUD("🎙 Koe: Voice Input Started");
  } catch (e) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Koe.app が見つかりません",
      message: "https://koe.example.com からインストールしてください",
    });
  }
}
```

### E-06 (P3) — content_scripts 未定義 (将来拡張時の備忘)
**File**: `browser-extension/manifest.json`
**Symptom**: `content_scripts` キーは現在無く、ページに対する XSS 経路はゼロ。問題なし。ただし将来「現在のページの選択テキストを Koe に送る」機能を足す場合、CSP / `world: "ISOLATED"` / `host_permissions` を明示する必要があり、本ファイルを改修する際の確認事項として記録。
**Suggested fix**: 現時点では変更不要。content_scripts 追加時に `"world": "ISOLATED"` + 最小限の `host_permissions` パターンを採用し、`<all_urls>` は避ける。

## Out of scope (this PR)
- ブラウザ拡張のアイコン pixel art / a11y
- Raycast preferences (API base URL 等) の追加
- Safari Web Extension への移植
- popup の i18n (現状は日本語固定)
