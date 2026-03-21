import Speech
import AVFoundation
import Combine

/// iOS用ウェイクワード検出器: Apple Speech Recognitionでストリーミング認識し、
/// 「ヘイこえ」などのウェイクワードを検出したら自動録音開始をトリガーする。
@MainActor
class WakeWordDetector: ObservableObject {
    static let shared = WakeWordDetector()

    @Published var isListening = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// ウェイクワード検出時に呼ばれるコールバック
    var onWakeWordDetected: (() -> Void)?

    // 検出するウェイクワード一覧（小文字・ひらがな正規化後にマッチ）
    private let wakeWords = [
        "ヘイこえ", "ヘイコエ", "hey koe", "ヘイ声", "おいこえ",
        "へいこえ", "へいコエ", "へい声", "heykoe",
    ]

    /// 連続リスタート回数の上限（Apple Speechの60秒制限対策）
    private var restartCount = 0
    private let maxRestarts = 100

    // MARK: - Start

    func start() {
        guard !isListening else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginListening()
                default:
                    print("[WakeWord] Speech recognition not authorized: \(status.rawValue)")
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        guard isListening else { return }
        isListening = false
        restartCount = 0
        teardown()
    }

    // MARK: - Internal

    private func beginListening() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("[WakeWord] Speech recognizer unavailable")
            return
        }

        teardown()

        // Audio session: playAndRecord allows wake word + other audio; measurement for low latency
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[WakeWord] Audio session error: \(error)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device recognition for low power / no network requirement
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[WakeWord] Audio engine start error: \(error)")
            teardown()
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if self.containsWakeWord(text) {
                    print("[WakeWord] Detected wake word in: \(text)")
                    self.handleDetection()
                    return
                }

                // Apple Speech 60秒制限: isFinalが来たらリスタート
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.restartIfNeeded()
                    }
                }
            }

            if let error = error as? NSError {
                // 216 = cancelled (normal), 1110 = no speech detected
                if error.code != 216 {
                    DispatchQueue.main.async {
                        self.restartIfNeeded()
                    }
                }
            }
        }

        isListening = true
        restartCount = 0
        print("[WakeWord] Listening started (on-device: \(speechRecognizer.supportsOnDeviceRecognition))")
    }

    private func handleDetection() {
        DispatchQueue.main.async {
            self.stop()
            self.onWakeWordDetected?()

            // 録音終了後にリスタートするため、1秒待ってからリスタートはしない。
            // ContentViewでrecorder.isRecordingの変化を監視してリスタートする。
        }
    }

    private func restartIfNeeded() {
        guard isListening else { return }
        restartCount += 1
        if restartCount < maxRestarts {
            // 短いディレイ後にリスタート
            teardown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isListening else { return }
                // isListeningはまだtrueのまま（stopされてなければ）
                self.isListening = false // beginListeningが再セットする
                self.beginListening()
            }
        } else {
            print("[WakeWord] Max restarts reached, stopping")
            stop()
        }
    }

    private func teardown() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Wake word matching

    private func containsWakeWord(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
        for word in wakeWords {
            let normalizedWord = word.lowercased()
                .replacingOccurrences(of: " ", with: "")
            if normalized.contains(normalizedWord) {
                return true
            }
        }
        return false
    }
}
