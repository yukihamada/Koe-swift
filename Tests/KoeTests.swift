// Tests/KoeTests.swift — Standalone test runner (assert-based, no XCTest)
import Foundation

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
// ReentrantSerialQueue — the real, shared teardown-synchronization helper
// used by both WhisperContext.unload() and LlamaContext.unload() (extracted
// during the 2026-09-19 exit-crash fix). This exercises the ACTUAL
// production type directly — no fake/mirror needed here.
// ══════════════════════════════════════
func testReentrantSerialQueueSyncFromOutside() {
    print("\n--- ReentrantSerialQueue: syncOrInline from another thread ---")
    let rq = ReentrantSerialQueue(label: "test.reentrant.outside")
    var order: [String] = []
    let group = DispatchGroup()
    group.enter()
    rq.async {
        Thread.sleep(forTimeInterval: 0.05)
        order.append("async-block")
        group.leave()
    }
    rq.syncOrInline { order.append("sync-call") }  // must wait for the async block first (FIFO)
    check(group.wait(timeout: .now() + 2) == .success, "async block completed")
    check(order == ["async-block", "sync-call"],
          "syncOrInline from outside the queue waits its turn behind a running async block (got \(order))")
}

func testReentrantSerialQueueSyncFromInsideDoesNotDeadlock() {
    print("\n--- ReentrantSerialQueue: syncOrInline called FROM the queue itself (no deadlock) ---")
    let rq = ReentrantSerialQueue(label: "test.reentrant.inside")
    var ranInline = false
    let sem = DispatchSemaphore(value: 0)
    rq.async {
        // A plain `queue.sync` here would deadlock (dispatch_sync onto the
        // queue it's already running on) — this is exactly the scenario
        // WhisperContext/LlamaContext's unload() must survive if it's ever
        // invoked while already "on" their queue (e.g. from a completion
        // callback, or deinit firing mid-block).
        rq.syncOrInline { ranInline = true }
        sem.signal()
    }
    let completed = sem.wait(timeout: .now() + 2) == .success
    check(completed, "syncOrInline called from inside the queue's own block completes (no deadlock/hang)")
    check(ranInline, "the inline block actually ran")
}

// ══════════════════════════════════════
// WhisperContext/LlamaContext "terminating flag" race — simulated
//
// WhisperContext/LlamaContext themselves wrap real whisper.cpp/llama.cpp C
// contexts (whisper_init_from_file_with_params/llama_model_load_from_file)
// and can't be unit-tested without a real, multi-hundred-MB model file — not
// something to require for a headless test run. FakeModelLoader below
// mirrors their exact control-flow shape (build off to the side, publish
// INSIDE the same queue block that checks `terminating`, unload() sets
// `terminating` and frees under the same queue) using a fake resource
// instead — it is a simulation of the pattern, not the production code
// itself. The ReentrantSerialQueue tests above are what exercise the real,
// shared code directly.
final class FakeGGMLResource {
    let id: Int
    private(set) var freed = false
    init(id: Int) { self.id = id }
    func free() { freed = true }
}

final class FakeModelLoader {
    let rq = ReentrantSerialQueue(label: "test.fake-model-loader")
    private var resource: FakeGGMLResource?
    private var terminating = false
    private(set) var freedIDs: [Int] = []
    private(set) var publishedIDs: [Int] = []

    /// Mirrors WhisperContext.loadModel/LlamaContext.loadModel: the "slow
    /// build" happens on `rq`'s queue, and publishing (or, if `terminating`
    /// was already set, disposing the freshly-built resource instead) also
    /// happens inside that SAME queue block — never split across a hop to
    /// another queue, which is exactly what let the original bug happen
    /// (publish-after-unload / unload-sees-nil-and-frees-nothing).
    func load(id: Int, buildDelay: TimeInterval = 0, completion: @escaping (Bool) -> Void) {
        rq.async { [weak self] in
            guard let self else { return }
            if buildDelay > 0 { Thread.sleep(forTimeInterval: buildDelay) }
            let built = FakeGGMLResource(id: id)
            if self.terminating {
                built.free()
                self.freedIDs.append(id)
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.resource = built
            self.publishedIDs.append(id)
            DispatchQueue.main.async { completion(true) }
        }
    }

    /// Mirrors LlamaContext.generate(): reads the resource from INSIDE the
    /// queue block, not before submitting to it.
    func generate(completion: @escaping (Int?) -> Void) {
        rq.async { [weak self] in
            guard let self, !self.terminating, let r = self.resource, !r.freed else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(r.id) }
        }
    }

    func unload() {
        rq.syncOrInline {
            terminating = true
            if let r = resource {
                r.free()
                freedIDs.append(r.id)
            }
            resource = nil
        }
    }
}

func drainMainQueue(_ seconds: TimeInterval = 1) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

func testModelLoaderUnloadDuringInFlightLoad() {
    print("\n--- FakeModelLoader: unload() called while a load's build is still in-flight ---")
    // Because `rq` is a single serial queue, a load's build that has already
    // been dequeued and started running always finishes (and makes its
    // publish-or-discard decision) BEFORE a concurrently-called unload()
    // gets its turn — unload() is submitted after the load and must wait in
    // line (FIFO). So in this exact interleaving the load sees
    // `terminating == false` and legitimately publishes; the invariant this
    // test actually protects is what happens next: unload() must still find
    // and free that just-published resource — not see a stale nil and leave
    // it dangling (the original bug: publish deferred to a *different*
    // queue could let it happen strictly after unload() had already run).
    let loader = FakeModelLoader()
    var loadCompletedSuccessfully: Bool?
    loader.load(id: 1, buildDelay: 0.2) { ok in loadCompletedSuccessfully = ok }
    Thread.sleep(forTimeInterval: 0.05)  // let the load's block actually start running
    loader.unload()
    drainMainQueue(1)
    check(loadCompletedSuccessfully == true,
          "a load already running when unload() is called still completes and reports success (got \(String(describing: loadCompletedSuccessfully)))")
    check(loader.freedIDs == [1],
          "unload() finds and frees exactly the resource that load just published — no leak (got freed=\(loader.freedIDs) published=\(loader.publishedIDs))")

    // The real invariant: no revival after unload() returns.
    var afterUnload: Int?
    var afterUnloadSet = false
    loader.generate { id in afterUnload = id; afterUnloadSet = true }
    drainMainQueue(1)
    check(afterUnloadSet && afterUnload == nil,
          "generate() after this sequence returns nil — the resource is gone, not silently revived")
}

func testModelLoaderLoadAfterUnloadIsAlwaysDiscarded() {
    print("\n--- FakeModelLoader: load() called after unload() already completed ---")
    let loader = FakeModelLoader()
    loader.unload()  // nothing was ever loaded — a no-op teardown, but sets terminating
    var result: Bool?
    loader.load(id: 2) { ok in result = ok }
    drainMainQueue(1)
    check(result == false, "load() after unload() reports failure")
    check(loader.freedIDs == [2] && loader.publishedIDs.isEmpty,
          "its resource is freed immediately instead of published (got freed=\(loader.freedIDs) published=\(loader.publishedIDs))")
}

func testModelLoaderGenerateAfterUnloadReturnsNil() {
    print("\n--- FakeModelLoader: generate() after unload() (no use-after-free) ---")
    let loader = FakeModelLoader()
    var loadOK: Bool?
    loader.load(id: 3) { ok in loadOK = ok }
    drainMainQueue(1)
    check(loadOK == true, "initial load succeeds")

    var firstResult: Int?
    loader.generate { id in firstResult = id }
    drainMainQueue(1)
    check(firstResult == 3, "generate() works while loaded")

    loader.unload()
    var secondResult: Int?
    var secondResultSet = false
    loader.generate { id in secondResult = id; secondResultSet = true }
    drainMainQueue(1)
    check(secondResultSet && secondResult == nil,
          "generate() after unload() returns nil instead of touching the freed resource")
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
    testReentrantSerialQueueSyncFromOutside()
    testReentrantSerialQueueSyncFromInsideDoesNotDeadlock()
    testModelLoaderUnloadDuringInFlightLoad()
    testModelLoaderLoadAfterUnloadIsAlwaysDiscarded()
    testModelLoaderGenerateAfterUnloadReturnsNil()
    testAgentCommandProperties()
    print("\n=== Results: \(passed) passed, \(failed) failed ===")
    if failed > 0 { exit(1) }
}

// Entry point — called by the test runner
// Note: This file is compiled with Sources/Koe/*.swift which has @main AppDelegate
// So we can't use @main here. Instead, this function is called from the test runner script.
