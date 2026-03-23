import Foundation
import AVFoundation

/// マイク音声とシステム音声をミックスして1つのWAVファイルにする
class AudioMixer {
    /// 2つのWAVファイルをミックスして新しいファイルを生成
    static func mix(micURL: URL, systemURL: URL?, outputURL: URL) -> Bool {
        guard let systemURL,
              FileManager.default.fileExists(atPath: systemURL.path) else {
            // システム音声なし→マイク音声をそのままコピー
            try? FileManager.default.copyItem(at: micURL, to: outputURL)
            return true
        }

        guard let micSamples = WhisperContext.loadWAVPublic(url: micURL),
              let sysSamples = WhisperContext.loadWAVPublic(url: systemURL) else {
            // 読み込み失敗→マイクのみ
            try? FileManager.default.copyItem(at: micURL, to: outputURL)
            return true
        }

        // ミックス（長い方に合わせる）
        let maxLen = max(micSamples.count, sysSamples.count)
        var mixed = [Float](repeating: 0, count: maxLen)
        for i in 0..<maxLen {
            let mic = i < micSamples.count ? micSamples[i] : 0
            let sys = i < sysSamples.count ? sysSamples[i] * 0.8 : 0  // システム音声を少し下げる
            mixed[i] = max(-1, min(1, mic + sys))  // クリッピング防止
        }

        // WAVファイルとして書き出し
        return writeWAV(samples: mixed, to: outputURL)
    }

    /// Float32サンプルをWAVファイルとして書き出し（16kHz, mono, 16bit）
    static func writeWAV(samples: [Float], to url: URL) -> Bool {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            try file.write(from: buffer)
            return true
        } catch {
            klog("AudioMixer: write failed: \(error)")
            return false
        }
    }
}
