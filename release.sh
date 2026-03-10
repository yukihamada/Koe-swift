#!/bin/bash
# release.sh — バージョン更新 → ビルド → 公証 → GitHub Release を一発で実行
# Usage: bash release.sh 2.1.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    CURRENT=$(defaults read "$(pwd)/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
    echo "Usage: bash release.sh <version>"
    echo "  Current version: $CURRENT"
    echo "  Example: bash release.sh 2.1.0"
    exit 1
fi

# Strip leading 'v' if present
VERSION="${VERSION#v}"
TAG="v$VERSION"

echo "==> Releasing Koe $TAG"

# 1. Update Info.plist version
CURRENT_BUILD=$(defaults read "$(pwd)/Info.plist" CFBundleVersion 2>/dev/null || echo "0")
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Info.plist
echo "✓ Info.plist updated: v$VERSION (build $NEW_BUILD)"

# 2. Build PKG (includes app build + notarization)
echo "==> Building PKG..."
bash build-pkg.sh

# 3. Build DMG (includes app build + notarization)
echo "==> Building DMG..."
# Clean up any mounted volumes first
hdiutil info 2>/dev/null | grep "Volumes/Koe" | awk '{print $NF}' | while read v; do
    hdiutil detach "$v" -force 2>/dev/null || true
done
rm -f Koe-Installer-rw.dmg Koe-Installer.dmg
bash build-dmg.sh

# 4. Verify both files exist
[ -f "Koe.pkg" ] || { echo "ERROR: Koe.pkg not found"; exit 1; }
[ -f "Koe-Installer.dmg" ] || { echo "ERROR: Koe-Installer.dmg not found"; exit 1; }

echo ""
echo "==> Artifacts ready:"
echo "  Koe.pkg          $(du -h Koe.pkg | cut -f1)"
echo "  Koe-Installer.dmg $(du -h Koe-Installer.dmg | cut -f1)"

# 5. Git commit + tag
git add Info.plist
git commit -m "Release $TAG" || true
git tag -f "$TAG"
git push origin HEAD --tags -f

# 6. Create/update GitHub Release
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> Updating existing release $TAG..."
    gh release upload "$TAG" Koe.pkg Koe-Installer.dmg --clobber
else
    echo "==> Creating release $TAG..."
    gh release create "$TAG" Koe.pkg Koe-Installer.dmg \
        --title "Koe $TAG" \
        --generate-notes
fi

echo ""
echo "✓ Released Koe $TAG"
echo "  https://github.com/yukihamada/Koe-swift/releases/tag/$TAG"
