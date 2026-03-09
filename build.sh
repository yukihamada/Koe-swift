#!/bin/bash
set -e

APP="Koe.app"
cd "$(dirname "$0")"

echo "Building Koe..."
# Keep existing bundle (preserves Accessibility permission) — only overwrite binary
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

swiftc Sources/Koe/*.swift \
    -framework AppKit \
    -framework AVFoundation \
    -framework Speech \
    -framework SwiftUI \
    -target arm64-apple-macos13.0 \
    -O \
    -o "$APP/Contents/MacOS/Koe"

# Sign with developer certificate (keeps Accessibility permission across rebuilds)
codesign --force --sign "F1EFBA93D51A3F2204A9E25679E1D77BA22DC59C" --deep "$APP" 2>&1 | grep -v "replacing" || true

echo "✓ Built and signed $APP"
echo "→ Launching..."
pkill -9 Koe 2>/dev/null
sleep 0.5
# Launch directly (not via open) so stdout/stderr is captured
nohup "$APP/Contents/MacOS/Koe" >> ~/Desktop/koe_debug.log 2>&1 &
echo "Koe PID: $!"
echo "Log: ~/Desktop/koe_debug.log"
