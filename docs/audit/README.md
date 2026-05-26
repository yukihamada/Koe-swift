# Koe-swift — friendly external audit

監査日: 2026-05-26
監査者: External contributor (PR を提出する fork のオーナー)
方法: 静的監査 (Explore + 実コード再 grep 検証)

> このディレクトリは、Koe-swift リポジトリ全体に対する第三者からの **「友好的な」監査レポート集** です。すべての指摘は **提案** であり、メンテナの判断で議論・修正・却下のいずれも歓迎します。

## 構成

| ファイル | 対象 | 件数 |
|---|---|---|
| [01-macos.md](./01-macos.md) | `Sources/Koe/`, `lib-macos/`, entitlements, Info.plist | 17 |
| [02-ios.md](./02-ios.md) | `Koe-iOS/` | 12 |
| [03-windows.md](./03-windows.md) | `Koe-windows/` | 8 |
| [04-extensions.md](./04-extensions.md) | `browser-extension/`, `raycast-extension/` | 6 |
| [05-build-ci.md](./05-build-ci.md) | `build*.sh`, `release.sh`, `fastlane/`, `.github/workflows/` | 15 |
| [06-site.md](./06-site.md) | `site/` (Fly.io 上の公式サイト) | 11 |
| [07-licensing.md](./07-licensing.md) | `LICENSE`, `README.md`, bundled dylibs, モデル DL | 10 |
| **合計** | | **79** |

## 優先度の凡例

- **P0** — 機密漏洩・任意コード実行・データ損失級。早期対応推奨。
- **P1** — 機能不全・コンプライアンス違反・配布物の信頼性低下。次のリリース候補。
- **P2** — UX 劣化・将来のリスク・コード保守性低下。
- **P3** — 軽微・備忘・コスメ。

## この PR で同梱する修正 (low-risk only)

本 PR は **「ドキュメントを読むためのチェンジ」を主眼に置いた包括 PR** です。挙動を変える修正は最小限に絞り、以下の 8 件のみ含めています:

1. `release.sh` 既に `set -euo pipefail` — 確認のみ
2. `build.sh` / `build-dmg.sh` に `set -ueo pipefail` を追加 (B-01)
3. `site/index.html` の全 `target="_blank"` に `rel="noopener noreferrer"` を付与 (S-02)
4. `site/robots.txt` / `site/sitemap.xml` を新規追加 (S-03)
5. ルート `LICENSE` を新規追加 (L-01)
6. ルート `THIRD_PARTY_LICENSES.md` を新規追加 (L-02, L-05, L-07)
7. `build.sh` の stapler 失敗 silent (`|| true`) を除去 (B-06)
8. `build.sh` の `/tmp/Koe-install.zip` を `mktemp` ベースに変更 (B-11)

それ以外の指摘 (特に挙動を変える P0/P1) は **本 PR には含めず**、メンテナと議論しつつ後続 PR (#2-#5) で扱うことを提案します。

## 後続 PR の提案 (本 PR マージ後にメンテナ承認のもとで)

- **PR #2 — macOS 安定性**: `Sources/Koe/` の force unwrap → guard、Carbon HotKey deinit、AVAudioEngine state machine
- **PR #3 — セキュリティ**: Keychain 移行 (M-04 / W-01)、Sparkle EdDSA appcast (M-01)、モデル SHA256 verify (M-05 / I-02 / W-02)
- **PR #4 — iOS App Store コンプライアンス**: App Groups (I-01)、背景録音 UX (I-04)、AVAudioSession 統一 (I-05)
- **PR #5 — Windows 強化**: SendInput foreground 検証 (W-04)、API key DPAPI (W-01)、自動更新 SignTool (W-03)

## 連絡

- PR コメントでの議論を歓迎します。指摘の取捨選択はメンテナの自由です。
- 認識違い・誤指摘・古い情報があればぜひ教えてください — 該当 .md を更新します。
