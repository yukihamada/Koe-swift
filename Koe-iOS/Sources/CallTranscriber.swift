import Foundation
import AVFoundation
import CallKit
import Accelerate
import Combine

/// 電話通話を検出してマイクで録音→Whisperで文字起こし
@MainActor
final class CallTranscriber: ObservableObject {
    static let shared = CallTranscriber()

    @Published var isMonitoring = false
    @Published var isCallActive = false
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var callDuration: TimeInterval = 0
    @Published var transcribedText = ""
    @Published var callHistory: [CallTranscript] = []

    private let callObserver = CXCallObserver()
    private var callDelegate: CallObserverDelegate?
    private var audioEngine: AVAudioEngine?
    private var pcmSamples: [Float] = []
    private let samplesLock = NSLock()
    private var callStartTime: Date?
    private var callTimer: Timer?
    private var audioLevel: Float = 0

    // 設定
    var autoRecord: Bool {
        get { UserDefaults.standard.bool(forKey: "koe_call_auto_record") }
        set { UserDefaults.standard.set(newValue, forKey: "koe_call_auto_record") }
    }

    private init() {
        loadHistory()
    }

    // MARK: - 通話監視

    func startMonitoring() {
        guard !isMonitoring else { return }
        let delegate = CallObserverDelegate { [weak self] call in
            Task { @MainActor in
                self?.handleCallStateChange(call)
            }
        }
        callObserver.setDelegate(delegate, queue: .main)
        callDelegate = delegate
        isMonitoring = true
        print("[CallTranscriber] monitoring started")
    }

    func stopMonitoring() {
        isMonitoring = false
        callDelegate = nil
        print("[CallTranscriber] monitoring stopped")
    }

    private func handleCallStateChange(_ call: CXCall) {
        if call.hasConnected && !call.hasEnded && !isCallActive {
            // 通話開始
            isCallActive = true
            callStartTime = Date()
            print("[CallTranscriber] call connected")

            if autoRecord {
                // 少し待ってからマイク録音開始（通話が安定してから）
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5秒
                    if self.isCallActive {
                        self.startCallRecording()
                    }
                }
            }

            // タイマーで通話時間更新
            callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let start = self.callStartTime else { return }
                Task { @MainActor in
                    self.callDuration = Date().timeIntervalSince(start)
                }
            }

        } else if call.hasEnded && isCallActive {
            // 通話終了
            isCallActive = false
            callTimer?.invalidate()
            callTimer = nil
            print("[CallTranscriber] call ended (duration: \(Int(callDuration))s)")

            if isRecording {
                stopCallRecording()
            }
        }
    }

    // MARK: - マイク録音

    func startCallRecording() {
        guard !isRecording else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // VoiceChat モードでエコーキャンセレーション有効化
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("[CallTranscriber] audio session error: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // 16kHz変換用
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else { return }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else { return }

        samplesLock.lock()
        pcmSamples = []
        samplesLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // RMSレベル計算
            if let channelData = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_measqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
                rms = sqrtf(rms)
                Task { @MainActor in self.audioLevel = min(1, rms * 10) }
            }

            // 16kHzにリサンプリング
            let ratio = 16000.0 / format.sampleRate
            let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let ptr = outputBuffer.floatChannelData?[0] {
                let count = Int(outputBuffer.frameLength)
                self.samplesLock.lock()
                self.pcmSamples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                self.samplesLock.unlock()
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
            print("[CallTranscriber] recording started")
        } catch {
            print("[CallTranscriber] engine start error: \(error)")
        }
    }

    func stopCallRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        print("[CallTranscriber] recording stopped, samples: \(pcmSamples.count)")

        // Whisper で文字起こし
        samplesLock.lock()
        let samples = pcmSamples
        pcmSamples = []
        samplesLock.unlock()

        guard !samples.isEmpty else { return }
        transcribe(samples: samples)
    }

    // MARK: - 文字起こし

    private func transcribe(samples: [Float]) {
        isTranscribing = true
        transcribedText = "文字起こし中..."

        let lang = UserDefaults.standard.string(forKey: "koe_language") ?? "ja"

        if WhisperContext.shared.isLoaded {
            // ローカルWhisper
            WhisperContext.shared.transcribeBuffer(samples: samples, language: lang) { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.isTranscribing = false
                    let result = text ?? ""
                    self.transcribedText = result
                    if !result.isEmpty {
                        self.saveTranscript(text: result, duration: self.callDuration)
                    }
                    print("[CallTranscriber] transcribed: \(result.prefix(50))")
                }
            }
        } else {
            // Macに送信して文字起こし
            MacBridge.shared.sendAudioForTranscription(samples, translate: false)
            isTranscribing = false
            transcribedText = "Macで文字起こし中..."
        }
    }

    // MARK: - 通話履歴

    private func saveTranscript(text: String, duration: TimeInterval) {
        let entry = CallTranscript(
            date: Date(),
            duration: duration,
            text: text
        )
        callHistory.insert(entry, at: 0)
        if callHistory.count > 100 { callHistory.removeLast() }
        persistHistory()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(callHistory) {
            UserDefaults.standard.set(data, forKey: "koe_call_history")
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "koe_call_history"),
           let decoded = try? JSONDecoder().decode([CallTranscript].self, from: data) {
            callHistory = decoded
        }
    }
}

// MARK: - Data Model

struct CallTranscript: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let duration: TimeInterval
    let text: String

    var durationFormatted: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - CXCallObserverDelegate

private class CallObserverDelegate: NSObject, CXCallObserverDelegate {
    let onChange: (CXCall) -> Void

    init(onChange: @escaping (CXCall) -> Void) {
        self.onChange = onChange
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onChange(call)
    }
}
