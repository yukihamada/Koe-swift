import AVFoundation
import AppKit
import CoreAudio

/// 🎙 ボイスレコーダー機能専用の録音エンジン。ディクテーション用 AudioRecorder(16kHz WAV)とは
/// 完全に別クラス・別ディレクトリ(VoiceMemoLibrary.voicememosDir)。
/// フォーマットは 48kHz/mono/AAC 96kbps(.m4a) — 「高音質」を謳える帯域かつ長時間録音でも軽量。
final class VoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    static let shared = VoiceMemoRecorder()

    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?
    private(set) var currentRecordID: UUID?
    private var startedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var lastResumeAt: Date?

    /// 録音中は他機能(ディクテーション)からの同時録音を避けるためのフラグ。
    private(set) var isRecording = false

    private var previousDefaultInputDevice: AudioObjectID?

    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        AVEncoderBitRateKey: 96000,
    ]

    /// 開始時にライブラリへ「録音中」の仮エントリを先行登録する(duration=0)。
    /// m4a は stop() で moov アトムが確定するため、録音中クラッシュに備え
    /// 先にインデックスへ存在を書いておく(黙ってデータを失わない方針。AudioRecorder/HistoryStore と同じ思想)。
    @discardableResult
    func start() -> UUID? {
        guard !isRecording else { return currentRecordID }
        if (NSApp.delegate as? AppDelegate)?.isDictationRecordingActive == true {
            klog("VoiceMemoRecorder: blocked, dictation recording is active")
            return nil
        }

        applySelectedInputDevice()

        let id = UUID()
        let fileName = "memo_\(Self.timestampString())_\(id.uuidString.prefix(8)).m4a"
        let url = VoiceMemoLibrary.voicememosDir.appendingPathComponent(fileName)

        guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
            klog("VoiceMemoRecorder: failed to create AVAudioRecorder")
            restoreDefaultInputDevice()
            return nil
        }
        r.delegate = self
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record() else {
            klog("VoiceMemoRecorder: record() failed")
            restoreDefaultInputDevice()
            return nil
        }

        recorder = r
        currentURL = url
        currentRecordID = id
        startedAt = Date()
        lastResumeAt = startedAt
        pausedAccumulated = 0
        isRecording = true

        let record = VoiceMemoRecord(fileName: fileName, createdAt: startedAt!, duration: 0, title: "")
        var stored = record
        stored.id = id
        VoiceMemoLibrary.shared.add(stored)
        tagLocation(id: id)

        klog("VoiceMemoRecorder: started -> \(fileName)")
        return id
    }

    /// 開始直後に一度だけ地名を取得してエントリへ書き戻す(非同期・録音自体はブロックしない)。
    private func tagLocation(id: UUID) {
        LocationTagger.shared.tagCurrentLocation { name in
            guard let name, !name.isEmpty else { return }
            DispatchQueue.main.async {
                // 録音が既に破棄/停止後にファイル差し替えされた可能性もあるが、
                // record(id:) が nil ならupdateは何もしないので安全。
                VoiceMemoLibrary.shared.update(id: id) { $0.location = name }
            }
        }
    }

    func pause() {
        guard isRecording, let r = recorder, r.isRecording else { return }
        r.pause()
        if let last = lastResumeAt { pausedAccumulated += Date().timeIntervalSince(last) }
        lastResumeAt = nil
    }

    func resume() {
        guard isRecording, let r = recorder, !r.isRecording else { return }
        r.record()
        lastResumeAt = Date()
    }

    var isPaused: Bool {
        guard isRecording, let r = recorder else { return false }
        return !r.isRecording
    }

    /// 現在の経過秒(pause区間を除く)
    func elapsed() -> TimeInterval {
        guard let started = startedAt else { return 0 }
        var total = Date().timeIntervalSince(started) - pausedAccumulated
        if let last = lastResumeAt {
            // record中なら lastResumeAt からの経過も pausedAccumulated 計算に既に含まれているため何もしない
            _ = last
        }
        return max(0, total)
    }

    func currentLevel() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        return max(0, min(1, (db + 55) / 55))
    }

    /// 録音を確定保存する。成功時に確定した VoiceMemoRecord の id を返す。
    @discardableResult
    func stop() -> UUID? {
        guard isRecording, let r = recorder, let id = currentRecordID, let url = currentURL else { return nil }
        let finalDuration = elapsed()
        r.stop()
        recorder = nil
        isRecording = false
        restoreDefaultInputDevice()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        VoiceMemoLibrary.shared.updateAndSaveNow(id: id) { rec in
            rec.duration = finalDuration
            rec.sizeBytes = size ?? 0
        }
        klog("VoiceMemoRecorder: stopped duration=\(finalDuration) size=\(size ?? 0)")
        extractAndStorePeaks(id: id, url: url)
        VoiceMemoTranscriptionQueue.shared.enqueue(id)

        currentURL = nil
        currentRecordID = nil
        startedAt = nil
        lastResumeAt = nil
        pausedAccumulated = 0
        return id
    }

    // MARK: - 静的波形(停止後・非同期)

    private func extractAndStorePeaks(id: UUID, url: URL, bucketCount: Int = 200) {
        DispatchQueue.global(qos: .utility).async {
            let peaks = Self.computePeaks(url: url, bucketCount: bucketCount)
            guard !peaks.isEmpty else { return }
            DispatchQueue.main.async {
                VoiceMemoLibrary.shared.updateAndSaveNow(id: id) { rec in
                    rec.waveformPeaks = peaks
                }
            }
        }
    }

    /// m4a を AVAudioFile で読み込み(自動でPCMへデコード)、bucketCount個のRMSピークに正規化する。
    static func computePeaks(url: URL, bucketCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return [] }
        do { try file.read(into: buffer) } catch {
            klog("VoiceMemoRecorder: peak extraction read failed: \(error.localizedDescription)")
            return []
        }
        guard let channelData = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, channelCount > 0 else { return [] }

        let samplesPerBucket = max(1, frameLength / bucketCount)
        var peaks: [Float] = []
        peaks.reserveCapacity(bucketCount)
        var offset = 0
        while offset < frameLength, peaks.count < bucketCount {
            let end = min(frameLength, offset + samplesPerBucket)
            var sumSq: Float = 0
            var count = 0
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in offset..<end {
                    let v = ptr[i]
                    sumSq += v * v
                    count += 1
                }
            }
            peaks.append(count > 0 ? sqrtf(sumSq / Float(count)) : 0)
            offset = end
        }
        let maxV = peaks.max() ?? 0
        if maxV > 0 { peaks = peaks.map { min(1, $0 / maxV) } }
        return peaks
    }

    /// 録音破棄(誤操作からのキャンセル用)。ファイルとライブラリエントリを両方削除する。
    func cancel() {
        guard isRecording, let id = currentRecordID else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        restoreDefaultInputDevice()
        VoiceMemoLibrary.shared.delete(id: id)
        currentURL = nil
        currentRecordID = nil
        startedAt = nil
        lastResumeAt = nil
        pausedAccumulated = 0
        klog("VoiceMemoRecorder: cancelled")
    }

    // MARK: - 入力デバイス(AudioRecorder.swift と同じ手法: システムデフォルト入力を一時昇格)

    private func applySelectedInputDevice() {
        let uid = AppSettings.shared.audioInputDeviceUID
        guard !uid.isEmpty else { return }
        guard let targetID = AudioDeviceEnumerator.deviceID(forUID: uid) else { return }
        let current = AudioDeviceEnumerator.defaultInputDeviceID()
        if current == targetID { return }
        previousDefaultInputDevice = current
        _ = AudioDeviceEnumerator.setDefaultInputDevice(targetID)
    }

    private func restoreDefaultInputDevice() {
        guard let prev = previousDefaultInputDevice else { return }
        previousDefaultInputDevice = nil
        _ = AudioDeviceEnumerator.setDefaultInputDevice(prev)
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        klog("VoiceMemoRecorder: encode error: \(error?.localizedDescription ?? "nil")")
    }
}
