import Speech
import Foundation

class SpeechEngine {
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?

    init() {
        let lang = AppSettings.shared.language
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang == "auto" ? Locale.current.identifier : lang))
            ?? SFSpeechRecognizer(locale: .current)!
        klog("SpeechEngine init: \(lang), available=\(recognizer.isAvailable)")
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            klog("Speech auth: \(status.rawValue)")
        }
    }

    func recognize(url: URL, prompt: String = "", languageOverride: String = "", onDone: @escaping (String) -> Void) {
        klog("recognize: \(url.lastPathComponent) prompt='\(prompt)' lang='\(languageOverride)'")
        switch AppSettings.shared.recognitionEngine {
        case .whisperCpp:
            recognizeWhisperCpp(url: url, prompt: prompt, languageOverride: languageOverride, onDone: onDone)
        case .appleCloud, .appleOnDevice:
            recognizeApple(url: url, languageOverride: languageOverride, onDone: onDone)
        case .whisper:
            recognizeWhisper(url: url, prompt: prompt, languageOverride: languageOverride,
                             baseURL: "https://api.openai.com",
                             apiKey: AppSettings.shared.whisperAPIKey,
                             model: "whisper-1", onDone: onDone)
        }
    }

    // MARK: - whisper.cpp (Metal / Python不要)

    private func recognizeWhisperCpp(url: URL, prompt: String, languageOverride: String,
                                      onDone: @escaping (String) -> Void) {
        let rawLang = languageOverride.isEmpty ? AppSettings.shared.language : languageOverride
        let lang = rawLang == "auto" ? "auto" : (rawLang.components(separatedBy: "-").first ?? "en")

        // モデル自動切替: 現在のモデルが選択言語をサポートしない場合、最適モデルに切替
        let dl = ModelDownloader.shared
        let best = ModelDownloader.bestModel(for: lang)
        if best.id != dl.currentModel.id {
            if dl.isDownloaded(best) {
                klog("SpeechEngine: auto-switching model to \(best.name) for lang=\(lang)")
                dl.selectModel(best)
                WhisperContext.shared.loadModel(path: dl.path(for: best)) { _ in }
            } else {
                klog("SpeechEngine: need model \(best.name) for lang=\(lang) but not downloaded")
            }
        }

        // 組み込みモデルが読み込み済みなら C API 直接呼び出し（最速パス）
        if WhisperContext.shared.isLoaded {
            klog("whisper: using embedded C API")
            WhisperContext.shared.transcribe(url: url, language: lang, prompt: prompt) { text in
                if let text, !text.isEmpty {
                    klog("whisper embedded done: '\(text)'")
                    onDone(text)
                } else {
                    klog("whisper embedded failed, trying subprocess")
                    self.whisperSubprocess(url: url, lang: lang, prompt: prompt, onDone: onDone)
                }
            }
            return
        }

        // 組み込みモデル未ロードならサーバー/subprocess にフォールバック
        whisperServerFallback(url: url, lang: lang, prompt: prompt, onDone: onDone)
    }

    private func whisperServerFallback(url: URL, lang: String, prompt: String,
                                       onDone: @escaping (String) -> Void) {
        if WhisperServer.shared.isAlive() {
            klog("whisper: using server")
            WhisperServer.shared.transcribe(url: url, language: lang, prompt: prompt) { text in
                if let text {
                    klog("whisper server done: '\(text)'")
                    DispatchQueue.main.async { onDone(text) }
                } else {
                    self.whisperSubprocess(url: url, lang: lang, prompt: prompt, onDone: onDone)
                }
            }
            return
        }
        whisperSubprocess(url: url, lang: lang, prompt: prompt, onDone: onDone)
    }

    private func whisperSubprocess(url: URL, lang: String, prompt: String,
                                    onDone: @escaping (String) -> Void) {
        guard let binary = findWhisperCppBinary() else {
            klog("whisper.cpp: binary not found"); onDone(""); return
        }
        let modelPath = AppSettings.shared.whisperCppModelPath
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            klog("whisper.cpp: model not found"); onDone(""); return
        }

        // "auto": omit -l flag so whisper auto-detects; otherwise pass the language code
        var args = ["-m", modelPath, "-f", url.path, "-nt", "-np"]
        if lang != "auto" { args += ["-l", lang] }
        if !prompt.isEmpty { args += ["--prompt", prompt] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = FileHandle.nullDevice

        p.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            klog("whisper subprocess done: '\(text)'")
            DispatchQueue.main.async { onDone(text) }
        }
        do {
            try p.run()
            klog("whisper subprocess: PID=\(p.processIdentifier)")
        } catch {
            klog("whisper subprocess error: \(error)"); onDone("")
        }
    }

    private func findWhisperCppBinary() -> String? {
        let custom = AppSettings.shared.whisperCppBinaryPath
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) { return custom }
        let candidates = ["/opt/homebrew/bin/whisper-cli",
                          "/usr/local/bin/whisper-cli",
                          "/opt/homebrew/bin/whisper-cpp",
                          "/usr/local/bin/whisper-cpp"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Apple Speech

    private func recognizeApple(url: URL, languageOverride: String, onDone: @escaping (String) -> Void) {
        task?.cancel()
        // Use per-app language override if set
        let lang = languageOverride.isEmpty ? AppSettings.shared.language : languageOverride
        let rec: SFSpeechRecognizer
        if lang != AppSettings.shared.language,
           let override = SFSpeechRecognizer(locale: Locale(identifier: lang)) {
            rec = override
        } else {
            rec = recognizer
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if #available(macOS 13, *) {
            req.addsPunctuation = true
        }
        if AppSettings.shared.recognitionEngine == .appleOnDevice {
            req.requiresOnDeviceRecognition = true
        }
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            if let result, result.isFinal {
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespaces)
                klog("recognition done: '\(text)'")
                onDone(text)
                self?.task = nil
            } else if let error {
                klog("recognition error: \(error.localizedDescription)")
                onDone("")
                self?.task = nil
            }
        }
    }

    // MARK: - OpenAI Whisper

    private func recognizeWhisper(url: URL, prompt: String, languageOverride: String,
                                   baseURL: String, apiKey: String, model: String,
                                   onDone: @escaping (String) -> Void) {
        guard !apiKey.isEmpty else {
            klog("Whisper: API key not set")
            onDone(""); return
        }
        guard let audioData = try? Data(contentsOf: url) else {
            klog("Whisper: failed to read audio file")
            onDone(""); return
        }

        let baseLang = languageOverride.isEmpty ? AppSettings.shared.language : languageOverride
        let langCode = baseLang == "auto" ? nil : (baseLang.components(separatedBy: "-").first ?? "en")
        klog("Whisper: baseURL=\(baseURL) model=\(model) lang=\(langCode ?? "auto")")

        let boundary = "KoeBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        func append(_ string: String) { body.append(Data(string.utf8)) }

        // model field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // language field (omit when auto-detecting)
        if let langCode {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(langCode)\r\n")
        }

        // prompt field (optional)
        if !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(prompt)\r\n")
        }

        // file field
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "\(baseURL)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                klog("Whisper error: \(error.localizedDescription)")
                onDone(""); return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                klog("Whisper: unexpected response: \(String(data: data ?? Data(), encoding: .utf8) ?? "")")
                onDone(""); return
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            klog("Whisper done: '\(trimmed)'")
            onDone(trimmed)
        }.resume()
    }

    func cancel() { task?.cancel(); task = nil }
}
