import Foundation
import AVFoundation
import ScreenCaptureKit

/// ScreenCaptureKitを使用してZoom/Teams等のアプリ音声をキャプチャ
/// macOS 13.0+ 必須
@available(macOS 13.0, *)
class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    static let shared = SystemAudioCapture()

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var isCapturing = false
    private var outputURL: URL?

    /// マイク録音と同時に使うための一時ファイルパス
    private let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("com.yuki.koe/sysaudio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 会議アプリ一覧（バンドルID）
    private let meetingAppBundleIDs: Set<String> = [
        "us.zoom.xos",              // Zoom
        "com.microsoft.teams",      // Microsoft Teams (classic)
        "com.microsoft.teams2",     // Microsoft Teams (new)
        "com.google.Chrome",        // Google Meet (Chrome)
        "com.apple.Safari",         // Google Meet (Safari)
        "com.brave.Browser",        // Google Meet (Brave)
        "org.mozilla.firefox",      // Google Meet (Firefox)
        "com.tinyspeck.slackmacgap",// Slack Huddle
        "com.cisco.webexmeetingsapp",// Webex
        "com.discord.Discord",      // Discord
        "com.logmein.goto.GoTo",    // GoTo Meeting
    ]

    /// キャプチャ可能な会議アプリが実行中か
    func findRunningMeetingApp() -> SCRunningApplication? {
        // SCShareableContent は async なので同期ラッパー
        let sem = DispatchSemaphore(value: 0)
        var found: SCRunningApplication?

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            guard let content else { sem.signal(); return }
            found = content.applications.first { app in
                self.meetingAppBundleIDs.contains(app.bundleIdentifier)
            }
            sem.signal()
        }
        sem.wait()
        return found
    }

    /// 指定アプリの音声キャプチャを開始
    func startCapture(app: SCRunningApplication? = nil, completion: @escaping (Bool) -> Void) {
        guard !isCapturing else { completion(true); return }

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self, let content else {
                klog("SystemAudioCapture: failed to get shareable content: \(error?.localizedDescription ?? "?")")
                completion(false)
                return
            }

            // キャプチャ対象を決定
            let targetApp = app ?? content.applications.first { self.meetingAppBundleIDs.contains($0.bundleIdentifier) }

            let filter: SCContentFilter
            if let target = targetApp {
                klog("SystemAudioCapture: targeting app \(target.applicationName) (\(target.bundleIdentifier))")
                filter = SCContentFilter(desktopIndependentWindow: content.windows.first { $0.owningApplication?.bundleIdentifier == target.bundleIdentifier } ?? content.windows[0])
            } else {
                // アプリが見つからない場合、全画面音声をキャプチャ
                klog("SystemAudioCapture: no meeting app found, capturing all audio")
                guard let display = content.displays.first else {
                    completion(false); return
                }
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true  // 自分のアプリ音声は除外
            config.sampleRate = 16000                   // Whisper最適化
            config.channelCount = 1                     // モノラル

            // 映像は不要（音声のみ）
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 最低フレームレート

            // 出力ファイル準備
            let url = self.tempDir.appendingPathComponent("system_\(UUID().uuidString.prefix(8)).wav")
            self.outputURL = url

            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                self.audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            } catch {
                klog("SystemAudioCapture: failed to create audio file: \(error)")
                completion(false)
                return
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
                stream.startCapture { error in
                    if let error {
                        klog("SystemAudioCapture: start failed: \(error)")
                        completion(false)
                    } else {
                        self.isCapturing = true
                        klog("SystemAudioCapture: started")
                        completion(true)
                    }
                }
                self.stream = stream
            } catch {
                klog("SystemAudioCapture: setup failed: \(error)")
                completion(false)
            }
        }
    }

    /// キャプチャ停止、録音ファイルのURLを返す
    func stopCapture() -> URL? {
        guard isCapturing else { return nil }
        stream?.stopCapture { _ in }
        stream = nil
        audioFile = nil
        isCapturing = false
        klog("SystemAudioCapture: stopped")
        return outputURL
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let audioFile else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // CMSampleBufferをAVAudioPCMBufferに変換
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer, length > 0 else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let sampleCount = length / MemoryLayout<Float>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        memcpy(buffer.floatChannelData![0], ptr, length)

        do {
            try audioFile.write(from: buffer)
        } catch {
            // 書き込みエラーは無視（バッファ競合の可能性）
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        klog("SystemAudioCapture: stream stopped with error: \(error)")
        isCapturing = false
    }
}
