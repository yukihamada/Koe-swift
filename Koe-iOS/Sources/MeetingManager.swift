import Foundation
import AVFoundation
import Accelerate

@MainActor
final class MeetingManager: ObservableObject {
    static let shared = MeetingManager()

    @Published var isRecording = false
    @Published var entries: [MeetingEntry] = []
    @Published var summary: String = ""
    @Published var isSummarizing = false
    @Published var elapsedTime: TimeInterval = 0

    private var audioEngine = AVAudioEngine()
    private let samplesLock = NSLock()
    private var pcmSamples: [Float] = []
    private var segmentTimer: Timer?
    private var elapsedTimer: Timer?
    private var startTime: Date?

    struct MeetingEntry: Identifiable {
        let id = UUID()
        let timestamp: TimeInterval
        let text: String
    }

    func startMeeting() {
        guard !isRecording else { return }
        entries.removeAll()
        summary = ""
        startTime = Date()
        elapsedTime = 0

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        samplesLock.lock()
        pcmSamples.removeAll(keepingCapacity: true)
        pcmSamples.reserveCapacity(16000 * 30)
        samplesLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = 16000.0 / hwFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }
            converter.convert(to: outBuf, error: nil) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let data = outBuf.floatChannelData?[0] {
                let count = Int(outBuf.frameLength)
                self.samplesLock.lock()
                self.pcmSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
                self.samplesLock.unlock()
            }
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true

        // Transcribe every 15 seconds
        segmentTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.transcribeSegment()
            }
        }

        // Elapsed time counter
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let start = self?.startTime {
                    self?.elapsedTime = Date().timeIntervalSince(start)
                }
            }
        }
    }

    func stopMeeting() {
        guard isRecording else { return }
        segmentTimer?.invalidate()
        elapsedTimer?.invalidate()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        // Transcribe remaining samples
        transcribeSegment()

        // Generate summary
        if !entries.isEmpty {
            generateSummary()
        }
    }

    private func transcribeSegment() {
        samplesLock.lock()
        let samples = pcmSamples
        pcmSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        guard samples.count > 4000 else { return }
        let timestamp = elapsedTime

        let lang = UserDefaults.standard.string(forKey: "koe_language") ?? "ja-JP"
        let whisperLang = lang == "auto" ? "auto" : (lang.components(separatedBy: "-").first ?? "ja")

        WhisperContext.shared.transcribeBuffer(samples: samples, language: whisperLang) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.entries.append(MeetingEntry(timestamp: timestamp, text: text))
        }
    }

    private func generateSummary() {
        isSummarizing = true
        let fullText = entries.map { entry in
            let mins = Int(entry.timestamp) / 60
            let secs = Int(entry.timestamp) % 60
            return "[\(String(format: "%02d:%02d", mins, secs))] \(entry.text)"
        }.joined(separator: "\n")

        let instruction = """
        以下は会議の文字起こしです。以下の形式で要約してください：
        ## 要約
        （3-5文で会議の概要）
        ## 主な議題
        - （箇条書き）
        ## アクションアイテム
        - [ ] （TODOリスト形式）
        """

        let body: [String: Any] = [
            "model": "auto",
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": fullText]
            ],
            "max_tokens": 1000
        ]

        guard let url = URL(string: "https://api.chatweb.ai/v1/chat/completions"),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            isSummarizing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSummarizing = false
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else { return }
                self.summary = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.resume()
    }

    var fullTranscript: String {
        entries.map { entry in
            let mins = Int(entry.timestamp) / 60
            let secs = Int(entry.timestamp) % 60
            return "[\(String(format: "%02d:%02d", mins, secs))] \(entry.text)"
        }.joined(separator: "\n")
    }
}
