import AVFoundation
import Foundation

/// 音声/動画ファイルを WhisperContext 経由で文字起こしするクラス。
/// 長いファイルは 30 秒チャンクに分割して順次処理する。
final class FileTranscriber {
    static let supportedTypes: [String] = [
        "mp3", "m4a", "wav", "mp4", "mov", "aac", "flac", "ogg", "caf"
    ]

    /// UTType 文字列（NSOpenPanel 用）
    static let allowedContentTypes: [String] = [
        "public.mp3", "public.mpeg-4-audio", "com.microsoft.waveform-audio",
        "public.mpeg-4", "com.apple.quicktime-movie", "public.aac-audio",
        "org.xiph.flac", "org.xiph.ogg-vorbis", "com.apple.coreaudio-format",
        "public.audio", "public.movie"
    ]

    private let chunkDuration: TimeInterval = 30  // 30 秒ごとに分割
    private var cancelled = false

    /// progress: (completedChunks, totalChunks)
    typealias ProgressCallback = (_ completed: Int, _ total: Int) -> Void
    typealias CompletionCallback = (_ text: String?, _ error: String?) -> Void

    func cancel() { cancelled = true }

    /// ファイルを文字起こし。バックグラウンドで実行し、メインスレッドでコールバック。
    func transcribe(url: URL, progress: @escaping ProgressCallback,
                    completion: @escaping CompletionCallback) {
        cancelled = false
        klog("FileTranscriber: start \(url.lastPathComponent)")

        guard WhisperContext.shared.isLoaded else {
            DispatchQueue.main.async { completion(nil, "Whisperモデルが読み込まれていません") }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processFile(url: url, progress: progress, completion: completion)
        }
    }

    // MARK: - Private

    private func processFile(url: URL, progress: @escaping ProgressCallback,
                             completion: @escaping CompletionCallback) {
        // Step 1: AVAsset からオーディオを読み取り、16kHz mono WAV に変換
        let asset = AVAsset(url: url)
        // 同期的に duration を取得（既にバックグラウンドスレッドで実行中）
        nonisolated(unsafe) var duration: TimeInterval = 0
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let d = try await asset.load(.duration)
                duration = CMTimeGetSeconds(d)
            } catch {
                klog("FileTranscriber: failed to load duration: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard duration > 0 else {
            DispatchQueue.main.async { completion(nil, "ファイルの長さを取得できません") }
            return
        }

        klog("FileTranscriber: duration=\(String(format: "%.1f", duration))s")

        // チャンク数を計算
        let totalChunks = max(1, Int(ceil(duration / chunkDuration)))
        DispatchQueue.main.async { progress(0, totalChunks) }

        var allText = ""

        for i in 0..<totalChunks {
            guard !cancelled else {
                DispatchQueue.main.async { completion(nil, "キャンセルされました") }
                return
            }

            let startTime = Double(i) * chunkDuration
            let endTime = min(startTime + chunkDuration, duration)

            klog("FileTranscriber: chunk \(i+1)/\(totalChunks) [\(String(format: "%.1f", startTime))s - \(String(format: "%.1f", endTime))s]")

            // チャンクを 16kHz mono PCM として抽出
            guard let samples = extractAudioSamples(from: asset, start: startTime, end: endTime) else {
                klog("FileTranscriber: failed to extract chunk \(i+1)")
                let chunkIdx = i
                DispatchQueue.main.async { progress(chunkIdx + 1, totalChunks) }
                continue
            }

            // WhisperContext で文字起こし（同期待ち）
            let chunkSemaphore = DispatchSemaphore(value: 0)
            var chunkText: String?

            let lang = AppSettings.shared.language
            let whisperLang = lang == "auto" ? "auto" : (lang.components(separatedBy: "-").first ?? "ja")

            WhisperContext.shared.transcribeBuffer(samples: samples, language: whisperLang, prompt: "") { text in
                chunkText = text
                chunkSemaphore.signal()
            }
            chunkSemaphore.wait()

            if let text = chunkText, !text.isEmpty {
                if !allText.isEmpty { allText += "\n" }
                allText += text
            }

            let chunkIdx = i
            DispatchQueue.main.async { progress(chunkIdx + 1, totalChunks) }
        }

        let finalText = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        klog("FileTranscriber: done, \(finalText.count) chars")
        DispatchQueue.main.async { completion(finalText.isEmpty ? nil : finalText, nil) }
    }

    /// AVAsset から指定範囲の音声を 16kHz mono Float32 として抽出
    private func extractAudioSamples(from asset: AVAsset, start: TimeInterval, end: TimeInterval) -> [Float]? {
        // 同期的にトラックを取得（バックグラウンドスレッドで実行中）
        nonisolated(unsafe) var audioTrackResult: AVAssetTrack?
        let trackSem = DispatchSemaphore(value: 0)
        Task {
            audioTrackResult = try? await asset.loadTracks(withMediaType: .audio).first
            trackSem.signal()
        }
        trackSem.wait()
        guard let audioTrack = audioTrackResult else {
            klog("FileTranscriber: no audio track found")
            return nil
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            klog("FileTranscriber: failed to create AVAssetReader")
            return nil
        }

        let startCMTime = CMTime(seconds: start, preferredTimescale: 44100)
        let endCMTime = CMTime(seconds: end, preferredTimescale: 44100)
        reader.timeRange = CMTimeRange(start: startCMTime, end: endCMTime)

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            klog("FileTranscriber: cannot add reader output")
            return nil
        }
        reader.add(output)

        guard reader.startReading() else {
            klog("FileTranscriber: failed to start reading: \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        }

        var allData = Data()

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let dataPointer, length > 0 {
                allData.append(UnsafeBufferPointer(start: UnsafeRawPointer(dataPointer)
                    .assumingMemoryBound(to: UInt8.self), count: length))
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        guard reader.status == .completed || reader.status == .cancelled else {
            klog("FileTranscriber: reader finished with status \(reader.status.rawValue): \(reader.error?.localizedDescription ?? "")")
            return nil
        }

        // Int16 PCM → Float32
        let sampleCount = allData.count / 2
        guard sampleCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        allData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }

        return samples
    }
}
