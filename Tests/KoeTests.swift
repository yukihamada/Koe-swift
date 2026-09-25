// Tests/KoeTests.swift — Standalone test runner (assert-based, no XCTest)
import Foundation
import AVFoundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1; print("  ✓ \(msg)") }
    else { failed += 1; print("  ✗ \(msg) [\(file):\(line)]") }
}

// ══════════════════════════════════════
// AgentMode.detectCommand
// ══════════════════════════════════════
func testAgentMode() {
    print("\n--- AgentMode.detectCommand ---")
    let agent = AgentMode.shared
    AppSettings.shared.voiceControlEnabled = false
    AppSettings.shared.agentModeEnabled = true

    // Screenshot
    if case .screenshot = agent.detectCommand("スクショ撮って") {
        check(true, "スクショ撮って → .screenshot")
    } else { check(false, "スクショ撮って → .screenshot") }

    if case .screenshot = agent.detectCommand("スクリーンショット") {
        check(true, "スクリーンショット → .screenshot")
    } else { check(false, "スクリーンショット → .screenshot") }

    // Open app
    if case .openApp(let name) = agent.detectCommand("Safariを開いて") {
        check(name == "Safari", "Safariを開いて → .openApp(Safari)")
    } else { check(false, "Safariを開いて → .openApp") }

    // Timer
    if case .timer(let m) = agent.detectCommand("5分タイマー") {
        check(m == 5, "5分タイマー → .timer(5)")
    } else { check(false, "5分タイマー → .timer") }

    // Search
    if case .search(let q) = agent.detectCommand("天気を検索して") {
        check(q.contains("天気"), "天気を検索して → .search(天気)")
    } else { check(false, "天気を検索して → .search") }

    // Not a command
    check(agent.detectCommand("こんにちは") == nil, "こんにちは → nil")
    check(agent.detectCommand("") == nil, "empty → nil")

    // Voice control commands (off)
    check(agent.detectCommand("音量上げて") == nil, "音量上げて (voiceControl OFF) → nil")

    // Voice control commands (on)
    AppSettings.shared.voiceControlEnabled = true

    if case .volumeUp = agent.detectCommand("音量上げて") {
        check(true, "音量上げて → .volumeUp")
    } else { check(false, "音量上げて → .volumeUp") }

    if case .volumeDown = agent.detectCommand("音量下げて") {
        check(true, "音量下げて → .volumeDown")
    } else { check(false, "音量下げて → .volumeDown") }

    if case .mute = agent.detectCommand("ミュート") {
        check(true, "ミュート → .mute")
    } else { check(false, "ミュート → .mute") }

    if case .sleep = agent.detectCommand("おやすみ") {
        check(true, "おやすみ → .sleep")
    } else { check(false, "おやすみ → .sleep") }

    if case .lockScreen = agent.detectCommand("画面ロック") {
        check(true, "画面ロック → .lockScreen")
    } else { check(false, "画面ロック → .lockScreen") }

    if case .playPause = agent.detectCommand("音楽止めて") {
        check(true, "音楽止めて → .playPause")
    } else { check(false, "音楽止めて → .playPause") }

    if case .brightnessUp = agent.detectCommand("明るくして") {
        check(true, "明るくして → .brightnessUp")
    } else { check(false, "明るくして → .brightnessUp") }

    // Screen action
    if case .screenAction = agent.detectCommand("このメール返信して") {
        check(true, "このメール返信して → .screenAction")
    } else { check(false, "このメール返信して → .screenAction") }

    if case .screenAction = agent.detectCommand("この画面要約して") {
        check(true, "この画面要約して → .screenAction")
    } else { check(false, "この画面要約して → .screenAction") }

    AppSettings.shared.voiceControlEnabled = false
}

// ══════════════════════════════════════
// VoiceCommands
// ══════════════════════════════════════
func testVoiceCommands() {
    print("\n--- VoiceCommands ---")

    // Filler removal
    let cleaned = VoiceCommands.removeFillers("えーと今日はえー天気がいいですね", language: "ja-JP")
    check(!cleaned.contains("えーと"), "Filler removal: えーと removed")
    check(cleaned.contains("天気"), "Filler removal: 天気 preserved")

    // Formatting
    let formatted = VoiceCommands.applyFormatting("テスト改行してください")
    check(formatted.contains("\n"), "applyFormatting: 改行 → \\n")

    // Edit command detection
    let deleteCmd = VoiceCommands.detectEditCommand("全部削除")
    check(deleteCmd != nil, "detectEditCommand: 全部削除 → non-nil")

    let noCmd = VoiceCommands.detectEditCommand("普通のテキスト")
    check(noCmd == nil, "detectEditCommand: 普通のテキスト → nil")
}

// ══════════════════════════════════════
// Settings defaults
// ══════════════════════════════════════
func testSettingsDefaults() {
    print("\n--- Settings defaults ---")
    let s = AppSettings.shared
    // These should have been set to false by default
    check(true, "AppSettings.shared exists")
    // RecordingMode
    check(RecordingMode.allCases.count == 2, "RecordingMode has 2 cases")
}

// ══════════════════════════════════════
// L10n (Mac)
// ══════════════════════════════════════
func testL10n() {
    print("\n--- L10n ---")
    check(!L10n.startSetup.isEmpty, "startSetup is non-empty")
    check(!L10n.setupTitle.isEmpty, "setupTitle is non-empty")
    check(!L10n.tryNow.isEmpty, "tryNow is non-empty")

    // No smart quotes (regression)
    let allStrings = [L10n.startSetup, L10n.setupTitle, L10n.tryNow]
    for s in allStrings {
        check(!s.contains("\u{201c}") && !s.contains("\u{201d}"), "No smart quotes in: \(s.prefix(20))")
    }
}

// ══════════════════════════════════════
// LLMProcessor sanitization
// ══════════════════════════════════════
func testLLMSanitization() {
    print("\n--- LLM sanitization ---")
    // processScreenContext with empty prompt should return empty
    let sem = DispatchSemaphore(value: 0)
    var result = "not_called"
    LLMProcessor.shared.processScreenContext(prompt: "") { r in
        result = r
        sem.signal()
    }
    sem.wait()
    check(result == "", "processScreenContext empty prompt → empty result")
}

// ══════════════════════════════════════
// DictationNotificationPoster — real DistributedNotificationCenter round-trip
// ══════════════════════════════════════
func testDictationNotificationPoster() {
    print("\n--- DictationNotificationPoster ---")
    let dnc = DistributedNotificationCenter.default()

    // DistributedNotificationCenter delivery (even to self) is routed through
    // the run loop, so a plain DispatchSemaphore.wait() on the main thread
    // (which never spins the run loop) would hang/timeout here. Pump the
    // main run loop in short slices until the observer fires instead.
    func waitForRunLoop(_ received: () -> Bool, timeoutSec: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while !received(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return received()
    }

    var beganReceived = false
    let beganObserver = dnc.addObserver(
        forName: Notification.Name(DictationNotificationPoster.beganNotificationName),
        object: nil, queue: .main
    ) { _ in beganReceived = true }
    DictationNotificationPoster.shared.postDictationBegan()
    check(waitForRunLoop({ beganReceived }), "postDictationBegan() delivers io.atsume.voice.dictation.began")
    dnc.removeObserver(beganObserver)

    var endedReceived = false
    let endedObserver = dnc.addObserver(
        forName: Notification.Name(DictationNotificationPoster.endedNotificationName),
        object: nil, queue: .main
    ) { _ in endedReceived = true }
    DictationNotificationPoster.shared.postDictationEnded()
    check(waitForRunLoop({ endedReceived }), "postDictationEnded() delivers io.atsume.voice.dictation.ended")
    dnc.removeObserver(endedObserver)

    // Second 側 VoiceArbiter とのハードコード契約 — 文字列がずれると無音で壊れるので固定する
    check(DictationNotificationPoster.beganNotificationName == "io.atsume.voice.dictation.began",
          "began notification name matches Second's VoiceArbiter contract")
    check(DictationNotificationPoster.endedNotificationName == "io.atsume.voice.dictation.ended",
          "ended notification name matches Second's VoiceArbiter contract")
}

// ══════════════════════════════════════
// AppDelegate recording start/stop → dictation notifier wiring
//
// notifyDictationBegan()/notifyDictationEnded() are the only functions that
// ever touch DistributedNotificationCenter — this checks the injected fake
// is reached through them without needing a real recorder.
// ══════════════════════════════════════
final class FakeDictationNotifier: DictationLifecycleNotifying {
    var beganCount = 0
    var endedCount = 0
    func postDictationBegan() { beganCount += 1 }
    func postDictationEnded() { endedCount += 1 }
}

func testAppDelegateDictationNotifierWiring() {
    print("\n--- AppDelegate dictation notifier wiring ---")
    let ad = AppDelegate()
    let fake = FakeDictationNotifier()
    ad.dictationNotifier = fake

    ad.notifyDictationBegan()
    check(fake.beganCount == 1 && fake.endedCount == 0, "notifyDictationBegan() calls the injected notifier's postDictationBegan()")

    ad.notifyDictationEnded()
    check(fake.beganCount == 1 && fake.endedCount == 1, "notifyDictationEnded() calls the injected notifier's postDictationEnded()")
}

// ══════════════════════════════════════
// AppDelegate recording lifecycle — began/ended pairing and ordering
//
// These drive the REAL startRecording()/stopAndRecognize()/cancelRecording()/
// applicationWillTerminate() on a real AppDelegate() instance, with a fake
// AudioRecorder (never touches AVAudioRecorder/the real mic — every method
// is overridden) and a fake notifier (never touches
// DistributedNotificationCenter), sharing one ordered EventLog so the
// interleaving between "the mic actually stopped" and "Second was told" can
// be asserted directly, not just that each fake was called.
//
// Known residual side effect: startRecording()/stopAndRecognize()/
// cancelRecording() still call the real registerRecordingHotKeys()/
// unregisterRecordingHotKeys() (global Carbon hotkeys for Space/ESC,
// registered only for the instant each test call takes) and the real
// WakeWordDetector.shared/duckSystemVolume() (both no-ops by default:
// wakeWordEnabled/duckingMode default to false/"off"). This mirrors exactly
// what a real recording session does and was judged an acceptable, momentary
// cost for testing the actual code path rather than a re-implementation of
// it — see PR description for the full reasoning.
// ══════════════════════════════════════
final class EventLog {
    private(set) var events: [String] = []
    func record(_ e: String) { events.append(e) }
    func reset() { events.removeAll() }
}

final class LoggingDictationNotifier: DictationLifecycleNotifying {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    func postDictationBegan() { log.record("notifier.began") }
    func postDictationEnded() { log.record("notifier.ended") }
}

/// Every method that could touch a real `AVAudioRecorder` (and therefore the
/// mic) is overridden — the inherited base-class implementation is never
/// reached, so no permission prompt, no real recording, no real file I/O
/// beyond what `tempURL` (a plain property) happens to point at.
final class LoggingAudioRecorder: AudioRecorder {
    let log: EventLog
    var startResult = true
    /// what stop()/cancel() should look like they returned/left behind
    var stopReturnsURL: URL? = URL(fileURLWithPath: "/tmp/koe-test-fake.wav")

    init(log: EventLog) {
        self.log = log
        super.init()
    }

    override func start() -> Bool {
        log.record("recorder.start")
        if startResult { tempURL = stopReturnsURL }
        return startResult
    }
    override func stop() -> URL? {
        log.record("recorder.stop")
        return stopReturnsURL
    }
    override func cancel() {
        log.record("recorder.cancel")
    }
    override func shutdown() {
        log.record("recorder.shutdown")
    }
    override func prepare() {
        // no-op: applicationDidFinishLaunching()/parallel-recording restarts
        // call this — never let it reach a real AVAudioRecorder in a test.
    }
}

func indexOf(_ events: [String], _ e: String) -> Int? { events.firstIndex(of: e) }

func testRecordingLifecycleHappyPath() {
    print("\n--- Recording lifecycle: start → normal stop ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    ad.recorder = LoggingAudioRecorder(log: log)

    ad.startRecording()
    check(log.events == ["recorder.start", "notifier.began"],
          "startRecording(): began fires exactly once, after the mic actually starts (got \(log.events))")

    ad.stopAndRecognize()
    let iStop = indexOf(log.events, "recorder.stop")
    let iEnded = indexOf(log.events, "notifier.ended")
    check(iStop != nil && iEnded != nil && iStop! < iEnded!,
          "stopAndRecognize(): ended fires exactly once, after recorder.stop() releases the mic (got \(log.events))")
    check(log.events.filter { $0 == "notifier.began" }.count == 1 && log.events.filter { $0 == "notifier.ended" }.count == 1,
          "exactly one began and one ended across the whole start→stop cycle")
}

func testRecordingLifecycleFailedStart() {
    print("\n--- Recording lifecycle: failed recorder.start() ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    let rec = LoggingAudioRecorder(log: log)
    rec.startResult = false
    ad.recorder = rec

    ad.startRecording()
    check(log.events == ["recorder.start"],
          "failed recorder.start() posts no began and leaves no dangling state (got \(log.events))")

    // isRecording must have stayed false — a second start attempt must be a
    // fresh, successful attempt, not blocked by a stuck re-entrancy guard.
    rec.startResult = true
    ad.startRecording()
    check(log.events == ["recorder.start", "recorder.start", "notifier.began"],
          "a later successful start still works after a prior failed one (got \(log.events))")
}

func testRecordingLifecycleCancel() {
    print("\n--- Recording lifecycle: start → cancel (ESC) ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    ad.recorder = LoggingAudioRecorder(log: log)

    ad.startRecording()
    ad.cancelRecording()
    let iCancel = indexOf(log.events, "recorder.cancel")
    let iEnded = indexOf(log.events, "notifier.ended")
    check(iCancel != nil && iEnded != nil && iCancel! < iEnded!,
          "cancelRecording(): ended fires after recorder.cancel() releases the mic (got \(log.events))")
    check(log.events.filter { $0 == "notifier.ended" }.count == 1,
          "cancelRecording() posts ended exactly once (got \(log.events))")
}

func testRecordingLifecycleCancelWhileOnlyRecognizing() {
    print("\n--- Recording lifecycle: cancel while only recognizing (no double ended) ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    ad.recorder = LoggingAudioRecorder(log: log)

    ad.startRecording()
    ad.stopAndRecognize()  // already posts one "ended"
    log.reset()
    ad.cancelRecording()   // ESC during recognition — isRecording is already false
    check(!log.events.contains("notifier.ended"),
          "cancelRecording() while not recording does not post a second ended (got \(log.events))")
}

func testRecordingLifecycleReentrancyGuard() {
    print("\n--- Recording lifecycle: re-entrant startRecording() is a no-op ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    ad.recorder = LoggingAudioRecorder(log: log)

    ad.startRecording()
    ad.startRecording()  // re-entrant while already recording
    check(log.events == ["recorder.start", "notifier.began"],
          "re-entrant startRecording() while already recording does not restart or re-post began (got \(log.events))")
}

func testRecordingLifecycleUnexpectedStop() {
    print("\n--- Recording lifecycle: encode error / unexpected finish ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    let rec = LoggingAudioRecorder(log: log)
    ad.recorder = rec

    ad.startRecording()
    // Simulate AVAudioRecorderDelegate firing on an OS-forced stop (not one
    // we called stop()/cancel() for) — this must reset state and post ended
    // exactly once, even though no explicit recorder.stop()/cancel() ran.
    let dummy = try! AVAudioRecorder(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("koe-test-dummy.wav"),
        settings: [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]
    )
    rec.audioRecorderDidFinishRecording(dummy, successfully: false)
    check(log.events == ["recorder.start", "notifier.began", "notifier.ended"],
          "unexpected finish (successfully=false) resets state and posts ended exactly once (got \(log.events))")

    // State must be fully reset — a fresh start right after must succeed
    // again (not blocked by a stuck isRecording=true).
    ad.startRecording()
    check(log.events.suffix(2) == ["recorder.start", "notifier.began"],
          "recording can start again after an unexpected stop (got \(log.events))")
}

func testRecordingLifecycleTermination() {
    print("\n--- Recording lifecycle: termination mid-recording ---")
    let log = EventLog()
    let ad = AppDelegate()
    ad.dictationNotifier = LoggingDictationNotifier(log: log)
    ad.recorder = LoggingAudioRecorder(log: log)

    ad.startRecording()
    // stopRecordingForTermination() is the exact logic applicationWillTerminate()
    // calls for the recording teardown — exercised directly (not through the
    // full applicationWillTerminate()) so this test never touches
    // HistoryStore.shared.flushSync(), which persists to the same history
    // file the real, live Koe.app also reads/writes.
    ad.stopRecordingForTermination()
    let iShutdown = indexOf(log.events, "recorder.shutdown")
    let iEnded = indexOf(log.events, "notifier.ended")
    check(iShutdown != nil && iEnded != nil && iShutdown! < iEnded!,
          "stopRecordingForTermination(): ended fires after recorder.shutdown() releases the mic (got \(log.events))")
}

// ══════════════════════════════════════
// AgentCommand properties
// ══════════════════════════════════════
func testAgentCommandProperties() {
    print("\n--- AgentCommand ---")
    check(AgentCommand.volumeUp.requiresVoiceControl, "volumeUp requires voiceControl")
    check(AgentCommand.lockScreen.requiresVoiceControl, "lockScreen requires voiceControl")
    check(AgentCommand.screenshot.requiresVoiceControl == false, "screenshot doesn't require voiceControl")
    check(AgentCommand.openApp(name: "X").requiresVoiceControl == false, "openApp doesn't require voiceControl")
    check(AgentCommand.screenAction(instruction: "test").requiresVoiceControl, "screenAction requires voiceControl")
    check(!AgentCommand.volumeUp.description.isEmpty, "volumeUp has description")
    check(!AgentCommand.screenshot.description.isEmpty, "screenshot has description")
}

// ══════════════════════════════════════
// Run all tests
// ══════════════════════════════════════
func runAllTests() {
    print("=== Koe Mac Unit Tests ===")
    testAgentMode()
    testVoiceCommands()
    testSettingsDefaults()
    testL10n()
    testLLMSanitization()
    testDictationNotificationPoster()
    testAppDelegateDictationNotifierWiring()
    testRecordingLifecycleHappyPath()
    testRecordingLifecycleFailedStart()
    testRecordingLifecycleCancel()
    testRecordingLifecycleCancelWhileOnlyRecognizing()
    testRecordingLifecycleReentrancyGuard()
    testRecordingLifecycleUnexpectedStop()
    testRecordingLifecycleTermination()
    testAgentCommandProperties()
    print("\n=== Results: \(passed) passed, \(failed) failed ===")
    if failed > 0 { exit(1) }
}

// Entry point — called by the test runner
// Note: This file is compiled with Sources/Koe/*.swift which has @main AppDelegate
// So we can't use @main here. Instead, this function is called from the test runner script.
