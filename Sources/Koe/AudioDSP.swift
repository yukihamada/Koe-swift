import Accelerate

/// 音声信号処理ユーティリティ。
/// Whisper に渡す前に音質を改善して認識精度を向上させる。
/// すべての処理は Accelerate フレームワークで高速実行。
enum AudioDSP {

    // MARK: - Pre-emphasis Filter (高域強調)
    // y[n] = x[n] - α * x[n-1]
    // カ行・サ行・タ行など子音の高周波成分を強調し、
    // Whisper が語頭・語境界を検出しやすくする。
    // α=0.97 が音声認識の標準値。計算コストほぼゼロ。

    static func preEmphasis(_ samples: [Float], alpha: Float = 0.97) -> [Float] {
        guard samples.count > 1 else { return samples }
        var output = [Float](repeating: 0, count: samples.count)
        output[0] = samples[0]
        for i in 1..<samples.count {
            output[i] = samples[i] - alpha * samples[i - 1]
        }
        return output
    }

    // MARK: - Volume Normalization (音量正規化)
    // ピーク値を検出して一定レベルに揃える。
    // マイクとの距離やゲイン差を吸収し、Whisper への入力を安定化。

    static func normalize(_ samples: [Float], targetPeak: Float = 0.95) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var maxVal: Float = 0
        vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))
        guard maxVal > 0.001 else { return samples } // ほぼ無音ならそのまま
        let scale = targetPeak / maxVal
        // クリッピング防止: 倍率上限 20x（小声でもしっかり拾う）
        let safeScale = min(scale, 20.0)
        var output = [Float](repeating: 0, count: samples.count)
        var s = safeScale
        vDSP_vsmul(samples, 1, &s, &output, 1, vDSP_Length(samples.count))
        return output
    }

    // MARK: - Voice Activity Detection (音声区間検出)
    // RMS パワーで音声の有無を判定。
    // 音声がまったく検出されない録音はWhisperに渡さずスキップ。

    static func hasVoice(_ samples: [Float], threshold: Float = 0.01, minVoiceFrames: Int = 5) -> Bool {
        let frameSize = 160 // 10ms @ 16kHz
        guard samples.count >= frameSize else { return false }
        let frameCount = samples.count / frameSize
        var voiceFrames = 0
        for i in 0..<frameCount {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            if rms > threshold {
                voiceFrames += 1
                if voiceFrames >= minVoiceFrames { return true }
            }
        }
        return false
    }

    // MARK: - VAD Trimming (音声区間のみ抽出)
    // 前後の無音を除去してWhisperの処理時間を短縮＋精度向上。
    // 音声区間の前後に余白(margin)を残して自然な区切りを維持。

    static func trimSilence(_ samples: [Float], threshold: Float = 0.005, margin: Int = 8000) -> [Float] {
        let frameSize = 160 // 10ms @ 16kHz
        guard samples.count >= frameSize else { return samples }
        let frameCount = samples.count / frameSize

        // 各フレームのRMSを計算して音声区間を検出
        var firstVoice = 0
        var lastVoice = frameCount - 1
        var foundFirst = false

        for i in 0..<frameCount {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            if rms > threshold {
                if !foundFirst { firstVoice = i; foundFirst = true }
                lastVoice = i
            }
        }

        guard foundFirst else { return samples }

        // マージン付きでサンプル範囲を計算
        let startSample = max(0, firstVoice * frameSize - margin)
        let endSample = min(samples.count, (lastVoice + 1) * frameSize + margin)

        // トリミングで50%以上削れる場合のみ適用（短い録音では不要）
        guard endSample - startSample < samples.count / 2 * 3 else { return samples }

        return Array(samples[startSample..<endSample])
    }

    // MARK: - Full Pipeline
    // 推奨処理順: 無音トリミング → 正規化 → プリエンファシス

    static func process(_ samples: [Float], preEmphasisEnabled: Bool = true) -> [Float] {
        var buf = trimSilence(samples)
        buf = normalize(buf)
        if preEmphasisEnabled {
            buf = preEmphasis(buf)
        }
        return buf
    }
}
