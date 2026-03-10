import Foundation
import CWhisper

/// whisper.cpp C API の Swift ラッパー。
/// モデルをプロセス内メモリに保持し、HTTP/subprocess オーバーヘッドなしで推論。
final class WhisperContext {
    static let shared = WhisperContext()

    private var ctx: OpaquePointer?  // whisper_context*
    private let queue = DispatchQueue(label: "com.yuki.koe.whisper", qos: .userInitiated)
    private(set) var isLoaded = false
    private(set) var isLoading = false

    // MARK: - Model loading

    /// モデルを非同期でロード。GPU (Metal) 自動有効化。
    func loadModel(path: String, completion: @escaping (Bool) -> Void) {
        guard !isLoading else { completion(false); return }
        if isLoaded { completion(true); return }

        isLoading = true
        klog("WhisperContext: loading model \(path)")

        queue.async { [weak self] in
            guard let self else { return }
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            cparams.flash_attn = true

            let ptr = whisper_init_from_file_with_params(path, cparams)
            DispatchQueue.main.async {
                self.isLoading = false
                if let ptr {
                    self.ctx = ptr
                    self.isLoaded = true
                    klog("WhisperContext: model loaded (GPU enabled)")
                    completion(true)
                } else {
                    klog("WhisperContext: failed to load model")
                    completion(false)
                }
            }
        }
    }

    /// モデルを同期でロード（起動時用）。
    func loadModelSync(path: String) -> Bool {
        guard !isLoaded else { return true }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let ptr = whisper_init_from_file_with_params(path, cparams) else {
            klog("WhisperContext: sync load failed")
            return false
        }
        ctx = ptr
        isLoaded = true
        klog("WhisperContext: model loaded sync (GPU enabled)")
        return true
    }

    func unload() {
        if let ctx { whisper_free(ctx) }
        ctx = nil
        isLoaded = false
        klog("WhisperContext: unloaded")
    }

    // MARK: - Transcribe

    /// WAV ファイルからテキストを生成。バックグラウンドで実行。
    func transcribe(url: URL, language: String = "ja", prompt: String = "",
                    completion: @escaping (String?) -> Void) {
        guard isLoaded, ctx != nil else {
            klog("WhisperContext: model not loaded")
            completion(nil); return
        }

        queue.async { [weak self] in
            guard let self, let ctx = self.ctx else { completion(nil); return }

            // WAV → Float32 PCM
            guard let samples = Self.loadWAV(url: url) else {
                klog("WhisperContext: failed to read WAV")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Setup params
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            params.print_progress = false
            params.print_special = false
            params.print_realtime = false
            params.print_timestamps = false
            params.no_timestamps = true
            params.single_segment = false
            params.suppress_blank = true
            params.suppress_nst = true
            params.no_context = true
            params.temperature = 0.0
            params.temperature_inc = 0.2
            params.greedy.best_of = 1

            // Language
            let langCStr = language == "auto" ? nil : (language as NSString).utf8String
            params.language = langCStr
            params.detect_language = (language == "auto")

            // Prompt
            let promptCStr = prompt.isEmpty ? nil : (prompt as NSString).utf8String
            params.initial_prompt = promptCStr

            let start = CFAbsoluteTimeGetCurrent()

            // Run inference
            let result = samples.withUnsafeBufferPointer { buf -> String? in
                guard let ptr = buf.baseAddress else { return nil }
                let ret = whisper_full(ctx, params, ptr, Int32(samples.count))
                guard ret == 0 else {
                    klog("WhisperContext: whisper_full returned \(ret)")
                    return nil
                }

                let nSegments = whisper_full_n_segments(ctx)
                var text = ""
                for i in 0..<nSegments {
                    if let seg = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: seg)
                    }
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            klog("WhisperContext: transcribed in \(String(format: "%.3f", elapsed))s → '\(result ?? "")'")

            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 既に Float32 PCM バッファがある場合（投機実行用）
    func transcribeBuffer(samples: [Float], language: String = "ja", prompt: String = "",
                          completion: @escaping (String?) -> Void) {
        guard isLoaded, ctx != nil else { completion(nil); return }

        queue.async { [weak self] in
            guard let self, let ctx = self.ctx else { completion(nil); return }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            params.print_progress = false
            params.print_special = false
            params.print_realtime = false
            params.print_timestamps = false
            params.no_timestamps = true
            params.single_segment = false
            params.suppress_blank = true
            params.suppress_nst = true
            params.no_context = true
            params.temperature = 0.0
            params.temperature_inc = 0.2
            params.greedy.best_of = 1

            let langCStr = language == "auto" ? nil : (language as NSString).utf8String
            params.language = langCStr
            params.detect_language = (language == "auto")
            let promptCStr = prompt.isEmpty ? nil : (prompt as NSString).utf8String
            params.initial_prompt = promptCStr

            let result = samples.withUnsafeBufferPointer { buf -> String? in
                guard let ptr = buf.baseAddress else { return nil }
                let ret = whisper_full(ctx, params, ptr, Int32(samples.count))
                guard ret == 0 else { return nil }

                let nSegments = whisper_full_n_segments(ctx)
                var text = ""
                for i in 0..<nSegments {
                    if let seg = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: seg)
                    }
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - WAV → Float32 PCM

    /// 16kHz mono 16bit WAV → [Float] (-1.0 ~ 1.0)
    static func loadWAV(url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }

        // Parse WAV header
        let headerSize = 44  // standard WAV header
        let audioData = data.subdata(in: headerSize..<data.count)
        let sampleCount = audioData.count / 2  // 16-bit samples

        var samples = [Float](repeating: 0, count: sampleCount)
        audioData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }
        return samples
    }

    deinit {
        unload()
    }
}
