# Lessons Learned

## whisper.cpp shim.h struct layout MUST match installed library version
**Date**: 2026-03-13
**Impact**: Critical — caused whisper_full() to return 0 segments for ALL audio

The project's `Sources/CWhisper/shim.h` had the `whisper_full_params` struct from a **newer** whisper.cpp version than the installed Homebrew library (v1.7.5). Two extra fields existed in the shim:
- `bool carry_initial_prompt;` (after `initial_prompt`)
- VAD fields at end (`bool vad`, `const char *vad_model_path`, `whisper_vad_params vad_params`)

The extra `carry_initial_prompt` shifted ALL subsequent fields by 8 bytes (with padding). This meant `language`, `temperature`, `best_of`, etc. all pointed to wrong memory offsets. `whisper_full_default_params()` returned a struct with garbage field values when interpreted through the wrong header.

**Symptoms**: `whisper_full()` returned `ret=0` (success) but `nSegments=0`. Subprocess with whisper-cli worked fine.

**Diagnosis**: Printed default params values — `best_of=-1082130432, temp=-1.0, no_speech=nan` confirmed struct mismatch.

**Fix**: Removed `carry_initial_prompt` and VAD fields from shim.h to match v1.7.5. Also created a C bridge (`whisper_bridge.c`) to avoid passing the struct from Swift entirely. Later upgraded to v1.8.3 and restored these fields.

**Rule**: When using a C library via a custom shim header, ALWAYS verify the header matches the EXACT installed version: `brew info whisper-cpp` → check version → compare struct fields.

## whisper.cpp v1.7.5 → v1.8.3 upgrade: no speed improvement on M2
**Date**: 2026-03-13
v1.8.3 adds `flash_attn`, Metal fusion/concurrency/graph-optimize, but on Apple M2 (no tensor API: "tensor API disabled for pre-M5 and pre-A19"), performance is essentially unchanged (~5.3s for 6s audio with Large V3 Turbo Q5). flash_attn=true gives slightly more consistent times vs OFF. Upgrade was done for stability/correctness, not speed.

## nohup launch doesn't capture NSLog output
`open Koe.app` and `nohup ./Koe >> log 2>&1` don't capture NSLog output. Logs go to `~/Library/Logs/Koe/koe.log` (custom klog function) and system log. Use `log show --predicate 'process == "Koe"'` for NSLog.

## リリース時にMARKETING_VERSIONを必ず更新する
**Date**: 2026-03-20
**解決済み**: `release.sh` が全バージョン参照を一括更新するように修正。
- `Info.plist` (CFBundleShortVersionString + CFBundleVersion)
- `project-macos.yml` (MARKETING_VERSION)
- `Koe-macOS.xcodeproj/project.pbxproj` (MARKETING_VERSION x2)

## 再インストール時にアクセシビリティ権限がリセットされる
**Date**: 2026-03-21
macOSはバイナリのCDHashが変わるとTCC権限をリセットする。対策:
- `build.sh`: インストール前に `tccutil reset Accessibility com.yuki.koe`
- `build-pkg.sh`: postinstall で同様にリセット
- `AppDelegate.checkAccessibility()`: 起動時にプロンプト＋設定画面誘導＋ポーリングで権限付与後に自動再登録
- **`checkAccessibility()` を `finishLaunch()` から呼ぶこと**（呼び忘れで機能しなかった前例あり）

## C string lifetime in Swift-to-C interop
`(str as NSString).utf8String` creates a temporary that can be freed before the C function uses it. Use `strdup(str)` + `free()` after the C call completes for safe lifetime management.
