import Foundation

/// whisper-server をバックグラウンドで常駐させてモデルをメモリに保持する。
/// 毎回 subprocess でモデルを読み込む (~2s) → HTTP で叩くだけ (~0.5s) に短縮。
class WhisperServer {
    static let shared = WhisperServer()

    let port = 18080
    var baseURL: String { "http://127.0.0.1:\(port)" }

    private var process: Process?

    // MARK: - Lifecycle

    func start() {
        guard let binary = findBinary() else {
            klog("WhisperServer: whisper-server not found")
            return
        }
        let model = AppSettings.shared.whisperCppModelPath
        guard !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
            klog("WhisperServer: model not set or missing")
            return
        }

        // すでに動いていれば何もしない
        if isAlive() { klog("WhisperServer: already running"); return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        let lang = AppSettings.shared.language
        let whisperLang = lang == "auto" ? "auto" : (lang.components(separatedBy: "-").first ?? "en")
        p.arguments = ["-m", model, "--port", "\(port)", "--host", "127.0.0.1", "-l", whisperLang]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice

        do {
            try p.run()
            process = p
            klog("WhisperServer: launched PID=\(p.processIdentifier)")
        } catch {
            klog("WhisperServer: launch error \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        klog("WhisperServer: stopped")
    }

    // MARK: - Transcribe via HTTP

    func transcribe(url: URL, language: String, prompt: String,
                    completion: @escaping (String?) -> Void) {
        guard let audioData = try? Data(contentsOf: url) else {
            completion(nil); return
        }

        let boundary = "KoeBoundary\(Int.random(in: 100000...999999))"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        if !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }
        if !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(prompt)\r\n")
        }
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: "\(baseURL)/inference")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error {
                klog("WhisperServer: HTTP error \(error.localizedDescription)")
                completion(nil); return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                klog("WhisperServer: bad response \(String(data: data ?? Data(), encoding: .utf8) ?? "")")
                completion(nil); return
            }
            completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }

    // MARK: - Helpers

    func isAlive() -> Bool {
        guard let url = URL(string: "\(baseURL)/") else { return false }
        var result = false
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.5
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            result = (resp as? HTTPURLResponse) != nil
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    /// 起動完了まで最大60秒ポーリング
    func waitUntilReady(timeout: Int = 60, onReady: @escaping () -> Void) {
        func check(_ remaining: Int) {
            guard remaining > 0 else {
                klog("WhisperServer: timeout waiting for ready"); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if self.isAlive() {
                    klog("WhisperServer: ready")
                    DispatchQueue.main.async { onReady() }
                } else {
                    check(remaining - 1)
                }
            }
        }
        check(timeout)
    }

    private func findBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/whisper-server",
                          "/usr/local/bin/whisper-server"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
