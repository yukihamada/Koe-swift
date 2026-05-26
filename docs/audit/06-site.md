# 06 — Site audit

検証対象: `site/index.html`, `site/pricing.html`, `site/support.html`,
`site/vs-notta.html`, `site/og.html`, `site/src/main.rs`, `site/Dockerfile`,
`site/fly.toml`, `site/install.sh`
監査日: 2026-05-26
方法: 静的監査 (Explore + 再 grep 検証)

> This is a friendly audit prepared by an external contributor. All
> suggestions are non-binding; happy to discuss, revise, or drop any item.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| S-01 | P1 | サーバ側で security response header (HSTS / X-Content-Type-Options / Referrer-Policy / CSP / Permissions-Policy) を一切付与していない | `site/src/main.rs` |
| S-02 | P1 | `<a target="_blank">` 全 10 箇所で `rel="noopener noreferrer"` 欠落 | `site/index.html` (10 occurrences) |
| S-03 | P2 | `robots.txt` / `sitemap.xml` が存在せず、`canonical` だけが頼り | `site/` |
| S-04 | P2 | Google Fonts を render-blocking で読み込んでおり LCP/CLS に悪影響 | `site/index.html:79-81` |
| S-05 | P2 | `prefers-reduced-motion` を尊重していないアニメーション (`hero-bar` keyframe `hero-wave`) | `site/index.html:111-121` |
| S-06 | P2 | `Dockerfile` がベースイメージを SHA pin しておらず非 root ユーザでも動かない | `site/Dockerfile:1,18` |
| S-07 | P2 | `fly.toml` に `min_machines_running = 0` で cold start、TLS-only / HSTS preload 未設定 | `site/fly.toml` |
| S-08 | P3 | `install.sh` を `curl \| sh` 経路で配布する場合の改ざんリスクを README で警告していない (要 README 側確認、site 側でも `/install.sh` をホスト) | `site/install.sh`, `site/src/main.rs` |
| S-09 | P3 | analytics endpoint (`track_event`) で User-Agent / Referer の長さに上限なし | `site/src/main.rs` |
| S-10 | P3 | `<meta name="theme-color">` のダーク固定で、システム light モード時にナビが浮く | `site/index.html:33` |
| S-11 | P3 | `<script type="application/ld+json">` の `softwareVersion: "2.8.0"` がデプロイ毎に手動更新 (リリース時 drift する) | `site/index.html:60` |

## 詳細

### S-01 (P1) — サーバ側の security header が空

**File**: `site/src/main.rs`
**Symptom**: `axum::Router` を `/`, `/pricing`, `/vs-notta`, `/support`, `/og.png`, `/install.sh`, `/api/event`, `/api/stats` で組んでいるが、レスポンス header に security 系を一切足していない (CORS の `access-control-allow-headers` のみ L150 で付与)。
**Impact**:
- HSTS なし: `fly.toml` の `force_https = true` はリダイレクトのみで、初回 HTTP リクエストが MITM 対象。
- `X-Content-Type-Options: nosniff` なし: `og.png` を text として誤判定された場合の MIME confusion。
- `Referrer-Policy` なし: GitHub やアフィリエイト遷移時に full URL が送られる。
- CSP なし: 万一 XSS 経路を作った場合の被害が無制限。

**Suggested fix**: `tower-http` の `SetResponseHeaderLayer` で middleware を 1 段。
```rust
use tower_http::set_header::SetResponseHeaderLayer;
use axum::http::{HeaderName, HeaderValue};

let security_headers = ServiceBuilder::new()
    .layer(SetResponseHeaderLayer::overriding(
        HeaderName::from_static("strict-transport-security"),
        HeaderValue::from_static("max-age=63072000; includeSubDomains; preload"),
    ))
    .layer(SetResponseHeaderLayer::overriding(
        HeaderName::from_static("x-content-type-options"),
        HeaderValue::from_static("nosniff"),
    ))
    .layer(SetResponseHeaderLayer::overriding(
        HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("strict-origin-when-cross-origin"),
    ))
    .layer(SetResponseHeaderLayer::overriding(
        HeaderName::from_static("content-security-policy"),
        HeaderValue::from_static(
            "default-src 'self'; \
             style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; \
             font-src 'self' https://fonts.gstatic.com; \
             img-src 'self' data: https:; \
             script-src 'self' 'unsafe-inline'; \
             connect-src 'self'; \
             frame-ancestors 'none'"
        ),
    ));
let app = Router::new()...
    .layer(security_headers);
```
(`'unsafe-inline'` は現行 `<style>` / `<script>` インラインを許容するため。中長期的には extract したい。)

### S-02 (P1) — `target="_blank"` + `rel` 欠落

**File**: `site/index.html`
**Symptom**: `grep -c 'target="_blank"'` = 10, `grep -c 'rel="noopener'` = 0。該当行: 318, 715, 720, 745, 762, 763, 764, 765, 770, 771。
**Impact**: モダンブラウザは reverse tabnabbing を自動で塞ぐが、Safari 古め / アプリ内 WebView では `window.opener` が露出。`https://x.com/intent/tweet?...` (745) は外部ドメインなので低リスクだが、`https://enablerdao.com` / `https://elio.love` 等は同様の懸念。
**Suggested fix**: 全 10 箇所に `rel="noopener noreferrer"` を付与。`<head>` に CSP `Referrer-Policy: strict-origin-when-cross-origin` を併用 (S-01 と一括)。

### S-03 (P2) — `robots.txt` / `sitemap.xml` 不在

**File**: `site/` (ファイル無し)
**Symptom**: `ls site/` で `robots.txt`, `sitemap.xml` ともに存在しない。`<link rel="canonical">` (L11) のみ。
**Impact**:
- `pricing.html`, `vs-notta.html`, `support.html` のクロール優先度を制御できない。
- 内部リンク (`/pricing`, `/vs-notta`) と HTML 直リンク (`/pricing.html`) の重複インデックスリスク。

**Suggested fix**: `site/` に追加し、`main.rs` で `Router::route("/robots.txt", get(robots))` / `/sitemap.xml` をハンドル:
```
# robots.txt
User-agent: *
Allow: /
Disallow: /api/
Sitemap: https://koe.elio.love/sitemap.xml
```

### S-04 (P2) — Google Fonts が render-blocking

**File**: `site/index.html:79-81`
**Symptom**:
```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Noto+Sans+JP:wght@400;500;700;800&display=swap" rel="stylesheet">
```
**Impact**: `font-display: swap` が指定されているので FOIT は回避されているが、CSS リクエスト自体は render-blocking。Noto Sans JP は約 1MB/weight でモバイルで LCP に乗る。
**Suggested fix**:
- 必要 weight だけに絞る (Inter 400/600/800, Noto 400/700)。
- `<link rel="preload" as="style" onload="this.rel='stylesheet'">` パターンで非ブロッキング化。
- もしくは `self host` で Fly のエッジから配信 (3rd party DNS 解決を 1 hop 減らせる)。

### S-05 (P2) — `prefers-reduced-motion` 未尊重

**File**: `site/index.html:111-121`, conn-pulse L191 等
**Symptom**: `@keyframes hero-wave` が無条件で 1.4 秒ループ。`@media (prefers-reduced-motion: reduce)` を一切定義していない。
**Impact**: 前庭感受性のあるユーザに不快感。WCAG 2.3.3 (Animation from Interactions) / iOS Reduce Motion 設定を無視。
**Suggested fix**:
```css
@media (prefers-reduced-motion: reduce) {
  .hero-bar, .connection-line::before, .reveal { animation: none !important; transition: none !important; }
  .hero-bar { transform: none; opacity: 0.7; }
}
```

### S-06 (P2) — Dockerfile が SHA pin 無し + root 実行

**File**: `site/Dockerfile:1,18`
**Symptom**: `FROM rust:1.85-slim AS builder` / `FROM debian:bookworm-slim` ともに digest 無し。`USER` 指令無しで root のまま CMD。
**Impact**:
- digest 無しはサプライチェーン的に rebuild が再現しない。
- root 実行はコンテナエスケープ時の権限拡大。

**Suggested fix**:
```dockerfile
FROM rust:1.85-slim@sha256:<pinned> AS builder
...
FROM debian:bookworm-slim@sha256:<pinned>
RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home koe
USER 10001
COPY --from=builder /app/target/release/koe-site /usr/local/bin/koe-site
ENV PORT=8080
EXPOSE 8080
CMD ["koe-site"]
```

### S-07 (P2) — `fly.toml` の HSTS preload / `[[services]]` 細部

**File**: `site/fly.toml`
**Symptom**: `force_https = true` のみ。`[http_service.http_options]` の `response.headers` ブロック未使用。`auto_stop_machines = "stop"` + `min_machines_running = 0` で cold start (256mb VM)。
**Impact**: cold start 時 TTFB > 1s で LCP が悪化。HSTS は app server で付ければ済むので fly 側は必須ではないが、`min_machines_running = 1` を検討。
**Suggested fix**: S-01 で app server から HSTS を返す。負荷に応じて `min_machines_running = 1` (= $2/月ほど追加コスト)。

### S-08 (P3) — `install.sh` の改ざんリスク警告

**File**: `site/install.sh`, `site/src/main.rs:18` (`INSTALL_SH`)
**Symptom**: サイトが `/install.sh` を配信し、おそらく `curl https://koe.elio.love/install.sh | sh` での導線を提供。SHA-256 や GPG 署名公開なし。
**Impact**: ドメイン乗っ取り / fly account 乗っ取り時に任意コード配布。
**Suggested fix**:
- GitHub Releases から DL する形に誘導 (`gh release download` or `curl -fL https://github.com/yukihamada/Koe-swift/releases/download/vX.Y.Z/install.sh`)。
- ページに SHA-256 を併記し、`install.sh` 内で自身の SHA を表示。

### S-09 (P3) — analytics endpoint の入力検証

**File**: `site/src/main.rs:71-79` (`EventPayload`), `track_event` 関数
**Symptom**: `referrer`, `path`, `app_version` が任意長 String で受理され、`DayStats.referrers: HashMap<String, u64>` に key として蓄積される。
**Impact**: スパム流入で `HashMap` が無制限拡大しメモリ圧迫 (256mb VM)。
**Suggested fix**:
- 各フィールドに長さ上限 (e.g. 256 chars) + 制御文字除去。
- `referrers` HashMap のサイズに上限 (1k entries 超えたら eviction or "other" バケットへ集約)。

### S-10 (P3) — `theme-color` がダーク固定

**File**: `site/index.html:33`
**Symptom**: `<meta name="theme-color" content="#0a0a0a">`。
**Impact**: Safari 17+ で `prefers-color-scheme: light` 利用時に Safari toolbar とサイト nav の繋ぎが破綻 (cosmetic)。
**Suggested fix**:
```html
<meta name="theme-color" content="#0a0a0a" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
```

### S-11 (P3) — JSON-LD `softwareVersion` が手動更新

**File**: `site/index.html:60`
**Symptom**: `"softwareVersion": "2.8.0"` (release.sh L317 のバージョンと drift)。`v2.9.0` は L741 / L794 でも参照されており、複数箇所に散らばっている。
**Impact**: 構造化データと実際の最新リリースが乖離し、Google Knowledge Graph で古いバージョンが提示される。
**Suggested fix**: `site/src/main.rs` でビルド時に `gh release view --json tagName` の結果を `include_str!` 相当で埋め込み、HTML 配信時に `{{VERSION}}` を置換するレンダラを噛ます。最低限 `release.sh` に sed step を追加して index.html / pricing.html を更新。

## Out of scope (this PR)

- `pricing.html` / `vs-notta.html` / `support.html` の個別監査 (本パスでは `index.html` のみ詳細チェック)
- analytics の永続化先 (現在 in-memory のみで再起動消失) のアーキテクチャ変更
- Fly.io から Cloudflare Pages / Workers への移行検討
- i18n 文言の英訳精度
- og.svg / og.png の差分自動化
