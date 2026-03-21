import AppKit
import UserNotifications
import IOKit.hidsystem
import Vision

// MARK: - Agent Command

enum AgentCommand {
    case openApp(name: String)
    case search(query: String)
    case screenshot
    case timer(minutes: Int)
    case shellCommand(cmd: String)
    case shortcut(name: String)
    // Screen-aware commands (require voiceControlEnabled)
    case clickElement(description: String)
    case explainScreen(question: String)
    // Screen AI agent — see screen, think, act
    case screenAction(instruction: String)  // 「〜して」→ 画面を見てLLMが実行
    // System control commands (require voiceControlEnabled)
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown
    case playPause
    case nextTrack
    case prevTrack
    case sleep
    case lockScreen

    var description: String {
        switch self {
        case .openApp(let name):     return "アプリを開く: \(name)"
        case .search(let query):     return "検索: \(query)"
        case .screenshot:            return "スクリーンショット"
        case .timer(let minutes):    return "タイマー: \(minutes)分"
        case .shellCommand(let cmd): return "コマンド実行: \(cmd)"
        case .shortcut(let name):    return "ショートカット: \(name)"
        case .clickElement(let desc): return "要素をクリック: \(desc)"
        case .explainScreen(let q):  return "画面について: \(q)"
        case .screenAction(let inst): return "画面AIアクション: \(inst)"
        case .volumeUp:              return "音量を上げる"
        case .volumeDown:            return "音量を下げる"
        case .mute:                  return "ミュート"
        case .brightnessUp:          return "画面を明るくする"
        case .brightnessDown:        return "画面を暗くする"
        case .playPause:             return "再生/一時停止"
        case .nextTrack:             return "次のトラック"
        case .prevTrack:             return "前のトラック"
        case .sleep:                 return "スリープ"
        case .lockScreen:            return "画面ロック"
        }
    }

    /// Whether this command requires voiceControlEnabled setting
    var requiresVoiceControl: Bool {
        switch self {
        case .clickElement, .explainScreen, .screenAction,
             .volumeUp, .volumeDown, .mute,
             .brightnessUp, .brightnessDown,
             .playPause, .nextTrack, .prevTrack,
             .sleep, .lockScreen:
            return true
        default:
            return false
        }
    }
}

// MARK: - Agent Mode

class AgentMode {
    static let shared = AgentMode()

    /// 高速文字列マッチ（即時判定）
    func detectCommand(_ text: String) -> AgentCommand? {
        return detectCommandFast(text)
    }

    /// LLMインテント判定（非同期）: 文字列マッチで検出できない場合にLLMで意図を判定
    func detectCommandAsync(_ text: String, completion: @escaping (AgentCommand?) -> Void) {
        // まず高速文字列マッチを試行
        if let fast = detectCommandFast(text) {
            completion(fast)
            return
        }
        // voiceControlが無効ならスキップ
        guard AppSettings.shared.voiceControlEnabled else {
            completion(nil)
            return
        }
        // LLMでインテント判定
        detectCommandWithLLM(text, completion: completion)
    }

    /// 高速文字列マッチ（既存ロジック）
    private func detectCommandFast(_ text: String) -> AgentCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // スクリーンショット
        if t.contains("スクショ") || t.contains("スクリーンショット") {
            return .screenshot
        }

        // Screen-aware + system control commands (guarded by voiceControlEnabled)
        if AppSettings.shared.voiceControlEnabled {
            // 画面要素クリック
            if let desc = matchClickElement(t) {
                return .clickElement(description: desc)
            }
            // 画面説明
            if let question = matchExplainScreen(t) {
                return .explainScreen(question: question)
            }
            // 音量
            if t.contains("音量上げ") || t.contains("ボリュームアップ") || t.contains("音量を上げ") { return .volumeUp }
            if t.contains("音量下げ") || t.contains("ボリュームダウン") || t.contains("音量を下げ") { return .volumeDown }
            if t.contains("ミュート") || t.contains("消音") { return .mute }
            // 明るさ
            if t.contains("明るくして") || t.contains("輝度上げ") || t.contains("画面を明るく") { return .brightnessUp }
            if t.contains("暗くして") || t.contains("輝度下げ") || t.contains("画面を暗く") { return .brightnessDown }
            // メディア
            if t.contains("音楽止めて") || t.contains("一時停止") || t.contains("再生して") || t.contains("音楽再生") { return .playPause }
            if t.contains("次の曲") || t.contains("次のトラック") || t.contains("スキップ") { return .nextTrack }
            if t.contains("前の曲") || t.contains("前のトラック") { return .prevTrack }
            // スリープ
            if t.contains("スリープ") || t.contains("もう寝る") || t.contains("おやすみ") { return .sleep }
            // 画面ロック
            if t.contains("画面ロック") || t.contains("ロックして") || t.contains("画面をロック") { return .lockScreen }
            // 画面AIアクション（汎用）
            if let instruction = matchScreenAction(t) {
                return .screenAction(instruction: instruction)
            }
        }

        // タイマー
        if let m = matchTimer(t) { return .timer(minutes: m) }
        // ショートカット
        if let name = matchShortcut(t) { return .shortcut(name: name) }
        // シェルコマンド
        if let cmd = matchShellCommand(t) { return .shellCommand(cmd: cmd) }
        // 検索
        if let query = matchSearch(t) { return .search(query: query) }
        // アプリを開く
        if let name = matchOpenApp(t) {
            return .openApp(name: name)
        }

        return nil
    }

    /// Execute the detected command
    func execute(_ command: AgentCommand, completion: @escaping (String) -> Void) {
        // Guard system control commands behind voiceControlEnabled
        if command.requiresVoiceControl && !AppSettings.shared.voiceControlEnabled {
            klog("Agent: voice control command blocked (voiceControlEnabled=false)")
            completion("音声コントロールが無効です。設定で有効にしてください。")
            return
        }

        switch command {
        case .openApp(let name):
            executeOpenApp(name: name, completion: completion)
        case .search(let query):
            executeSearch(query: query, completion: completion)
        case .screenshot:
            executeScreenshot(completion: completion)
        case .timer(let minutes):
            executeTimer(minutes: minutes, completion: completion)
        case .shellCommand(let cmd):
            executeShell(cmd: cmd, completion: completion)
        case .shortcut(let name):
            executeShortcut(name: name, completion: completion)
        case .clickElement(let description):
            executeClickElement(description: description, completion: completion)
        case .explainScreen(let question):
            executeExplainScreen(question: question, completion: completion)
        case .screenAction(let instruction):
            executeScreenAction(instruction: instruction, completion: completion)
        case .volumeUp:
            executeVolumeChange(direction: .up, completion: completion)
        case .volumeDown:
            executeVolumeChange(direction: .down, completion: completion)
        case .mute:
            executeMute(completion: completion)
        case .brightnessUp:
            executeBrightnessChange(direction: .up, completion: completion)
        case .brightnessDown:
            executeBrightnessChange(direction: .down, completion: completion)
        case .playPause:
            executeMediaKey(keyType: Self.NX_KEYTYPE_PLAY, completion: completion, label: "再生/一時停止")
        case .nextTrack:
            executeMediaKey(keyType: Self.NX_KEYTYPE_NEXT, completion: completion, label: "次のトラック")
        case .prevTrack:
            executeMediaKey(keyType: Self.NX_KEYTYPE_PREVIOUS, completion: completion, label: "前のトラック")
        case .sleep:
            executeSleep(completion: completion)
        case .lockScreen:
            executeLockScreen(completion: completion)
        }
    }

    // MARK: - LLM Intent Detection

    /// LLMでユーザーの意図を判定して適切なコマンドに変換
    private func detectCommandWithLLM(_ text: String, completion: @escaping (AgentCommand?) -> Void) {
        let prompt = """
        ユーザーの発話からMac操作コマンドを判定してください。
        該当するコマンドがあれば、コマンドIDのみを1行で出力。該当しなければ「NONE」と出力。

        コマンド一覧:
        VOLUME_UP — 音量を上げる（「うるさい」の逆、「音大きく」等）
        VOLUME_DOWN — 音量を下げる（「うるさい」「音小さく」「静かに」等）
        MUTE — 消音（「黙って」「音消して」等）
        BRIGHTNESS_UP — 画面を明るく（「見えない」「眩しくして」等）
        BRIGHTNESS_DOWN — 画面を暗く（「眩しい」「暗くして」等）
        PLAY_PAUSE — 音楽再生/停止（「音楽」「曲」「止めて」「かけて」等）
        NEXT_TRACK — 次の曲（「飛ばして」「これじゃない」等）
        PREV_TRACK — 前の曲（「戻して」「さっきの曲」等）
        SLEEP — スリープ（「寝る」「おやすみ」「もういい」等）
        LOCK — 画面ロック（「離席」「ロック」等）
        SCREENSHOT — スクリーンショット
        SCREEN_ACTION:（指示内容） — 画面を見てAIが行動（「返信して」「翻訳して」「要約して」「直して」等）
        OPEN_APP:（アプリ名） — アプリを開く
        SEARCH:（検索語） — 検索する
        EXPLAIN — 画面の内容を説明する（「何これ」「わからない」等）

        ユーザー: \(text)
        コマンド:
        """

        LLMProcessor.shared.processScreenContext(prompt: prompt) { result in
            let r = result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            klog("Agent(LLM intent): '\(text)' → '\(r)'")

            let command: AgentCommand?
            if r == "NONE" || r.isEmpty || r == prompt.uppercased() {
                command = nil
            } else if r == "VOLUME_UP" {
                command = .volumeUp
            } else if r == "VOLUME_DOWN" {
                command = .volumeDown
            } else if r == "MUTE" {
                command = .mute
            } else if r == "BRIGHTNESS_UP" {
                command = .brightnessUp
            } else if r == "BRIGHTNESS_DOWN" {
                command = .brightnessDown
            } else if r == "PLAY_PAUSE" {
                command = .playPause
            } else if r == "NEXT_TRACK" {
                command = .nextTrack
            } else if r == "PREV_TRACK" {
                command = .prevTrack
            } else if r == "SLEEP" {
                command = .sleep
            } else if r == "LOCK" {
                command = .lockScreen
            } else if r == "SCREENSHOT" {
                command = .screenshot
            } else if r == "EXPLAIN" {
                command = .explainScreen(question: text)
            } else if r.hasPrefix("SCREEN_ACTION:") {
                let instruction = String(r.dropFirst("SCREEN_ACTION:".count)).trimmingCharacters(in: .whitespaces)
                command = .screenAction(instruction: instruction.isEmpty ? text : instruction)
            } else if r.hasPrefix("OPEN_APP:") {
                let app = String(r.dropFirst("OPEN_APP:".count)).trimmingCharacters(in: .whitespaces)
                command = .openApp(name: app)
            } else if r.hasPrefix("SEARCH:") {
                let query = String(r.dropFirst("SEARCH:".count)).trimmingCharacters(in: .whitespaces)
                command = .search(query: query)
            } else {
                // LLMが想定外の出力をした場合、screenActionとして扱う
                command = .screenAction(instruction: text)
            }

            DispatchQueue.main.async { completion(command) }
        }
    }

    // MARK: - Pattern Matching

    private func matchOpenApp(_ text: String) -> String? {
        // "〜を開いて", "〜を開く", "〜開いて", "〜を起動", "〜起動して"
        let patterns: [(suffix: String, trim: Bool)] = [
            ("を開いて", true), ("を開く", true), ("開いて", true),
            ("を起動して", true), ("を起動", true), ("起動して", true),
        ]
        for p in patterns {
            if text.hasSuffix(p.suffix) {
                let name = String(text.dropLast(p.suffix.count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private func matchSearch(_ text: String) -> String? {
        // "〜を検索", "〜で検索", "〜を検索して", "〜検索して"
        let suffixes = ["を検索して", "で検索して", "を検索", "で検索", "検索して"]
        for suffix in suffixes {
            if text.hasSuffix(suffix) {
                let query = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if !query.isEmpty { return query }
            }
        }
        // "検索して〜" or "検索 〜"
        let prefixes = ["検索して", "検索 "]
        for prefix in prefixes {
            if text.hasPrefix(prefix) {
                let query = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !query.isEmpty { return query }
            }
        }
        return nil
    }

    private func matchTimer(_ text: String) -> Int? {
        // "N分タイマー", "タイマーN分", "N分のタイマー"
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard !digits.isEmpty, text.contains("タイマー") || text.contains("たいまー") else { return nil }
        let numStr = String(digits)
        guard let n = Int(numStr), n > 0, n <= 1440 else { return nil }
        return n
    }

    private func matchShellCommand(_ text: String) -> String? {
        let prefixes = ["ターミナルで", "コマンドで", "シェルで"]
        for prefix in prefixes {
            if text.hasPrefix(prefix) {
                let cmd = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty { return cmd }
            }
        }
        return nil
    }

    private func matchShortcut(_ text: String) -> String? {
        // "ショートカット〜を実行" or "ショートカット〜を実行して"
        if text.hasPrefix("ショートカット") {
            var rest = String(text.dropFirst("ショートカット".count)).trimmingCharacters(in: .whitespaces)
            for suffix in ["を実行して", "を実行", "実行して", "実行"] {
                if rest.hasSuffix(suffix) {
                    rest = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if !rest.isEmpty { return rest }
        }
        // "〜を実行して" (only if it doesn't match other patterns)
        if text.hasSuffix("を実行して") || text.hasSuffix("を実行") {
            let suffix = text.hasSuffix("を実行して") ? "を実行して" : "を実行"
            let name = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    // MARK: - Execution

    private func executeOpenApp(name: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name]
            let pipe = Pipe()
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    klog("Agent: opened app '\(name)'")
                    DispatchQueue.main.async { completion("\(name) を開きました") }
                } else {
                    let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "不明なエラー"
                    klog("Agent: failed to open '\(name)': \(errStr)")
                    DispatchQueue.main.async { completion("\(name) を開けませんでした") }
                }
            } catch {
                klog("Agent: open app error: \(error)")
                DispatchQueue.main.async { completion("\(name) を開けませんでした") }
            }
        }
    }

    private func executeSearch(query: String, completion: @escaping (String) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            completion("検索に失敗しました")
            return
        }
        NSWorkspace.shared.open(url)
        klog("Agent: search '\(query)'")
        completion("「\(query)」を検索しました")
    }

    private func executeScreenshot(completion: @escaping (String) -> Void) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "screenshot_\(dateFormatter.string(from: Date())).png"
        let path = NSHomeDirectory() + "/Desktop/\(filename)"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    klog("Agent: screenshot saved to \(path)")
                    DispatchQueue.main.async { completion("スクリーンショットを保存しました") }
                } else {
                    klog("Agent: screenshot cancelled or failed")
                    DispatchQueue.main.async { completion("スクリーンショットをキャンセルしました") }
                }
            } catch {
                klog("Agent: screenshot error: \(error)")
                DispatchQueue.main.async { completion("スクリーンショットに失敗しました") }
            }
        }
    }

    private func executeTimer(minutes: Int, completion: @escaping (String) -> Void) {
        // Use AppleScript to set a timer via Shortcuts or a simple notification
        let script = """
        tell application "Shortcuts Events"
            run shortcut "Timer" with input "\(minutes)"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            // Try Shortcuts first; fall back to a delayed notification
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if error == nil {
                    klog("Agent: timer set via Shortcuts for \(minutes) min")
                    DispatchQueue.main.async { completion("\(minutes)分のタイマーをセットしました") }
                    return
                }
            }
            // Fallback: schedule a local notification
            let content = UNMutableNotificationContent()
            content.title = "Koe タイマー"
            content.body = "\(minutes)分が経過しました"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
            let request = UNNotificationRequest(identifier: "koe-timer-\(UUID().uuidString)", content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    klog("Agent: timer notification error: \(error)")
                    DispatchQueue.main.async { completion("タイマーの設定に失敗しました") }
                } else {
                    klog("Agent: timer set via notification for \(minutes) min")
                    DispatchQueue.main.async { completion("\(minutes)分のタイマーをセットしました") }
                }
            }
        }
    }

    // セキュリティ: 許可されたコマンドのホワイトリスト（読み取り専用 + 安全な操作のみ）
    private static let allowedCommands = Set([
        "ls", "pwd", "date", "cal", "uptime", "whoami", "hostname",
        "df", "du", "top", "ps", "sw_vers", "system_profiler",
        "say", "afplay",
        "ping", "dig", "nslookup", "ifconfig",
        "echo", "head", "tail", "wc", "sort", "uniq",
        "pmset", "caffeinate",
    ])

    /// シェルメタ文字を含む引数を拒否
    private static let shellMetaChars = CharacterSet(charactersIn: ";|&$`><(){}!\\")

    private func isSafeCommand(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        // コマンドを分割（最初のワード = コマンド名）
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = parts.first else { return false }
        let basename = (first as NSString).lastPathComponent

        // ホワイトリストチェック
        guard AgentMode.allowedCommands.contains(basename) else { return false }

        // 引数にシェルメタ文字があれば拒否
        for arg in parts.dropFirst() {
            if arg.unicodeScalars.contains(where: { AgentMode.shellMetaChars.contains($0) }) {
                klog("Agent: rejected shell metachar in arg '\(arg.prefix(20))'")
                return false
            }
        }
        return true
    }

    private func executeShell(cmd: String, completion: @escaping (String) -> Void) {
        guard isSafeCommand(cmd) else {
            klog("Agent: blocked unsafe command '\(cmd.prefix(50))'")
            DispatchQueue.main.async { completion("セキュリティ上の理由でこのコマンドは実行できません") }
            return
        }
        // シェル経由ではなく直接実行（メタ文字インジェクション防止）
        let parts = cmd.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = parts
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = process.terminationStatus
                klog("Agent: shell '\(cmd)' exit=\(status) output='\(output.prefix(200))'")
                let result = status == 0
                    ? "コマンド実行完了" + (output.isEmpty ? "" : ": \(String(output.prefix(100)))")
                    : "コマンド失敗 (exit \(status))"
                DispatchQueue.main.async { completion(result) }
            } catch {
                klog("Agent: shell error: \(error)")
                DispatchQueue.main.async { completion("コマンド実行に失敗しました") }
            }
        }
    }

    private func executeShortcut(name: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    klog("Agent: shortcut '\(name)' completed")
                    DispatchQueue.main.async { completion("ショートカット「\(name)」を実行しました") }
                } else {
                    klog("Agent: shortcut '\(name)' failed (exit \(process.terminationStatus))")
                    DispatchQueue.main.async { completion("ショートカット「\(name)」の実行に失敗しました") }
                }
            } catch {
                klog("Agent: shortcut error: \(error)")
                DispatchQueue.main.async { completion("ショートカットの実行に失敗しました") }
            }
        }
    }

    // MARK: - Screen-Aware Pattern Matching

    private func matchClickElement(_ text: String) -> String? {
        // "〜を押して", "〜押して", "〜をクリックして", "〜クリックして", "〜をクリック", "〜ボタン押して", "〜ボタンをクリック"
        let suffixes = ["ボタンを押して", "ボタン押して", "をクリックして", "クリックして", "をクリック", "を押して", "押して"]
        for suffix in suffixes {
            if text.hasSuffix(suffix) {
                let desc = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if !desc.isEmpty { return desc }
            }
        }
        return nil
    }

    private func matchExplainScreen(_ text: String) -> String? {
        // Direct question patterns about screen content
        if text.contains("これ何") || text.contains("これなに") {
            return text
        }
        if text.contains("このエラー") {
            return text
        }
        // "画面.*教えて" or "画面.*説明"
        if text.contains("画面") && (text.contains("教えて") || text.contains("説明")) {
            return text
        }
        // "何が書いてある", "何て書いてある"
        if text.contains("書いてある") || text.contains("書いている") {
            return text
        }
        return nil
    }

    // MARK: - Screen-Aware Execution

    /// Capture the frontmost app's screen as a CGImage
    private func captureScreen() -> CGImage? {
        // screencaptureコマンド経由で確実にキャプチャ（権限問題を回避）
        let tmpPath = "/tmp/koe_agent_capture.png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", tmpPath]  // -x: no sound, -C: capture cursor
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            klog("Agent: screencapture failed: \(error)")
            return nil
        }
        guard let dataProvider = CGDataProvider(url: URL(fileURLWithPath: tmpPath) as CFURL),
              let image = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            klog("Agent: failed to load captured image")
            return nil
        }
        try? FileManager.default.removeItem(atPath: tmpPath)
        klog("Agent: captured screen \(image.width)x\(image.height)")
        return image
    }

    /// Perform OCR with bounding boxes on a CGImage
    private func performOCRWithBounds(on image: CGImage, completion: @escaping ([(String, CGRect)]) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion([]); return
            }
            let results: [(String, CGRect)] = observations.compactMap { obs in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                return (candidate.string, obs.boundingBox)
            }
            completion(results)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja", "en"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    /// Perform OCR returning text only
    private func performOCRText(on image: CGImage, completion: @escaping (String) -> Void) {
        performOCRWithBounds(on: image) { results in
            let text = results.map { $0.0 }.joined(separator: "\n")
            completion(text)
        }
    }

    private func executeClickElement(description: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let image = self.captureScreen() else {
                klog("Agent: clickElement - screen capture failed")
                DispatchQueue.main.async { completion("画面のキャプチャに失敗しました") }
                return
            }

            let screenWidth = CGFloat(image.width)
            let screenHeight = CGFloat(image.height)

            self.performOCRWithBounds(on: image) { results in
                guard !results.isEmpty else {
                    klog("Agent: clickElement - OCR found no text")
                    DispatchQueue.main.async { completion("画面上にテキストが見つかりませんでした") }
                    return
                }

                // Find the best matching OCR result
                let target = description.lowercased()
                var bestMatch: (String, CGRect)? = nil
                var bestScore: Int = 0

                for (text, box) in results {
                    let lower = text.lowercased()
                    // Exact match gets highest score
                    if lower == target {
                        bestMatch = (text, box)
                        bestScore = 1000
                        break
                    }
                    // Contains match
                    if lower.contains(target) || target.contains(lower) {
                        let score = lower.contains(target) ? 500 : 100
                        if score > bestScore {
                            bestScore = score
                            bestMatch = (text, box)
                        }
                    }
                }

                guard let (matchedText, boundingBox) = bestMatch else {
                    klog("Agent: clickElement - no match for '\(description)'")
                    let available = results.prefix(5).map { $0.0 }.joined(separator: ", ")
                    DispatchQueue.main.async { completion("「\(description)」が見つかりませんでした。画面上: \(available)") }
                    return
                }

                // Convert Vision bounding box (normalized, bottom-left origin) to screen coordinates
                // Vision: origin at bottom-left, x right, y up, values 0-1
                // Screen (CGEvent): origin at top-left, x right, y down
                guard let screen = NSScreen.main else {
                    DispatchQueue.main.async { completion("画面情報を取得できませんでした") }
                    return
                }
                let displayWidth = screen.frame.width
                let displayHeight = screen.frame.height
                let screenX = boundingBox.midX * displayWidth
                let screenY = (1.0 - boundingBox.midY) * displayHeight

                let point = CGPoint(x: screenX, y: screenY)
                klog("Agent: clickElement - clicking '\(matchedText)' at (\(Int(screenX)), \(Int(screenY)))")

                // Post mouse click
                let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
                let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                mouseDown?.post(tap: .cghidEventTap)
                mouseUp?.post(tap: .cghidEventTap)

                DispatchQueue.main.async { completion("「\(matchedText)」をクリックしました") }
            }
        }
    }

    private func executeExplainScreen(question: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let image = self.captureScreen() else {
                klog("Agent: explainScreen - screen capture failed")
                DispatchQueue.main.async { completion("画面のキャプチャに失敗しました") }
                return
            }

            self.performOCRText(on: image) { ocrText in
                guard !ocrText.isEmpty else {
                    klog("Agent: explainScreen - OCR returned empty")
                    DispatchQueue.main.async { completion("画面からテキストを読み取れませんでした") }
                    return
                }

                let prompt = """
                ユーザーの質問: \(question)

                画面のテキスト内容:
                \(String(ocrText.prefix(2000)))

                上記の画面内容に基づいて、ユーザーの質問に簡潔に日本語で回答してください。
                """

                LLMProcessor.shared.processScreenContext(prompt: prompt) { response in
                    let answer = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if answer.isEmpty {
                        klog("Agent: explainScreen - LLM returned empty")
                        DispatchQueue.main.async { completion("回答を生成できませんでした。OCRテキスト: \(String(ocrText.prefix(200)))") }
                        return
                    }

                    klog("Agent: explainScreen - answer: \(answer.prefix(100))")

                    // Speak the answer aloud
                    let synthesizer = NSSpeechSynthesizer()
                    synthesizer.startSpeaking(answer)

                    DispatchQueue.main.async { completion(answer) }
                }
            }
        }
    }

    // MARK: - System Control Execution

    private enum VolumeDirection { case up, down }

    private func executeVolumeChange(direction: VolumeDirection, completion: @escaping (String) -> Void) {
        let script: String
        switch direction {
        case .up:
            script = "set volume output volume ((output volume of (get volume settings)) + 10)"
        case .down:
            script = "set volume output volume ((output volume of (get volume settings)) - 10)"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error {
                    klog("Agent: volume change error: \(error)")
                    DispatchQueue.main.async { completion("音量変更に失敗しました") }
                } else {
                    let label = direction == .up ? "上げ" : "下げ"
                    klog("Agent: volume \(direction)")
                    DispatchQueue.main.async { completion("音量を\(label)ました") }
                }
            }
        }
    }

    private func executeMute(completion: @escaping (String) -> Void) {
        let script = "set volume with output muted"
        DispatchQueue.global(qos: .userInitiated).async {
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error {
                    klog("Agent: mute error: \(error)")
                    DispatchQueue.main.async { completion("ミュートに失敗しました") }
                } else {
                    klog("Agent: muted")
                    DispatchQueue.main.async { completion("ミュートにしました") }
                }
            }
        }
    }

    private enum BrightnessDirection { case up, down }

    private func executeBrightnessChange(direction: BrightnessDirection, completion: @escaping (String) -> Void) {
        // Use NX key events to simulate F1 (brightness down) / F2 (brightness up)
        let keyCode: Int32 = direction == .up ? 0x78 : 0x7A  // F2=0x78, F1=0x7A
        DispatchQueue.global(qos: .userInitiated).async {
            Self.sendSpecialKey(keyCode: keyCode)
            let label = direction == .up ? "明るく" : "暗く"
            klog("Agent: brightness \(direction)")
            DispatchQueue.main.async { completion("画面を\(label)しました") }
        }
    }

    /// Send a special key event (brightness, etc.) via CGEvent
    private static func sendSpecialKey(keyCode: Int32) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // Media key constants
    private static let NX_KEYTYPE_PLAY: Int32     = 16
    private static let NX_KEYTYPE_NEXT: Int32     = 17
    private static let NX_KEYTYPE_PREVIOUS: Int32 = 18

    private func executeMediaKey(keyType: Int32, completion: @escaping (String) -> Void, label: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            Self.sendMediaKey(keyType: keyType, keyDown: true)
            Self.sendMediaKey(keyType: keyType, keyDown: false)
            klog("Agent: media key \(keyType) (\(label))")
            DispatchQueue.main.async { completion("\(label)を実行しました") }
        }
    }

    /// Post a system-defined media key event via IOKit HID
    private static func sendMediaKey(keyType: Int32, keyDown: Bool) {
        let flags: Int32 = keyDown ? 0xa00 : 0xb00  // NX_KEYDOWN=0xa00, NX_KEYUP=0xb00
        let data1 = Int32((Int(keyType) << 16) | Int(flags))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: keyDown ? 0xa00 : 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: Int(data1),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    private func executeSleep(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            do {
                try process.run()
                process.waitUntilExit()
                klog("Agent: sleep initiated")
                DispatchQueue.main.async { completion("スリープします") }
            } catch {
                klog("Agent: sleep error: \(error)")
                DispatchQueue.main.async { completion("スリープに失敗しました") }
            }
        }
    }

    // MARK: - Screen Action Matching

    /// 画面AIアクションの検出パターン
    /// 「このメール返信して」「この英語翻訳して」「このコード直して」等
    private func matchScreenAction(_ text: String) -> String? {
        // 「この〜して」パターン
        let screenPrefixes = ["この", "これ", "今の画面", "画面の", "表示されてる", "表示されている", "見えてる", "見えている"]
        let actionSuffixes = ["して", "やって", "お願い", "頼む", "ください", "返信", "翻訳", "要約", "まとめ", "直し", "修正", "説明", "書い"]

        let hasScreenRef = screenPrefixes.contains(where: { text.contains($0) })
        let hasAction = actionSuffixes.contains(where: { text.contains($0) })

        if hasScreenRef && hasAction {
            return text
        }

        // 直接的なパターン
        let directPatterns = [
            "返信して", "返事して", "返事書いて",
            "翻訳して", "日本語にして", "英語にして",
            "要約して", "まとめて",
            "コード.*直して", "バグ.*直して", "修正して",
            "丁寧に.*書いて", "カジュアルに.*書いて",
            "フォーム.*入力", "入力して",
        ]
        for pattern in directPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return text
            }
        }

        return nil
    }

    // MARK: - Screen AI Agent Execution

    /// 画面を見て → LLM に指示 → 結果をタイプ入力
    private func executeScreenAction(instruction: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 1. 画面キャプチャ
            guard let image = self.captureScreen() else {
                klog("Agent(screen): capture failed")
                DispatchQueue.main.async { completion("画面のキャプチャに失敗しました") }
                return
            }

            let screenW = CGFloat(image.width)
            let screenH = CGFloat(image.height)
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "不明"

            // VLM優先: リモートAPIが使える場合は画像を直接VLMに送信（OCRより高精度）
            let s = AppSettings.shared
            if !s.llmUseLocal && (!s.llmProvider.requiresAPIKey || !s.llmAPIKey.isEmpty) {
                klog("Agent(screen): using VLM for \(appName)")
                let vlmPrompt = """
                あなたはMacを操作するAIアシスタント「Koe」です。画面のスクリーンショットを見て、ユーザーの指示に従ってください。
                アプリ: \(appName)
                ユーザーの指示: \(instruction)

                実行可能なアクション（各行に1つ）:
                TYPE: テキスト — テキストを入力する
                CLICK: x,y — 画面座標(px)をクリック
                KEY: ⌘C — キーボードショートカット
                SAY: テキスト — 音声で読み上げ
                WAIT: 秒数 — 待機

                アクション行のみを出力してください。
                """
                LLMProcessor.shared.processWithVision(image: image, prompt: vlmPrompt) { [weak self] result in
                    guard let self, !result.isEmpty else {
                        // VLM失敗 → OCRフォールバック
                        klog("Agent(screen): VLM failed, falling back to OCR")
                        self?.executeScreenActionWithOCR(instruction: instruction, image: image, screenW: screenW, screenH: screenH, completion: completion)
                        return
                    }
                    klog("Agent(screen): VLM plan:\n\(result)")
                    // VLMはピクセル座標を返すのでOCR結果不要
                    DispatchQueue.main.async {
                        self.executeVLMActionPlan(result, screenW: screenW, screenH: screenH, completion: completion)
                    }
                }
                return
            }

            // フォールバック: OCRベース（ローカルLLM使用時）
            self.executeScreenActionWithOCR(instruction: instruction, image: image, screenW: screenW, screenH: screenH, completion: completion)
        }
    }

    /// OCRベースの画面操作（VLM非対応時のフォールバック）
    private func executeScreenActionWithOCR(instruction: String, image: CGImage, screenW: CGFloat, screenH: CGFloat, completion: @escaping (String) -> Void) {
        performOCRWithBounds(on: image) { [weak self] results in
            guard let self else { return }
            let ocrText = results.map { $0.0 }.joined(separator: "\n")
            guard !ocrText.isEmpty else {
                klog("Agent(screen): OCR returned empty")
                DispatchQueue.main.async { completion("画面からテキストを読み取れませんでした") }
                return
            }

            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "不明"
            let ocrWithPositions = results.prefix(50).enumerated().map { i, item in
                let (text, box) = item
                let cx = Int(box.midX * screenW)
                let cy = Int((1 - box.midY) * screenH)
                return "[\(i)] \"\(text)\" (x:\(cx), y:\(cy))"
            }.joined(separator: "\n")

            klog("Agent(screen): OCR \(results.count) elements from \(appName)")

            let prompt = """
            あなたはMacを操作するAIアシスタント「Koe」です。ユーザーが「\(appName)」を使っています。
            【画面上のテキスト要素】\n\(String(ocrWithPositions.prefix(3000)))
            【ユーザーの指示】\(instruction)
            【アクション形式】TYPE: テキスト / CLICK: 番号 / KEY: ⌘C / SAY: テキスト / WAIT: 秒数
            アクション行のみ出力。
            """

            LLMProcessor.shared.processScreenContext(prompt: prompt) { [weak self] result in
                guard let self else { return }
                let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty, output != prompt else {
                    klog("Agent(screen): LLM returned empty")
                    DispatchQueue.main.async { completion("LLMが応答を生成できませんでした") }
                    return
                }
                klog("Agent(screen): LLM plan:\n\(output)")
                DispatchQueue.main.async {
                    self.executeActionPlan(output, ocrResults: results, screenW: screenW, screenH: screenH, completion: completion)
                }
            }
        }
    }

    /// VLMが出力したアクションプランを実行（ピクセル座標対応, CLICK: x,y形式）
    private func executeVLMActionPlan(_ plan: String, screenW: CGFloat, screenH: CGFloat, completion: @escaping (String) -> Void) {
        // VLMのCLICK座標はピクセル値なので、Retinaスケール補正
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let lines = plan.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var actions: [String] = []
        let typer = AutoTyper()

        func next(_ i: Int) {
            guard i < lines.count else {
                completion("✓ \(actions.joined(separator: " → "))")
                return
            }
            let line = lines[i]
            klog("Agent(VLM): action \(i): \(line.prefix(60))")

            if line.hasPrefix("TYPE:") {
                let text = String(line.dropFirst("TYPE:".count)).trimmingCharacters(in: .whitespaces)
                typer.type(text)
                actions.append("入力(\(text.count)文字)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(i + 1) }
            } else if line.hasPrefix("CLICK:") {
                let coords = String(line.dropFirst("CLICK:".count)).trimmingCharacters(in: .whitespaces)
                let parts = coords.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                    // VLMが返すのは画像上のピクセル座標 → Retinaスケールで割る
                    let point = CGPoint(x: x / Double(scale), y: y / Double(scale))
                    if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                       let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                        down.post(tap: .cghidEventTap)
                        usleep(50000)
                        up.post(tap: .cghidEventTap)
                    }
                    actions.append("クリック(\(Int(x/Double(scale))),\(Int(y/Double(scale))))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next(i + 1) }
            } else if line.hasPrefix("KEY:") {
                let keyStr = String(line.dropFirst("KEY:".count)).trimmingCharacters(in: .whitespaces)
                self.executeKeyCombo(keyStr)
                actions.append("キー(\(keyStr))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(i + 1) }
            } else if line.hasPrefix("SAY:") {
                let text = String(line.dropFirst("SAY:".count)).trimmingCharacters(in: .whitespaces)
                NSSpeechSynthesizer().startSpeaking(text)
                actions.append("読上げ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next(i + 1) }
            } else if line.hasPrefix("WAIT:") {
                let secs = min(max(Double(String(line.dropFirst("WAIT:".count)).trimmingCharacters(in: .whitespaces)) ?? 1, 0.1), 5)
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { next(i + 1) }
            } else {
                typer.type(line)
                actions.append("入力(\(line.count)文字)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(i + 1) }
            }
        }
        next(0)
    }

    /// LLMが出力したアクションプランを順次実行（OCRベース）
    private func executeActionPlan(_ plan: String, ocrResults: [(String, CGRect)], screenW: CGFloat, screenH: CGFloat, completion: @escaping (String) -> Void) {
        let lines = plan.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var actions: [String] = []
        let typer = AutoTyper()

        func executeNext(_ index: Int) {
            guard index < lines.count else {
                let summary = actions.isEmpty ? "アクションなし" : actions.joined(separator: " → ")
                completion("✓ \(summary)")
                return
            }
            let line = lines[index]
            klog("Agent(screen): executing action \(index): \(line.prefix(60))")

            if line.hasPrefix("TYPE:") {
                let text = String(line.dropFirst("TYPE:".count)).trimmingCharacters(in: .whitespaces)
                typer.type(text)
                actions.append("入力(\(text.count)文字)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { executeNext(index + 1) }

            } else if line.hasPrefix("CLICK:") {
                let idxStr = String(line.dropFirst("CLICK:".count)).trimmingCharacters(in: .whitespaces)
                if let idx = Int(idxStr), idx < ocrResults.count {
                    let (clickText, box) = ocrResults[idx]
                    let x = box.midX * screenW
                    let y = (1 - box.midY) * screenH
                    // CGEvent click
                    let point = CGPoint(x: x, y: y)
                    if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                       let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                        mouseDown.post(tap: .cghidEventTap)
                        usleep(50000)
                        mouseUp.post(tap: .cghidEventTap)
                    }
                    actions.append("クリック「\(clickText.prefix(10))」")
                    klog("Agent(screen): clicked [\(idx)] '\(clickText)' at (\(Int(x)),\(Int(y)))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { executeNext(index + 1) }

            } else if line.hasPrefix("KEY:") {
                let keyStr = String(line.dropFirst("KEY:".count)).trimmingCharacters(in: .whitespaces)
                self.executeKeyCombo(keyStr)
                actions.append("キー(\(keyStr))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { executeNext(index + 1) }

            } else if line.hasPrefix("SAY:") {
                let text = String(line.dropFirst("SAY:".count)).trimmingCharacters(in: .whitespaces)
                NSSpeechSynthesizer().startSpeaking(text)
                actions.append("読上げ")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { executeNext(index + 1) }

            } else if line.hasPrefix("WAIT:") {
                let secStr = String(line.dropFirst("WAIT:".count)).trimmingCharacters(in: .whitespaces)
                let secs = Double(secStr) ?? 1.0
                let clamped = min(max(secs, 0.1), 5.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + clamped) { executeNext(index + 1) }

            } else {
                // 不明な行 → テキスト入力として扱う
                typer.type(line)
                actions.append("入力(\(line.count)文字)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { executeNext(index + 1) }
            }
        }

        executeNext(0)
    }

    /// キーコンボ文字列を解釈して実行（例: "⌘C", "⌘⇧S", "Return"）
    private func executeKeyCombo(_ combo: String) {
        var flags: CGEventFlags = []
        var key: String = combo

        if key.contains("⌘") { flags.insert(.maskCommand); key = key.replacingOccurrences(of: "⌘", with: "") }
        if key.contains("⌃") { flags.insert(.maskControl); key = key.replacingOccurrences(of: "⌃", with: "") }
        if key.contains("⌥") { flags.insert(.maskAlternate); key = key.replacingOccurrences(of: "⌥", with: "") }
        if key.contains("⇧") { flags.insert(.maskShift); key = key.replacingOccurrences(of: "⇧", with: "") }

        key = key.trimmingCharacters(in: .whitespaces).uppercased()
        let keyCode: CGKeyCode
        switch key {
        case "A": keyCode = 0x00; case "B": keyCode = 0x0B; case "C": keyCode = 0x08
        case "D": keyCode = 0x02; case "E": keyCode = 0x0E; case "F": keyCode = 0x03
        case "G": keyCode = 0x05; case "H": keyCode = 0x04; case "I": keyCode = 0x22
        case "J": keyCode = 0x26; case "K": keyCode = 0x28; case "L": keyCode = 0x25
        case "M": keyCode = 0x2E; case "N": keyCode = 0x2D; case "O": keyCode = 0x1F
        case "P": keyCode = 0x23; case "Q": keyCode = 0x0C; case "R": keyCode = 0x0F
        case "S": keyCode = 0x01; case "T": keyCode = 0x11; case "U": keyCode = 0x20
        case "V": keyCode = 0x09; case "W": keyCode = 0x0D; case "X": keyCode = 0x07
        case "Y": keyCode = 0x10; case "Z": keyCode = 0x06
        case "RETURN", "ENTER": keyCode = 0x24
        case "TAB": keyCode = 0x30
        case "SPACE": keyCode = 0x31
        case "DELETE", "BACKSPACE": keyCode = 0x33
        case "ESCAPE", "ESC": keyCode = 0x35
        default: klog("Agent: unknown key '\(key)'"); return
        }

        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            down.flags = flags; up.flags = flags
            down.post(tap: .cghidEventTap)
            usleep(50000)
            up.post(tap: .cghidEventTap)
        }
    }

    private func executeLockScreen(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Use CGSession via loginwindow to lock screen
            let script = """
            tell application "System Events" to keystroke "q" using {command down, control down}
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error {
                    klog("Agent: lock screen error: \(error)")
                    DispatchQueue.main.async { completion("画面ロックに失敗しました") }
                } else {
                    klog("Agent: screen locked")
                    DispatchQueue.main.async { completion("画面をロックしました") }
                }
            }
        }
    }
}
