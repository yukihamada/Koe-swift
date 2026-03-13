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
    var isLocal: Bool {
        switch self {
        case .whisperCpp, .appleOnDevice: return true
        case .appleCloud, .whisper:       return false
        }
    }
    var badgeText: String { isLocal ? "LOCAL" : "CLOUD" }
}

enum LLMMode: String, CaseIterable, Codable {
    case none      = "none"
    case correct   = "correct"
    case email     = "email"
    case chat      = "chat"
    case minutes   = "minutes"
    case code      = "code"
    case translate = "translate"
    case custom    = "custom"

    var displayName: String {
        switch self {
        case .none:      return "なし（LLM処理しない）"
        case .correct:   return "修正（誤字・句読点）"
        case .email:     return "メール（丁寧な文体）"
        case .chat:      return "チャット（カジュアル）"
        case .minutes:   return "議事録（箇条書き）"
        case .code:      return "コード（コメント形式）"
        case .translate: return "翻訳（日↔英）"
        case .custom:    return "カスタム"
        }
    }

    var instruction: String {
        switch self {
        case .none:
            return ""
        case .correct:
            return """
            音声認識の結果を修正してください。以下のルールに従ってください：
            - 誤字・脱字を修正
            - 適切な句読点（、。）を追加
            - 明らかな認識ミスを文脈から推測して修正
            - 元の意味を変えない
            - 修正後のテキストのみを出力（説明不要）
            """
        case .email:
            return """
            音声認識の結果を丁寧なメール文体に変換してください：
            - 敬語・丁寧語を適切に使用
            - ビジネスメールにふさわしい文体に整える
            - 句読点を正しく配置
            - 挨拶文や結びの言葉は追加しない（本文のみ）
            - 変換後のテキストのみを出力（説明不要）
            """
        case .chat:
            return """
            音声認識の結果をカジュアルなチャットメッセージに変換してください：
            - 短く簡潔に
            - 話し言葉のまま自然に
            - 句読点は最小限
            - 変換後のテキストのみを出力（説明不要）
            """
        case .minutes:
            return """
            音声認識の結果を議事録形式の箇条書きに変換してください：
            - 要点を箇条書き（・）で整理
            - 冗長な表現を省略
            - 結論・決定事項・アクションアイテムを明確に
            - 変換後のテキストのみを出力（説明不要）
            """
        case .code:
            return """
            音声認識の結果をコードコメントまたは変数名に変換してください：
            - 日本語の説明は // コメント形式に
            - 変数名・関数名の指示があれば camelCase で出力
            - プログラミング用語を正確に
            - 変換後のテキストのみを出力（説明不要）
            """
        case .translate:
            return """
            音声認識の結果を翻訳してください：
            - 日本語の入力は自然な英語に翻訳
            - 英語の入力は自然な日本語に翻訳
            - 意味を正確に保つ
            - 翻訳後のテキストのみを出力（説明不要）
            """
        case .custom:
            return ""  // カスタムプロンプトを使用
        }
    }
}

enum LLMProvider: String, CaseIterable {
    case chatweb   = "chatweb"     // chatweb.ai (default, free)
    case openai    = "openai"      // OpenAI
    case anthropic = "anthropic"   // Anthropic Claude
    case groq      = "groq"        // Groq (fast)
    case custom    = "custom"      // Custom endpoint

    var displayName: String {
        switch self {
        case .chatweb:   return "chatweb.ai (無料)"
        case .openai:    return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .groq:      return "Groq (高速)"
        case .custom:    return "カスタム"
        }
    }

    var baseURL: String {
        switch self {
        case .chatweb:   return "https://api.chatweb.ai"
        case .openai:    return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .groq:      return "https://api.groq.com/openai"
        case .custom:    return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .chatweb:   return "nemotron"
        case .openai:    return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .groq:      return "llama-3.1-8b-instant"
        case .custom:    return "auto"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .chatweb: return false
        default:       return true
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

// MARK: - Architecture Detection

enum ArchUtil {
    /// Apple Silicon (arm64) かどうかを判定
    static var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0)
            }
        }
        return machine?.contains("arm64") == true
    }
}

// MARK: - AppSettings

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Shortcut
    @Published var shortcutKeyCode: Int   { didSet { ud.set(shortcutKeyCode,                   forKey: "shortcutKeyCode") } }
    @Published var shortcutModifiers: UInt { didSet { ud.set(Int(bitPattern: shortcutModifiers), forKey: "shortcutModifiers") } }
    @Published var recordingMode: RecordingMode { didSet { ud.set(recordingMode.rawValue, forKey: "recordingMode") } }

    // Translation hotkey
    @Published var translateHotkeyCode: Int   { didSet { ud.set(translateHotkeyCode, forKey: "translateHotkeyCode") } }
    @Published var translateHotkeyModifiers: UInt { didSet { ud.set(Int(bitPattern: translateHotkeyModifiers), forKey: "translateHotkeyModifiers") } }
    @Published var translateTargetLang: String { didSet { ud.set(translateTargetLang, forKey: "translateTargetLang") } }

    // Recognition
    @Published var language: String          { didSet { ud.set(language,               forKey: "language"); AppDelegate.shared?.reloadSpeechEngine() } }

    /// 主要言語のフラグ・表示名マッピング（メニューバー・設定画面で共用）
    static let quickLanguages: [(flag: String, name: String, code: String)] = [
        ("🇯🇵", "日本語",       "ja-JP"),
        ("🇺🇸", "English",     "en-US"),
        ("🇨🇳", "中文(简体)",   "zh-CN"),
        ("🇹🇼", "中文(繁體)",   "zh-TW"),
        ("🇰🇷", "한국어",       "ko-KR"),
        ("🇪🇸", "Español",     "es-ES"),
        ("🇫🇷", "Français",    "fr-FR"),
        ("🇩🇪", "Deutsch",     "de-DE"),
        ("🇮🇹", "Italiano",    "it-IT"),
        ("🇵🇹", "Português",   "pt-BR"),
        ("🇷🇺", "Русский",     "ru-RU"),
        ("🇮🇳", "हिन्दी",        "hi-IN"),
        ("🇹🇭", "ไทย",         "th-TH"),
        ("🇻🇳", "Tiếng Việt",  "vi-VN"),
        ("🇮🇩", "Indonesia",   "id-ID"),
        ("🇳🇱", "Nederlands",  "nl-NL"),
        ("🇵🇱", "Polski",      "pl-PL"),
        ("🇹🇷", "Türkçe",      "tr-TR"),
        ("🇸🇦", "العربية",      "ar-SA"),
        ("🌐", "Auto Detect",  "auto"),
    ]

    /// メニューバーに表示する言語コード一覧（ユーザーがカスタマイズ可能）
    @Published var menuBarLanguageCodes: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(menuBarLanguageCodes) { ud.set(data, forKey: "menuBarLanguageCodes") }
            AppDelegate.shared?.rebuildMenuPublic()
        }
    }

    /// メニューバー用の言語リスト（menuBarLanguageCodes に基づく）
    var menuBarLanguages: [(flag: String, name: String, code: String)] {
        menuBarLanguageCodes.compactMap { code in
            Self.quickLanguages.first { $0.code == code }
        }
    }

    /// メニューバーに表示されない言語リスト
    var otherLanguages: [(flag: String, name: String, code: String)] {
        Self.quickLanguages.filter { lang in !menuBarLanguageCodes.contains(lang.code) }
    }

    /// 現在の言語に対応するフラグ絵文字を返す
    var languageFlag: String {
        AppSettings.quickLanguages.first { $0.code == language }?.flag ?? "🌐"
    }
    @Published var recognitionEngine: RecognitionEngine { didSet { ud.set(recognitionEngine.rawValue, forKey: "recognitionEngine") } }
    @Published var whisperAPIKey: String     { didSet { ud.set(whisperAPIKey,           forKey: "whisperAPIKey") } }
    @Published var whisperCppBinaryPath: String { didSet { ud.set(whisperCppBinaryPath, forKey: "whisperCppBinaryPath") } }
    @Published var whisperCppModelPath: String  { didSet { ud.set(whisperCppModelPath,  forKey: "whisperCppModelPath") } }

    // LLM
    @Published var llmEnabled: Bool   { didSet { ud.set(llmEnabled,  forKey: "llmEnabled") } }
    @Published var llmUseLocal: Bool  { didSet { ud.set(llmUseLocal, forKey: "llmUseLocal") } }
    @Published var llmProvider: LLMProvider { didSet {
        ud.set(llmProvider.rawValue, forKey: "llmProvider")
        // プロバイダ変更時にベースURLとモデルをプリセットで上書き
        if llmProvider != .custom {
            llmBaseURL = llmProvider.baseURL
            llmModel   = llmProvider.defaultModel
        }
    }}
    @Published var llmBaseURL: String { didSet { ud.set(llmBaseURL,  forKey: "llmBaseURL") } }
    @Published var llmAPIKey: String  { didSet { ud.set(llmAPIKey,   forKey: "llmAPIKey") } }
    @Published var llmModel: String   { didSet { ud.set(llmModel,    forKey: "llmModel") } }
    @Published var llmCustomPrompt: String { didSet { ud.set(llmCustomPrompt, forKey: "llmCustomPrompt") } }
    @Published var llmMode: LLMMode { didSet { ud.set(llmMode.rawValue, forKey: "llmMode") } }
    @Published var llmMemorySaveMode: Bool { didSet { ud.set(llmMemorySaveMode, forKey: "llmMemorySaveMode") } }
    @Published var superModeEnabled: Bool { didSet { ud.set(superModeEnabled, forKey: "superModeEnabled") } }

    // Agent mode (voice commands)
    @Published var agentModeEnabled: Bool { didSet { ud.set(agentModeEnabled, forKey: "agentModeEnabled") } }

    // Login item (ログイン時に自動起動)
    @Published var launchAtLogin: Bool { didSet {
        ud.set(launchAtLogin, forKey: "launchAtLogin")
        LoginItemManager.setEnabled(launchAtLogin)
    }}

    // Context-aware recognition
    @Published var contextAwareEnabled: Bool { didSet { ud.set(contextAwareEnabled, forKey: "contextAwareEnabled") } }
    @Published var contextUseClipboard: Bool { didSet { ud.set(contextUseClipboard, forKey: "contextUseClipboard") } }
    @Published var contextUseAppHint: Bool   { didSet { ud.set(contextUseAppHint, forKey: "contextUseAppHint") } }
    @Published var contextCustomPrompt: String { didSet { ud.set(contextCustomPrompt, forKey: "contextCustomPrompt") } }

    // Clipboard
    @Published var autoCopyToClipboard: Bool { didSet { ud.set(autoCopyToClipboard, forKey: "autoCopyToClipboard") } }

    // Notifications
    @Published var notifyOnComplete: Bool { didSet { ud.set(notifyOnComplete, forKey: "notifyOnComplete") } }

    // Floating button
    @Published var floatingButtonEnabled: Bool { didSet {
        ud.set(floatingButtonEnabled, forKey: "floatingButtonEnabled")
        if floatingButtonEnabled { FloatingButton.shared.show() } else { FloatingButton.shared.hide() }
    }}

    // Streaming preview (real-time transcription during recording)
    @Published var streamingPreviewEnabled: Bool { didSet { ud.set(streamingPreviewEnabled, forKey: "streamingPreviewEnabled") } }

    // Whisper advanced params
    @Published var whisperBestOf: Int { didSet { ud.set(whisperBestOf, forKey: "whisperBestOf") } }
    @Published var whisperEntropyThreshold: Double { didSet { ud.set(whisperEntropyThreshold, forKey: "whisperEntropyThreshold") } }
    @Published var whisperTemperature: Double { didSet { ud.set(whisperTemperature, forKey: "whisperTemperature") } }
    @Published var whisperTemperatureInc: Double { didSet { ud.set(whisperTemperatureInc, forKey: "whisperTemperatureInc") } }
    @Published var silenceAutoStopSeconds: Double { didSet { ud.set(silenceAutoStopSeconds, forKey: "silenceAutoStopSeconds") } }
    @Published var whisperBeamSearch: Bool { didSet { ud.set(whisperBeamSearch, forKey: "whisperBeamSearch") } }
    @Published var whisperUseContext: Bool { didSet { ud.set(whisperUseContext, forKey: "whisperUseContext") } }

    // Speaker diarization (tinydiarize)
    @Published var diarizationEnabled: Bool { didSet { ud.set(diarizationEnabled, forKey: "diarizationEnabled") } }

    // IME switch (左⌘→英語, 右⌘→日本語)
    @Published var cmdIMESwitchEnabled: Bool { didSet { ud.set(cmdIMESwitchEnabled, forKey: "cmdIMESwitchEnabled") } }

    // Wake word
    @Published var wakeWordEnabled: Bool { didSet {
        ud.set(wakeWordEnabled, forKey: "wakeWordEnabled")
        if wakeWordEnabled { WakeWordDetector.shared.start() } else { WakeWordDetector.shared.stop() }
    }}
    @Published var wakeWords: [String] { didSet { saveWakeWords() } }

    // App profiles & text expansions
    @Published var appProfiles: [AppProfile]    { didSet { saveJSON(appProfiles,    key: "appProfiles") } }
    @Published var textExpansions: [TextExpansion] { didSet { saveJSON(textExpansions, key: "textExpansions"); rebuildExpansionMap() } }

    // Filler removal (えー、あの、えっと等の自動除去)
    @Published var fillerRemovalEnabled: Bool { didSet { ud.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled") } }

    // Punctuation style (句読点スタイル)
    @Published var punctuationStyle: String { didSet { ud.set(punctuationStyle, forKey: "punctuationStyle") } }

    // Command Mode (音声でテキスト編集)
    @Published var commandModeEnabled: Bool { didSet { ud.set(commandModeEnabled, forKey: "commandModeEnabled") } }

    // Noise level display (環境ノイズレベル表示)
    @Published var showNoiseLevel: Bool { didSet { ud.set(showNoiseLevel, forKey: "showNoiseLevel") } }

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

    var translateShortcutDisplayString: String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: translateHotkeyModifiers)
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(translateHotkeyCode))
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
        case 0:  return "A";  case 9:  return "V"; case 17: return "T"
        case 49: return "Space"
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

        // Translation hotkey defaults: Cmd+Option+T (keyCode 17 = T)
        translateHotkeyCode = ud.object(forKey: "translateHotkeyCode") as? Int ?? 17
        let savedTransMods  = ud.object(forKey: "translateHotkeyModifiers") as? Int
        translateHotkeyModifiers = savedTransMods.map { UInt(bitPattern: $0) }
            ?? (NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue)
        // Default target language: "en" if current lang starts with "ja", otherwise "ja"
        let savedLang = ud.string(forKey: "language") ?? "ja-JP"
        let defaultTarget = savedLang.hasPrefix("ja") ? "en" : "ja"
        translateTargetLang = ud.string(forKey: "translateTargetLang") ?? defaultTarget

        language          = savedLang
        menuBarLanguageCodes = (ud.data(forKey: "menuBarLanguageCodes").flatMap { try? JSONDecoder().decode([String].self, from: $0) })
            ?? ["ja-JP", "en-US", "zh-CN", "ko-KR", "auto"]
        recognitionEngine = RecognitionEngine(rawValue: ud.string(forKey: "recognitionEngine") ?? "") ?? .whisperCpp
        whisperAPIKey        = ud.string(forKey: "whisperAPIKey") ?? ""
        whisperCppBinaryPath = ud.string(forKey: "whisperCppBinaryPath") ?? ""
        whisperCppModelPath  = ud.string(forKey: "whisperCppModelPath") ?? ""
        launchAtLogin         = ud.object(forKey: "launchAtLogin") as? Bool ?? true  // デフォルトON
        contextAwareEnabled   = ud.object(forKey: "contextAwareEnabled") as? Bool ?? true  // デフォルトON
        contextUseClipboard   = ud.object(forKey: "contextUseClipboard") as? Bool ?? false  // デフォルトOFF（精度低下の原因になりやすい）
        contextUseAppHint     = ud.object(forKey: "contextUseAppHint") as? Bool ?? true
        contextCustomPrompt   = ud.string(forKey: "contextCustomPrompt") ?? ""
        autoCopyToClipboard   = ud.bool(forKey: "autoCopyToClipboard")
        notifyOnComplete      = ud.bool(forKey: "notifyOnComplete")
        floatingButtonEnabled = ud.bool(forKey: "floatingButtonEnabled")
        llmEnabled  = ud.object(forKey: "llmEnabled") as? Bool ?? true  // デフォルトON
        llmUseLocal = ud.object(forKey: "llmUseLocal") as? Bool ?? true  // デフォルトはローカル
        llmProvider = LLMProvider(rawValue: ud.string(forKey: "llmProvider") ?? "") ?? .chatweb
        llmBaseURL  = ud.string(forKey: "llmBaseURL") ?? "https://api.chatweb.ai"
        llmAPIKey   = ud.string(forKey: "llmAPIKey") ?? ""
        llmModel    = ud.string(forKey: "llmModel") ?? "auto"
        llmCustomPrompt = ud.string(forKey: "llmCustomPrompt") ?? ""
        llmMode = LLMMode(rawValue: ud.string(forKey: "llmMode") ?? "") ?? .none
        llmMemorySaveMode = ud.object(forKey: "llmMemorySaveMode") as? Bool ?? false  // デフォルトOFF（常時読み込み）
        superModeEnabled = ud.object(forKey: "superModeEnabled") as? Bool ?? false  // デフォルトOFF
        agentModeEnabled = ud.object(forKey: "agentModeEnabled") as? Bool ?? false  // デフォルトOFF
        streamingPreviewEnabled = ud.object(forKey: "streamingPreviewEnabled") as? Bool ?? false  // デフォルトOFF: Apple Speechでリアルタイム入力
        whisperBestOf = ud.object(forKey: "whisperBestOf") as? Int ?? 1
        whisperEntropyThreshold = ud.object(forKey: "whisperEntropyThreshold") as? Double ?? 2.4
        whisperTemperature = ud.object(forKey: "whisperTemperature") as? Double ?? 0.0
        whisperTemperatureInc = ud.object(forKey: "whisperTemperatureInc") as? Double ?? 0.2
        silenceAutoStopSeconds = ud.object(forKey: "silenceAutoStopSeconds") as? Double ?? 2.0
        whisperBeamSearch = ud.object(forKey: "whisperBeamSearch") as? Bool ?? false  // デフォルトOFF（速度優先、greedyで十分）
        whisperUseContext = ud.object(forKey: "whisperUseContext") as? Bool ?? true   // デフォルトON（長文の一貫性）
        diarizationEnabled = ud.object(forKey: "diarizationEnabled") as? Bool ?? false  // デフォルトOFF
        cmdIMESwitchEnabled = ud.object(forKey: "cmdIMESwitchEnabled") as? Bool ?? true  // デフォルトON
        wakeWordEnabled = ud.bool(forKey: "wakeWordEnabled")
        wakeWords = (ud.data(forKey: "wakeWords").flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? ["ヘイエリオ", "ヘイこえ"]
        textExpansions = (ud.data(forKey: "textExpansions").flatMap { try? JSONDecoder().decode([TextExpansion].self, from: $0) }) ?? []
        appProfiles = (ud.data(forKey: "appProfiles").flatMap { try? JSONDecoder().decode([AppProfile].self, from: $0) }) ?? AppSettings.defaultProfiles()
        fillerRemovalEnabled = ud.object(forKey: "fillerRemovalEnabled") as? Bool ?? true  // デフォルトON
        punctuationStyle = ud.string(forKey: "punctuationStyle") ?? "japanese"
        commandModeEnabled = ud.object(forKey: "commandModeEnabled") as? Bool ?? true  // デフォルトON
        showNoiseLevel = ud.object(forKey: "showNoiseLevel") as? Bool ?? true  // デフォルトON
        rebuildExpansionMap()
    }

    private static func defaultProfiles() -> [AppProfile] {
        let terminalPrompt = "これは開発者のターミナル操作です。コマンド、ファイルパス、CLI、Git、シェルスクリプトの用語を正確に認識してください。"
        let codePrompt = "これはコードエディタでの作業です。プログラミング用語、変数名、関数名、Swift、Python、Rust、TypeScript の構文を正確に認識してください。"
        return [
            // ターミナル
            AppProfile(bundleID: "com.mitchellh.ghostty",  appName: "Ghostty",   prompt: terminalPrompt, language: "ja-JP"),
            AppProfile(bundleID: "com.apple.Terminal",      appName: "ターミナル", prompt: terminalPrompt, language: "ja-JP"),
            AppProfile(bundleID: "com.googlecode.iterm2",   appName: "iTerm2",    prompt: terminalPrompt, language: "ja-JP"),
            // コードエディタ
            AppProfile(bundleID: "com.microsoft.VSCode",    appName: "VS Code",   prompt: codePrompt,     language: "ja-JP"),
            AppProfile(bundleID: "com.apple.dt.Xcode",      appName: "Xcode",
                       prompt: "これは Xcode での Swift/SwiftUI 開発です。Swift、SwiftUI、UIKit、Xcode の用語を正確に認識してください。",
                       language: "ja-JP"),
            // ブラウザ
            AppProfile(bundleID: "com.apple.Safari",        appName: "Safari",
                       prompt: "ブラウザでの作業です。URL、ウェブサイト名、検索ワードを正確に認識してください。",
                       language: "ja-JP"),
            AppProfile(bundleID: "com.google.Chrome",       appName: "Chrome",
                       prompt: "ブラウザでの作業です。URL、ウェブサイト名、検索ワードを正確に認識してください。",
                       language: "ja-JP"),
            // メール・チャット
            AppProfile(bundleID: "com.apple.mail",          appName: "メール",
                       prompt: "メール作成中です。敬語や丁寧な表現を優先してください。",
                       language: "ja-JP",
                       llmInstruction: "メールにふさわしい丁寧な文体に整えてください。敬語を適切に使い、句読点を補正してください。"),
            AppProfile(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                       prompt: "Slackでのチャットです。カジュアルな表現も許容してください。",
                       language: "ja-JP"),
            // ドキュメント
            AppProfile(bundleID: "com.apple.iWork.Pages",   appName: "Pages",
                       prompt: "文書作成中です。正確な日本語で認識してください。",
                       language: "ja-JP"),
            AppProfile(bundleID: "com.apple.Notes",         appName: "メモ",
                       prompt: "メモの入力です。箇条書きやキーワードを正確に認識してください。",
                       language: "ja-JP"),
        ]
    }
}
