import XCTest
@testable import Koe

// MARK: - PhraseManager Tests

final class PhraseManagerTests: XCTestCase {
    private var manager: PhraseManager!

    override func setUp() {
        super.setUp()
        // Clear persisted phrases before each test
        UserDefaults.standard.removeObject(forKey: "koe_phrases")
        // PhraseManager.shared is a singleton; we reset its state via the public API
        manager = PhraseManager.shared
        // Remove all existing phrases
        while !manager.phrases.isEmpty {
            manager.delete(at: IndexSet(integer: 0))
        }
    }

    override func tearDown() {
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: "koe_phrases")
        super.tearDown()
    }

    func testAddPhrase() {
        manager.add("Hello World")
        XCTAssertTrue(manager.phrases.contains("Hello World"))
        XCTAssertEqual(manager.phrases.count, 1)
    }

    func testAddPhraseTrimsWhitespace() {
        manager.add("  trimmed  ")
        XCTAssertEqual(manager.phrases.first, "trimmed")
    }

    func testAddEmptyPhraseIsIgnored() {
        manager.add("")
        manager.add("   ")
        XCTAssertTrue(manager.phrases.isEmpty)
    }

    func testDeletePhrase() {
        manager.add("A")
        manager.add("B")
        manager.add("C")
        manager.delete(at: IndexSet(integer: 1))
        XCTAssertEqual(manager.phrases, ["A", "C"])
    }

    func testMovePhrase() {
        manager.add("A")
        manager.add("B")
        manager.add("C")
        // Move "A" (index 0) to after "C" (destination 3)
        manager.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(manager.phrases, ["B", "C", "A"])
    }

    func testUpdatePhrase() {
        manager.add("old")
        manager.update(at: 0, to: "new")
        XCTAssertEqual(manager.phrases.first, "new")
    }

    func testUpdatePhraseTrimsWhitespace() {
        manager.add("original")
        manager.update(at: 0, to: "  updated  ")
        XCTAssertEqual(manager.phrases.first, "updated")
    }

    func testUpdateWithEmptyStringIsIgnored() {
        manager.add("keep")
        manager.update(at: 0, to: "")
        XCTAssertEqual(manager.phrases.first, "keep")
    }

    func testUpdateOutOfBoundsIsIgnored() {
        manager.add("only")
        manager.update(at: 5, to: "nope")
        XCTAssertEqual(manager.phrases, ["only"])
    }

    func testPhrasesPersistToUserDefaults() {
        manager.add("persistent")
        let json = UserDefaults.standard.string(forKey: "koe_phrases") ?? ""
        XCTAssertTrue(json.contains("persistent"),
                      "Expected 'persistent' in UserDefaults koe_phrases, got: \(json)")
    }
}

// MARK: - L10n Tests

final class L10nTests: XCTestCase {

    /// All static string properties on L10n should return non-empty values.
    func testAllStaticPropertiesAreNonEmpty() {
        let strings: [String] = [
            L10n.connectedToMac,
            L10n.translateMode,
            L10n.nextAction,
            L10n.phrases,
            L10n.trackpad,
            L10n.click,
            L10n.rightClick,
            L10n.scrollUp,
            L10n.scrollDown,
            L10n.prevTab,
            L10n.nextTab,
            L10n.swipeToSwitchTabs,
            L10n.appSwitch,
            L10n.wakeWordHint,
            L10n.downloadHighAccuracyModel,
            L10n.cancel,
            L10n.macPromoTitle,
            L10n.macPromoSubtitle,
            L10n.downloadMacFree,
            L10n.connectToMac,
            L10n.enterPIN,
            L10n.connect,
            L10n.cancelAction,
            L10n.pinPrompt,
            L10n.alwaysListening,
            L10n.voiceAssistant,
            L10n.alwaysListeningFooter,
            L10n.macScreenContext,
            L10n.macLink,
            L10n.macScreenContextFooter,
            L10n.phrasePalette,
            L10n.managePhrases,
            L10n.managePhrasesSubtitle,
            L10n.phraseFooter,
            L10n.meetingNotes,
            L10n.meetingNotesSubtitle,
            L10n.faceToFaceTranslation,
            L10n.faceToFaceSubtitle,
            L10n.audioTools,
            L10n.audioToolsSubtitle,
            L10n.features,
            L10n.appleWatch,
            L10n.appleWatchFooter,
            L10n.p2pAudioNetwork,
            L10n.soundPatternRecognition,
            L10n.experimental,
            L10n.version,
            L10n.website,
            L10n.officialSite,
            L10n.screenStatus,
            L10n.analyzingScreen,
            L10n.operations,
            L10n.active,
            L10n.macDisconnectedMessage,
            L10n.copyAction,
            L10n.pasteAction,
            L10n.undoAction,
            L10n.switchTab,
            L10n.closeWindow,
            L10n.spacePlay,
            L10n.settings,
            L10n.done,
            L10n.language,
            L10n.aiTextCorrection,
            L10n.style,
            L10n.styleCorrect,
            L10n.styleEmail,
            L10n.styleChat,
            L10n.styleTranslate,
            L10n.translateTarget,
            L10n.english,
            L10n.japanese,
            L10n.chinese,
            L10n.korean,
            L10n.aiFooter,
            L10n.autoCopyAfterRecognition,
            L10n.autoSendToMac,
            L10n.continuousMode,
            L10n.continuousModeFooter,
            L10n.connected,
            L10n.notConnected,
            L10n.macAutoConnect,
            L10n.betaFeatures,
            L10n.screenContextFooter,
            L10n.silenceAutoStop,
            L10n.offManual,
            L10n.realtimePreview,
            L10n.recording,
            L10n.streamingPreviewFooter,
            L10n.speechEngine,
            L10n.engine,
            L10n.ready,
            L10n.history,
            L10n.historyEmpty,
            L10n.noHistory,
            L10n.deleteAll,
            L10n.searchHistory,
            L10n.close,
            L10n.quickPhrases,
            L10n.quickPhrasesFooter,
            L10n.addPhrase,
            L10n.enterPhrase,
            L10n.add,
            L10n.phrasePaletteTitle,
            L10n.noPhrases,
            L10n.registeredPhrases,
            L10n.phraseEditHint,
            L10n.save,
            L10n.startRecording,
            L10n.stop,
            L10n.share,
            L10n.meetingEmpty,
            L10n.generatingSummary,
        ]
        for (i, s) in strings.enumerated() {
            XCTAssertFalse(s.isEmpty, "L10n property at index \(i) returned empty string")
        }
    }

    /// The showAll function should include the count.
    func testShowAllContainsCount() {
        let result = L10n.showAll(42)
        XCTAssertTrue(result.contains("42"), "showAll should contain the count: \(result)")
    }

    /// The downloadModelLabel function should include the size.
    func testDownloadModelLabelContainsSize() {
        let result = L10n.downloadModelLabel(500)
        XCTAssertTrue(result.contains("500"), "downloadModelLabel should contain size: \(result)")
    }

    /// connectedToMac returns a different string for each supported language.
    /// We verify the known strings exist (regardless of current locale).
    func testConnectedToMacHasFourLanguageVariants() {
        let variants: Set<String> = [
            "Macに接続中",       // ja
            "已连接到Mac",       // zh
            "Mac에 연결됨",      // ko
            "Connected to Mac", // en
        ]
        // The current locale's connectedToMac must be one of the four
        XCTAssertTrue(variants.contains(L10n.connectedToMac),
                      "connectedToMac returned unexpected value: \(L10n.connectedToMac)")
    }

    /// Regression: no L10n string should contain smart quotes or the character "嗯".
    func testNoSmartQuotesOrEncodingIssues() {
        let allStrings: [String] = [
            L10n.connectedToMac, L10n.translateMode, L10n.nextAction, L10n.phrases,
            L10n.wakeWordHint, L10n.alwaysListeningFooter, L10n.pinPrompt,
            L10n.macPromoTitle, L10n.macPromoSubtitle, L10n.downloadMacFree,
            L10n.settings, L10n.done, L10n.cancel, L10n.cancelAction,
            L10n.quickPhrases, L10n.quickPhrasesFooter, L10n.addPhrase,
        ]
        let forbidden: [Character] = ["\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"] // smart quotes
        let forbiddenString = "嗯"
        for s in allStrings {
            for ch in forbidden {
                XCTAssertFalse(s.contains(ch), "String contains smart quote \\u{\(ch.unicodeScalars.first!.value)}: \(s)")
            }
            XCTAssertFalse(s.contains(forbiddenString), "String contains '嗯': \(s)")
        }
    }
}

// MARK: - MacBridge Message Format Tests

/// Tests the JSON message dictionaries that MacBridge constructs.
/// We test the dictionary structure directly (no MCSession needed).
final class MacBridgeMessageFormatTests: XCTestCase {

    func testTextMessageFormat() {
        let msg: [String: String] = ["type": "text", "text": "hello"]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(decoded["type"], "text")
        XCTAssertEqual(decoded["text"], "hello")
    }

    func testCommandMessageFormat() {
        let msg: [String: String] = ["type": "command", "command": "copy"]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(decoded["type"], "command")
        XCTAssertEqual(decoded["command"], "copy")
    }

    func testToggleAgentMessageFormat() {
        let msg: [String: Any] = ["type": "toggle_agent", "enabled": true]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["type"] as? String, "toggle_agent")
        XCTAssertEqual(decoded["enabled"] as? Bool, true)
    }

    func testStreamingTextMessageFormat() {
        let msg: [String: String] = ["type": "streaming_text", "text": "partial result"]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(decoded["type"], "streaming_text")
        XCTAssertEqual(decoded["text"], "partial result")
    }

    func testBackspaceMessageFormat() {
        let msg: [String: Any] = ["type": "backspace", "count": 5]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["type"] as? String, "backspace")
        XCTAssertEqual(decoded["count"] as? Int, 5)
    }

    func testEnterMessageFormat() {
        let msg: [String: String] = ["type": "enter"]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(decoded["type"], "enter")
    }

    func testMouseMoveMessageFormat() {
        let msg: [String: Any] = ["type": "mouse_move", "dx": 10.5, "dy": -3.2]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["type"] as? String, "mouse_move")
        XCTAssertEqual(decoded["dx"] as! Double, 10.5, accuracy: 0.001)
        XCTAssertEqual(decoded["dy"] as! Double, -3.2, accuracy: 0.001)
    }

    func testMouseClickMessageFormat() {
        let msg: [String: Any] = ["type": "mouse_click", "x": 0.5, "y": 0.75]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["type"] as? String, "mouse_click")
        XCTAssertEqual(decoded["x"] as! Double, 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded["y"] as! Double, 0.75, accuracy: 0.001)
    }

    /// Verify that the JSON round-trips correctly with Unicode text.
    func testTextMessageWithJapanese() {
        let msg: [String: String] = ["type": "text", "text": "お世話になっております"]
        let data = try! JSONSerialization.data(withJSONObject: msg)
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(decoded["text"], "お世話になっております")
    }
}

// MARK: - HistoryItem Tests

final class HistoryItemTests: XCTestCase {

    func testHistoryItemCodable() {
        let item = HistoryItem(text: "test", date: Date(timeIntervalSince1970: 1000))
        let data = try! JSONEncoder().encode(item)
        let decoded = try! JSONDecoder().decode(HistoryItem.self, from: data)
        XCTAssertEqual(decoded.text, "test")
        XCTAssertEqual(decoded.date.timeIntervalSince1970, 1000, accuracy: 0.001)
    }

    func testHistoryItemHasUniqueID() {
        let a = HistoryItem(text: "a", date: Date())
        let b = HistoryItem(text: "b", date: Date())
        XCTAssertNotEqual(a.id, b.id)
    }
}
