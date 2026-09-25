import Foundation
import AVFoundation
import Accelerate
import CWhisper

/// whisper.cpp C API の Swift ラッパー。
/// モデルをプロセス内メモリに保持し、HTTP/subprocess オーバーヘッドなしで推論。
final class WhisperContext {
    static let shared = WhisperContext()

    private var ctx: OpaquePointer?  // whisper_context*
    /// unload() を deinit/queue 内から呼んでも自己 dispatch_sync でデッドロック
    /// しないための共有ラッパー。WhisperContext/LlamaContext で共通実装 —
    /// 詳細は ReentrantSerialQueue.swift 参照。
    private let rq = ReentrantSerialQueue(label: "com.yuki.koe.whisper")
    private var queue: DispatchQueue { rq.queue }
    // 投機実行は同じqueueを使用（whisper_contextは並行アクセス不可）
    private(set) var isLoaded = false
    private(set) var isLoading = false
    /// `ctx`/`isLoaded` と同じく `queue` 上でのみ読み書きする (queue-confined)。
    /// `unload()`/`loadModel`/`loadModelSync` はどれもこれを「今から作る/作った
    /// ctx が、まだ有効な試行か」の判定に使う: `unload()`/`unloadForTermination()`
    /// が呼ばれるたびに +1 され、ある試行の開始時に読んだ値と、公開する直前に
    /// 読んだ値が食い違っていれば「その間に誰かが unload した」ということなので、
    /// 作ったばかりの ctx を publish せず即座に free する。
    ///
    /// **重要**: これは「呼ばれたら二度とロードさせない」ための恒久フラグでは
    /// ない（それは `isShutDown` の役目）— 通常の `unload()` はモデル切替や
    /// 低メモリ時の解放でも使われ、その後の `loadModel` は普通に成功しなければ
    /// ならない。恒久的な `terminating` 相当のフラグをここに置いてしまうと、
    /// 一度でも unload するとモデルが二度とロードできなくなる不具合になる
    /// (2026-09-26 のレビューで指摘・修正)。
    private var generation = 0
    /// アプリ終了専用の恒久フラグ。`unloadForTermination()` だけが立てる —
    /// 立った後は `generation` の食い違いを待つまでもなく、以後のロードを
    /// 全て拒否する。通常の `unload()` はこれを立てない。
    private var isShutDown = false
    /// 直前の認識にかかった時間（秒）
    private(set) var lastTranscriptionTime: Double = 0
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
            // このロード試行が「有効」だった世代を記録しておく。whisper_init は
            // 数百ms〜数秒かかりうる重い呼び出し — その間に unload()/
            // unloadForTermination() が割り込んで generation が進んでいれば、
            // 今作ったばかりの ctx は publish せず捨てる。
            let myGeneration = self.generation
            if self.isShutDown {
                DispatchQueue.main.async {
                    self.isLoading = false
                    completion(false)
                }
                return
            }

            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            cparams.flash_attn = true

            let ptr = whisper_init_from_file_with_params(path, cparams)

            // ctx/isLoaded の publish は queue 上でここで行う (queue-confined
            // state) — unload() の teardown も同じ queue 上で直列に走るため、
            // 「load完了後にunloadが古いctxをfreeし損ねる」「unload後にloadが
            // ctxを再publishしてしまう」という順序の食い違いが起きない。
            if self.isShutDown || self.generation != myGeneration {
                if let ptr { whisper_free(ptr) }
                DispatchQueue.main.async {
                    self.isLoading = false
                    completion(false)
                }
                return
            }
            if let ptr {
                self.ctx = ptr
                self.isLoaded = true
            }
            DispatchQueue.main.async {
                self.isLoading = false
                if ptr != nil {
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
    ///
    /// `loadModel` (非同期版) と違い、重い `whisper_init_from_file_with_params`
    /// を **queue の外**（呼び出し元のスレッド）で実行する — publish だけを
    /// `rq.syncOrInline` で queue に閉じ込める。つまり「build」と「publish」が
    /// 別ステップに分かれるため、その間に `unload()` が割り込む余地が実際にある
    /// (queue 1ブロックの中で build から publish まで完結する `loadModel` の
    /// 非同期パスでは、同じ queue 上で他の何かが割り込むことは構造上あり得ない
    /// ので generation の食い違いは通常起きない — ここでは genuinely 起き得る)。
    func loadModelSync(path: String) -> Bool {
        guard !isLoaded else { return true }
        var myGeneration = 0
        var shutDown = false
        rq.syncOrInline {
            myGeneration = generation
            shutDown = isShutDown
        }
        guard !shutDown else { return false }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let ptr = whisper_init_from_file_with_params(path, cparams) else {
            klog("WhisperContext: sync load failed")
            return false
        }
        var published = false
        rq.syncOrInline {
            if isShutDown || generation != myGeneration {
                whisper_free(ptr)
            } else {
                ctx = ptr
                isLoaded = true
                published = true
            }
        }
        if published {
            klog("WhisperContext: model loaded sync (GPU enabled)")
        }
        return published
    }

    /// モデルを解放する（モデル切替・低メモリ時の解放など通常の用途）。
    /// **恒久的な拒否ではない** — この後の `loadModel`/`loadModelSync` は普通に
    /// 成功する。in-flight のロードは `generation` を進めることで無効化する
    /// (作り終えた ctx を publish せず free する) だけで、以後のロード自体は
    /// 妨げない。
    ///
    /// `transcribe`/`transcribeBuffer`/`transcribeWithSpeakers` はすべて `queue`
    /// 上で `ctx` を読んで `whisper_full` を実行する。ここでも同じ `queue` 上で
    /// 直列化して、実行中/キュー待ちの推論が完了してから free することで、実行中の
    /// 推論に対する use-after-free を防ぐ。
    func unload() {
        rq.syncOrInline {
            generation += 1
            if let ctx { whisper_free(ctx) }
            ctx = nil
            isLoaded = false
        }
        klog("WhisperContext: unloaded")
    }

    /// アプリ終了専用。`AppDelegate.applicationWillTerminate` から必ず呼ぶこと —
    /// `unload()` と違い、これは**恒久的**に以後の `loadModel`/`loadModelSync` を
    /// 拒否する（アプリが終了する以上、二度とロードされるべきではない）。
    ///
    /// `WhisperContext.shared` は `static let` なので、プロセス終了時に Swift の
    /// `deinit` が確実に呼ばれる保証はない（呼ばれなければ `whisper_free` が
    /// 一度も走らず、whisper が保持する ggml Metal backend の解放は C++ 側の
    /// 静的デストラクタ任せになる。Metal デバイスが既にティアダウンされた後に
    /// `__cxa_finalize` 経由でそれが走ると `ggml_metal_device_free` で abort する
    /// — 2026-09-19 の終了時クラッシュの原因）。
    func unloadForTermination() {
        rq.syncOrInline {
            isShutDown = true
            generation += 1
            if let ctx { whisper_free(ctx) }
            ctx = nil
            isLoaded = false
        }
        klog("WhisperContext: unloaded for termination")
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
        // 速度最適化: best_of=1 + single_segment + temperature_inc=0 で最速
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = !timestamps
        params.single_segment = false  // ハルシネーション防止: セグメント分割を許可
        params.suppress_blank = true
        params.suppress_nst = true    // 非音声トークンを抑制（ハルシネーション防止）
        params.token_timestamps = timestamps
        params.no_context = true      // 前回コンテキストによる繰り返しループを防止
        params.greedy.best_of = 1      // 速度: 1回の推論で結果を返す（5→1で3-5倍速い）
        params.entropy_thold = 2.4
        params.logprob_thold = -1.0
        params.no_speech_thold = 0.6
        params.temperature = 0.0
        params.temperature_inc = 0.0   // 速度: 温度上げ再試行なし（0.2→0で余分な推論をカット）
        params.vad = false
        return params
    }

    // MARK: - Transcribe

    /// WAV ファイルからテキストを生成。バックグラウンドで実行。
    /// メイン認識パス: 投機実行をキャンセルしてから実行。
    func transcribe(url: URL, language: String = "ja", prompt: String = "",
                    completion: @escaping (String?) -> Void) {
        // `isLoaded`/`ctx` はここでは呼び出し元のスレッド (UI 等) から読む —
        // queue-confined ではなく、意図的にレースを許容した「だめ元」の早期
        // リターンでしかない。本当の可否判定は必ず下の `queue.async` の中で
        // `self.ctx`/`self.isLoaded` を読み直して行う (queue-confined) ため、
        // ここが古い値を読んでも実害は「無駄に completion(nil) で早期returnする」
        // か「無駄に queue.async を1個積んで、その中で正しく nil 判定される」
        // だけで、use-after-free には繋がらない。ここを queue.sync 越しに
        // 読むと、レイテンシに敏感な音声入力の全 transcribe 呼び出しに
        // 同期キューホップが乗ってしまうため、意図的にしていない。
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

            // 先頭・末尾の無音をトリム（認識サンプル数を削減して高速化）
            let trimThreshold: Float = 0.002
            let trimBlock = 160  // 10ms @ 16kHz
            var trimStart = 0
            while trimStart + trimBlock < samples.count {
                let block = samples[trimStart..<(trimStart + trimBlock)]
                if block.contains(where: { abs($0) > trimThreshold }) { break }
                trimStart += trimBlock
            }
            var trimEnd = samples.count
            while trimEnd - trimBlock > trimStart {
                let block = samples[(trimEnd - trimBlock)..<trimEnd]
                if block.contains(where: { abs($0) > trimThreshold }) { break }
                trimEnd -= trimBlock
            }
            // 前後に0.1秒のマージンを残す
            trimStart = max(0, trimStart - 1600)
            trimEnd = min(samples.count, trimEnd + 1600)
            samples = Array(samples[trimStart..<trimEnd])

            let nThreads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
            klog("WhisperContext: [bridge] lang=\(language) samples=\(samples.count) trimmed=\(trimStart)-\(trimEnd) threads=\(nThreads)")
            let start = CFAbsoluteTimeGetCurrent()

            // 短すぎる音声はスキップ（0.5秒未満 = ハルシネーション防止）
            guard samples.count >= 8000 else {
                klog("WhisperContext: too short (\(samples.count) samples), skipping")
                DispatchQueue.main.async { completion(nil) }
                return
            }

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
                    1,  // best_of=1 for speed (was ws.bestOf=5)
                    true,   // suppress_blank
                    ws.temperature,
                    0.0,  // temperature_inc=0 for speed (was ws.temperatureInc=0.2)
                    ws.entropyThreshold,
                    -1.0,   // logprob_thold
                    0.6,    // no_speech_thold
                    &outputBuf, Int32(bufSize)
                )
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            self.lastTranscriptionTime = elapsed
            let text = String(cString: outputBuf).trimmingCharacters(in: .whitespacesAndNewlines)
            klog("WhisperContext: [bridge] \(nSeg) segments in \(String(format: "%.3f", elapsed))s → '\(text.isEmpty ? "(empty)" : String(text.prefix(80)))'")

            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
    }

    /// 既に Float32 PCM バッファがある場合（投機実行・ストリーミング用）
    /// メイン認識がリクエストされたらキャンセルされる。
    func transcribeBuffer(samples: [Float], language: String = "ja", prompt: String = "",
                          completion: @escaping (String?) -> Void) {
        // 早期リターンの位置付けは transcribe() 冒頭のコメント参照
        // (queue 外の「だめ元」チェック — 本判定は queue.async の中で再度行う)。
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
                    1,  // best_of=1 for speed (was ws.bestOf=5)
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
        // 早期リターンの位置付けは transcribe() 冒頭のコメント参照
        // (queue 外の「だめ元」チェック — 本判定は queue.async の中で再度行う)。
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
        // AVAudioFile で確実に Float32 PCM 16kHz mono を読む。
        // 録音中のWAVはヘッダーのサイズフィールドが未確定(0)のため length=0 で読めない →
        // 自前の生PCMパースにフォールバック（投機実行=停止前の先行認識に必須）。
        guard let audioFile = try? AVAudioFile(forReading: url), audioFile.length > 0 else {
            return loadWAVRaw(url: url)
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
            klog("WhisperContext: AVAudioFile read failed (\(error.localizedDescription)) — raw fallback")
            return loadWAVRaw(url: url)
        }

        guard let floatData = buffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
        return samples
    }

    /// 自前WAVパース: data チャンクを探して 16bit LE PCM を直接読む。
    /// アプリ自身の録音 (16kHz/mono/16bit) 前提。ヘッダー未確定の録音中ファイルも読める。
    private static func loadWAVRaw(url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else {
            klog("WhisperContext: raw WAV fallback failed (too small)")
            return nil
        }
        let off = findDataChunk(in: data)
        guard off > 0, off < data.count else { return nil }
        let payload = data.count - off
        let sampleCount = (payload - payload % 2) / 2
        guard sampleCount > 0 else { return nil }
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.advanced(by: off) else { return }
            for i in 0..<sampleCount {
                var v: Int16 = 0
                memcpy(&v, base.advanced(by: i * 2), 2)   // 2バイト境界非保証のため memcpy
                samples[i] = Float(v) / 32768.0
            }
        }
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
