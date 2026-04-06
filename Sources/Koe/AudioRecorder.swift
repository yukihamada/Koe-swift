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
        guard let r = recorder else {
            klog("AudioRecorder: recorder is nil after prepare, retrying")
            prepare()
            guard let r2 = recorder else {
                klog("AudioRecorder: failed to create recorder")
                return
            }
            let ok = r2.record()
            klog("Recording started (retry), ok=\(ok)")
            return
        }
        // recorderが前回のセッションから残っている場合、明示的にリセット
        if r.isRecording {
            klog("AudioRecorder: already recording, stopping first")
            r.stop()
        }
        let ok = r.record()
        if !ok {
            klog("AudioRecorder: record() failed, re-preparing")
            recorder = nil
            prepare()
            let retryOk = recorder?.record() ?? false
            klog("Recording started (re-prepare), ok=\(retryOk)")
        } else {
            klog("Recording started, ok=true")
        }
    }

    func stop() -> URL? {
        guard let r = recorder else {
            klog("AudioRecorder: stop called but recorder is nil")
            return nil
        }
        if r.isRecording {
            r.stop()
        }
        recorder = nil
        guard let src = tempURL else { return nil }
        // 一意なファイル名で保存（議事録モードで次の録音に上書きされないように）
        let id = UUID().uuidString.prefix(8)
        let dest = Self.audioDir.appendingPathComponent("recognize_\(id).wav")
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            klog("AudioRecorder: copy failed: \(error.localizedDescription)")
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        klog("Recording stopped, size=\(size) bytes -> \(dest.lastPathComponent)")
        // 古い一時ファイルを掃除（議事録モード中は保持、通常時は最新5件以外を削除）
        if !MeetingMode.shared.isActive {
            cleanOldFiles()
        }
        prepare()   // 次回のために即再準備
        return dest
    }

    /// 古い recognize_*.wav を掃除（最新5件を残す）
    private func cleanOldFiles() {
        let dir = Self.audioDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let recFiles = files.filter { $0.lastPathComponent.hasPrefix("recognize_") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
        for file in recFiles.dropFirst(5) {
            try? FileManager.default.removeItem(at: file)
        }
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

        // WAVヘッダーを正しくパース ("data"チャンクを探す)
        let dataOffset = Self.findDataChunk(in: data)
        guard dataOffset > 0, dataOffset < data.count else { return nil }

        let audioData = data.subdata(in: dataOffset..<data.count)
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

    /// WAVファイル内の "data" チャンクのデータ開始オフセットを返す
    static func findDataChunk(in data: Data) -> Int {
        guard data.count > 12 else { return 44 }
        var offset = 12
        while offset + 8 < data.count {
            let chunkID = data.subdata(in: offset..<offset+4)
            let sizeBytes = data.subdata(in: offset+4..<offset+8)
            let chunkSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            if chunkID == Data("data".utf8) { return offset + 8 }
            offset += 8 + Int(chunkSize)
            if Int(chunkSize) % 2 != 0 { offset += 1 }
        }
        return 44
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        klog("Encode error: \(error?.localizedDescription ?? "nil")")
    }
}
