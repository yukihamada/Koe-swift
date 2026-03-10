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

    static func normalize(_ samples: [Float], targetPeak: Float = 0.9) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var maxVal: Float = 0
        vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))
        guard maxVal > 0.001 else { return samples } // ほぼ無音ならそのまま
        let scale = targetPeak / maxVal
        // クリッピング防止: 倍率上限 10x
        let safeScale = min(scale, 10.0)
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

    // MARK: - Full Pipeline
    // 推奨処理順: 正規化 → プリエンファシス → (トリミングは WhisperContext で実行)

    static func process(_ samples: [Float], preEmphasisEnabled: Bool = true) -> [Float] {
        var buf = normalize(samples)
        if preEmphasisEnabled {
            buf = preEmphasis(buf)
        }
        return buf
    }
}
