import Accelerate
import AVFoundation
import Foundation

/// 自製ウェイクワードエンジン: MFCC特徴量抽出 + DTW距離マッチング
/// Porcupine相当の仕組みを外部依存なしで実装
class WakeWordEngine {
    static let shared = WakeWordEngine()

    // MARK: - Audio / MFCC parameters

    private let targetRate: Double = 16000
    private let frameLen   = 400   // 25ms @ 16kHz
    private let hopLen     = 160   // 10ms @ 16kHz
    private let fftN       = 512
    private let nMel       = 26
    private let nMFCC      = 13
    private let preEmph: Float = 0.97

    /// DTW正規化距離の閾値（大きいほど緩い）。ログのdistを見て調整
    var distThreshold: Float = 4.5

    // MARK: - Pre-computed tables

    private let fftSetup: FFTSetup
    private let hannWin:  [Float]    // [frameLen]
    private let melFB:    [[Float]]  // [nMel][fftN/2+1]
    private let dctMat:   [[Float]]  // [nMFCC][nMel]

    // MARK: - State

    private(set) var templates: [[[Float]]] = []  // [N templates][frames][nMFCC]
    private var audioEngine: AVAudioEngine?
    private var audioBuf: [Float] = []
    private let bufMax    = 24000  // 1.5s @ 16kHz (テンプレートと同じ長さ)
    private let minSamples = 6000  // 0.375s minimum before checking
    private var lastCheck  = Date()
    private let checkEvery: TimeInterval = 0.1   // 100ms毎にチェック（低レイテンシ）
    private var targetFmt: AVAudioFormat?         // キャッシュ: 毎回生成しない
    private(set) var isRunning = false

    /// AVAudioEngine.start() の連続失敗回数。3 回までは指数 backoff で retry、
    /// それ以上は諦めて koeWakeWordEngineFailed 通知を発火する（無限再帰防止）。
    internal var consecutiveBuildFailures: Int = 0
    #if DEBUG
    /// テスト用フック: true の間 buildEngine() の catch 分岐を強制的に実行する。
    /// DEBUG ビルドのみ存在し、production ビルドには出てこない。
    internal var testHookForcedFailure: Bool = false
    #endif

    var onDetected: (() -> Void)?

    // MARK: - Init

    init() {
        let log2n = vDSP_Length(log2f(Float(fftN)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))!

        var w = [Float](repeating: 0, count: frameLen)
        vDSP_hann_window(&w, vDSP_Length(frameLen), Int32(vDSP_HANN_NORM))
        hannWin = w

        melFB  = Self.buildMelFB(fftN: 512, nMel: 26)
        dctMat = Self.buildDCT(nMFCC: 13, nMel: 26)

        loadTemplates()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - Mel filterbank & DCT

    private static func melScale(_ hz: Float) -> Float { 2595 * log10f(1 + hz / 700) }
    private static func invMel(_ m: Float) -> Float { 700 * (powf(10, m / 2595) - 1) }

    private static func buildMelFB(fftN: Int, nMel: Int,
                                    loHz: Float = 80, hiHz: Float = 8000,
                                    sr: Int = 16000) -> [[Float]] {
        let lo = melScale(loHz), hi = melScale(hiHz)
        let pts = (0..<nMel + 2).map { invMel(lo + Float($0) * (hi - lo) / Float(nMel + 1)) }
        let bins = pts.map { max(0, min(fftN / 2, Int(($0 / Float(sr / 2)) * Float(fftN / 2)))) }
        var fb = [[Float]](repeating: [Float](repeating: 0, count: fftN / 2 + 1), count: nMel)
        for m in 0..<nMel {
            let (l, c, r) = (bins[m], bins[m + 1], bins[m + 2])
            for k in l..<c where c > l { fb[m][k] = Float(k - l) / Float(c - l) }
            for k in c..<r where r > c { fb[m][k] = Float(r - k) / Float(r - c) }
        }
        return fb
    }

    private static func buildDCT(nMFCC: Int, nMel: Int) -> [[Float]] {
        let s = sqrtf(2.0 / Float(nMel))
        return (0..<nMFCC).map { i in
            (0..<nMel).map { j in s * cosf(.pi * Float(i) * (Float(j) + 0.5) / Float(nMel)) }
        }
    }

    // MARK: - MFCC extraction

    func extractMFCC(from samples: [Float]) -> [[Float]] {
        guard samples.count >= frameLen else { return [] }

        // Pre-emphasis
        var s = samples
        for i in stride(from: s.count - 1, through: 1, by: -1) { s[i] -= preEmph * s[i - 1] }

        var frames: [[Float]] = []
        var start = 0
        while start + frameLen <= s.count {
            // Hann window
            var frame = [Float](repeating: 0, count: fftN)
            vDSP_vmul(Array(s[start..<start + frameLen]), 1, hannWin, 1, &frame, 1, vDSP_Length(frameLen))

            // Real FFT: pack as split complex (even → re, odd → im)
            var re = [Float](repeating: 0, count: fftN / 2)
            var im = [Float](repeating: 0, count: fftN / 2)
            for k in 0..<fftN / 2 { re[k] = frame[2 * k]; im[k] = frame[2 * k + 1] }

            // Power spectrum
            var power = [Float](repeating: 0, count: fftN / 2 + 1)
            re.withUnsafeMutableBufferPointer { rePtr in
                im.withUnsafeMutableBufferPointer { imPtr in
                    var split = DSPSplitComplex(realp: rePtr.baseAddress!, imagp: imPtr.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2f(Float(fftN))), FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftN / 2))
                }
            }

            // Mel filterbank → log energy
            var melE = [Float](repeating: 0, count: nMel)
            for m in 0..<nMel {
                var e: Float = 0
                vDSP_dotpr(power, 1, melFB[m], 1, &e, vDSP_Length(fftN / 2 + 1))
                melE[m] = logf(max(e, 1e-8))
            }

            // DCT → MFCC
            var coeff = [Float](repeating: 0, count: nMFCC)
            for c in 0..<nMFCC {
                vDSP_dotpr(melE, 1, dctMat[c], 1, &coeff[c], vDSP_Length(nMel))
            }
            frames.append(coeff)
            start += hopLen
        }

        // CMVN: subtract per-coefficient mean (removes channel/distance effects)
        // vDSPで各係数の平均を一括計算
        if frames.count > 1 {
            let nf = vDSP_Length(frames.count)
            var col = [Float](repeating: 0, count: frames.count)
            for c in 0..<nMFCC {
                for f in 0..<frames.count { col[f] = frames[f][c] }
                var mean: Float = 0
                vDSP_meanv(col, 1, &mean, nf)
                mean = -mean
                vDSP_vsadd(col, 1, &mean, &col, 1, nf)
                for f in 0..<frames.count { frames[f][c] = col[f] }
            }
        }
        return frames
    }

    // MARK: - DTW (Sakoe-Chiba band)

    func dtwDist(_ a: [[Float]], _ b: [[Float]]) -> Float {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        let band = max(Int(Float(max(n, m)) * 0.3), 10)

        // 1行ずつ計算（メモリ節約: 2行分だけ保持）
        var prev = [Float](repeating: .infinity, count: m + 1)
        var curr = [Float](repeating: .infinity, count: m + 1)
        prev[0] = 0

        for i in 1...n {
            curr = [Float](repeating: .infinity, count: m + 1)
            let jMin = max(1, i - band), jMax = min(m, i + band)
            for j in jMin...jMax {
                var d: Float = 0
                vDSP_distancesq(a[i - 1], 1, b[j - 1], 1, &d, vDSP_Length(nMFCC))
                curr[j] = sqrtf(d) + min(prev[j], min(curr[j - 1], prev[j - 1]))
            }
            swap(&prev, &curr)
        }
        guard prev[m] != .infinity else { return .infinity }
        return prev[m] / Float(n + m)
    }

    // MARK: - VAD: skip processing when silent

    private func hasVoice(_ s: [Float]) -> Bool {
        var rms: Float = 0
        vDSP_rmsqv(s, 1, &rms, vDSP_Length(s.count))
        return rms > 0.002
    }

    // MARK: - Real-time detection

    func start() {
        guard !isRunning else { return }
        #if DEBUG
        let forced = testHookForcedFailure
        #else
        let forced = false
        #endif
        guard isReady || forced else {
            klog("WakeWordEngine: need \(Self.minTemplates) templates (have \(templates.count))")
            return
        }
        isRunning = true
        audioBuf = []
        lastCheck = Date()
        buildEngine()
        klog("WakeWordEngine: started (\(templates.count) templates, threshold=\(distThreshold))")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        teardown()
        klog("WakeWordEngine: stopped")
    }

    private func buildEngine() {
        #if DEBUG
        // テスト用フック: AVAudioEngine 自体を組み立てずに catch 分岐へ直行する。
        // CLI テスト環境では AVAudioEngine.inputNode が CoreAudio 待ちで無期限ブロックするため、
        // 実音声デバイスに触れずに backoff state machine を検証できるようにしておく。
        if testHookForcedFailure {
            handleBuildFailure(NSError(domain: "WakeWordEngineTest", code: -1))
            return
        }
        #endif

        let engine = AVAudioEngine()
        audioEngine = engine
        let node = engine.inputNode
        let natFmt = node.outputFormat(forBus: 0)
        // AVAudioFormatをキャッシュ（毎回生成しない）
        if targetFmt == nil {
            targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: targetRate, channels: 1, interleaved: false)
        }
        guard let tgtFmt = targetFmt,
              let conv = AVAudioConverter(from: natFmt, to: tgtFmt) else {
            audioEngine = nil
            isRunning = false; return
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: natFmt) { [weak self] buf, _ in
            self?.ingest(buf, converter: conv, targetFmt: tgtFmt)
        }
        do {
            engine.prepare()
            try engine.start()
            // 起動成功 → 失敗カウンタをリセット
            consecutiveBuildFailures = 0
        } catch {
            // start() 失敗時に tap を残すと次回 buildEngine() で
            // "required condition is false: format.sampleRate == hwFormat.sampleRate" 系で crash する
            node.removeTap(onBus: 0)
            handleBuildFailure(error)
        }
    }

    /// AVAudioEngine.start() の失敗を一元処理する: tear-down → カウンタ更新 → backoff retry or give-up。
    /// 直接 self.start() を再帰呼び出ししていた旧実装は連続失敗時にスタックを食い潰してハングした。
    private func handleBuildFailure(_ error: Error) {
        klog("WakeWordEngine: engine error \(error) (failures=\(consecutiveBuildFailures + 1))")
        audioEngine = nil
        isRunning = false

        if consecutiveBuildFailures < 3 {
            consecutiveBuildFailures += 1
            // 1s / 2s / 4s の指数 backoff で retry
            let delay = pow(2.0, Double(consecutiveBuildFailures - 1))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.start()
            }
        } else {
            // すでに 3 回失敗済み → これ以上 retry せず通知。
            // counter は 3 のまま据え置き（success 時に 0 にリセットされる）。
            klog("WakeWordEngine: giving up after \(consecutiveBuildFailures) consecutive failures")
            NotificationCenter.default.post(name: .koeWakeWordEngineFailed, object: nil)
        }
    }

    private func ingest(_ buf: AVAudioPCMBuffer, converter: AVAudioConverter,
                        targetFmt: AVAudioFormat) {
        let cap = AVAudioFrameCount(Double(buf.frameLength) * targetRate / buf.format.sampleRate + 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: cap) else { return }
        var done = false
        converter.convert(to: out, error: nil) { _, st in
            if done { st.pointee = .noDataNow; return buf }
            done = true; st.pointee = .haveData; return buf
        }
        if let ch = out.floatChannelData?[0] {
            audioBuf.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        }
        if audioBuf.count > bufMax { audioBuf.removeFirst(audioBuf.count - bufMax) }

        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= checkEvery,
              audioBuf.count >= minSamples else { return }
        lastCheck = now

        let snap = audioBuf
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.isRunning else { return }
            guard self.hasVoice(snap) else { return }

            let query = self.extractMFCC(from: snap)
            guard query.count >= 5 else { return }

            let minDist = self.templates.map { self.dtwDist(query, $0) }.min() ?? .infinity
            klog("WakeWordEngine: DTW dist=\(String(format:"%.3f", minDist)) (threshold=\(self.distThreshold))")

            if minDist <= self.distThreshold {
                DispatchQueue.main.async {
                    self.stop()
                    self.onDetected?()
                }
            }
        }
    }

    private func teardown() {
        if let e = audioEngine {
            if e.isRunning { e.stop() }
            e.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    // MARK: - Template recording

    /// テンプレートが使用可能か（最低録音回数を満たしているか）
    static let minTemplates = 3
    var isReady: Bool { templates.count >= Self.minTemplates }

    /// 無音チェック用の最低RMS閾値（テンプレート登録時）
    private let templateMinRMS: Float = 0.002

    func recordTemplate(duration: Double = 1.5, completion: @escaping (Bool) -> Void) {
        // 検出エンジンが動いていると競合するので一時停止
        let wasRunning = audioEngine?.isRunning == true
        if wasRunning { teardown() }

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let natFmt = node.outputFormat(forBus: 0)
        guard let tgtFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: targetRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: natFmt, to: tgtFmt) else {
            DispatchQueue.main.async { completion(false) }; return
        }

        let needed = Int(targetRate * duration)
        var collected: [Float] = []
        let sema = DispatchSemaphore(value: 0)

        node.installTap(onBus: 0, bufferSize: 4096, format: natFmt) { buf, _ in
            guard collected.count < needed else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * self.targetRate / buf.format.sampleRate + 1)
            guard let out = AVAudioPCMBuffer(pcmFormat: tgtFmt, frameCapacity: cap) else { return }
            var done = false
            conv.convert(to: out, error: nil) { _, st in
                if done { st.pointee = .noDataNow; return buf }
                done = true; st.pointee = .haveData; return buf
            }
            if let ch = out.floatChannelData?[0] {
                collected.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            }
            if collected.count >= needed { sema.signal() }
        }
        do { engine.prepare(); try engine.start() }
        catch {
            klog("WakeWordEngine.recordTemplate: engine error \(error)")
            node.removeTap(onBus: 0)
            // 以前ここで wasRunning && self.start() を呼んでいたが、buildEngine() 失敗が
            // 連続する状況下で無限再帰してアプリがハングする退行を生んでいた。検出側の
            // 再開は recordTemplate 利用元 (設定 UI 等) が判断する。
            DispatchQueue.main.async { completion(false) }
            return
        }

        DispatchQueue.global().async {
            _ = sema.wait(timeout: .now() + duration + 1)
            engine.stop(); node.removeTap(onBus: 0)

            let samples = Array(collected.prefix(needed))

            // 無音チェック: RMSが閾値以下なら拒否（無音テンプレートは誤検出の原因）
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
            if rms < self.templateMinRMS {
                klog("WakeWordEngine: rejected — too quiet (RMS=\(String(format:"%.4f", rms)))")
                DispatchQueue.main.async {
                    if wasRunning { self.start() }
                    completion(false)
                }
                return
            }

            let frames = self.extractMFCC(from: samples)
            guard frames.count >= 5 else {
                DispatchQueue.main.async {
                    if wasRunning { self.start() }
                    completion(false)
                }
                return
            }
            self.templates.append(frames)
            self.saveTemplates()
            klog("WakeWordEngine: template added (\(self.templates.count) total, \(frames.count) frames, RMS=\(String(format:"%.4f", rms)))")
            DispatchQueue.main.async {
                if wasRunning { self.start() }
                completion(true)
            }
        }
    }

    func clearTemplates() {
        templates = []
        UserDefaults.standard.removeObject(forKey: "wakeWordMFCC")
        klog("WakeWordEngine: templates cleared")
    }

    // MARK: - Persistence

    private func saveTemplates() {
        if let d = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(d, forKey: "wakeWordMFCC")
        }
    }

    private func loadTemplates() {
        guard let d = UserDefaults.standard.data(forKey: "wakeWordMFCC"),
              let t = try? JSONDecoder().decode([[[Float]]].self, from: d) else { return }
        templates = t
        klog("WakeWordEngine: loaded \(t.count) templates")
    }
}
