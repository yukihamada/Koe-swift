import Foundation

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

    func process(text: String, instruction: String, completion: @escaping (String) -> Void) {
        let s = AppSettings.shared
        guard s.llmEnabled, !text.isEmpty else {
            completion(text); return
        }

        // ユーザーカスタムプロンプト → アプリ別指示 → デフォルト
        let customPrompt = s.llmCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt: String
        if !instruction.isEmpty {
            systemPrompt = instruction
        } else if !customPrompt.isEmpty {
            systemPrompt = customPrompt
        } else {
            systemPrompt = Self.defaultInstruction
        }

        // ローカルLLM
        if s.llmUseLocal {
            processLocalOnDemand(text: text, instruction: systemPrompt, completion: completion)
            return
        }

        // リモートAPI
        if !s.llmAPIKey.isEmpty {
            processRemote(text: text, instruction: systemPrompt, completion: completion)
            return
        }

        completion(text)
    }

    // MARK: - Local (オンデマンド: ロード → 推論 → 遅延アンロード)

    private func processLocalOnDemand(text: String, instruction: String, completion: @escaping (String) -> Void) {
        // タイマーをキャンセル（連続使用時はアンロードしない）
        unloadTimer?.invalidate()
        unloadTimer = nil

        let llm = LlamaContext.shared

        // 既にロード済みなら即実行
        if llm.isLoaded {
            runAndScheduleUnload(text: text, instruction: instruction, completion: completion)
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
                self?.runAndScheduleUnload(text: text, instruction: instruction, completion: completion)
            } else {
                klog("LLM: on-demand load failed, using original")
                completion(text)
            }
        }
    }

    private func runAndScheduleUnload(text: String, instruction: String, completion: @escaping (String) -> Void) {
        klog("LLM: local processing...")
        LlamaContext.shared.generate(system: instruction, user: text, maxTokens: 300) { [weak self] result in
            if let result, !result.isEmpty {
                klog("LLM local done: '\(result.prefix(80))'")
                completion(result)
            } else {
                klog("LLM local: failed, using original")
                completion(text)
            }
            // 30秒後にアンロード（連続使用でなければメモリ解放）
            self?.scheduleUnload()
        }
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: unloadDelay, repeats: false) { _ in
            let llm = LlamaContext.shared
            if llm.isLoaded {
                klog("LLM: auto-unloading after \(Int(self.unloadDelay))s idle")
                llm.unload()
            }
        }
    }

    // MARK: - Remote (OpenAI-compatible API)

    private func processRemote(text: String, instruction: String, completion: @escaping (String) -> Void) {
        let s = AppSettings.shared
        let body: [String: Any] = [
            "model": s.llmModel,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text]
            ],
            "max_tokens": 1000,
            "stream": false
        ]
        let urlStr = "\(s.llmBaseURL)/v1/chat/completions"
        guard let url = URL(string: urlStr),
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost",
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            if URL(string: urlStr)?.scheme == "http" { klog("LLM: HTTP rejected (use HTTPS)") }
            completion(text); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(s.llmAPIKey)", forHTTPHeaderField: "Authorization")
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
}
