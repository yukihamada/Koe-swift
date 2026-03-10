#!/bin/bash
set -e

APP="Koe.app"
cd "$(dirname "$0")"

echo "Building Koe..."
# Keep existing bundle (preserves Accessibility permission) — only overwrite binary
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

# Copy app icon
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP/Contents/Resources/"
fi

# whisper.cpp library paths (libinternal preferred, fallback to lib)
WHISPER_LIB="/opt/homebrew/opt/whisper-cpp/libinternal"
if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
    WHISPER_LIB="/opt/homebrew/opt/whisper-cpp/lib"
fi
if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
    WHISPER_LIB="/opt/homebrew/lib"
fi
GGML_INCLUDE="/opt/homebrew/include"

# Verify whisper dylib exists
if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
    echo "⚠ libwhisper.dylib not found"
    echo "  Install: brew install whisper-cpp"
    exit 1
fi

# llama.cpp library paths
LLAMA_LIB="/opt/homebrew/lib"
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
    LLAMA_LIB="/opt/homebrew/opt/llama.cpp/lib"
fi

# Verify llama dylib exists
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
    echo "⚠ libllama.dylib not found at $LLAMA_LIB"
    echo "  Install: brew install llama.cpp"
    exit 1
fi

swiftc Sources/Koe/*.swift \
    -I Sources/CWhisper \
    -I Sources/CLlama \
    -L "$WHISPER_LIB" \
    -L "$LLAMA_LIB" \
    -lwhisper \
    -lllama \
    -lggml \
    -lggml-base \
    -framework AppKit \
    -framework AVFoundation \
    -framework Speech \
    -framework SwiftUI \
    -framework Metal \
    -framework Accelerate \
    -framework UserNotifications \
    -framework ServiceManagement \
    -target arm64-apple-macos13.0 \
    -O \
    -o "$APP/Contents/MacOS/Koe"

# Embed whisper + llama dylibs in app bundle for self-contained distribution
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
for lib in libwhisper.dylib libggml.dylib libggml-base.dylib libggml-cpu.dylib libggml-blas.dylib libggml-metal.dylib; do
    if [ -f "$WHISPER_LIB/$lib" ]; then
        cp "$WHISPER_LIB/$lib" "$FRAMEWORKS/"
    fi
done
# llama.cpp dylib
if [ -f "$LLAMA_LIB/libllama.dylib" ]; then
    cp "$LLAMA_LIB/libllama.dylib" "$FRAMEWORKS/"
fi

# Fix dylib rpaths so the app finds embedded libraries
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Koe" 2>/dev/null || true

# Update dylib install names to use @rpath
for lib in "$FRAMEWORKS"/*.dylib; do
    libname=$(basename "$lib")
    install_name_tool -id "@rpath/$libname" "$lib" 2>/dev/null || true
done

# Fix inter-dylib references (libwhisper → libggml etc.)
for lib in "$FRAMEWORKS"/*.dylib; do
    for dep in libggml.dylib libggml-base.dylib libggml-cpu.dylib libggml-blas.dylib libggml-metal.dylib libwhisper.dylib libllama.dylib; do
        # Try to change references from various possible original paths
        install_name_tool -change "$WHISPER_LIB/$dep" "@rpath/$dep" "$lib" 2>/dev/null || true
        install_name_tool -change "$LLAMA_LIB/$dep" "@rpath/$dep" "$lib" 2>/dev/null || true
        install_name_tool -change "@rpath/$dep" "@rpath/$dep" "$lib" 2>/dev/null || true
        # Also handle versioned names
        for versioned in libwhisper.1.dylib libwhisper.1.7.5.dylib libllama.0.dylib; do
            install_name_tool -change "$WHISPER_LIB/$versioned" "@rpath/libwhisper.dylib" "$lib" 2>/dev/null || true
            install_name_tool -change "$LLAMA_LIB/$versioned" "@rpath/libllama.dylib" "$lib" 2>/dev/null || true
        done
    done
done

# Copy Metal shader if exists
METAL_SHADER="$WHISPER_LIB/ggml-metal.metal"
if [ -f "$METAL_SHADER" ]; then
    cp "$METAL_SHADER" "$APP/Contents/Resources/"
fi
# Also check for compiled metallib
for mlib in "$WHISPER_LIB"/ggml*.metallib "$WHISPER_LIB"/../share/whisper-cpp/*.metallib; do
    if [ -f "$mlib" ]; then
        cp "$mlib" "$APP/Contents/Resources/"
    fi
done

# Sign everything — use Developer ID if available, else ad-hoc
SIGN_ID="Developer ID Application: Yuki Hamada (5BV85JW8US)"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    SIGN_ID="-"
    echo "⚠ Developer ID not found, using ad-hoc signing"
fi
ENTITLEMENTS="entitlements.plist"

# Create entitlements if not exists
if [ ! -f "$ENTITLEMENTS" ]; then
cat > "$ENTITLEMENTS" << 'ENTXML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTXML
fi

# Signing flags — ad-hoc can't use --timestamp
SIGN_FLAGS="--force --sign $SIGN_ID --options runtime"
if [ "$SIGN_ID" != "-" ]; then
    SIGN_FLAGS="$SIGN_FLAGS --timestamp"
fi

# Sign dylibs first (inside-out signing)
for lib in "$FRAMEWORKS"/*.dylib; do
    eval codesign $SIGN_FLAGS "$lib"
done

# Sign the main binary and app bundle
eval codesign $SIGN_FLAGS --entitlements "$ENTITLEMENTS" --deep "$APP"

echo "✓ Built and signed $APP (with embedded whisper.cpp)"

if [ "$1" = "--no-launch" ] || [ -n "$CI" ]; then
    echo "Build complete (no launch)"
    exit 0
fi

echo "→ Launching..."
pkill -9 Koe 2>/dev/null
sleep 0.5
# Launch directly (not via open) so stdout/stderr is captured
nohup "$APP/Contents/MacOS/Koe" >> ~/Desktop/koe_debug.log 2>&1 &
echo "Koe PID: $!"
echo "Log: ~/Desktop/koe_debug.log"
