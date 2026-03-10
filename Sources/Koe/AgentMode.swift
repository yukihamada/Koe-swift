import AppKit
import UserNotifications

// MARK: - Agent Command

enum AgentCommand {
    case openApp(name: String)
    case search(query: String)
    case screenshot
    case timer(minutes: Int)
    case shellCommand(cmd: String)
    case shortcut(name: String)

    var description: String {
        switch self {
        case .openApp(let name):     return "アプリを開く: \(name)"
        case .search(let query):     return "検索: \(query)"
        case .screenshot:            return "スクリーンショット"
        case .timer(let minutes):    return "タイマー: \(minutes)分"
        case .shellCommand(let cmd): return "コマンド実行: \(cmd)"
        case .shortcut(let name):    return "ショートカット: \(name)"
        }
    }
}

// MARK: - Agent Mode

class AgentMode {
    static let shared = AgentMode()

    /// Check if text looks like a command (returns nil if it's normal text)
    func detectCommand(_ text: String) -> AgentCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // スクリーンショット
        if t.contains("スクショ") || t.contains("スクリーンショット") {
            return .screenshot
        }

        // タイマー: "N分タイマー" or "タイマーN分"
        if let m = matchTimer(t) {
            return .timer(minutes: m)
        }

        // ショートカット実行: "ショートカット〜を実行" or "〜を実行して"
        if let name = matchShortcut(t) {
            return .shortcut(name: name)
        }

        // ターミナルコマンド: "ターミナルで〜"
        if let cmd = matchShellCommand(t) {
            return .shellCommand(cmd: cmd)
        }

        // 検索: "〜を検索" or "〜で検索" or "〜検索して" or "検索して〜"
        if let query = matchSearch(t) {
            return .search(query: query)
        }

        // アプリを開く: "〜を開いて" or "〜を開く" or "〜開いて"
        if let name = matchOpenApp(t) {
            return .openApp(name: name)
        }

        return nil
    }

    /// Execute the detected command
    func execute(_ command: AgentCommand, completion: @escaping (String) -> Void) {
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

    // セキュリティ: 許可されたコマンドのホワイトリスト
    private static let allowedCommands = Set([
        "ls", "pwd", "date", "cal", "uptime", "whoami", "hostname",
        "df", "du", "top", "ps", "sw_vers", "system_profiler",
        "say", "afplay", "open", "pbcopy", "pbpaste",
        "curl", "ping", "dig", "nslookup", "ifconfig",
        "echo", "cat", "head", "tail", "wc", "sort", "uniq", "grep",
        "defaults", "diskutil", "pmset", "caffeinate",
    ])

    private func isSafeCommand(_ cmd: String) -> Bool {
        // 危険なパターンを拒否
        let dangerous = ["rm ", "rm\t", "rmdir", "sudo", "chmod", "chown",
                         "mkfs", "dd ", "kill", "pkill", "killall",
                         "> /", ">> /", "| sh", "| bash", "| zsh",
                         "`", "$(",  "&&", "||", ";",
                         "/etc/", "/var/", "/usr/", "/System/"]
        for d in dangerous {
            if cmd.contains(d) { return false }
        }
        // 最初のコマンドがホワイトリストにあるか確認
        let first = cmd.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? ""
        let basename = (first as NSString).lastPathComponent
        return AgentMode.allowedCommands.contains(basename)
    }

    private func executeShell(cmd: String, completion: @escaping (String) -> Void) {
        guard isSafeCommand(cmd) else {
            klog("Agent: blocked unsafe command '\(cmd.prefix(50))'")
            DispatchQueue.main.async { completion("セキュリティ上の理由でこのコマンドは実行できません") }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", cmd]
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
}
