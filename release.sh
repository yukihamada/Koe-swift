#!/bin/bash
# release.sh — Koe リリース完全自動ワークフロー
# Usage: bash release.sh [version]
#   version省略時: パッチバージョンを自動インクリメント (2.8.0 → 2.8.1)
#
# ワークフロー:
#   1. プリフライトチェック（環境・署名・ブランチ・未コミット）
#   2. バージョン更新（全ファイル一括、漏れなし）
#   3. ビルド（PKG + DMG）
#   4. 署名・公証の検証
#   5. Git commit + tag + push
#   6. GitHub Release 作成
#   7. ポストチェック（リリースの存在確認）
set -euo pipefail
cd "$(dirname "$0")"

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
step() { echo -e "\n${CYAN}==> $1${NC}"; }

ERRORS=()

# ══════════════════════════════════════════════════════════════
# STEP 1: プリフライトチェック
# ══════════════════════════════════════════════════════════════
step "1/7 プリフライトチェック"

# 必須ツール
for cmd in git gh codesign xcrun pkgbuild productbuild hdiutil /usr/libexec/PlistBuddy; do
    if command -v "$cmd" &>/dev/null || [ -x "$cmd" ]; then
        pass "$cmd"
    else
        fail "$cmd が見つかりません"
    fi
done

# Developer ID Application 証明書
SIGN_ID="Developer ID Application: Yuki Hamada (5BV85JW8US)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    pass "署名証明書: Developer ID Application"
else
    fail "署名証明書が見つかりません: $SIGN_ID"
fi

# Developer ID Installer 証明書
if security find-identity -v -p basic 2>/dev/null | grep -q "Developer ID Installer"; then
    pass "署名証明書: Developer ID Installer"
else
    warn "Developer ID Installer がありません（PKGは未署名になります）"
fi

# Notarization 設定
if xcrun notarytool history --keychain-profile "notary" >/dev/null 2>&1; then
    pass "Notarization: keychain profile 'notary'"
else
    warn "Notarization の keychain profile がありません"
fi

# Git: クリーンな状態か
if [ -z "$(git status --porcelain -- ':!release.sh')" ]; then
    pass "Git: ワーキングツリーがクリーン"
else
    warn "Git: 未コミットの変更あり（リリースコミットに含まれます）"
fi

# Git: メインブランチか
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    pass "Git: $BRANCH ブランチ"
else
    warn "Git: $BRANCH ブランチ（main/master 以外）"
fi

# プリフライトにエラーがあれば中止
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo -e "\n${RED}プリフライトチェック失敗:${NC}"
    for e in "${ERRORS[@]}"; do echo "  - $e"; done
    exit 1
fi
echo -e "\n${GREEN}プリフライトチェック OK${NC}"

# ══════════════════════════════════════════════════════════════
# STEP 2: バージョン更新
# ══════════════════════════════════════════════════════════════
step "2/7 バージョン更新"

CURRENT=$(defaults read "$(pwd)/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
CURRENT_BUILD=$(defaults read "$(pwd)/Info.plist" CFBundleVersion 2>/dev/null || echo "0")

# バージョン自動計算（引数なしならパッチ+1）
if [ -n "${1:-}" ]; then
    VERSION="${1#v}"
else
    IFS='.' read -r major minor patch <<< "$CURRENT"
    VERSION="$major.$minor.$((patch + 1))"
    echo "バージョン自動計算: $CURRENT → $VERSION"
fi

TAG="v$VERSION"
NEW_BUILD=$((CURRENT_BUILD + 1))

# 同じタグが既に存在するか
if git tag -l "$TAG" | grep -q "$TAG"; then
    echo -e "${YELLOW}警告: タグ $TAG は既に存在します。上書きします。${NC}"
fi

# ── 全ファイル一括更新 ──
VERSION_FILES=(
    "Info.plist"
    "project-macos.yml"
    "Koe-macOS.xcodeproj/project.pbxproj"
)

# Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Info.plist
pass "Info.plist → $VERSION (build $NEW_BUILD)"

# project-macos.yml
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project-macos.yml
pass "project-macos.yml → $VERSION"

# Xcode project.pbxproj
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/g" Koe-macOS.xcodeproj/project.pbxproj
PBXPROJ_COUNT=$(grep -c "MARKETING_VERSION = $VERSION;" Koe-macOS.xcodeproj/project.pbxproj)
pass "project.pbxproj → $VERSION ($PBXPROJ_COUNT 箇所)"

# ── バージョン整合性の検証 ──
echo ""
echo "バージョン整合性チェック:"
V_PLIST=$(defaults read "$(pwd)/Info.plist" CFBundleShortVersionString)
V_YML=$(grep 'MARKETING_VERSION:' project-macos.yml | head -1 | sed 's/.*"\(.*\)"/\1/')
V_PBX=$(grep 'MARKETING_VERSION = ' Koe-macOS.xcodeproj/project.pbxproj | head -1 | sed 's/.*= \(.*\);/\1/' | tr -d ' ')

for label_val in "Info.plist:$V_PLIST" "project-macos.yml:$V_YML" "project.pbxproj:$V_PBX"; do
    label="${label_val%%:*}"
    val="${label_val#*:}"
    if [ "$val" = "$VERSION" ]; then
        pass "$label = $val"
    else
        fail "$label = $val (expected $VERSION)"
        exit 1
    fi
done

# ══════════════════════════════════════════════════════════════
# STEP 3: ビルド
# ══════════════════════════════════════════════════════════════
step "3/7 ビルド (PKG + DMG)"

rm -rf build-macos/Koe.app

echo "--- PKG ビルド ---"
bash build-pkg.sh

echo ""
echo "--- DMG ビルド ---"
hdiutil info 2>/dev/null | grep "Volumes/Koe" | awk '{print $NF}' | while read v; do
    hdiutil detach "$v" -force 2>/dev/null || true
done
rm -f Koe-Installer-rw.dmg Koe-Installer.dmg
bash build-dmg.sh

# ── ビルド成果物の確認 ──
for artifact in Koe.pkg Koe-Installer.dmg; do
    if [ -f "$artifact" ]; then
        SIZE=$(du -h "$artifact" | cut -f1)
        pass "$artifact ($SIZE)"
    else
        fail "$artifact が見つかりません"
        exit 1
    fi
done

# ══════════════════════════════════════════════════════════════
# STEP 4: 署名・公証の検証
# ══════════════════════════════════════════════════════════════
step "4/7 署名・公証の検証"

# App の署名チェック
APP_PATH="build-macos/Koe.app"
if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | grep "Authority=Developer ID" | head -1 || true)
    if [ -n "$AUTHORITY" ]; then
        pass "App 署名: Developer ID"
    else
        warn "App 署名: Developer ID ではない可能性"
    fi
else
    fail "App の署名検証に失敗"
fi

# バージョン確認
APP_VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
if [ "$APP_VERSION" = "$VERSION" ]; then
    pass "App バージョン: $APP_VERSION"
else
    fail "App バージョン不一致: $APP_VERSION (expected $VERSION)"
    exit 1
fi

# PKG のステープル確認
if xcrun stapler validate Koe.pkg 2>/dev/null; then
    pass "PKG: Notarization stapled"
else
    warn "PKG: Notarization ステープルなし"
fi

# DMG のステープル確認
if xcrun stapler validate Koe-Installer.dmg 2>/dev/null; then
    pass "DMG: Notarization stapled"
else
    warn "DMG: Notarization ステープルなし"
fi

# ══════════════════════════════════════════════════════════════
# STEP 5: Git commit + tag + push
# ══════════════════════════════════════════════════════════════
step "5/7 Git commit + tag + push"

git add Info.plist project-macos.yml Koe-macOS.xcodeproj/project.pbxproj
if git diff --cached --quiet; then
    warn "バージョンファイルに差分なし（既にコミット済み？）"
else
    git commit -m "Release $TAG"
    pass "コミット: Release $TAG"
fi

git tag -f "$TAG"
pass "タグ: $TAG"

git push origin HEAD --tags -f
pass "プッシュ完了"

# ══════════════════════════════════════════════════════════════
# STEP 6: GitHub Release 作成
# ══════════════════════════════════════════════════════════════
step "6/7 GitHub Release 作成"

# リリースノートの自動生成
PREV_TAG=$(git tag --sort=-version:refname | grep -v "$TAG" | head -1)
if [ -n "$PREV_TAG" ]; then
    NOTES=$(git log --pretty=format:"- %s" "$PREV_TAG..HEAD" -- . ':!*.pkg' ':!*.dmg' | head -20)
else
    NOTES="Initial release"
fi

RELEASE_BODY="$(cat <<EOF
## Koe $TAG

### Changes
$NOTES

### Install
- **PKG (推奨)**: \`Koe.pkg\` をダブルクリック → インストーラーの指示に従う
- **DMG**: \`Koe-Installer.dmg\` を開いて Koe.app を Applications にドラッグ

### Requirements
- macOS 13.0+
- Apple Silicon (M1/M2/M3/M4)
EOF
)"

if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" Koe.pkg Koe-Installer.dmg --clobber
    pass "既存リリース $TAG を更新"
else
    gh release create "$TAG" Koe.pkg Koe-Installer.dmg \
        --title "Koe $TAG" \
        --notes "$RELEASE_BODY"
    pass "リリース $TAG を作成"
fi

# ══════════════════════════════════════════════════════════════
# STEP 7: ポストチェック
# ══════════════════════════════════════════════════════════════
step "7/7 ポストチェック"

# GitHub Release の存在確認
if gh release view "$TAG" >/dev/null 2>&1; then
    pass "GitHub Release $TAG が存在"
else
    fail "GitHub Release $TAG が見つかりません"
fi

# アセットの確認
ASSETS=$(gh release view "$TAG" --json assets -q '.assets[].name' 2>/dev/null)
for expected in Koe.pkg Koe-Installer.dmg; do
    if echo "$ASSETS" | grep -q "$expected"; then
        pass "アセット: $expected"
    else
        fail "アセット $expected がリリースにありません"
    fi
done

# AutoUpdater 互換性チェック（tag_name が "v" で始まるか）
RELEASE_TAG=$(gh release view "$TAG" --json tagName -q '.tagName' 2>/dev/null)
if [[ "$RELEASE_TAG" == v* ]]; then
    pass "AutoUpdater 互換: tag=$RELEASE_TAG"
else
    warn "AutoUpdater: tag に 'v' プレフィックスなし"
fi

# ══════════════════════════════════════════════════════════════
# 完了サマリー
# ══════════════════════════════════════════════════════════════
RELEASE_URL="https://github.com/yukihamada/Koe-swift/releases/tag/$TAG"

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Koe $TAG リリース完了${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "  Version:  $VERSION (build $NEW_BUILD)"
echo "  Tag:      $TAG"
echo "  PKG:      $(du -h Koe.pkg | cut -f1)"
echo "  DMG:      $(du -h Koe-Installer.dmg | cut -f1)"
echo "  URL:      $RELEASE_URL"
echo ""

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo -e "${YELLOW}警告:${NC}"
    for e in "${ERRORS[@]}"; do echo "  - $e"; done
fi
