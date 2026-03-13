import Foundation
import AVFoundation
import Accelerate
import CWhisper

/// whisper.cpp C API の Swift ラッパー。
/// モデルをプロセス内メモリに保持し、HTTP/subprocess オーバーヘッドなしで推論。
final class WhisperContext {
    static let shared = WhisperContext()

    private var ctx: OpaquePointer?  // whisper_context*
    private let queue = DispatchQueue(label: "com.yuki.koe.whisper", qos: .userInitiated)
    // 投機実行は同じqueueを使用（whisper_contextは並行アクセス不可）
    private(set) var isLoaded = false
    private(set) var isLoading = false
    /// 投機実行をキャンセルするフラグ
    /// UnsafeMutablePointer経由でCコールバックからアクセスするためclass変数として管理
    private var cancelSpeculation = false
    /// abort_callback用: C関数からアクセス可能なポインタ
    private var cancelFlag: UnsafeMutablePointer<Bool> = {
        let ptr = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        ptr.initialize(to: false)
        return ptr
    }()

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

    // MARK: - Settings snapshot (メインスレッドで読む)

    private struct WhisperSettings {
        let bestOf: Int32
        let temperature: Float
        let temperatureInc: Float
        let entropyThreshold: Float
        let beamSearch: Bool
        let useContext: Bool

        init() {
            let s = AppSettings.shared
            bestOf = Int32(s.whisperBestOf)
            temperature = Float(s.whisperTemperature)
            temperatureInc = Float(s.whisperTemperatureInc)
            entropyThreshold = Float(s.whisperEntropyThreshold)
            beamSearch = s.whisperBeamSearch
            useContext = s.whisperUseContext
        }
    }

    private func makeParams(settings ws: WhisperSettings, timestamps: Bool = false) -> whisper_full_params {
        // whisper-cliのデフォルトに合わせた設定（best_of=5が精度の鍵）
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = false   // whisper-cliデフォルト
        params.single_segment = false
        params.suppress_blank = true   // whisper-cliデフォルト
        params.suppress_nst = false
        params.token_timestamps = timestamps
        params.no_context = false  // whisper-cliデフォルト
        params.greedy.best_of = 5     // whisper-cliデフォルト（精度の鍵）
        params.entropy_thold = 2.4   // whisper-cliデフォルト
        params.logprob_thold = -1.0  // whisper-cliデフォルト
        params.no_speech_thold = 0.6 // whisper-cliデフォルト
        params.temperature = 0.0     // whisper-cliデフォルト
        params.temperature_inc = 0.2 // whisper-cliデフォルト
        params.vad = false
        return params
    }

    // MARK: - Transcribe

    /// WAV ファイルからテキストを生成。バックグラウンドで実行。
    /// メイン認識パス: 投機実行をキャンセルしてから実行。
    func transcribe(url: URL, language: String = "ja", prompt: String = "",
                    completion: @escaping (String?) -> Void) {
        guard isLoaded, ctx != nil else {
            klog("WhisperContext: model not loaded")
            completion(nil); return
        }

        // 投機実行をキャンセル（キューに溜まっているものをスキップ + 実行中のものをabort）
        cancelSpeculation = true
        cancelFlag.pointee = true

        let ws = WhisperSettings()
        queue.async { [weak self] in
            guard let self, let ctx = self.ctx else { completion(nil); return }
            // メイン認識開始: 投機キャンセルをリセット
            self.cancelSpeculation = false
            self.cancelFlag.pointee = false

            // WAV → Float32 PCM
            guard var samples = Self.loadWAV(url: url) else {
                klog("WhisperContext: failed to read WAV")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // 音量情報（デバッグ用）
            let peak = samples.map { abs($0) }.max() ?? 0
            let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(max(samples.count, 1)))
            let nThreads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            klog("WhisperContext: [bridge] lang=\(language) samples=\(samples.count) rms=\(String(format:"%.4f",rms)) peak=\(String(format:"%.4f",peak)) threads=\(nThreads)")
            let start = CFAbsoluteTimeGetCurrent()

            // 音声がなければスキップ (生データで判定)
            guard AudioDSP.hasVoice(samples, threshold: 0.003, minVoiceFrames: 3) else {
                klog("WhisperContext: no voice detected, skipping")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // C bridge経由で認識（struct layout問題を回避）
            let bufSize = 8192
            var outputBuf = [CChar](repeating: 0, count: bufSize)
            let langC = language == "auto" ? nil : language
            let promptC = prompt.isEmpty ? nil : prompt

            let nSeg = samples.withUnsafeBufferPointer { buf -> Int32 in
                guard let ptr = buf.baseAddress else { return -1 }
                return whisper_bridge_transcribe(
                    ctx, ptr, Int32(samples.count),
                    langC, promptC,
                    nThreads,
                    Int32(ws.bestOf),
                    true,   // suppress_blank
                    ws.temperature,
                    ws.temperatureInc,
                    ws.entropyThreshold,
                    -1.0,   // logprob_thold
                    0.6,    // no_speech_thold
                    &outputBuf, Int32(bufSize)
                )
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let samplesSec = String(format: "%.1f", Double(samples.count) / 16000.0)
            let text = String(cString: outputBuf).trimmingCharacters(in: .whitespacesAndNewlines)
            klog("WhisperContext: [bridge] \(nSeg) segments in \(String(format: "%.3f", elapsed))s → '\(text.isEmpty ? "(empty)" : String(text.prefix(80)))'")

            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
    }

    /// 既に Float32 PCM バッファがある場合（投機実行・ストリーミング用）
    /// メイン認識がリクエストされたらキャンセルされる。
    func transcribeBuffer(samples: [Float], language: String = "ja", prompt: String = "",
                          completion: @escaping (String?) -> Void) {
        guard isLoaded, ctx != nil else { completion(nil); return }

        let ws = WhisperSettings()
        queue.async { [weak self] in
            guard let self, let ctx = self.ctx else { completion(nil); return }
            // メイン認識が来たらスキップ
            if self.cancelSpeculation {
                klog("WhisperContext: speculation cancelled, skipping")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // C bridge経由で投機実行（abort_flag対応）
            let flagPtr = self.cancelFlag
            let bufSize = 8192
            var outputBuf = [CChar](repeating: 0, count: bufSize)
            let langC = language == "auto" ? nil : language
            let promptC = prompt.isEmpty ? nil : prompt
            let nThreads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

            let nSeg = samples.withUnsafeBufferPointer { buf -> Int32 in
                guard let ptr = buf.baseAddress else { return -1 }
                return whisper_bridge_transcribe_abortable(
                    ctx, ptr, Int32(samples.count),
                    langC, promptC,
                    nThreads,
                    Int32(ws.bestOf),
                    flagPtr,
                    &outputBuf, Int32(bufSize)
                )
            }

            let result: String?
            if nSeg < 0 {
                klog("WhisperContext: speculation aborted or failed (ret=\(nSeg))")
                result = nil
            } else {
                let text = String(cString: outputBuf).trimmingCharacters(in: .whitespacesAndNewlines)
                result = text.isEmpty ? nil : text
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

        let ws = WhisperSettings()
        queue.async { [weak self] in
            guard let self, let ctx = self.ctx else { completion([]); return }

            guard let samples = Self.loadWAV(url: url) else {
                klog("WhisperContext: failed to read WAV (diarize)")
                DispatchQueue.main.async { completion([]) }
                return
            }

            var params = self.makeParams(settings: ws, timestamps: true)

            // tinydiarize 有効化
            params.tdrz_enable = true

            let langCStr = language == "auto" ? nil : strdup(language)
            defer { langCStr.map { free($0) } }
            params.language = langCStr.map { UnsafePointer($0) }
            params.detect_language = false  // detect_language=trueはハングする
            let promptCStr = prompt.isEmpty ? nil : strdup(prompt)
            defer { promptCStr.map { free($0) } }
            params.initial_prompt = promptCStr.map { UnsafePointer($0) }

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

    // MARK: - Whisper inference helper

    /// whisper_full を実行してテキストを返す（チャンク分割の共通処理）
    private func runWhisperFull(ctx: OpaquePointer, params: whisper_full_params, samples: [Float]) -> String? {
        var p = params
        return samples.withUnsafeBufferPointer { buf -> String? in
            guard let ptr = buf.baseAddress else { return nil }
            let ret = whisper_full(ctx, p, ptr, Int32(samples.count))
            guard ret == 0 else {
                klog("WhisperContext: whisper_full returned \(ret)")
                return nil
            }
            let nSegments = whisper_full_n_segments(ctx)
            klog("WhisperContext: whisper_full ret=\(ret) nSegments=\(nSegments)")
            var text = ""
            for i in 0..<nSegments {
                if let seg = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: seg)
                }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - WAV → Float32 PCM

    /// 外部から WAV ロードだけ使う場合（音声有無チェック用）
    static func loadWAVPublic(url: URL) -> [Float]? { loadWAV(url: url) }

    /// 16kHz mono 16bit WAV → [Float] (-1.0 ~ 1.0)、前後の無音をトリミング
    static func loadWAV(url: URL) -> [Float]? {
        // AVAudioFile で確実に Float32 PCM 16kHz mono を読む
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            klog("WhisperContext: failed to open audio file")
            return nil
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            klog("WhisperContext: failed to create buffer")
            return nil
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            klog("WhisperContext: failed to read audio: \(error)")
            return nil
        }

        guard let floatData = buffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
        return samples
    }

    /// WAVファイル内の "data" チャンクのデータ開始オフセットを返す
    private static func findDataChunk(in data: Data) -> Int {
        // RIFF header: 12 bytes (RIFF + size + WAVE)
        guard data.count > 12 else { return -1 }
        var offset = 12
        while offset + 8 < data.count {
            // チャンクID (4 bytes) + サイズ (4 bytes)
            let chunkID = data.subdata(in: offset..<offset+4)
            let sizeBytes = data.subdata(in: offset+4..<offset+8)
            let chunkSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }

            if chunkID == Data("data".utf8) {
                // データチャンクの開始位置 = チャンクヘッダー(8バイト)の直後
                return offset + 8
            }
            // 次のチャンクへ (チャンクサイズが奇数の場合パディング1バイト)
            offset += 8 + Int(chunkSize)
            if Int(chunkSize) % 2 != 0 { offset += 1 }
        }
        // フォールバック: 見つからなければ44を返す
        klog("WhisperContext: data chunk not found, falling back to offset 44")
        return 44
    }

    /// 前後の無音区間をカットして音声部分だけ返す
    /// 160サンプル(10ms)のフレーム単位で判定、前後にマージンを確保
    private static func trimSilence(_ samples: [Float], threshold: Float = 0.005) -> [Float] {
        let frameSize = 160  // 10ms @ 16kHz
        let margin = 8000    // 500ms margin（後半の言葉を拾い損ねない）
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
        cancelFlag.deallocate()
    }
}
