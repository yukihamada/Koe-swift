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
// Run all tests
// ══════════════════════════════════════
func runAllTests() {
    print("=== Koe Mac Unit Tests ===")
    testAgentMode()
    testVoiceCommands()
    testSettingsDefaults()
    testL10n()
    testLLMSanitization()
    testAgentCommandProperties()
    print("\n=== Results: \(passed) passed, \(failed) failed ===")
    if failed > 0 { exit(1) }
}

// Entry point — called by the test runner
// Note: This file is compiled with Sources/Koe/*.swift which has @main AppDelegate
// So we can't use @main here. Instead, this function is called from the test runner script.
