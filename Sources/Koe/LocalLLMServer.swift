import Foundation
import CLlama

/// llama.cpp C API のSwiftラッパー（WhisperContextと同じパターン）。
/// モデルをプロセス内メモリに保持し、Metal GPU で高速推論。
final class LlamaContext {
    static let shared = LlamaContext()

    private var model: OpaquePointer?   // llama_model*
    private var ctx: OpaquePointer?     // llama_context*
    private let queue = DispatchQueue(label: "com.yuki.koe.llama", qos: .userInitiated)
    private(set) var isLoaded = false
    private(set) var isLoading = false

    // MARK: - Model catalog

    struct LLMModel: Identifiable {
        let id: String
        let name: String
        let description: String
        let sizeMB: Int
        let url: String
        let fileName: String
    }

    static let availableModels: [LLMModel] = [
        LLMModel(
            id: "qwen3-0.6b-q8",
            name: "Qwen3 0.6B (Q8_0)",
            description: "最軽量・即応。メモリ16GB以下に最適",
            sizeMB: 750,
            url: "https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf",
            fileName: "Qwen3-0.6B-Q8_0.gguf"
        ),
        LLMModel(
            id: "qwen3-1.7b-q4",
            name: "Qwen3 1.7B (Q4_K_M)",
            description: "軽量・高速。基本的な後処理に最適",
            sizeMB: 1280,
            url: "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
            fileName: "Qwen3-1.7B-Q4_K_M.gguf"
        ),
        LLMModel(
            id: "qwen3-1.7b-q8",
            name: "Qwen3 1.7B (Q8_0)",
            description: "高品質。精度重視の後処理に",
            sizeMB: 2170,
            url: "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf",
            fileName: "Qwen3-1.7B-Q8_0.gguf"
        ),
        LLMModel(
            id: "qwen3.5-4b-q4",
            name: "Qwen3.5 4B (Q4_K_M)",
            description: "高性能。メモリ32GB以上推奨",
            sizeMB: 2740,
            url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
            fileName: "Qwen3.5-4B-Q4_K_M.gguf"
        ),
    ]

    /// モデル保存先ディレクトリ
    var modelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/llm-models")
    }

    func modelPath(for model: LLMModel) -> URL {
        modelDir.appendingPathComponent(model.fileName)
    }

    func isDownloaded(_ model: LLMModel) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }

    var selectedModelID: String {
        get {
            // 初回はメモリに応じた推奨モデルをデフォルトに
            if let saved = UserDefaults.standard.string(forKey: "localLLMModelID") {
                return saved
            }
            return MemoryMonitor.recommendedLLMModel() ?? "qwen3-0.6b-q8"
        }
        set { UserDefaults.standard.set(newValue, forKey: "localLLMModelID") }
    }

    var selectedModel: LLMModel? {
        Self.availableModels.first { $0.id == selectedModelID }
    }

    // MARK: - Load / Unload

    /// ロード前にメモリ不足の警告メッセージを返す（nil = 安全）
    var memoryWarning: String? {
        guard let model = selectedModel else { return nil }
        return MemoryMonitor.warningText(modelSizeMB: model.sizeMB)
    }

    func loadModel(completion: @escaping (Bool) -> Void) {
        guard !isLoading, !isLoaded else { completion(isLoaded); return }
        guard let model = selectedModel else {
            klog("Llama: no model selected")
            completion(false); return
        }
        let path = modelPath(for: model).path
        guard FileManager.default.fileExists(atPath: path) else {
            klog("Llama: model file not found: \(path)")
            completion(false); return
        }

        // メモリチェック
        if !MemoryMonitor.canLoad(modelSizeMB: model.sizeMB) {
            klog("Llama: insufficient memory for \(model.name) (\(MemoryMonitor.availableMemoryMB)MB available)")
            completion(false); return
        }

        isLoading = true
        klog("Llama: loading \(model.name) (\(MemoryMonitor.statusText))...")

        queue.async { [weak self] in
            guard let self else { return }

            // Initialize backends (Metal etc.) — whisperと共有済みなら軽い
            ggml_backend_load_all()

            // メモリに応じてGPUレイヤー数を調整
            var mparams = llama_model_default_params()
            let availMB = MemoryMonitor.availableMemoryMB
            if availMB > model.sizeMB * 2 {
                mparams.n_gpu_layers = 99  // 全レイヤーGPU
            } else {
                // メモリ少ない場合は一部CPUにオフロード
                mparams.n_gpu_layers = 20
                klog("Llama: limited GPU layers (low memory)")
            }

            guard let mdl = llama_model_load_from_file(path, mparams) else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    klog("Llama: failed to load model")
                    completion(false)
                }
                return
            }

            // Create context
            var cparams = llama_context_default_params()
            cparams.n_ctx = 2048      // 後処理には十分
            cparams.n_batch = 512
            cparams.n_threads = UInt32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

            guard let context = llama_init_from_model(mdl, cparams) else {
                llama_model_free(mdl)
                DispatchQueue.main.async {
                    self.isLoading = false
                    klog("Llama: failed to create context")
                    completion(false)
                }
                return
            }

            DispatchQueue.main.async {
                self.model = mdl
                self.ctx = context
                self.isLoaded = true
                self.isLoading = false
                klog("Llama: model loaded (Metal GPU)")
                completion(true)
            }
        }
    }

    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil
        model = nil
        isLoaded = false
        klog("Llama: unloaded")
    }

    // MARK: - Chat completion

    /// system + user メッセージからテキスト生成
    func generate(system: String, user: String, maxTokens: Int = 256,
                  completion: @escaping (String?) -> Void) {
        guard isLoaded, let model = model, let ctx = ctx else {
            completion(nil); return
        }

        queue.async { [weak self] in
            guard self != nil else { completion(nil); return }

            let vocab = llama_model_get_vocab(model)!

            // Apply chat template
            let prompt = Self.applyChatTemplate(vocab: vocab, system: system, user: user)

            // Tokenize
            let maxToks = Int32(prompt.count + 256)
            var tokens = [llama_token](repeating: 0, count: Int(maxToks))
            let nTokens = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count),
                                          &tokens, maxToks, true, true)
            guard nTokens > 0 else {
                klog("Llama: tokenize failed")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            tokens = Array(tokens.prefix(Int(nTokens)))

            let eosToken = llama_vocab_eos(vocab)
            let start = CFAbsoluteTimeGetCurrent()

            // Clear KV cache
            let mem = llama_get_memory(ctx)
            llama_memory_clear(mem, true)

            // Process prompt (prefill)
            var batch = llama_batch_get_one(&tokens, nTokens)
            guard llama_decode(ctx, batch) == 0 else {
                klog("Llama: decode prompt failed")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Setup sampler
            let sparams = llama_sampler_chain_default_params()
            let smpl = llama_sampler_chain_init(sparams)!
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.3))
            llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(smpl, llama_sampler_init_min_p(0.05, 1))
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy())

            // Generate tokens
            var output = ""
            var inThink = false   // Qwen3 thinking mode: skip <think>...</think>

            for _ in 0..<maxTokens {
                let tokenID = llama_sampler_sample(smpl, ctx, -1)
                if tokenID == eosToken { break }

                // Detokenize
                var buf = [CChar](repeating: 0, count: 256)
                let len = llama_token_to_piece(vocab, tokenID, &buf, 256, 0, false)
                if len > 0 {
                    let piece = String(cString: buf)

                    // Handle <think>...</think> tags
                    if piece.contains("<think>") { inThink = true; continue }
                    if piece.contains("</think>") { inThink = false; continue }
                    if !inThink {
                        output += piece
                    }
                }

                // Decode next token
                var nextTokens = [tokenID]
                batch = llama_batch_get_one(&nextTokens, 1)
                if llama_decode(ctx, batch) != 0 { break }
            }

            llama_sampler_free(smpl)

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
            klog("Llama: generated in \(String(format: "%.2f", elapsed))s → '\(result.prefix(80))'")

            DispatchQueue.main.async { completion(result.isEmpty ? nil : result) }
        }
    }

    // MARK: - Chat template

    private static func applyChatTemplate(vocab: OpaquePointer, system: String, user: String) -> String {
        // Use llama_chat_apply_template for proper formatting
        let messages: [(role: String, content: String)] = [
            ("system", system),
            ("user", user)
        ]

        // Create C chat messages
        var cMessages: [llama_chat_message] = messages.map { msg in
            llama_chat_message(
                role: (msg.role as NSString).utf8String,
                content: (msg.content as NSString).utf8String
            )
        }

        // First call to get required buffer size
        let needed = llama_chat_apply_template(nil, &cMessages, cMessages.count, true, nil, 0)
        guard needed > 0 else {
            // Fallback: manual Qwen/ChatML format
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }

        var buf = [CChar](repeating: 0, count: Int(needed) + 1)
        llama_chat_apply_template(nil, &cMessages, cMessages.count, true, &buf, Int32(buf.count))
        return String(cString: buf)
    }

    // MARK: - Model download

    func downloadModel(_ model: LLMModel, progress: @escaping (Double, String) -> Void,
                       completion: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let dest = modelPath(for: model)

        guard let url = URL(string: model.url) else { completion(false); return }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    progress(0, "失敗: \(error?.localizedDescription ?? "")")
                    completion(false)
                }
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                DispatchQueue.main.async {
                    self?.selectedModelID = model.id
                    completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    progress(0, "保存失敗: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }

        let expectedBytes = Int64(model.sizeMB) * 1_000_000
        let observer = task.progress.observe(\.completedUnitCount) { prog, _ in
            DispatchQueue.main.async {
                let doneMB = Double(prog.completedUnitCount) / 1_000_000
                let totalMB = prog.totalUnitCount > 0 ? Double(prog.totalUnitCount) / 1_000_000 : Double(model.sizeMB)
                let pct = prog.totalUnitCount > 0
                    ? prog.fractionCompleted * 100
                    : Double(prog.completedUnitCount) / Double(expectedBytes) * 100
                let remainMB = totalMB - doneMB
                let detail = String(format: "%.0f / %.0f MB (残り %.0f MB)", doneMB, totalMB, max(0, remainMB))
                progress(min(pct, 100), detail)
            }
        }
        objc_setAssociatedObject(task, "obs", observer, .OBJC_ASSOCIATION_RETAIN)
        task.resume()
    }

    deinit { unload() }
}
