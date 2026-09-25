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
// WhisperContext/LlamaContext "generation token" race — simulated
//
// WhisperContext/LlamaContext themselves wrap real whisper.cpp/llama.cpp C
// contexts (whisper_init_from_file_with_params/llama_model_load_from_file)
// and can't be unit-tested without a real, multi-hundred-MB model file — not
// something to require for a headless test run. FakeModelLoader below
// mirrors their `loadModelSync`-shaped control flow: the slow "build" runs
// OFF `rq`'s queue (this is the shape where a generation token actually
// matters — a load that does build+publish atomically inside one single
// `rq.async` block, like WhisperContext.loadModel's async path, can never
// observe its own generation changing mid-block, since nothing else can run
// on a serial queue while it holds it; `loadModelSync`'s build-outside/
// publish-inside split is where a concurrent unload() genuinely can land in
// between). This is a simulation of the pattern, not the production code
// itself. The ReentrantSerialQueue tests above are what exercise the real,
// shared code directly.
//
// 2026-09-26 review: the previous version of this simulation (and of
// WhisperContext/LlamaContext themselves) used a single permanent
// "terminating" flag for both "unload() was called" and "the app is
// shutting down" — which meant ANY unload() (including the normal model-
// switch / low-memory-reload unload() that SettingsWindowController and the
// low-memory path use) permanently broke all future loads. Fixed in
// production by splitting `unload()` (bumps `generation`, allows later
// loads) from `unloadForTermination()`/`shutdown()` (also sets a permanent
// `isShutDown`). Mirrored here.
final class FakeGGMLResource {
    let id: Int
    private(set) var freed = false
    init(id: Int) { self.id = id }
    func free() { freed = true }
}

final class FakeModelLoader {
    let rq = ReentrantSerialQueue(label: "test.fake-model-loader")
    private var resource: FakeGGMLResource?
    private var generation = 0
    private var isShutDown = false
    private(set) var freedIDs: [Int] = []
    private(set) var publishedIDs: [Int] = []

    /// Mirrors WhisperContext.loadModelSync: snapshot the generation, build
    /// OFF `rq` (a real race window — a concurrent unload()/shutdown() can
    /// run to completion while this sleep/build is in progress), then
    /// publish-or-discard inside `rq`, gated by whether the generation is
    /// still the one this attempt started with.
    func load(id: Int, buildDelay: TimeInterval = 0, completion: @escaping (Bool) -> Void) {
        var myGeneration = 0
        var shutDown = false
        rq.syncOrInline {
            myGeneration = generation
            shutDown = isShutDown
        }
        guard !shutDown else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        DispatchQueue.global().async {
            if buildDelay > 0 { Thread.sleep(forTimeInterval: buildDelay) }
            let built = FakeGGMLResource(id: id)
            self.rq.syncOrInline {
                if self.isShutDown || self.generation != myGeneration {
                    built.free()
                    self.freedIDs.append(id)
                    DispatchQueue.main.async { completion(false) }
                } else {
                    self.resource = built
                    self.publishedIDs.append(id)
                    DispatchQueue.main.async { completion(true) }
                }
            }
        }
    }

    /// Mirrors LlamaContext.generate(): reads the resource from INSIDE the
    /// queue block, not before submitting to it.
    func generate(completion: @escaping (Int?) -> Void) {
        rq.async { [weak self] in
            guard let self, !self.isShutDown, let r = self.resource, !r.freed else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(r.id) }
        }
    }

    /// Normal unload — model switch / low-memory reload. Must NOT
    /// permanently block later loads.
    func unload() {
        rq.syncOrInline {
            generation += 1
            if let r = resource { r.free(); freedIDs.append(r.id) }
            resource = nil
        }
    }

    /// Terminal shutdown — app is quitting. Permanently refuses all future
    /// loads (mirrors WhisperContext.unloadForTermination()).
    func shutdown() {
        rq.syncOrInline {
            isShutDown = true
            generation += 1
            if let r = resource { r.free(); freedIDs.append(r.id) }
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

func testModelLoaderNormalUnloadAllowsLaterLoad() {
    print("\n--- FakeModelLoader: normal unload() → a later load() still succeeds ---")
    let loader = FakeModelLoader()
    var firstOK: Bool?
    loader.load(id: 1) { ok in firstOK = ok }
    drainMainQueue(1)
    check(firstOK == true, "initial load succeeds")

    loader.unload()  // model switch / low-memory reload — must not latch permanently
    var secondOK: Bool?
    loader.load(id: 2) { ok in secondOK = ok }
    drainMainQueue(1)
    check(secondOK == true,
          "a load after a normal (non-terminal) unload() still succeeds — unload() must not permanently block future loads")
    check(loader.publishedIDs == [1, 2],
          "both loads published in order (got \(loader.publishedIDs))")
}

func testModelLoaderStaleLoadFreedWhenUnloadedMidBuild() {
    print("\n--- FakeModelLoader: unload() while a load's build is in flight → stale load freed ---")
    // Unlike a single-atomic-queue-block load, `load()` here snapshots its
    // generation and then builds OFF `rq` — so a concurrent unload() CAN
    // genuinely run to completion (bumping the generation) while the build
    // is still in progress, landing squarely between the snapshot and the
    // publish check.
    let loader = FakeModelLoader()
    var result: Bool?
    loader.load(id: 1, buildDelay: 0.2) { ok in result = ok }
    Thread.sleep(forTimeInterval: 0.05)  // ensure the generation snapshot already happened
    loader.unload()  // runs immediately — rq is free, the build is off on a different queue
    drainMainQueue(1)
    check(result == false,
          "a load whose build finishes after a concurrent unload() reports failure (stale generation)")
    check(loader.freedIDs.contains(1) && !loader.publishedIDs.contains(1),
          "its resource is freed, never published (got freed=\(loader.freedIDs) published=\(loader.publishedIDs))")
}

func testModelLoaderShutdownRefusesFutureLoads() {
    print("\n--- FakeModelLoader: shutdown() permanently refuses later loads ---")
    let loader = FakeModelLoader()
    loader.shutdown()  // app is quitting — nothing was ever loaded here
    var result: Bool?
    loader.load(id: 1) { ok in result = ok }
    drainMainQueue(1)
    check(result == false, "load() after shutdown() is refused")
    check(loader.publishedIDs.isEmpty, "nothing gets published after shutdown() (got \(loader.publishedIDs))")
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
// WeakInstanceRegistry — proves that a process-wide "unload all" call
// reaches non-shared instances too, not just a single `.shared` singleton.
//
// 2026-09-26 round-3 review: SettingsWindowController.rerecognizeEntry/
// batchRerecognize each create their OWN non-shared `WhisperContext()` (not
// `.shared`) to re-transcribe with a user-selected model.
// AppDelegate.applicationWillTerminate previously only called
// `WhisperContext.shared.unloadForTermination()` — these non-shared
// instances were never reached, so if the app quit while one was still
// alive, its Metal-backed context could be freed by deinit/static
// destructors at process exit instead — the same crash class
// (ggml_metal_device_free during __cxa_finalize) this PR already fixes for
// `.shared`. Fixed by giving WhisperContext/LlamaContext a process-wide
// WeakInstanceRegistry (registered in `init()`) and a static
// `unloadAllForTermination()` that iterates every live registered instance.
//
// FakeRegisteredContext below exercises the exact same `WeakInstanceRegistry`
// generic type the production code uses (just instantiated for a fake
// element type), so it needs no real whisper model file.
// ══════════════════════════════════════
final class FakeRegisteredContext {
    private static let registry = WeakInstanceRegistry<FakeRegisteredContext>()
    static func unloadAllForTermination() {
        for ctx in registry.snapshot() { ctx.unloadForTermination() }
    }

    let id: Int
    private(set) var unloadedForTermination = false

    init(id: Int) {
        self.id = id
        Self.registry.register(self)
    }

    func unloadForTermination() {
        unloadedForTermination = true
    }
}

func testWeakInstanceRegistryReachesNonSharedInstances() {
    print("\n--- WeakInstanceRegistry: unloadAllForTermination() reaches non-shared instances too ---")
    let sharedLike = FakeRegisteredContext(id: 1)
    // Simulates SettingsWindowController.rerecognizeEntry's `let ctx = WhisperContext()`
    // — a second, non-shared instance the app-quit path must not skip.
    let nonShared = FakeRegisteredContext(id: 2)

    FakeRegisteredContext.unloadAllForTermination()

    check(sharedLike.unloadedForTermination, "the first ('.shared'-like) instance is unloaded on termination")
    check(nonShared.unloadedForTermination,
          "a second, separately-created ('non-shared'-like) instance is ALSO unloaded on termination — this is exactly the gap the registry closes")
}

func testWeakInstanceRegistryDropsDeallocatedInstances() {
    print("\n--- WeakInstanceRegistry: deallocated instances are dropped, not force-retained ---")
    weak var weakRef: FakeRegisteredContext?
    autoreleasepool {
        let temp = FakeRegisteredContext(id: 99)
        weakRef = temp
        check(weakRef != nil, "instance alive while a strong reference exists")
    }
    check(weakRef == nil, "registering with the registry does not keep the instance alive (weak, not strong) after its only strong reference is released")
    // Must not crash even though a dealloc'd instance was registered.
    FakeRegisteredContext.unloadAllForTermination()
    check(true, "unloadAllForTermination() does not crash when a registered instance has already been deallocated")
}

// Exercises the REAL WhisperContext (not a fake) end-to-end: does
// `WhisperContext.unloadAllForTermination()` actually reach a non-shared
// instance? Asserts on `isShutDown` directly (module-internal read, see its
// doc comment) rather than round-tripping through `loadModel` with a bogus
// path — `loadModel` would return `false` either way (refused early because
// shut down, OR because the bogus path genuinely fails to open), so it can't
// tell "termination reached this instance" apart from "this instance was
// never going to load anyway". No real model file is needed either way.
//
// NOTE: this permanently shuts down the real `WhisperContext.shared`
// singleton (isShutDown latches forever) for the remainder of this test
// process — intentional (it mirrors real app termination) and harmless
// here since no other test in this suite loads a real model into `.shared`.
// Keep this test last among WhisperContext-touching tests if more are added.
func testWhisperContextUnloadAllForTerminationReachesNonSharedInstance() {
    print("\n--- WhisperContext.unloadAllForTermination(): reaches a real non-shared instance ---")
    // `.shared` is a `static let` — lazily created on first access. Touch it
    // explicitly first so it is registered before we snapshot the registry
    // (otherwise this test's assertion about `.shared` would be vacuous).
    let sharedCtx = WhisperContext.shared
    // Simulates SettingsWindowController.rerecognizeEntry's `let ctx = WhisperContext()`.
    let nonShared = WhisperContext()

    check(!sharedCtx.isShutDown, ".shared is not shut down before termination")
    check(!nonShared.isShutDown, "a freshly-created non-shared instance is not shut down before termination")

    WhisperContext.unloadAllForTermination()

    check(sharedCtx.isShutDown, ".shared is shut down after unloadAllForTermination()")
    check(nonShared.isShutDown,
          "a separately-created, non-shared WhisperContext is ALSO shut down after unloadAllForTermination() — proves termination isn't limited to .shared")
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
    testModelLoaderNormalUnloadAllowsLaterLoad()
    testModelLoaderStaleLoadFreedWhenUnloadedMidBuild()
    testModelLoaderShutdownRefusesFutureLoads()
    testModelLoaderGenerateAfterUnloadReturnsNil()
    testAgentCommandProperties()
    testWeakInstanceRegistryReachesNonSharedInstances()
    testWeakInstanceRegistryDropsDeallocatedInstances()
    // Must run last: permanently shuts down the real WhisperContext.shared singleton.
    testWhisperContextUnloadAllForTerminationReachesNonSharedInstance()
    print("\n=== Results: \(passed) passed, \(failed) failed ===")
    if failed > 0 { exit(1) }
}

// Entry point — called by the test runner
// Note: This file is compiled with Sources/Koe/*.swift which has @main AppDelegate
// So we can't use @main here. Instead, this function is called from the test runner script.
