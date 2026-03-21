#!/bin/bash
# Compile and run Koe Mac unit tests
set -e
cd "$(dirname "$0")/.."

echo "=== Koe Mac Tests ==="

BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
WHISPER_LIB="$BREW_PREFIX/opt/whisper-cpp/lib"
[ ! -f "$WHISPER_LIB/libwhisper.dylib" ] && WHISPER_LIB="$BREW_PREFIX/lib"
GGML_LIB="$WHISPER_LIB"
LLAMA_LIB="$BREW_PREFIX/lib"
[ ! -f "$LLAMA_LIB/libllama.dylib" ] && LLAMA_LIB="$BREW_PREFIX/opt/llama.cpp/lib"

ARCH=$(uname -m)
SWIFT_TARGET="${ARCH}-apple-macos13.0"

# Compile whisper bridge
cc -c Sources/CWhisper/whisper_bridge.c -I Sources/CWhisper -o /tmp/whisper_bridge_test.o -O2

# Create test main that calls runAllTests instead of AppDelegate
# Test entry — just a main() wrapper
cat > /tmp/koe_test_main.swift << 'MAIN'
import AppKit

@main struct KoeTestRunner {
    static func main() {
        runAllTests()
    }
}
MAIN

echo "Compiling..."
# Exclude main.swift (app entry point) — replaced by test main
SOURCES=$(ls Sources/Koe/*.swift | grep -v main.swift)
swiftc -parse-as-library $SOURCES Tests/KoeTests.swift /tmp/koe_test_main.swift \
    /tmp/whisper_bridge_test.o \
    -I Sources/CWhisper \
    -I Sources/CLlama \
    -L "$WHISPER_LIB" -L "$GGML_LIB" -L "$LLAMA_LIB" \
    -lwhisper -lllama -lggml -lggml-base \
    -framework AppKit -framework AVFoundation -framework Speech \
    -framework SwiftUI -framework Metal -framework Accelerate \
    -framework AudioToolbox -framework CoreAudio -framework UserNotifications \
    -framework ServiceManagement -framework MultipeerConnectivity \
    -framework Vision -framework Carbon \
    -target "$SWIFT_TARGET" -O \
    -Xlinker -rpath -Xlinker "$WHISPER_LIB" \
    -Xlinker -rpath -Xlinker "$LLAMA_LIB" \
    -o build-macos/KoeTests 2>&1

echo ""
echo "Running tests..."
./build-macos/KoeTests 2>&1
