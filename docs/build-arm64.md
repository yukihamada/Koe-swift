# Building on arm64 Macs without /opt/homebrew

`build.sh` and `Tests/run_tests.sh` link against `libwhisper`, `libllama`, and the
`libggml*` family. On Apple Silicon Macs that only have x86_64 Homebrew installed
under `/usr/local/`, the brew dylibs are x86_64 and cannot link into the arm64
target — the linker reports `ld: warning: ignoring file ... found architecture
'x86_64', required architecture 'arm64'` followed by undefined symbols.

The scripts detect source-built dylibs at the following paths and prefer them
over the Homebrew ones:

| Library | Expected path |
| --- | --- |
| whisper.cpp | `/tmp/whisper.cpp/build/src/libwhisper.dylib` |
| ggml (shared with whisper) | `/tmp/whisper.cpp/build/ggml/src/libggml*.dylib` |
| llama.cpp | `/tmp/llama.cpp/build/bin/libllama.dylib` |

## One-time setup

```bash
# whisper.cpp
cd /tmp && git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git
arch -arm64 /bin/bash -lc '
  cd /tmp/whisper.cpp
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DGGML_BLAS=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build build -j 8
'

# llama.cpp — build only the `llama` target (the `app/` target needs a generated
# build-info.h that is only produced by full CMake configure).
cd /tmp && git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
arch -arm64 /bin/bash -lc '
  cd /tmp/llama.cpp
  cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DGGML_BLAS=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_CURL=OFF -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON \
    -DBUILD_SHARED_LIBS=ON
  cmake --build build -j 8 --target llama
'
```

## Required cmake flags

- `GGML_NATIVE=OFF` — without this, ggml passes `-mcpu=native` which Apple
  clang rejects on arm64 (`unsupported argument 'native'`).
- `LLAMA_CURL=OFF` + `CMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON` — `cpp-httplib`
  otherwise picks up the x86_64 OpenSSL from `/usr/local/Cellar/openssl@3`
  and fails at link with `Undefined symbols for architecture arm64`.

After the source-build exists, plain `bash build.sh` and `bash
Tests/run_tests.sh` work — the scripts auto-detect and use them.
