#!/bin/bash
# Host-side runner for iOS test logic that doesn't require an iOS Simulator.
#
# We bridge Koe-iOS sources to macOS by compiling against the macOS SDK
# (Speech.framework / Foundation are available on both platforms). The
# AudioSessionCoordinator (iOS-only AVAudioSession wrapper) is stubbed.
#
# This lets contributors verify the regression fixes without installing
# Xcode + iOS Simulator (~15 GB). It exercises the same logic that the
# real XCTest cases in Koe-iOS/Tests/KoeIOSTests.swift verify:
#
#   1. migrateKoeLanguageIfNeeded() — copies legacy `koe_language` from
#      UserDefaults.standard into the App Group store exactly once.
#   2. WakeWordDetector — picks up `koe_language` from .koeShared at init,
#      and re-builds its SFSpeechRecognizer whenever `.koeLanguageDidChange`
#      fires (i.e. user switches Japanese/English).
#
# On a Mac with full Xcode, `xcodebuild test -scheme Koe` runs the same logic
# inside the iOS Simulator (see `KoeTests` target in project.yml).

set -eo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d -t koe-host-tests.XXXXXX)
STUB="$WORK/audio_session_stub.swift"
DRIVER="$WORK/host_driver.swift"
BIN="$WORK/host_tests"
trap 'rm -rf "$WORK"' EXIT

cat > "$STUB" <<'STUB'
// macOS host-test stub for the iOS-only AudioSessionCoordinator.
import Foundation
final class AudioSessionCoordinator {
    enum Intent { case wakeWord, recording, soundMemory }
    static let shared = AudioSessionCoordinator()
    func acquire(_ intent: Intent) throws {}
    func release(_ intent: Intent) {}
}
STUB

cat > "$DRIVER" <<'DRIVER'
import Foundation
import Speech

@main
struct HostTests {
    @MainActor
    static func main() {
        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ desc: String) {
            if ok { print("  ✓ \(desc)"); passed += 1 } else { print("  ✗ \(desc)"); failed += 1 }
        }

        let shared = UserDefaults.koeShared
        let flag = "koe_language_migrated_v2_10_1"
        let key = "koe_language"

        print("\n=== iOS regression host tests ===")

        print("\n--- testLegacyLanguageMigratesToSharedDefaults ---")
        shared.removeObject(forKey: flag)
        shared.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set("en-US", forKey: key)
        migrateKoeLanguageIfNeeded()
        check(shared.string(forKey: key) == "en-US", "shared.koe_language == 'en-US' after first migration")
        check(shared.bool(forKey: flag) == true, "migration flag set")

        print("\n--- testLegacyMigrationIsIdempotent ---")
        shared.set("ja-JP", forKey: key)
        UserDefaults.standard.set("zh-CN", forKey: key)
        migrateKoeLanguageIfNeeded()
        check(shared.string(forKey: key) == "ja-JP", "2nd run does not overwrite shared")

        // Reset for locale test
        UserDefaults.standard.removeObject(forKey: key)
        shared.removeObject(forKey: flag)

        print("\n--- testWakeWordDetectorUsesInitialLanguage ---")
        shared.set("en-US", forKey: key)
        let d = WakeWordDetector()
        check(d.currentRecognizerLocaleIdentifier == "en-US",
              "WakeWordDetector picks up initial language from .koeShared")

        print("\n--- testWakeWordDetectorUpdatesLocaleOnLanguageChange ---")
        shared.set("ja-JP", forKey: key)
        NotificationCenter.default.post(name: .koeLanguageDidChange, object: nil)
        check(d.currentRecognizerLocaleIdentifier == "ja-JP",
              "recognizer rebuilt to ja-JP after .koeLanguageDidChange")

        shared.set("zh-CN", forKey: key)
        NotificationCenter.default.post(name: .koeLanguageDidChange, object: nil)
        check(d.currentRecognizerLocaleIdentifier == "zh-CN",
              "recognizer rebuilt to zh-CN on subsequent change")

        // cleanup
        shared.removeObject(forKey: key)

        print("\n=== Results: \(passed) passed, \(failed) failed ===")
        if failed > 0 { exit(1) }
    }
}
DRIVER

swiftc -parse-as-library \
    Sources/SharedDefaults.swift \
    Sources/WakeWordDetector.swift \
    "$STUB" \
    "$DRIVER" \
    -framework Speech \
    -o "$BIN"

"$BIN"
