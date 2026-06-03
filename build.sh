#!/bin/bash
# `set -u` is intentionally omitted: this script relies on several conditionally-
# defined variables (WHISPER_LIBEXEC_LIB, brew prefix optionals, etc.) that would
# trip nounset. Tightening to -u is tracked as a follow-up; see docs/audit/05-build-ci.md (B-01).
set -eo pipefail

cd "$(dirname "$0")"
APP="build-macos/Koe.app"

echo "Building Koe..."
# Build into build-macos/ (not project root) to keep workspace clean.
# 前回ビルドの dylib (特に versioned な libggml-*.0.dylib) が残ると、libwhisper が
# soname 経由で古い/非互換な ggml を掴み「backends=0 / GGML_ASSERT(device)」で
# 起動時クラッシュする。毎回クリーンビルドして stale dylib の混入を断つ。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"

# Required for Gatekeeper: PkgInfo + CFBundlePackageType + CFBundleExecutable
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Delete :CFBundlePackageType" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Koe" "$APP/Contents/Info.plist"

# Copy app icon
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP/Contents/Resources/"
fi

# Copy openWakeWord detector script
if [ -f "Resources/oww_detector.py" ]; then
    cp Resources/oww_detector.py "$APP/Contents/Resources/"
fi

# Homebrew prefix (Apple Silicon: /opt/homebrew, Intel: /usr/local)
BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")

# whisper.cpp library paths
# Prefer custom CoreML-enabled build, fallback to Homebrew
WHISPER_COREML_BUILD="/tmp/whisper.cpp/build"
# Use source-built whisper if available — it uses its own ggml (compatible version)
# Homebrew ggml (0.9.11) broke compatibility with whisper-cpp 1.8.4 (compiled against 0.9.8)
if [ -f "$WHISPER_COREML_BUILD/src/libwhisper.dylib" ] && [ -f "$WHISPER_COREML_BUILD/ggml/src/libggml.dylib" ]; then
    if [ -f "$WHISPER_COREML_BUILD/src/libwhisper.coreml.dylib" ]; then
        echo "Using CoreML-enabled whisper.cpp build"
        USE_COREML=1
    else
        echo "Using source-built whisper.cpp (with compatible ggml)"
        USE_COREML=0
    fi
    WHISPER_LIB="$WHISPER_COREML_BUILD/src"
    GGML_LIB="$WHISPER_COREML_BUILD/ggml/src"
    GGML_METAL_LIB="$WHISPER_COREML_BUILD/ggml/src/ggml-metal"
    GGML_BLAS_LIB="$WHISPER_COREML_BUILD/ggml/src/ggml-blas"
    GGML_CPU_LIB="$WHISPER_COREML_BUILD/ggml/src"
    USE_SOURCE_GGML=1
elif [ -f "lib-macos/prebuilt-dylibs/libwhisper.dylib" ] && [ -f "lib-macos/prebuilt-dylibs/libggml.dylib" ]; then
    # /tmp は OS 再起動で消える。動作実績のある dylib 一式をリポ内に退避してあり、
    # brew (ggml 0.9.11 非互換 → 起動クラッシュ) より先にこちらを使う。
    echo "Using repo prebuilt dylibs (lib-macos/prebuilt-dylibs)"
    USE_COREML=0
    USE_SOURCE_GGML=1
    WHISPER_LIB="$(pwd)/lib-macos/prebuilt-dylibs"
    GGML_LIB="$WHISPER_LIB"
    GGML_METAL_LIB="$WHISPER_LIB"
    GGML_BLAS_LIB="$WHISPER_LIB"
    GGML_CPU_LIB="$WHISPER_LIB"
else
    USE_SOURCE_GGML=0
    WHISPER_LIB="$BREW_PREFIX/opt/whisper-cpp/libinternal"
    if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
        WHISPER_LIB="$BREW_PREFIX/opt/whisper-cpp/lib"
    fi
    if [ ! -f "$WHISPER_LIB/libwhisper.dylib" ]; then
        WHISPER_LIB="$BREW_PREFIX/lib"
    fi
    # ggml dylibs may be in WHISPER_LIB, its libexec sibling, or BREW_PREFIX/lib — probe each
    WHISPER_LIBEXEC_LIB="$BREW_PREFIX/opt/whisper-cpp/libexec/lib"
    if [ -f "$WHISPER_LIB/libggml.dylib" ]; then
        GGML_LIB="$WHISPER_LIB"
    elif [ -f "$WHISPER_LIBEXEC_LIB/libggml.dylib" ]; then
        GGML_LIB="$WHISPER_LIBEXEC_LIB"
    else
        GGML_LIB="$BREW_PREFIX/lib"
    fi
    if [ -f "$WHISPER_LIB/libggml-metal.dylib" ]; then
        GGML_METAL_LIB="$WHISPER_LIB"
    elif [ -f "$WHISPER_LIBEXEC_LIB/libggml-metal.dylib" ]; then
        GGML_METAL_LIB="$WHISPER_LIBEXEC_LIB"
    else
        GGML_METAL_LIB="$BREW_PREFIX/lib"
    fi
    if [ -f "$WHISPER_LIB/libggml-blas.dylib" ]; then
        GGML_BLAS_LIB="$WHISPER_LIB"
    elif [ -f "$WHISPER_LIBEXEC_LIB/libggml-blas.dylib" ]; then
        GGML_BLAS_LIB="$WHISPER_LIBEXEC_LIB"
    else
        GGML_BLAS_LIB="$BREW_PREFIX/lib"
    fi
    if [ -f "$WHISPER_LIB/libggml-cpu.dylib" ]; then
        GGML_CPU_LIB="$WHISPER_LIB"
    elif [ -f "$WHISPER_LIBEXEC_LIB/libggml-cpu.dylib" ]; then
        GGML_CPU_LIB="$WHISPER_LIBEXEC_LIB"
    else
        GGML_CPU_LIB="$BREW_PREFIX/lib"
    fi
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
# Mirror the whisper.cpp source-build fallback above: arm64 Macs with only
# x86_64 Homebrew (no /opt/homebrew) cannot link against brew's llama.cpp.
# If /tmp/llama.cpp/build exists, use it.
LLAMA_SOURCE_BUILD="/tmp/llama.cpp/build"
# cmake puts the shared library under build/bin (not build/src) when BUILD_SHARED_LIBS=ON
if [ -f "lib-macos/prebuilt-dylibs/libllama.dylib" ] && [ ! -f "$LLAMA_SOURCE_BUILD/bin/libllama.dylib" ] && [ ! -f "$LLAMA_SOURCE_BUILD/src/libllama.dylib" ]; then
    echo "Using repo prebuilt libllama (lib-macos/prebuilt-dylibs)"
    LLAMA_LIB="$(pwd)/lib-macos/prebuilt-dylibs"
    USE_SOURCE_LLAMA=1
elif [ -f "$LLAMA_SOURCE_BUILD/bin/libllama.dylib" ]; then
    echo "Using source-built llama.cpp ($LLAMA_SOURCE_BUILD/bin)"
    LLAMA_LIB="$LLAMA_SOURCE_BUILD/bin"
    USE_SOURCE_LLAMA=1
elif [ -f "$LLAMA_SOURCE_BUILD/src/libllama.dylib" ]; then
    echo "Using source-built llama.cpp ($LLAMA_SOURCE_BUILD/src)"
    LLAMA_LIB="$LLAMA_SOURCE_BUILD/src"
    USE_SOURCE_LLAMA=1
else
    USE_SOURCE_LLAMA=0
    LLAMA_LIB="$BREW_PREFIX/lib"
    if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
        LLAMA_LIB="$BREW_PREFIX/opt/llama.cpp/lib"
    fi
fi

# Verify llama dylib exists
if [ ! -f "$LLAMA_LIB/libllama.dylib" ]; then
    echo "⚠ libllama.dylib not found at $LLAMA_LIB"
    echo "  Install: brew install llama.cpp"
    echo "  Or build from source into /tmp/llama.cpp (see docs/build-arm64.md)"
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

# Compile C bridge into a static library to avoid WMO overwriting the .o file
echo "Compiling whisper bridge..."
BRIDGE_OBJ="$APP/Contents/MacOS/whisper_bridge.o"
BRIDGE_LIB="$APP/Contents/MacOS/libwhisper_bridge.a"
cc -c Sources/CWhisper/whisper_bridge.c \
    -I Sources/CWhisper \
    -o "$BRIDGE_OBJ" \
    -O3
ar rcs "$BRIDGE_LIB" "$BRIDGE_OBJ"

swiftc Sources/Koe/*.swift \
    -I Sources/CWhisper \
    -I Sources/CLlama \
    -L "$APP/Contents/MacOS" \
    -lwhisper_bridge \
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
    -D DIRECT_DISTRIBUTION \
    -O \
    -whole-module-optimization \
    -o "$APP/Contents/MacOS/Koe"

# Remove temporary build artifacts
rm -f "$BRIDGE_OBJ" "$BRIDGE_LIB"

# Embed whisper + llama dylibs in app bundle for self-contained distribution
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

if [ "$USE_SOURCE_GGML" = "1" ]; then
    # Use source-built whisper + its own ggml (API-compatible, avoids Homebrew ggml version skew)
    for lib in libwhisper.dylib libwhisper.coreml.dylib; do
        src="$WHISPER_LIB/$lib"
        if [ -L "$src" ]; then src=$(readlink -f "$src"); fi
        if [ -f "$src" ]; then cp "$src" "$FRAMEWORKS/$lib"; fi
    done
    for pair in "libggml.dylib:$GGML_LIB" "libggml-base.dylib:$GGML_LIB" "libggml-cpu.dylib:$GGML_CPU_LIB" "libggml-blas.dylib:$GGML_BLAS_LIB" "libggml-metal.dylib:$GGML_METAL_LIB"; do
        lib="${pair%%:*}"
        dir="${pair##*:}"
        src="$dir/$lib"
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

# llama.cpp dylib — copy with homebrew ggml under distinct names to avoid conflict with whisper's ggml
if [ -f "$LLAMA_LIB/libllama.dylib" ]; then
    cp "$LLAMA_LIB/libllama.dylib" "$FRAMEWORKS/"
fi
# Bundle homebrew ggml 0.9.11 (for llama) under -hb names to coexist with source-built ggml 0.9.8 (for whisper)
# libllama depends on ggml 0.9.11 which has different symbols than our bundled ggml 0.9.8
# Skip the -hb shim when llama is *also* source-built: it then shares the same ggml as whisper.
HB_GGML="$BREW_PREFIX/opt/ggml/lib"
if [ "$USE_SOURCE_GGML" = "1" ] && [ "$USE_SOURCE_LLAMA" != "1" ] && [ -f "$HB_GGML/libggml.dylib" ] && [ -f "$LLAMA_LIB/libllama.dylib" ]; then
    cp "$HB_GGML/libggml.dylib" "$FRAMEWORKS/libggml-hb.dylib"
    cp "$HB_GGML/libggml-base.dylib" "$FRAMEWORKS/libggml-base-hb.dylib"
    install_name_tool -id "@rpath/libggml-hb.dylib" "$FRAMEWORKS/libggml-hb.dylib" 2>/dev/null || true
    install_name_tool -id "@rpath/libggml-base-hb.dylib" "$FRAMEWORKS/libggml-base-hb.dylib" 2>/dev/null || true
    # Fix internal refs in libggml-hb
    install_name_tool -change "$HB_GGML/libggml.0.dylib" "@rpath/libggml-hb.dylib" "$FRAMEWORKS/libggml-hb.dylib" 2>/dev/null || true
    install_name_tool -change "@rpath/libggml-base.0.dylib" "@rpath/libggml-base-hb.dylib" "$FRAMEWORKS/libggml-hb.dylib" 2>/dev/null || true
    install_name_tool -change "$HB_GGML/libggml-base.0.dylib" "@rpath/libggml-base-hb.dylib" "$FRAMEWORKS/libggml-hb.dylib" 2>/dev/null || true
    install_name_tool -change "$HB_GGML/libggml-base.dylib" "@rpath/libggml-base-hb.dylib" "$FRAMEWORKS/libggml-hb.dylib" 2>/dev/null || true
    install_name_tool -change "$HB_GGML/libggml-base.0.dylib" "@rpath/libggml-base-hb.dylib" "$FRAMEWORKS/libggml-base-hb.dylib" 2>/dev/null || true
fi

# Fix dylib rpaths so the app finds embedded libraries
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Koe" 2>/dev/null || true

# Update dylib install names to use @rpath
for lib in "$FRAMEWORKS"/*.dylib; do
    libname=$(basename "$lib")
    install_name_tool -id "@rpath/$libname" "$lib" 2>/dev/null || true
done

# Fix inter-dylib references (libwhisper → libggml etc.)
ALL_LIB_DIRS="$WHISPER_LIB $LLAMA_LIB $GGML_LIB $GGML_METAL_LIB $GGML_BLAS_LIB $GGML_CPU_LIB $BREW_PREFIX/lib $BREW_PREFIX/opt/ggml/lib $BREW_PREFIX/opt/llama.cpp/lib $BREW_PREFIX/opt/whisper-cpp/lib $BREW_PREFIX/opt/whisper-cpp/libexec/lib $BREW_PREFIX/opt/llama.cpp/libexec/lib ${WHISPER_LIBEXEC_LIB:-}"
for lib in "$FRAMEWORKS"/*.dylib; do
    libbase=$(basename "$lib")
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

# Redirect libllama's ggml refs to the -hb versions (homebrew ggml 0.9.11 bundled separately)
# When llama is also source-built (USE_SOURCE_LLAMA=1) the -hb shim is not produced and the
# default @rpath/libggml.dylib refs already resolve to the bundled source-built ggml.
if [ "$USE_SOURCE_GGML" = "1" ] && [ "$USE_SOURCE_LLAMA" != "1" ] && [ -f "$FRAMEWORKS/libggml-hb.dylib" ]; then
    for glib in libggml libggml-base; do
        install_name_tool -change "@rpath/${glib}.dylib" "@rpath/${glib}-hb.dylib" "$FRAMEWORKS/libllama.dylib" 2>/dev/null || true
        install_name_tool -change "@rpath/${glib}.0.dylib" "@rpath/${glib}-hb.dylib" "$FRAMEWORKS/libllama.dylib" 2>/dev/null || true
    done
fi

# Also fix versioned refs in the main binary
install_name_tool -change "@rpath/libwhisper.1.dylib" "@rpath/libwhisper.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
install_name_tool -change "@rpath/libllama.0.dylib" "@rpath/libllama.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal; do
    install_name_tool -change "@rpath/${glib}.0.dylib" "@rpath/${glib}.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
done

# Fix absolute homebrew paths in main binary (critical for distribution)
for dir in $ALL_LIB_DIRS; do
    for versioned in libwhisper.1.dylib libwhisper.dylib; do
        install_name_tool -change "$dir/$versioned" "@rpath/libwhisper.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
    done
    for versioned in libllama.0.dylib libllama.dylib; do
        install_name_tool -change "$dir/$versioned" "@rpath/libllama.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
    done
    for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal; do
        install_name_tool -change "$dir/${glib}.0.dylib" "@rpath/${glib}.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
        install_name_tool -change "$dir/${glib}.dylib" "@rpath/${glib}.dylib" "$APP/Contents/MacOS/Koe" 2>/dev/null || true
    done
done

# Create versioned copies for ggml + llama (must be real files, not symlinks — symlinks break codesign --deep)
for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal; do
    if [ -f "$FRAMEWORKS/${glib}.dylib" ] && [ ! -f "$FRAMEWORKS/${glib}.0.dylib" ]; then
        cp "$FRAMEWORKS/${glib}.dylib" "$FRAMEWORKS/${glib}.0.dylib"
    fi
done
# llama: the source-built libllama.dylib carries SONAME libllama.0.dylib, so callers may
# dlopen the versioned name. Provide a real-file copy alongside the unversioned one.
if [ -f "$FRAMEWORKS/libllama.dylib" ] && [ ! -f "$FRAMEWORKS/libllama.0.dylib" ]; then
    cp "$FRAMEWORKS/libllama.dylib" "$FRAMEWORKS/libllama.0.dylib"
fi

# Strip debug symbols (only real files, skip .0.dylib duplicates to avoid double-work)
echo "  Stripping debug symbols..."
for lib in "$FRAMEWORKS"/*.dylib; do
    [[ "$lib" == *".0.dylib" ]] && continue
    strip -x "$lib" 2>/dev/null || true
done
# Sync stripped content to .0.dylib copies (use cp -f to overwrite without error on identical)
for glib in libggml libggml-base libggml-cpu libggml-blas libggml-metal libllama; do
    if [ -f "$FRAMEWORKS/${glib}.dylib" ] && [ -f "$FRAMEWORKS/${glib}.0.dylib" ]; then
        cp -f "$FRAMEWORKS/${glib}.dylib" "$FRAMEWORKS/${glib}.0.dylib" 2>/dev/null || true
    fi
done
strip -x "$APP/Contents/MacOS/Koe" 2>/dev/null || true

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
# set -e 下で「Koe 未起動 = pkill exit 1」だと install 全体が中断するため || true で吸収
pkill -9 Koe 2>/dev/null || true
sleep 0.5

# Notarize only if staple ticket not already present (skip for fast dev iteration)
if ! xcrun stapler validate "$APP" 2>/dev/null | grep -q "worked"; then
    # Use a per-run temp file to avoid /tmp/Koe-install.zip symlink races on shared hosts.
    TMPZ="$(mktemp -t Koe-install).zip"
    trap 'rm -f "$TMPZ"' EXIT
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMPZ"
    if xcrun notarytool history --keychain-profile "notary" >/dev/null 2>&1; then
        # Surface notarization errors instead of swallowing them with `|| true`.
        xcrun notarytool submit "$TMPZ" --keychain-profile "notary" --wait
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP" >/dev/null
    else
        echo "ℹ notarytool keychain profile 'notary' not configured; skipping notarization (local dev)."
    fi
    rm -f "$TMPZ"
    trap - EXIT
fi

# Copy to /Applications (use sudo if needed for root-owned existing install)
if [ -w /Applications/Koe.app ] || [ ! -e /Applications/Koe.app ]; then
    rsync -a --delete "$APP/" /Applications/Koe.app/
else
    sudo rsync -a --delete "$APP/" /Applications/Koe.app/
fi
open /Applications/Koe.app
echo "✓ Installed and launched /Applications/Koe.app"
