import Foundation
import AppKit

class LLMProcessor {
    static let shared = LLMProcessor()

    /// デフォルトの後処理指示（アプリ別指示がない場合に使用）
    static let defaultInstruction = """
    音声認識の結果を修正してください。以下のルールに従ってください：
    - 誤字・脱字を修正
    - 適切な句読点（、。）を追加
    - 明らかな認識ミスを文脈から推測して修正
    - 元の意味を変えない
    - 修正後のテキストのみを出力（説明不要）
    """

    /// アンロードまでの待機時間（秒）
    private var unloadTimer: Timer?
    private let unloadDelay: TimeInterval = 30  // 30秒後にアンロード

    func process(text: String, instruction: String, appBundleID: String = "", completion: @escaping (String) -> Void) {
        let s = AppSettings.shared
        guard s.llmEnabled, !text.isEmpty else {
            completion(text); return
        }

        // モードが「なし」でアプリ別指示もなければスキップ
        if s.llmMode == .none && instruction.isEmpty {
            klog("LLM: skipped (mode=none)")
            completion(text); return
        }

        // 優先順位: アプリ別指示 > カスタムモードのプロンプト > モード別指示 > デフォルト
        var systemPrompt: String
        if !instruction.isEmpty {
            systemPrompt = instruction
        } else if s.llmMode == .custom {
            let customPrompt = s.llmCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            systemPrompt = customPrompt.isEmpty ? Self.defaultInstruction : customPrompt
        } else {
            let modeInstruction = s.llmMode.instruction
            systemPrompt = modeInstruction.isEmpty ? Self.defaultInstruction : modeInstruction
        }

        // Super Mode: 画面コンテキストをシステムプロンプトに追加
        if let context = ContextCollector.collectForLLM(appBundleID: appBundleID) {
            systemPrompt = "コンテキスト: \(context)\n\n\(systemPrompt)"
        }

        klog("LLM: mode=\(s.llmMode.rawValue) useLocal=\(s.llmUseLocal) provider=\(s.llmProvider.rawValue) instruction=\(systemPrompt.prefix(60))")

        // ローカルLLM
        if s.llmUseLocal {
            processLocalOnDemand(text: text, instruction: systemPrompt, completion: completion)
            return
        }

        // リモートAPI（chatweb.aiはAPIキー不要、それ以外はAPIキー必須）
        if !s.llmProvider.requiresAPIKey || !s.llmAPIKey.isEmpty {
            if s.llmProvider == .anthropic {
                processAnthropic(text: text, instruction: systemPrompt, completion: completion)
            } else {
                processRemote(text: text, instruction: systemPrompt, completion: completion)
            }
            return
        }

        klog("LLM: no valid provider configured, skipping")
        completion(text)
    }

    /// VLM（Vision Language Model）: 画像 + テキストプロンプトで処理
    /// スクリーンショットを直接VLMに送って画面の内容を理解させる
    func processWithVision(image: CGImage, prompt: String, completion: @escaping (String) -> Void) {
        let s = AppSettings.shared

        // 画像をJPEG Base64に変換（品質70%でサイズ削減）
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            klog("LLM(VLM): failed to encode image")
            completion("")
            return
        }
        let base64 = jpegData.base64EncodedString()
        klog("LLM(VLM): image \(image.width)x\(image.height), base64 \(base64.count / 1024)KB")

        // OpenAI Vision API 互換形式で送信
        let messages: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                ["type": "text", "text": prompt]
            ] as [[String: Any]]]
        ]

        // リモートAPI（VLM対応モデル: gpt-4o, claude, qwen3-vl等）
        var baseURL = "https://chatweb.ai/api/v1/chat/completions"
        var model = "auto"
        var apiKey = ""

        if !s.llmProvider.requiresAPIKey || !s.llmAPIKey.isEmpty {
            baseURL = s.llmProvider.baseURL
            model = s.llmModel.isEmpty ? s.llmProvider.defaultModel : s.llmModel
            apiKey = s.llmAPIKey
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.3
        ]

        guard let url = URL(string: baseURL),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            klog("LLM(VLM): invalid URL or body")
            completion("")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                klog("LLM(VLM): API error: \(error?.localizedDescription ?? "parse failed")")
                completion("")
                return
            }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FFFD}", with: "")
            klog("LLM(VLM): result \(cleaned.count) chars")
            completion(cleaned)
        }.resume()
    }

    /// 画面コンテキスト専用: llmEnabled/llmModeに関係なく、利用可能なLLMで処理
    func processScreenContext(prompt: String, completion: @escaping (String) -> Void) {
        guard !prompt.isEmpty else { completion(""); return }
        let s = AppSettings.shared

        // UTF-8文字化けをサニタイズするラッパー
        let sanitizedCompletion: (String) -> Void = { result in
            // マルチバイト途中切断による文字化け（U+FFFD）を除去
            let cleaned = result.replacingOccurrences(of: "\u{FFFD}", with: "")
                .replacingOccurrences(of: "��", with: "")
            completion(cleaned)
        }

        // ローカルLLM
        if s.llmUseLocal {
            klog("LLM(screen): using local")
            processLocalOnDemand(text: prompt, instruction: "要約と提案のみ出力", completion: sanitizedCompletion)
            return
        }

        // リモートAPI
        if !s.llmProvider.requiresAPIKey || !s.llmAPIKey.isEmpty {
            klog("LLM(screen): using remote \(s.llmProvider.rawValue)")
            if s.llmProvider == .anthropic {
                processAnthropic(text: prompt, instruction: "要約と提案のみ出力", completion: sanitizedCompletion)
            } else {
                processRemote(text: prompt, instruction: "要約と提案のみ出力", completion: sanitizedCompletion)
            }
            return
        }

        // chatweb.ai (APIキー不要)
        klog("LLM(screen): trying chatweb.ai fallback")
        processRemoteWith(text: prompt, instruction: "要約と提案のみ出力",
                          baseURL: "https://chatweb.ai/api/v1/chat/completions",
                          model: "auto", apiKey: "", completion: sanitizedCompletion)
    }

    // MARK: - Local (通常モード: 常時ロード / メモリ省略モード: 使用時にロード→即解放)

    private func processLocalOnDemand(text: String, instruction: String, completion: @escaping (String) -> Void) {
        unloadTimer?.invalidate()
        unloadTimer = nil

        let llm = LlamaContext.shared

        // 既にロード済みなら即実行
        if llm.isLoaded {
            runLocalGeneration(text: text, instruction: instruction, completion: completion)
            return
        }

        // モデルファイルがあるか確認
        guard let model = llm.selectedModel, llm.isDownloaded(model) else {
            klog("LLM: no local model downloaded, skipping")
            completion(text); return
        }

        // オンデマンドでロード
        klog("LLM: on-demand loading \(model.name)...")
        llm.loadModel { [weak self] ok in
            if ok {
                self?.runLocalGeneration(text: text, instruction: instruction, completion: completion)
            } else {
                klog("LLM: on-demand load failed, using original")
                completion(text)
            }
        }
    }

    private func runLocalGeneration(text: String, instruction: String, completion: @escaping (String) -> Void) {
        // thinking tokens (≈300) + 回答用（入力の2倍 or 最低200）
        let answerBudget = max(200, text.count)
        let tokens = min(2048, 400 + answerBudget)  // 画面コンテキスト用に2048まで拡大
        klog("LLM: local processing (maxTokens=\(tokens))...")
        LlamaContext.shared.generate(system: instruction, user: text, maxTokens: tokens) { [weak self] result in
            if let result, !result.isEmpty {
                klog("LLM local done: '\(result.prefix(80))'")
                completion(result)
            } else {
                klog("LLM local: failed, using original")
                completion(text)
            }
            // メモリ省略モード: LLM処理後すぐにアンロード（Whisperとメモリを共有）
            if AppSettings.shared.llmMemorySaveMode {
                self?.scheduleUnload()
            }
        }
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            let llm = LlamaContext.shared
            if llm.isLoaded {
                klog("LLM: memory-save mode — unloading after use")
                llm.unload()
            }
        }
    }

    // MARK: - Remote (OpenAI-compatible API)

    /// 指定したベースURL/モデルでリモート処理（フォールバック用）
    private func processRemoteWith(text: String, instruction: String,
                                    baseURL: String, model: String, apiKey: String,
                                    completion: @escaping (String) -> Void) {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text]
            ],
            "max_tokens": 1000,
            "stream": false
        ]
        let urlStr = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: urlStr),
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost",
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(text); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                klog("LLM: remote fallback failed, using original")
                DispatchQueue.main.async { completion(text) }
                return
            }
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            klog("LLM remote fallback done: '\(result)'")
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func processRemote(text: String, instruction: String, completion: @escaping (String) -> Void) {
        let s = AppSettings.shared
        let baseURL = s.llmProvider == .custom ? s.llmBaseURL : s.llmProvider.baseURL
        let model   = s.llmModel

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text]
            ],
            "max_tokens": 1000,
            "stream": false
        ]
        let urlStr = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: urlStr),
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost",
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            if URL(string: urlStr)?.scheme == "http" { klog("LLM: HTTP rejected (use HTTPS)") }
            completion(text); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !s.llmAPIKey.isEmpty {
            req.setValue("Bearer \(s.llmAPIKey)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                klog("LLM: remote failed, using original")
                DispatchQueue.main.async { completion(text) }
                return
            }
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            klog("LLM remote done: '\(result)'")
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - Remote (Anthropic Messages API)

    private func processAnthropic(text: String, instruction: String, completion: @escaping (String) -> Void) {
        let s = AppSettings.shared
        let model = s.llmModel
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1000,
            "system": instruction,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]
        let urlStr = "\(LLMProvider.anthropic.baseURL)/v1/messages"
        guard let url = URL(string: urlStr),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(text); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(s.llmAPIKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contentArray = json["content"] as? [[String: Any]],
                  let firstBlock = contentArray.first,
                  let content = firstBlock["text"] as? String else {
                klog("LLM: Anthropic failed, using original")
                DispatchQueue.main.async { completion(text) }
                return
            }
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            klog("LLM Anthropic done: '\(result)'")
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
