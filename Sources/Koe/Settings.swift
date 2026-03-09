import Foundation
import AppKit

// MARK: - Supporting types

struct AppProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var bundleID: String
    var appName: String
    var prompt: String
    var language: String
    var llmInstruction: String

    init(id: UUID = UUID(), bundleID: String, appName: String, prompt: String = "", language: String = "", llmInstruction: String = "") {
        self.id = id
        self.bundleID = bundleID; self.appName = appName
        self.prompt = prompt; self.language = language; self.llmInstruction = llmInstruction
    }

    // Backward-compatible decode (llmInstruction may be missing in old data)
    enum CodingKeys: String, CodingKey { case id, bundleID, appName, prompt, language, llmInstruction }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = (try? c.decode(UUID.self,   forKey: .id))             ?? UUID()
        bundleID       = try  c.decode(String.self,  forKey: .bundleID)
        appName        = try  c.decode(String.self,  forKey: .appName)
        prompt         = (try? c.decode(String.self, forKey: .prompt))         ?? ""
        language       = (try? c.decode(String.self, forKey: .language))       ?? ""
        llmInstruction = (try? c.decode(String.self, forKey: .llmInstruction)) ?? ""
    }
}

struct TextExpansion: Codable, Identifiable {
    var id: UUID = UUID()
    var trigger: String    // 話す言葉 e.g. "メアド"
    var expansion: String  // 展開後   e.g. "yuki@example.com"
}

enum RecognitionEngine: String, CaseIterable {
    case whisperCpp    = "whisper-cpp"
    case appleOnDevice = "apple-ondevice"
    case appleCloud    = "apple-cloud"
    case whisper       = "whisper"
    var displayName: String {
        switch self {
        case .whisperCpp:    return "whisper.cpp (Metal・最速)"
        case .appleOnDevice: return "Apple (オンデバイス)"
        case .appleCloud:    return "Apple (クラウド)"
        case .whisper:       return "OpenAI Whisper API"
        }
    }
}

enum RecordingMode: String, CaseIterable {
    case hold   = "hold"
    case toggle = "toggle"
    var displayName: String {
        switch self {
        case .hold:   return "ホールド（押している間）"
        case .toggle: return "トグル（1回で開始・もう1回で終了）"
        }
    }
}

// MARK: - AppSettings

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Shortcut
    @Published var shortcutKeyCode: Int   { didSet { ud.set(shortcutKeyCode,                   forKey: "shortcutKeyCode") } }
    @Published var shortcutModifiers: UInt { didSet { ud.set(Int(bitPattern: shortcutModifiers), forKey: "shortcutModifiers") } }
    @Published var recordingMode: RecordingMode { didSet { ud.set(recordingMode.rawValue, forKey: "recordingMode") } }

    // Recognition
    @Published var language: String          { didSet { ud.set(language,               forKey: "language") } }
    @Published var recognitionEngine: RecognitionEngine { didSet { ud.set(recognitionEngine.rawValue, forKey: "recognitionEngine") } }
    @Published var whisperAPIKey: String     { didSet { ud.set(whisperAPIKey,           forKey: "whisperAPIKey") } }
    @Published var whisperCppBinaryPath: String { didSet { ud.set(whisperCppBinaryPath, forKey: "whisperCppBinaryPath") } }
    @Published var whisperCppModelPath: String  { didSet { ud.set(whisperCppModelPath,  forKey: "whisperCppModelPath") } }

    // LLM
    @Published var llmEnabled: Bool   { didSet { ud.set(llmEnabled,  forKey: "llmEnabled") } }
    @Published var llmBaseURL: String { didSet { ud.set(llmBaseURL,  forKey: "llmBaseURL") } }
    @Published var llmAPIKey: String  { didSet { ud.set(llmAPIKey,   forKey: "llmAPIKey") } }
    @Published var llmModel: String   { didSet { ud.set(llmModel,    forKey: "llmModel") } }

    // Floating button
    @Published var floatingButtonEnabled: Bool { didSet {
        ud.set(floatingButtonEnabled, forKey: "floatingButtonEnabled")
        if floatingButtonEnabled { FloatingButton.shared.show() } else { FloatingButton.shared.hide() }
    }}

    // Wake word
    @Published var wakeWordEnabled: Bool { didSet {
        ud.set(wakeWordEnabled, forKey: "wakeWordEnabled")
        if wakeWordEnabled { WakeWordDetector.shared.start() } else { WakeWordDetector.shared.stop() }
    }}
    @Published var wakeWords: [String] { didSet { saveWakeWords() } }

    // App profiles & text expansions
    @Published var appProfiles: [AppProfile]    { didSet { saveJSON(appProfiles,    key: "appProfiles") } }
    @Published var textExpansions: [TextExpansion] { didSet { saveJSON(textExpansions, key: "textExpansions"); rebuildExpansionMap() } }

    private let ud = UserDefaults.standard

    // MARK: Computed

    var shortcutDisplayString: String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: shortcutModifiers)
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(shortcutKeyCode))
        return parts.joined()
    }

    func profile(for bundleID: String) -> AppProfile? {
        appProfiles.first { $0.bundleID == bundleID }
    }

    // O(1) 展開: textExpansions変更時に自動更新
    private var expansionMap: [String: String] = [:]

    func expand(_ text: String) -> String {
        let key = text.trimmingCharacters(in: .whitespaces)
        if let hit = expansionMap[key] {
            klog("TextExpand: '\(key)' → '\(hit)'")
            return hit
        }
        return text
    }

    private func rebuildExpansionMap() {
        expansionMap = Dictionary(textExpansions.map { ($0.trigger, $0.expansion) },
                                  uniquingKeysWith: { $1 })
    }

    // MARK: Private helpers

    private func keyCodeToString(_ code: Int) -> String {
        switch code {
        case 0:  return "A";  case 9:  return "V"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"
        case 100: return "F8"; case 101: return "F9"; case 109: return "F10"
        default: return "Key(\(code))"
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { ud.set(data, forKey: key) }
    }

    private func saveWakeWords() {
        if let data = try? JSONEncoder().encode(wakeWords) { ud.set(data, forKey: "wakeWords") }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        ud.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private init() {
        shortcutKeyCode   = ud.object(forKey: "shortcutKeyCode") as? Int ?? 9
        let savedMods     = ud.object(forKey: "shortcutModifiers") as? Int
        shortcutModifiers = savedMods.map { UInt(bitPattern: $0) }
            ?? (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue)
        recordingMode     = RecordingMode(rawValue: ud.string(forKey: "recordingMode") ?? "") ?? .hold
        language          = ud.string(forKey: "language") ?? "ja-JP"
        recognitionEngine = RecognitionEngine(rawValue: ud.string(forKey: "recognitionEngine") ?? "") ?? .whisperCpp
        whisperAPIKey        = ud.string(forKey: "whisperAPIKey") ?? ""
        whisperCppBinaryPath = ud.string(forKey: "whisperCppBinaryPath") ?? ""
        whisperCppModelPath  = ud.string(forKey: "whisperCppModelPath") ?? ""
        floatingButtonEnabled = ud.bool(forKey: "floatingButtonEnabled")
        llmEnabled  = ud.bool(forKey: "llmEnabled")
        llmBaseURL  = ud.string(forKey: "llmBaseURL") ?? "https://api.chatweb.ai"
        llmAPIKey   = ud.string(forKey: "llmAPIKey") ?? ""
        llmModel    = ud.string(forKey: "llmModel") ?? "auto"
        wakeWordEnabled = ud.bool(forKey: "wakeWordEnabled")
        wakeWords = (ud.data(forKey: "wakeWords").flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? ["ヘイエリオ", "ヘイこえ"]
        textExpansions = (ud.data(forKey: "textExpansions").flatMap { try? JSONDecoder().decode([TextExpansion].self, from: $0) }) ?? []
        appProfiles = (ud.data(forKey: "appProfiles").flatMap { try? JSONDecoder().decode([AppProfile].self, from: $0) }) ?? AppSettings.defaultProfiles()
        rebuildExpansionMap()
    }

    private static func defaultProfiles() -> [AppProfile] {
        let terminalPrompt = "これは開発者のターミナル操作です。コマンド、ファイルパス、CLI、Git、シェルスクリプトの用語を正確に認識してください。"
        let codePrompt = "これはコードエディタでの作業です。プログラミング用語、変数名、関数名、Swift、Python、Rust、TypeScript の構文を正確に認識してください。"
        return [
            AppProfile(bundleID: "com.mitchellh.ghostty",  appName: "Ghostty",   prompt: terminalPrompt, language: "ja-JP"),
            AppProfile(bundleID: "com.apple.Terminal",      appName: "ターミナル", prompt: terminalPrompt, language: "ja-JP"),
            AppProfile(bundleID: "com.googlecode.iterm2",   appName: "iTerm2",    prompt: terminalPrompt, language: "ja-JP"),
            AppProfile(bundleID: "com.microsoft.VSCode",    appName: "VS Code",   prompt: codePrompt,     language: "ja-JP"),
            AppProfile(bundleID: "com.apple.dt.Xcode",      appName: "Xcode",
                       prompt: "これは Xcode での Swift/SwiftUI 開発です。Swift、SwiftUI、UIKit、Xcode の用語を正確に認識してください。",
                       language: "ja-JP"),
        ]
    }
}
