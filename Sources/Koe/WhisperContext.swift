import Foundation
import Accelerate
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

    // MARK: - Transcribe with speaker diarization

    /// セグメント結果: 話者番号とテキスト
    struct SpeakerSegment {
        let speaker: Int
        let text: String
    }

    /// tinydiarize を使った話者分離付き文字起こし。
    /// whisper.cpp の tdrz_enable で話者交代を検出し、話者番号を割り当てる。
    func transcribeWithSpeakers(url: URL, language: String = "ja", prompt: String = "",
                                completion: @escaping ([SpeakerSegment]) -> Void) {
        guard isLoaded, ctx != nil else {
            klog("WhisperContext: model not loaded (diarize)")
            completion([]); return
        }

        queue.async { [weak self] in
            guard let self, let ctx = self.ctx else { completion([]); return }

            guard let samples = Self.loadWAV(url: url) else {
                klog("WhisperContext: failed to read WAV (diarize)")
                DispatchQueue.main.async { completion([]) }
                return
            }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            params.print_progress = false
            params.print_special = false
            params.print_realtime = false
            params.print_timestamps = false
            params.no_timestamps = false  // タイムスタンプが必要（話者検出用）
            params.single_segment = false
            params.suppress_blank = true
            params.suppress_nst = true
            params.no_context = true
            params.temperature = 0.0
            params.temperature_inc = 0.2
            params.greedy.best_of = 1

            // tinydiarize 有効化
            params.tdrz_enable = true

            let langCStr = language == "auto" ? nil : (language as NSString).utf8String
            params.language = langCStr
            params.detect_language = (language == "auto")
            let promptCStr = prompt.isEmpty ? nil : (prompt as NSString).utf8String
            params.initial_prompt = promptCStr

            let start = CFAbsoluteTimeGetCurrent()

            let segments: [SpeakerSegment] = samples.withUnsafeBufferPointer { buf in
                guard let ptr = buf.baseAddress else { return [] }
                let ret = whisper_full(ctx, params, ptr, Int32(samples.count))
                guard ret == 0 else {
                    klog("WhisperContext: whisper_full returned \(ret) (diarize)")
                    return []
                }

                let nSegments = whisper_full_n_segments(ctx)
                guard nSegments > 0 else { return [] }

                // tinydiarize: speaker_turn_next が true のセグメントの「次」で話者が変わる
                var currentSpeaker = 0
                var results: [SpeakerSegment] = []

                for i in 0..<nSegments {
                    guard let seg = whisper_full_get_segment_text(ctx, i) else { continue }
                    let text = String(cString: seg).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    // [SPEAKER_TURN] トークンがテキストに含まれる場合も除去
                    let cleaned = text.replacingOccurrences(of: "[SPEAKER_TURN]", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { continue }

                    results.append(SpeakerSegment(speaker: currentSpeaker, text: cleaned))

                    // このセグメントの後に話者交代があるかチェック
                    if whisper_full_get_segment_speaker_turn_next(ctx, i) {
                        currentSpeaker += 1
                        klog("WhisperContext: speaker turn after segment \(i) → speaker \(currentSpeaker)")
                    }
                }

                // tinydiarize が話者交代を1つも検出しなかった場合、
                // フォールバック: セグメント間の無音ギャップ(>1.5s)で話者交代を推定
                let hasTurns = results.contains { $0.speaker > 0 }
                if !hasTurns && nSegments > 1 {
                    var fallbackResults: [SpeakerSegment] = []
                    var fbSpeaker = 0
                    for i in 0..<nSegments {
                        guard let seg = whisper_full_get_segment_text(ctx, i) else { continue }
                        let text = String(cString: seg).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }

                        // セグメント間のギャップをチェック
                        if i > 0 {
                            let prevEnd = whisper_full_get_segment_t1(ctx, i - 1)
                            let curStart = whisper_full_get_segment_t0(ctx, i)
                            // タイムスタンプは 10ms 単位 (centiseconds)
                            let gapMs = (curStart - prevEnd) * 10
                            if gapMs > 1500 {
                                fbSpeaker += 1
                                klog("WhisperContext: silence gap \(gapMs)ms → speaker \(fbSpeaker)")
                            }
                        }
                        fallbackResults.append(SpeakerSegment(speaker: fbSpeaker, text: text))
                    }
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    klog("WhisperContext: diarized (fallback) in \(String(format: "%.3f", elapsed))s, \(fallbackResults.count) segments")
                    return fallbackResults
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - start
                klog("WhisperContext: diarized (tdrz) in \(String(format: "%.3f", elapsed))s, \(results.count) segments")
                return results
            }

            DispatchQueue.main.async { completion(segments) }
        }
    }

    // MARK: - WAV → Float32 PCM

    /// 16kHz mono 16bit WAV → [Float] (-1.0 ~ 1.0)、前後の無音をトリミング
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

        // トリミング: 前後の無音を除去（Whisperの処理時間を短縮）
        return trimSilence(samples)
    }

    /// 前後の無音区間をカットして音声部分だけ返す
    /// 160サンプル(10ms)のフレーム単位で判定、前後に200ms(3200サンプル)のマージン
    private static func trimSilence(_ samples: [Float], threshold: Float = 0.005) -> [Float] {
        let frameSize = 160  // 10ms @ 16kHz
        let margin = 3200    // 200ms margin
        let frameCount = samples.count / frameSize
        guard frameCount > 0 else { return samples }

        // 各フレームのRMSを計算してvoice/silenceを判定
        var firstVoice = 0
        var lastVoice = frameCount - 1

        for i in 0..<frameCount {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            if rms > threshold {
                firstVoice = i
                break
            }
        }

        for i in stride(from: frameCount - 1, through: 0, by: -1) {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            if rms > threshold {
                lastVoice = i
                break
            }
        }

        let trimStart = max(0, firstVoice * frameSize - margin)
        let trimEnd = min(samples.count, (lastVoice + 1) * frameSize + margin)

        if trimEnd - trimStart < samples.count / 2 {
            // トリミングが半分以上削ると精度に影響するので元のまま
            return samples
        }

        let trimmed = Array(samples[trimStart..<trimEnd])
        let savedMs = (samples.count - trimmed.count) * 1000 / 16000
        if savedMs > 50 {
            klog("WhisperContext: trimmed \(savedMs)ms silence (\(samples.count)→\(trimmed.count) samples)")
        }
        return trimmed
    }

    deinit {
        unload()
    }
}
