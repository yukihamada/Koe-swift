# 07 — Licensing audit

検証対象: ルート (`LICENSE` 不在を含む), `README.md`, `Sources/Koe/ModelDownloader.swift`,
`build.sh` (bundled dylibs), `Koe-windows/Cargo.toml`, 配布物 (`Koe.pkg` / `Koe-Installer.dmg`)
監査日: 2026-05-26
方法: 静的監査 (Explore + 再 grep 検証)

> This is a friendly audit prepared by an external contributor. All
> suggestions are non-binding; happy to discuss, revise, or drop any item.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| L-01 | P1 | ルートに `LICENSE` ファイルが存在せず、README badge / JSON-LD で MIT を宣言しているのみ | repo root |
| L-02 | P1 | bundled dylibs (`libwhisper.dylib`, `libllama.dylib`, `libggml*.dylib`) を MIT クレジット無しで配布 | `build.sh:179-216`, `Koe.app/Contents/Frameworks/*` |
| L-03 | P2 | アプリ内に "About" / "Licenses" / "Acknowledgements" 画面が無く、エンドユーザが third-party license を確認できない | `Sources/Koe/` |
| L-04 | P2 | DL する Whisper モデル (`huggingface.co/ggerganov/whisper.cpp/...`) の license / source 表示なし | `Sources/Koe/ModelDownloader.swift:114-132` |
| L-05 | P2 | `Koe-windows` も `whisper-rs` 経由で whisper.cpp/ggml をリンクするが README / バイナリ配布物に MIT 通知無し | `Koe-windows/Cargo.toml:15`, `.github/workflows/windows-build.yml` |
| L-06 | P3 | README の MIT badge と JSON-LD の `"license": "https://opensource.org/licenses/MIT"` のみで、Copyright holder が明示されていない | `README.md:10`, `site/index.html:59` |
| L-07 | P3 | `NOTICE` / `THIRD_PARTY_LICENSES.md` ファイルが repo に無く、貢献者ライセンス整理の単一ソースが無い | repo root |
| L-08 | P3 | `Resources/oww_detector.py` (openWakeWord 連携) のライセンス所属が不明 | `Resources/oww_detector.py`, `build.sh:26-28` |
| L-09 | P3 | `fastlane/` / `fastlane-macos/` 配下に `Appfile` の Apple ID が含まれる場合 PII 漏洩リスク (要中身確認) | `fastlane/Appfile`, `fastlane-macos/Appfile` |
| L-10 | P3 | Site の `<meta name="author" content="Yuki Hamada">` と footer `Made by Enabler / enablerhq.com` で copyright holder が二重で曖昧 | `site/index.html:9,770-771` |

## 詳細

### L-01 (P1) — ルートに `LICENSE` ファイルが無い

**File**: repo root
**Symptom**: `ls LICENSE* COPYING*` で no match。README L10 で `![License](https://img.shields.io/badge/license-MIT-blue?...)` を提示し、`site/index.html:59` の JSON-LD で `"license": "https://opensource.org/licenses/MIT"` を宣言しているのみ。
**Impact**:
- GitHub の repo metadata 上、license が "MIT" として認識されない (sidebar 表示の License 欄が "No license" になる可能性)。
- 第三者が fork / 再配布する際の文面 (Copyright holder, year) が無く、MIT の Copyright Notice 要件を満たせない。
- "No license" は厳密には all rights reserved 扱いになるため、現在の README 主張と実態に齟齬。

**Suggested fix**: `LICENSE` をリポジトリ root に追加:
```
MIT License

Copyright (c) 2024-2026 Yuki Hamada / Enabler, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
... (MIT 標準文面)
```

### L-02 (P1) — bundled dylibs に MIT 通知無し

**File**: `build.sh:179-216`, `Koe.app/Contents/Frameworks/`
**Symptom**: `build.sh` が `libwhisper.dylib`, `libwhisper.coreml.dylib`, `libllama.dylib`, `libggml.dylib`, `libggml-base.dylib`, `libggml-cpu.dylib`, `libggml-blas.dylib`, `libggml-metal.dylib`, `libggml-hb.dylib`, `libggml-base-hb.dylib` を `Frameworks/` にコピー。これらは全て [ggerganov/whisper.cpp](https://github.com/ggerganov/whisper.cpp) / [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) / [ggerganov/ggml](https://github.com/ggerganov/ggml) (MIT) の成果物。
**Impact**: MIT ライセンス第 1 項:
> The above copyright notice and this permission notice shall be included
> in all copies or substantial portions of the Software.

配布する `Koe.pkg` / `Koe-Installer.dmg` は "copies" に該当し、whisper.cpp / llama.cpp / ggml の Copyright notice + permission notice 同梱が法的義務。現在の配布物にはこれが含まれない。
**Suggested fix**:
1. `Resources/THIRD_PARTY_LICENSES.txt` (もしくは `.rtf`) を新規作成し、whisper.cpp / llama.cpp / ggml の LICENSE 文面を貼る:
   ```
   ── whisper.cpp ──
   MIT License
   Copyright (c) 2023-2024 Georgi Gerganov
   <full MIT text>

   ── llama.cpp ──
   MIT License
   Copyright (c) 2023-2024 Georgi Gerganov
   <full MIT text>

   ── ggml ──
   MIT License
   Copyright (c) 2022-2024 Georgi Gerganov
   <full MIT text>
   ```
2. `build.sh` に `cp Resources/THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/"` を追加。
3. `build-pkg.sh` の welcome HTML (L63-77) で「OSS Licenses」リンクを置く、もしくは `productbuild --resources` で license として渡す。
4. 自動化したい場合は CI で `brew --prefix whisper-cpp`/`llama.cpp` の `LICENSE` を curl / cp で取得 → bundle。

### L-03 (P2) — アプリ内 "Licenses" UI 無し

**File**: `Sources/Koe/` (該当ファイル無し), `Sources/Koe/SettingsWindow.swift` 等
**Symptom**: `grep -rln "Acknowledgement\|Third.party\|Licenses" Sources/Koe/` でヒット無し (本監査では top-level grep のみ実施 / `tasks` で要再確認)。Settings 画面に license タブが見当たらない。
**Impact**: macOS App Store ガイドライン 5.0 系 + MIT の attribution 要件を考えると、エンドユーザが手元で third-party license を確認できる UI が望ましい。Apple は MAS 審査で `Third Party Acknowledgements` を求めることがある (今は緩いが)。
**Suggested fix**: SettingsWindow に "About" タブを足し、L-02 の `THIRD_PARTY_LICENSES.txt` を読んで scrollable TextView で表示。

### L-04 (P2) — モデル DL 時の出典・ライセンス表示無し

**File**: `Sources/Koe/ModelDownloader.swift:114-132`
**Symptom**:
```swift
url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
```
HuggingFace 上の ggerganov 公開モデルから直接 DL。元の Whisper モデルは OpenAI による MIT (model weights は別ライセンス論争があるが、ggerganov の repo 上では MIT として配布)。
**Impact**:
- DL UI / 設定画面で「出典: ggerganov/whisper.cpp on HuggingFace」「ライセンス: MIT」を表示すべき。
- HuggingFace の利用規約上 robots / rate-limit を考慮した DL 実装かは別途要確認。

**Suggested fix**:
- ModelDownloader の各 `WhisperModel` 構造体に `licenseURL: String` と `attribution: String` フィールドを足し、DL ダイアログに表示。
- 大型モデル (1.5GB) DL 前に "by downloading you agree to OpenAI Whisper / ggerganov terms" を一文置く。

### L-05 (P2) — Windows 側も同じ MIT 通知欠落

**File**: `Koe-windows/Cargo.toml:15`, `.github/workflows/windows-build.yml`
**Symptom**: `whisper-rs = "0.14"` が依存。`whisper-rs` は MIT/Apache-2.0 dual license で、内部で whisper.cpp/ggml の C++ コードを vendoring する。リリースされる `koe.exe` / `Koe-Setup.exe` には whisper.cpp + ggml のコードがバンドルされるが、配布物に LICENSE 同梱無し。
**Impact**: L-02 と同じ MIT 1 項違反。
**Suggested fix**:
- `Koe-windows/dist/` に `LICENSES/` ディレクトリを作り、`cargo about generate` や `cargo-deny` でビルド時に依存全部のライセンス文面を集約 → NSIS インストーラに同梱。
- `cargo about` 例:
  ```toml
  # Koe-windows/about.toml
  accepted = ["MIT", "Apache-2.0", "BSD-3-Clause", "Unicode-DFS-2016"]
  ```
  CI で `cargo about generate about.hbs > dist/LICENSES.html`。

### L-06 (P3) — Copyright holder が曖昧

**File**: `README.md:10`, `site/index.html:54-58,770-771`
**Symptom**:
- JSON-LD: `"author": {"@type": "Person", "name": "Yuki Hamada"}`
- Footer: `Made by Enabler` → `enablerhq.com`
- README には Copyright 表記無し。

**Impact**: 法人 (Enabler) と個人 (Yuki Hamada) のどちらが著作権者か不明確で、PR 受入時の DCO / CLA 設計に支障。商標 ("Koe", "声") の権利帰属も不明。
**Suggested fix**: L-01 の LICENSE で `Copyright (c) 2024-2026 Yuki Hamada / Enabler, Inc.` のように両方を明示し、README に同じ表記を入れる。

### L-07 (P3) — `THIRD_PARTY_LICENSES.md` / `NOTICE` 不在

**File**: repo root
**Symptom**: `grep -rln 'NOTICE\|THIRD_PARTY\|ACKNOWLEDGEMENT'` でヒット 0。
**Impact**: 開発者・コントリビュータが「どのライブラリがどのライセンスで使われているか」を把握する単一ドキュメントが無い。新しい依存追加時のライセンス互換チェックが属人化。
**Suggested fix**: `THIRD_PARTY_LICENSES.md` を repo に追加し、以下を列挙:
- whisper.cpp (MIT)
- llama.cpp (MIT)
- ggml (MIT)
- openWakeWord (Apache-2.0, `Resources/oww_detector.py` 経由)
- whisper-rs (MIT OR Apache-2.0, Windows)
- axum / tokio / serde 系 (MIT OR Apache-2.0, site)
- Inter font (OFL-1.1, embed/preconnect 経由)
- Noto Sans JP (OFL-1.1)

### L-08 (P3) — `oww_detector.py` のライセンス所属

**File**: `Resources/oww_detector.py`, `build.sh:26-28`
**Symptom**: `build.sh:27` で `cp Resources/oww_detector.py "$APP/Contents/Resources/"`。openWakeWord は Apache-2.0 だが、`oww_detector.py` のヘッダにライセンスコメントがあるか未確認。
**Impact**: Apache-2.0 は NOTICE ファイル要件があり、MIT より厳格 (元の NOTICE があれば derivative にも継承)。
**Suggested fix**: `oww_detector.py` 冒頭に SPDX-License-Identifier コメントを追加、必要なら openWakeWord 上流の NOTICE を `Resources/NOTICE` に複製。

### L-09 (P3) — `fastlane/Appfile` の PII 漏洩リスク

**File**: `fastlane/Appfile`, `fastlane-macos/Appfile`
**Symptom**: 本監査では中身未読 (top-level `ls` のみ)。fastlane の `Appfile` には通常 `apple_id "..."` / `team_id "..."` / `itc_team_id "..."` が記載される。
**Impact**: Apple ID メールアドレスが public repo に残ると spam / phishing 標的。
**Suggested fix**: 中身を確認し、Apple ID が plain で書かれているなら `ENV["APPLE_ID"]` 参照に置換 + `.env.local` を `.gitignore`。

### L-10 (P3) — Copyright holder 表記の二重化

**File**: `site/index.html:9,54-58,770-771`
**Symptom**: meta author "Yuki Hamada", JSON-LD author "Yuki Hamada", footer "Made by Enabler" / "enablerhq.com" / "MIT License" のみ。
**Impact**: 訪問者・SEO クローラ・LLM scrape にとって著作権帰属が読み取りづらい。
**Suggested fix**: footer に `© 2024-2026 Yuki Hamada / Enabler, Inc. — Released under the MIT License` を明示。

## Out of scope (this PR)

- 法人 (Enabler, Inc.) と個人著作権の正式な譲渡契約 / CLA 整備
- 商標 ("Koe", "声", 波形ロゴ) の登録状況
- 各国別の輸出規制 (whisper モデルは現状規制対象外と理解だが、輸出管理は別途確認)
- App Store 配布版での Apple の License Agreement (EULA) 整合
- HuggingFace Hub Terms of Service への準拠 (モデル DL レート / 商用利用条件)
- `raycast-extension/`, `browser-extension/` 配下の license (本監査では未踏)
