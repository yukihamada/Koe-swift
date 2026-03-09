import AVFoundation

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var tempURL: URL?

    private let settings: [String: Any] = [
        AVFormatIDKey:             Int(kAudioFormatLinearPCM),
        AVSampleRateKey:           16000,
        AVNumberOfChannelsKey:     1,
        AVLinearPCMBitDepthKey:    16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey:     false,
    ]

    // 事前にバッファを確保してレイテンシをゼロにする
    func prepare() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe_rec.wav")
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
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe_recognize.wav")
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

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        klog("Encode error: \(error?.localizedDescription ?? "nil")")
    }
}
