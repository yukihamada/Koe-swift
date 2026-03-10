#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Koe"
DMG_NAME="Koe-Installer"
VOLUME_NAME="Koe — 声で入力"

# Build the app first
bash build.sh

# Kill launched instance (build.sh auto-launches)
pkill -9 Koe 2>/dev/null || true
sleep 0.3

# Create a temporary directory for DMG contents
DMG_DIR=$(mktemp -d)
trap 'rm -rf "$DMG_DIR"' EXIT

cp -R "${APP_NAME}.app" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

# Create DMG
hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov -format UDZO \
    "${DMG_NAME}.dmg"

# Notarize if credentials are available
if [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
    echo "Notarizing..."
    xcrun notarytool submit "${DMG_NAME}.dmg" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait
    xcrun stapler staple "${DMG_NAME}.dmg"
    echo "Notarization complete"
else
    echo "Skipping notarization (set APPLE_ID, APPLE_PASSWORD, TEAM_ID)"
fi

echo ""
echo "Created: ${DMG_NAME}.dmg ($(du -h "${DMG_NAME}.dmg" | cut -f1))"
echo "  -> Double-click to install, drag Koe.app to Applications"
