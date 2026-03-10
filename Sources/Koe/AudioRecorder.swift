import AVFoundation

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    var tempURL: URL?

    private let settings: [String: Any] = [
        AVFormatIDKey:             Int(kAudioFormatLinearPCM),
        AVSampleRateKey:           16000,
        AVNumberOfChannelsKey:     1,
        AVLinearPCMBitDepthKey:    16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey:     false,
    ]

    /// アプリ専用ディレクトリ (0700) に音声ファイルを保存
    private static let audioDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("com.yuki.koe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir
    }()

    // 事前にバッファを確保してレイテンシをゼロにする
    func prepare() {
        let url = Self.audioDir.appendingPathComponent("rec.wav")
        try? FileManager.default.removeItem(at: url)
        tempURL = url
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.delegate = self
        r.isMeteringEnabled = true
        r.prepareToRecord()   // オーディオバッファを事前確保
        recorder = r
        klog("AudioRecorder prepared")
    }

    func start() {
        if recorder == nil { prepare() }
        let ok = recorder?.record() ?? false
        klog("Recording started, ok=\(ok)")
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        guard let src = tempURL else { return nil }
        // 認識が終わるまで上書きされないよう別名にコピー
        let dest = Self.audioDir.appendingPathComponent("recognize.wav")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        klog("Recording stopped, size=\(size) bytes")
        prepare()   // 次回のために即再準備
        return dest
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        klog("Recording cancelled")
        prepare()
    }

    func currentLevel() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        return max(0, min(1, (db + 55) / 55))
    }

    /// 録音中の部分WAVファイルを読み取り、Float32 PCMサンプルとして返す。
    /// ストリーミングプレビュー用。録音中でなければnilを返す。
    func currentSamples() -> [Float]? {
        guard let r = recorder, r.isRecording, let url = tempURL else { return nil }
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }

        let headerSize = 44
        let audioData = data.subdata(in: headerSize..<data.count)
        let sampleCount = audioData.count / 2  // 16-bit samples

        guard sampleCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        audioData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }
        return samples
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        klog("Encode error: \(error?.localizedDescription ?? "nil")")
    }
}
