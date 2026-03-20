#!/bin/bash
set -e

cd "$(dirname "$0")"
APP="build-macos/Koe.app"

echo "Building Koe..."
# Build into build-macos/ (not project root) to keep workspace clean
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

# Copy app icon
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP/Contents/Resources/"
fi

# Homebrew prefix (Apple Silicon: /opt/homebrew, Intel: /usr/local)
BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")

# whisper.cpp library paths
# Prefer custom CoreML-enabled build, fallback to Homebrew
WHISPER_COREML_BUILD="/tmp/whisper.cpp/build"
if [ -f "$WHISPER_COREML_BUILD/src/libwhisper.dylib" ] && [ -f "$WHISPER_COREML_BUILD/src/libwhisper.coreml.dylib" ]; then
    echo "Using CoreML-enabled whisper.cpp build"
    WHISPER_LIB="$WHISPER_COREML_BUILD/src"
    GGML_LIB="$WHISPER_COREML_BUILD/ggml/src"
    GGML_METAL_LIB="$WHISPER_COREML_BUILD/ggml/src/ggml-metal"
    GGML_BLAS_LIB="$WHISPER_COREML_BUILD/ggml/src/ggml-blas"
    GGML_CPU_LIB="$WHISPER_COREML_BUILD/ggml/src"
    USE_COREML=1
else
    WHISPER_LIB="$BREW_PREFIX/opt/whisper-cpp/libinternal"
    if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
        WHISPER_LIB="$BREW_PREFIX/opt/whisper-cpp/lib"
    fi
    if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
        WHISPER_LIB="$BREW_PREFIX/lib"
    fi
    GGML_LIB="$WHISPER_LIB"
    GGML_METAL_LIB="$WHISPER_LIB"
    GGML_BLAS_LIB="$WHISPER_LIB"
    GGML_CPU_LIB="$WHISPER_LIB"
    USE_COREML=0
fi
GGML_INCLUDE="$BREW_PREFIX/include"

# Verify whisper dylib exists
if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
    echo "⚠ libwhisper.dylib not found"
    echo "  Install: brew install whisper-cpp"
    exit 1
fi

# llama.cpp library paths
LLAMA_LIB="$BREW_PREFIX/lib"
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
    LLAMA_LIB="$BREW_PREFIX/opt/llama.cpp/lib"
fi

# Verify llama dylib exists
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
    echo "⚠ libllama.dylib not found at $LLAMA_LIB"
    echo "  Install: brew install llama.cpp"
    exit 1
fi

# Detect architecture for target
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    SWIFT_TARGET="x86_64-apple-macos13.0"
else
    SWIFT_TARGET="arm64-apple-macos13.0"
fi

COREML_FLAGS=""
if [ "$USE_COREML" = "1" ]; then
    COREML_FLAGS="-L $WHISPER_LIB -lwhisper.coreml -framework CoreML"
fi

# Compile C bridge (uses shim.h matching installed whisper v1.8.3)
echo "Compiling whisper bridge..."
cc -c Sources/CWhisper/whisper_bridge.c \
    -I Sources/CWhisper \
    -o /tmp/whisper_bridge.o \
    -O2

swiftc Sources/Koe/*.swift \
    /tmp/whisper_bridge.o \
    -I Sources/CWhisper \
    -I Sources/CLlama \
    -L "$WHISPER_LIB" \
    -L "$GGML_LIB" \
    -L "$GGML_METAL_LIB" \
    -L "$GGML_BLAS_LIB" \
    -L "$GGML_CPU_LIB" \
    -L "$LLAMA_LIB" \
    -lwhisper \
    -lllama \
    -lggml \
    -lggml-base \
    $COREML_FLAGS \
    -framework AppKit \
    -framework AVFoundation \
    -framework Speech \
    -framework SwiftUI \
    -framework Metal \
    -framework Accelerate \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework UserNotifications \
    -framework ServiceManagement \
    -target "$SWIFT_TARGET" \
    -O \
    -o "$APP/Contents/MacOS/Koe"

# Embed whisper + llama dylibs in app bundle for self-contained distribution
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# When using CoreML build, ggml dylibs come from whisper's custom build (0.9.5)
# but llama.cpp from Homebrew needs ggml 0.9.7. Use Homebrew ggml for compatibility.
if [ "$USE_COREML" = "1" ]; then
    # whisper dylibs from CoreML build
    for lib in libwhisper.dylib libwhisper.coreml.dylib; do
        src="$WHISPER_LIB/$lib"
        if [ -L "$src" ]; then src=$(readlink -f "$src"); fi
        if [ -f "$src" ]; then cp "$src" "$FRAMEWORKS/$lib"; fi
    done
    # ggml dylibs from Homebrew (compatible with both whisper and llama)
    for lib in libggml.dylib libggml-base.dylib libggml-cpu.dylib libggml-blas.dylib libggml-metal.dylib; do
        src="$BREW_PREFIX/lib/$lib"
        if [ -L "$src" ]; then src=$(readlink -f "$src"); fi
        if [ -f "$src" ]; then cp "$src" "$FRAMEWORKS/$lib"; fi
    done
else
    # Copy whisper dylibs
    for lib in libwhisper.dylib libwhisper.coreml.dylib; do
        src="$WHISPER_LIB/$lib"
        if [ -L "$src" ]; then src=$(readlink -f "$src"); fi
        if [ -f "$src" ]; then cp "$src" "$FRAMEWORKS/$lib"; fi
    done
    # Copy ggml dylibs from potentially different directories
    for pair in "libggml.dylib:$GGML_LIB" "libggml-base.dylib:$GGML_LIB" "libggml-cpu.dylib:$GGML_CPU_LIB" "libggml-blas.dylib:$GGML_BLAS_LIB" "libggml-metal.dylib:$GGML_METAL_LIB"; do
        lib="${pair%%:*}"
        dir="${pair##*:}"
        src="$dir/$lib"
        if [ -L "$src" ]; then src=$(readlink -f "$src"); fi
        if [ -f "$src" ]; then cp "$src" "$FRAMEWORKS/$lib"; fi
    done
fi

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
ALL_LIB_DIRS="$WHISPER_LIB $LLAMA_LIB $GGML_LIB $GGML_METAL_LIB $GGML_BLAS_LIB $GGML_CPU_LIB $BREW_PREFIX/lib $BREW_PREFIX/opt/llama.cpp/lib $BREW_PREFIX/opt/whisper-cpp/lib"
for lib in "$FRAMEWORKS"/*.dylib; do
    for dep in libggml.dylib libggml-base.dylib libggml-cpu.dylib libggml-blas.dylib libggml-metal.dylib libwhisper.dylib libwhisper.coreml.dylib libllama.dylib; do
        for dir in $ALL_LIB_DIRS; do
            install_name_tool -change "$dir/$dep" "@rpath/$dep" "$lib" 2>/dev/null || true
        done
        # Handle versioned names → unversioned
        for versioned in libwhisper.1.dylib libwhisper.1.8.3.dylib; do
            install_name_tool -change "@rpath/$versioned" "@rpath/libwhisper.dylib" "$lib" 2>/dev/null || true
            for dir in $ALL_LIB_DIRS; do
                install_name_tool -change "$dir/$versioned" "@rpath/libwhisper.dylib" "$lib" 2>/dev/null || true
            done
        done
        for versioned in libllama.0.dylib; do
            install_name_tool -change "@rpath/$versioned" "@rpath/libllama.dylib" "$lib" 2>/dev/null || true
            for dir in $ALL_LIB_DIRS; do
                install_name_tool -change "$dir/$versioned" "@rpath/libllama.dylib" "$lib" 2>/dev/null || true
            done
        done
        # Handle versioned ggml .0 names
        for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal; do
            install_name_tool -change "@rpath/${glib}.0.dylib" "@rpath/${glib}.dylib" "$lib" 2>/dev/null || true
            for dir in $ALL_LIB_DIRS; do
                install_name_tool -change "$dir/${glib}.0.dylib" "@rpath/${glib}.dylib" "$lib" 2>/dev/null || true
            done
        done
    done
    # Remove build-directory rpaths baked into CoreML build
    for rp in $(otool -l "$lib" 2>/dev/null | grep "path /tmp/" | awk '{print $2}'); do
        install_name_tool -delete_rpath "$rp" "$lib" 2>/dev/null || true
    done
    # Ensure @loader_path rpath for inter-framework resolution
    install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

# Also fix versioned refs in the main binary
install_name_tool -change "@rpath/libwhisper.1.dylib" "@rpath/libwhisper.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal; do
    install_name_tool -change "@rpath/${glib}.0.dylib" "@rpath/${glib}.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
done

# Create versioned symlinks for ggml (llama.cpp refs .0 names)
for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal; do
    if [ -f "$FRAMEWORKS/${glib}.dylib" ] && [ ! -f "$FRAMEWORKS/${glib}.0.dylib" ]; then
        cp "$FRAMEWORKS/${glib}.dylib" "$FRAMEWORKS/${glib}.0.dylib"
    fi
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

# Sign dylibs first (inside-out signing)
for lib in "$FRAMEWORKS"/*.dylib; do
    if [ "$SIGN_ID" = "-" ]; then
        codesign --force --sign - --options runtime "$lib"
    else
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$lib"
    fi
done

# Sign the main binary and app bundle
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --deep "$APP"
else
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS" --deep "$APP"
fi

echo "✓ Built and signed $APP (with embedded whisper.cpp)"

if [ "$1" = "--no-launch" ] || [ -n "$CI" ]; then
    echo "Build complete (no launch)"
    exit 0
fi

echo "→ Installing to /Applications and launching..."
pkill -9 Koe 2>/dev/null
sleep 0.5
# Copy to /Applications (preserves Accessibility permission if already granted)
rsync -a --delete "$APP/" /Applications/Koe.app/
open /Applications/Koe.app
echo "✓ Installed and launched /Applications/Koe.app"
