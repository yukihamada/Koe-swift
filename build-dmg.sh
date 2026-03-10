#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="Koe"
DMG_NAME="Koe-Installer"
VOLUME_NAME="Koe — 声で入力"
BG_SCRIPT="create-dmg-background.swift"
BG_IMG="/tmp/koe-dmg-bg.png"
WIN_W=600
WIN_H=400

# 1. Build the app
bash build.sh --no-launch

# 2. Generate DMG background
echo "Generating DMG background..."
swift "$BG_SCRIPT" "$BG_IMG"

# 3. Prepare DMG contents
DMG_DIR=$(mktemp -d)
trap 'rm -rf "$DMG_DIR"' EXIT

cp -R "${APP_NAME}.app" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"

# Hidden background folder
mkdir -p "${DMG_DIR}/.background"
cp "$BG_IMG" "${DMG_DIR}/.background/bg.png"

# 4. Create read-write DMG first
rm -f "${DMG_NAME}.dmg" "${DMG_NAME}-rw.dmg"
hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov -format UDRW \
    "${DMG_NAME}-rw.dmg"

# 5. Mount and customize with AppleScript
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "${DMG_NAME}-rw.dmg" | grep "Volumes" | awk -F'\t' '{print $NF}')
echo "Mounted: ${MOUNT_DIR}"

# Set custom icon positions, background, window size
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, $((100 + WIN_W)), $((100 + WIN_H))}

        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set background picture of theViewOptions to file ".background:bg.png"

        -- Koe.app on left, Applications on right
        set position of item "${APP_NAME}.app" of container window to {155, 200}
        set position of item "Applications" of container window to {445, 200}

        close
        open
        update without registering applications
    end tell
end tell
APPLESCRIPT

# Wait for Finder to apply
sleep 2

# Set volume icon
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${MOUNT_DIR}/.VolumeIcon.icns"
    SetFile -c icnC "${MOUNT_DIR}/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "${MOUNT_DIR}" 2>/dev/null || true
fi

sync
hdiutil detach "${MOUNT_DIR}" -quiet

# 6. Convert to compressed read-only DMG
hdiutil convert "${DMG_NAME}-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "${DMG_NAME}.dmg"
rm -f "${DMG_NAME}-rw.dmg"

# 7. Notarize (prefer keychain profile, fallback to env vars)
if xcrun notarytool history --keychain-profile "notary" >/dev/null 2>&1; then
    echo "Notarizing (keychain profile)..."
    xcrun notarytool submit "${DMG_NAME}.dmg" --keychain-profile "notary" --wait
    xcrun stapler staple "${DMG_NAME}.dmg"
    echo "Notarization complete"
elif [ -n "$APPLE_ID" ] && [ -n "$APPLE_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
    echo "Notarizing (env vars)..."
    xcrun notarytool submit "${DMG_NAME}.dmg" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait
    xcrun stapler staple "${DMG_NAME}.dmg"
    echo "Notarization complete"
else
    echo "Skipping notarization (run: xcrun notarytool store-credentials \"notary\")"
fi

echo ""
echo "Created: ${DMG_NAME}.dmg ($(du -h "${DMG_NAME}.dmg" | cut -f1))"
echo "  -> Custom background, icon layout, drag-to-install"
