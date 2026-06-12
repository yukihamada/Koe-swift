import AVFoundation
import Foundation

/// 常時録音: ホットキー録音と無関係に、マイク音声をバックグラウンドで録り続ける。
/// 「ボタンを押した時以外でも音声は録音されている状態に」(本人指示 2026-06-12)。
///
/// - 10分ごとにチャンクを確定して AudioArchive へ保存（履歴への文字入力はしない）
/// - 完全ローカル: ファイルはこの Mac から外に出ない
/// - アーカイブ無効時はチャンクを recordings/ に残す（いずれにせよ失わない）
/// - アプリ終了時は現在のチャンクを確定保存。クラッシュしても次回 start() の sweep で回収
final class AlwaysOnRecorder {
    static let shared = AlwaysOnRecorder()

    private var recorder: AVAudioRecorder?
    private var rotateTimer: Timer?
    private let chunkSeconds: TimeInterval = 600  // 10分
    private(set) var isRunning = false

    private let settings: [String: Any] = [
        AVFormatIDKey:             Int(kAudioFormatLinearPCM),
        AVSampleRateKey:           16000,
        AVNumberOfChannelsKey:     1,
        AVLinearPCMBitDepthKey:    16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey:     false,
    ]

    func start() {
        guard !isRunning else { return }
        sweepOldChunks()  // 前回終了/クラッシュ時の取り残しをアーカイブへ
        beginChunk()
        isRunning = recorder != nil
        klog("AlwaysOnRecorder: started=\(isRunning)")
    }

    func stop() {
        guard isRunning else { return }
        rotateTimer?.invalidate(); rotateTimer = nil
        finalizeCurrentChunk()
        isRunning = false
        klog("AlwaysOnRecorder: stopped")
    }

    private func beginChunk() {
        let url = AudioRecorder.audioDir
            .appendingPathComponent("always_\(Int(Date().timeIntervalSince1970)).wav")
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
            klog("AlwaysOnRecorder: failed to create recorder")
            return
        }
        if !r.record() {
            klog("AlwaysOnRecorder: record() failed")
            return
        }
        recorder = r
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: chunkSeconds, repeats: false) { [weak self] _ in
            self?.finalizeCurrentChunk()
            self?.beginChunk()
        }
    }

    private func finalizeCurrentChunk() {
        guard let r = recorder else { return }
        let url = r.url
        r.stop()
        recorder = nil
        archiveChunk(url)
    }

    /// チャンクをアーカイブへ移動。2秒未満 (≈64KB) の無内容チャンクは捨てる。
    /// アーカイブ無効/失敗時は recordings/ に残す（データを失わない）。
    private func archiveChunk(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size < 64_000 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let id = AudioArchive.shared.save(tempURL: url) {
            klog("AlwaysOnRecorder: archived chunk \(id) (\(size / 1024)KB)")
            try? FileManager.default.removeItem(at: url)
        } else {
            klog("AlwaysOnRecorder: archive disabled — chunk kept at \(url.lastPathComponent)")
        }
    }

    /// 前回セッションの always_*.wav をアーカイブへ回収
    private func sweepOldChunks() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AudioRecorder.audioDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("always_") && f.pathExtension == "wav" {
            archiveChunk(f)
        }
    }
}
