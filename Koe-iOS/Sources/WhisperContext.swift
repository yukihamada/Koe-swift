import Foundation
import Accelerate
import CWhisper

/// whisper.cpp C API の Swift ラッパー (iOS 版)。
/// Mac 版と同じモデル・同じエンジンで動作。
final class WhisperContext: ObservableObject {
    static let shared = WhisperContext()

    private var ctx: OpaquePointer?  // whisper_context*
    private let queue = DispatchQueue(label: "com.yuki.koe.whisper", qos: .userInitiated)
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false

    // MARK: - Model loading

    func loadModel(path: String, completion: @escaping (Bool) -> Void) {
        guard !isLoading else { completion(false); return }
        if isLoaded { completion(true); return }

        isLoading = true
        print("[Koe] WhisperContext: loading model \(path)")

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
                    print("[Koe] WhisperContext: model loaded (GPU enabled)")
                    completion(true)
                } else {
                    print("[Koe] WhisperContext: failed to load model")
                    completion(false)
                }
            }
        }
    }

    func unload() {
        if let ctx { whisper_free(ctx) }
        ctx = nil
        isLoaded = false
    }

    // MARK: - Transcribe from audio buffer

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
            params.no_context = true   // ハルシネーション防止
            params.temperature = 0.0
            params.temperature_inc = 0.2 // 失敗時に温度を上げてリトライ
            params.greedy.best_of = Int32(UserDefaults.standard.object(forKey: "koe_whisper_best_of") as? Int ?? 1)
            params.entropy_thold = 2.4   // 高エントロピーセグメントを再試行
            params.logprob_thold = -1.0  // 低確率セグメントのフィルタ

            let langCStr = language == "auto" ? nil : (language as NSString).utf8String
            params.language = langCStr
            params.detect_language = (language == "auto")
            let promptCStr = prompt.isEmpty ? nil : (prompt as NSString).utf8String
            params.initial_prompt = promptCStr

            let start = CFAbsoluteTimeGetCurrent()

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

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            print("[Koe] WhisperContext: transcribed in \(String(format: "%.3f", elapsed))s")

            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - WAV file transcription

    func transcribe(url: URL, language: String = "ja", prompt: String = "",
                    completion: @escaping (String?) -> Void) {
        guard let samples = Self.loadWAV(url: url) else {
            completion(nil); return
        }
        transcribeBuffer(samples: samples, language: language, prompt: prompt, completion: completion)
    }

    // MARK: - WAV → Float32 PCM

    static func loadWAV(url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let headerSize = 44
        let audioData = data.subdata(in: headerSize..<data.count)
        let sampleCount = audioData.count / 2

        var samples = [Float](repeating: 0, count: sampleCount)
        audioData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }
        return trimSilence(samples)
    }

    private static func trimSilence(_ samples: [Float], threshold: Float = 0.005) -> [Float] {
        let frameSize = 160
        let margin = 3200
        let frameCount = samples.count / frameSize
        guard frameCount > 0 else { return samples }

        var firstVoice = 0
        var lastVoice = frameCount - 1

        for i in 0..<frameCount {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            if rms > threshold { firstVoice = i; break }
        }

        for i in stride(from: frameCount - 1, through: 0, by: -1) {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            if rms > threshold { lastVoice = i; break }
        }

        let trimStart = max(0, firstVoice * frameSize - margin)
        let trimEnd = min(samples.count, (lastVoice + 1) * frameSize + margin)

        if trimEnd - trimStart < samples.count / 2 { return samples }
        return Array(samples[trimStart..<trimEnd])
    }

    deinit { unload() }
}
