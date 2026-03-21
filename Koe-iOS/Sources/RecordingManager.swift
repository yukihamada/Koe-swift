import Foundation
import UIKit
import AVFoundation
import Speech
import Accelerate
import Combine
import ActivityKit
import Intents

@MainActor
final class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var recognizedText = ""
    @Published var statusText = "タップして録音"
    @Published var audioLevel: Float = 0
    @Published var history: [HistoryItem] = []
    @Published var autoCopy: Bool = UserDefaults.standard.bool(forKey: "koe_auto_copy")
    @Published var autoSendMac: Bool = UserDefaults.standard.bool(forKey: "koe_auto_send_mac") {
        didSet { UserDefaults.standard.set(autoSendMac, forKey: "koe_auto_send_mac") }
    }
    @Published var continuousMode: Bool = UserDefaults.standard.bool(forKey: "koe_continuous_mode") {
        didSet { UserDefaults.standard.set(continuousMode, forKey: "koe_continuous_mode") }
    }
    @Published var quickPhrases: [String] = UserDefaults.standard.stringArray(forKey: "koe_quick_phrases") ?? ["お世話になっております。", "承知いたしました。", "よろしくお願いいたします。"]
    @Published var streamingText: String = ""

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer: SFSpeechRecognizer?

    // Streaming preview (Apple Speech running in parallel with Whisper)
    private var streamingRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var streamingRecognitionTask: SFSpeechRecognitionTask?
    private var streamingPreviewEnabled: Bool {
        UserDefaults.standard.bool(forKey: "koe_streaming_preview")
    }

    // whisper.cpp: オーディオスレッドで直接書き込む (ロックで保護)
    private let samplesLock = NSLock()
    private var pcmSamples: [Float] = []
    private var useWhisper: Bool { WhisperContext.shared.isLoaded }

    // 無音検出
    private var silenceStart: Date?
    private let silenceThreshold: Float = 0.01
    private var silenceDuration: TimeInterval {
        // 0 = 無音自動停止OFF（手動停止のみ）
        UserDefaults.standard.object(forKey: "koe_silence_duration") as? Double ?? 0
    }
    private var silenceTimer: Timer?

    // Apple Speech 継続認識（60秒制限対策）
    private var accumulatedText = ""
    private var recognitionRestartCount = 0
    private let maxRecognitionRestarts = 10 // 最大10回リスタート（約10分）

    private var currentActivity: NSUserActivity?

    // 最後の録音サンプル（VoiceMemoStore保存用）
    private var lastRecordedSamples: [Float] = []

    // Live Activity (Dynamic Island)
    private var recordingActivity: Activity<KoeRecordingAttributes>?

    init() {
        // koe_auto_send_mac のデフォルトを true に設定
        UserDefaults.standard.register(defaults: ["koe_auto_send_mac": true])
        autoSendMac = UserDefaults.standard.bool(forKey: "koe_auto_send_mac")

        let locale = Locale(identifier: UserDefaults.standard.string(forKey: "koe_language") ?? "ja-JP")
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        loadHistory()
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                if case .denied = status { self.statusText = "音声認識の権限がありません" }
                if case .restricted = status { self.statusText = "音声認識の権限がありません" }
            }
        }
        AVAudioApplication.requestRecordPermission { granted in
            if !granted {
                DispatchQueue.main.async { self.statusText = "マイクの権限がありません" }
            }
        }
    }

    func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusText = "オーディオエラー"
            return
        }

        if useWhisper { startWhisperRecording() }
        else { startAppleSpeechRecording() }
    }

    // MARK: - whisper.cpp

    private func startWhisperRecording() {
        samplesLock.lock()
        pcmSamples.removeAll(keepingCapacity: true)
        pcmSamples.reserveCapacity(16000 * 30) // 30秒分を事前確保
        samplesLock.unlock()

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            startAppleSpeechRecording()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Feed audio to streaming preview recognizer
            self.streamingRecognitionRequest?.append(buffer)

            // Audio level (軽量: vDSP は十分高速)
            var rms: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
                DispatchQueue.main.async { self.audioLevel = min(rms * 5, 1.0) }
            }

            // 無音検出: rmsが閾値以下なら無音開始を記録
            DispatchQueue.main.async {
                if rms < self.silenceThreshold {
                    if self.silenceStart == nil { self.silenceStart = Date() }
                } else {
                    self.silenceStart = nil
                }
            }

            // Resample 直接オーディオスレッドで実行
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
        do { try audioEngine.start() } catch {
            statusText = "録音開始エラー"
            return
        }

        // Start streaming preview after audio engine is running
        startStreamingPreview()

        isRecording = true
        statusText = "録音中…"
        recognizedText = ""
        silenceStart = nil
        startLiveActivity()

        // 無音検出タイマー (silenceDuration > 0 の場合のみ自動停止)
        if silenceDuration > 0 {
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.samplesLock.lock()
                    let sampleCount = self.pcmSamples.count
                    self.samplesLock.unlock()
                    guard sampleCount > 16000 else { return }

                    if let start = self.silenceStart, Date().timeIntervalSince(start) >= self.silenceDuration {
                        self.stopRecording()
                    }
                    // Live Activity 更新
                    self.updateLiveActivity()
                }
            }
        }
    }

    // MARK: - Apple Speech

    private func startAppleSpeechRecording() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusText = "音声認識が利用できません"
            return
        }

        accumulatedText = ""
        recognitionRestartCount = 0
        startAppleSpeechSession()

        isRecording = true
        statusText = "録音中…"
        recognizedText = ""
        silenceStart = nil
        startLiveActivity()

        // Apple Speechでも無音検出タイマー起動 (silenceDuration > 0 の場合のみ)
        if silenceDuration > 0 {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, !self.useWhisper else { return }
                if let start = self.silenceStart, Date().timeIntervalSince(start) >= self.silenceDuration {
                    if !self.recognizedText.isEmpty {
                        self.stopRecording()
                    }
                }
                // Live Activity 更新
                self.updateLiveActivity()
            }
        }
        } // if silenceDuration > 0
    }

    /// Apple Speech認識セッションを開始（60秒制限対策: isFinalで自動リスタート）
    private func startAppleSpeechSession() {
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        if #available(iOS 16, *) {
            recognitionRequest.addsPunctuation = true
        }
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        // 初回のみtapをインストール（リスタート時はtapは維持）
        if !audioEngine.isRunning {
            let inputNode = audioEngine.inputNode
            let fmt = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
                guard let self else { return }
                self.recognitionRequest?.append(buffer)
                if let ch = buffer.floatChannelData?[0] {
                    var rms: Float = 0
                    vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
                    DispatchQueue.main.async {
                        self.audioLevel = min(rms * 5, 1.0)
                        if rms < self.silenceThreshold {
                            if self.silenceStart == nil { self.silenceStart = Date() }
                        } else {
                            self.silenceStart = nil
                        }
                    }
                }
            }

            audioEngine.prepare()
            do { try audioEngine.start() } catch {
                statusText = "録音開始エラー"
                return
            }
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let segmentText = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    let fullText = self.accumulatedText.isEmpty
                        ? segmentText
                        : self.accumulatedText + " " + segmentText
                    if segmentText.count < 4 && !result.isFinal {
                        self.statusText = "認識中…"
                    } else {
                        self.recognizedText = fullText
                        self.statusText = "録音中…"
                    }
                    // ストリーミング: 部分認識結果をMacにリアルタイム送信
                    if !result.isFinal && !fullText.isEmpty {
                        MacBridge.shared.sendStreamingText(fullText)
                    }
                }
                if result.isFinal {
                    DispatchQueue.main.async {
                        // 60秒制限到達 → まだ録音中なら蓄積してリスタート
                        let finalText = result.bestTranscription.formattedString
                        if !finalText.isEmpty {
                            self.accumulatedText = self.accumulatedText.isEmpty
                                ? finalText
                                : self.accumulatedText + " " + finalText
                        }
                        if self.isRecording && self.recognitionRestartCount < self.maxRecognitionRestarts {
                            self.recognitionRestartCount += 1
                            self.startAppleSpeechSession()
                        } else {
                            self.finishAppleSpeech()
                        }
                    }
                }
            }
            if let error = error as? NSError, error.code != 216 { // 216 = cancelled (normal)
                DispatchQueue.main.async {
                    // エラーでもリスタート試行（ネットワーク一時障害など）
                    if self.isRecording && self.recognitionRestartCount < self.maxRecognitionRestarts {
                        self.recognitionRestartCount += 1
                        self.startAppleSpeechSession()
                    } else {
                        self.finishAppleSpeech()
                    }
                }
            }
        }
    }

    // MARK: - Streaming Preview (Apple Speech in parallel with Whisper)

    private func startStreamingPreview() {
        guard streamingPreviewEnabled, useWhisper,
              let speechRecognizer, speechRecognizer.isAvailable else { return }

        streamingRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = streamingRecognitionRequest else { return }
        request.shouldReportPartialResults = true
        if #available(iOS 16, *) {
            request.addsPunctuation = true
        }
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        streamingText = ""
        streamingRecognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    self.streamingText = result.bestTranscription.formattedString
                }
            }
            // Errors are expected when we end audio — just ignore
        }
    }

    private func stopStreamingPreview() {
        streamingRecognitionRequest?.endAudio()
        streamingRecognitionTask?.cancel()
        streamingRecognitionRequest = nil
        streamingRecognitionTask = nil
        streamingText = ""
    }

    // MARK: - Stop

    func stopRecording() {
        guard isRecording else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        silenceStart = nil
        stopStreamingPreview()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isRecording = false
        audioLevel = 0

        // 安全策: 30秒後にステータスが「認識中」のままならリセット
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if self.statusText.contains("認識中") || self.statusText.contains("処理中") {
                self.statusText = "タップして録音"
            }
        }
        endLiveActivity()

        if useWhisper {
            statusText = "認識中…"
            samplesLock.lock()
            let samples = pcmSamples
            pcmSamples.removeAll(keepingCapacity: true)
            samplesLock.unlock()

            guard samples.count > 4000 else { // 0.25秒未満は無視
                statusText = "音声が短すぎます"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.statusText = "タップして録音" }
                handleContinuousMode()
                return
            }

            // VoiceMemo保存用にサンプルを保持
            lastRecordedSamples = samples

            let lang = UserDefaults.standard.string(forKey: "koe_language") ?? "ja-JP"
            let whisperLang = lang == "auto" ? "auto" : (lang.components(separatedBy: "-").first ?? "en")

            WhisperContext.shared.transcribeBuffer(samples: samples, language: whisperLang) { [weak self] text in
                guard let self else { return }
                if let text, !text.isEmpty {
                    self.handleRecognitionResultWithLLM(text)
                } else {
                    self.statusText = "認識できませんでした"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.statusText = "タップして録音" }
                    self.handleContinuousMode()
                }
            }
        } else {
            recognitionRequest?.endAudio()
            statusText = "認識中…"
        }
    }

    private func finishAppleSpeech() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        audioLevel = 0

        // accumulatedText に最終テキストをマージ
        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        accumulatedText = ""
        recognitionRestartCount = 0

        if !text.isEmpty {
            handleRecognitionResultWithLLM(text)
        } else {
            statusText = "認識できませんでした"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.statusText = "タップして録音" }
            handleContinuousMode()
        }
    }

    // MARK: - Voice Commands

    /// 音声コマンドを検出して処理する。コマンドだった場合は true を返す
    private func processVoiceCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "改行", "かいぎょう":
            MacBridge.shared.sendText("\n")
            statusText = "改行を送信しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.statusText = "タップして録音" }
            handleContinuousMode()
            return true
        case "送信", "そうしん":
            MacBridge.shared.sendEnter()
            statusText = "送信しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.statusText = "タップして録音" }
            handleContinuousMode()
            return true
        case "消して", "けして":
            recognizedText = ""
            statusText = "クリアしました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.statusText = "タップして録音" }
            handleContinuousMode()
            return true
        case "取り消し", "取り消して", "もどして", "アンドゥ":
            MacBridge.shared.sendCommand("undo")
            statusText = "取り消しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.statusText = "タップして録音" }
            handleContinuousMode()
            return true
        case "全選択", "ぜんせんたく":
            MacBridge.shared.sendCommand("selectAll")
            statusText = "全選択しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.statusText = "タップして録音" }
            handleContinuousMode()
            return true
        case "タブ":
            MacBridge.shared.sendCommand("tab")
            statusText = "タブを送信しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.statusText = "タップして録音" }
            handleContinuousMode()
            return true
        case "ストップ", "おわり", "終了":
            continuousMode = false
            statusText = "連続モードを停止しました"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.statusText = "タップして録音" }
            return true
        default:
            return false
        }
    }

    // MARK: - Post-Recognition

    /// 認識完了後の共通処理: コマンド判定 → 保存 → ハンドオフ → 連続モード
    private func handleRecognitionResult(_ text: String) {
        // 音声コマンドチェック
        if processVoiceCommand(text) { return }

        recognizedText = text
        addToHistory(text)

        // VoiceMemo保存 (Whisper使用時のみ音声あり)
        if !lastRecordedSamples.isEmpty {
            VoiceMemoStore.shared.save(text: text, samples: lastRecordedSamples)
            lastRecordedSamples = []
        }

        // Mac自動送信
        if autoSendMac {
            publishHandoff(text: text)
        }

        // Siri Shortcut donation
        let shortcutActivity = NSUserActivity(activityType: "com.yuki.koe.transcribe")
        shortcutActivity.title = "Koeで音声入力"
        shortcutActivity.isEligibleForPrediction = true
        shortcutActivity.suggestedInvocationPhrase = "声で入力"
        shortcutActivity.becomeCurrent()

        statusText = "タップして録音"
        handleContinuousMode()
    }

    /// LLM後処理付きの認識結果ハンドラー
    private func handleRecognitionResultWithLLM(_ text: String) {
        if UserDefaults.standard.bool(forKey: "koe_llm_enabled") {
            statusText = "LLM修正中…"
            recognizedText = text
            postProcessWithLLM(text) { [weak self] processed in
                guard let self else { return }
                self.handleRecognitionResult(processed)
            }
        } else {
            handleRecognitionResult(text)
        }
    }

    /// 連続認識モード: 完了後に自動で録音再開
    private func handleContinuousMode() {
        if continuousMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isRecording else { return }
                self.startRecording()
            }
        }
    }

    // MARK: - Handoff

    private func publishHandoff(text: String) {
        // Handoff (Apple)
        let activity = NSUserActivity(activityType: "com.yuki.koe.transcription")
        activity.title = "Koe 音声入力"
        activity.userInfo = ["text": text, "timestamp": Date().timeIntervalSince1970]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.needsSave = true
        currentActivity = activity
        currentActivity?.becomeCurrent()

        // MacBridge — テキストをMacに送信 (Macのカーソル位置に入力)
        MacBridge.shared.sendText(text)
    }

    // MARK: - History

    func addToHistory(_ text: String) {
        let item = HistoryItem(text: text, date: Date())
        history.insert(item, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        saveHistory()

        // 自動コピー
        if autoCopy {
            UIPasteboard.general.string = text
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "koe_history")
        }
    }

    func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "koe_history"),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = items
        }
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "koe_history")
    }

    func searchHistory(_ query: String) -> [HistoryItem] {
        guard !query.isEmpty else { return history }
        return history.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Quick Phrases

    func sendQuickPhrase(_ phrase: String) {
        MacBridge.shared.sendText(phrase)
    }

    func addQuickPhrase(_ phrase: String) {
        quickPhrases.append(phrase)
        UserDefaults.standard.set(quickPhrases, forKey: "koe_quick_phrases")
    }

    func removeQuickPhrase(at offsets: IndexSet) {
        quickPhrases.remove(atOffsets: offsets)
        UserDefaults.standard.set(quickPhrases, forKey: "koe_quick_phrases")
    }

    // MARK: - LLM Post-Processing (chatweb.ai)

    // MARK: - Live Activity

    private func startLiveActivity() {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            let attrs = KoeRecordingAttributes(startTime: Date())
            let state = KoeRecordingAttributes.ContentState(isRecording: true, statusText: "録音中…", audioLevel: 0)
            recordingActivity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
        }
    }

    private func updateLiveActivity() {
        Task {
            await recordingActivity?.update(.init(state: .init(isRecording: true, statusText: "録音中…", audioLevel: Double(self.audioLevel)), staleDate: nil))
        }
    }

    private func endLiveActivity() {
        Task {
            await recordingActivity?.end(.init(state: .init(isRecording: false, statusText: "認識中…", audioLevel: 0), staleDate: nil), dismissalPolicy: .immediate)
            recordingActivity = nil
        }
    }

    // MARK: - LLM Post-Processing (chatweb.ai)

    private func postProcessWithLLM(_ text: String, completion: @escaping (String) -> Void) {
        let mode = UserDefaults.standard.string(forKey: "koe_llm_mode") ?? "correct"
        let instruction: String
        switch mode {
        case "email":
            instruction = "音声認識の結果を丁寧なメール文体に変換してください。変換後のテキストのみを出力してください。"
        case "chat":
            instruction = "音声認識の結果をカジュアルなチャットメッセージに変換してください。変換後のテキストのみを出力してください。"
        case "translate":
            instruction = "日本語は英語に、英語は日本語に翻訳してください。翻訳後のテキストのみを出力してください。"
        default: // correct
            instruction = "音声認識の結果を修正してください。誤字・脱字を修正し、適切な句読点を追加してください。修正後のテキストのみを出力してください。"
        }

        let body: [String: Any] = [
            "model": "auto",
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text]
            ],
            "max_tokens": 500,
            "temperature": 0.3
        ]

        guard let url = URL(string: "https://api.chatweb.ai/v1/chat/completions"),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(text); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // chatweb.ai は API キー不要（匿名アクセス可）
        // ユーザーが独自キーを設定している場合はKeychainから取得
        if let apiKey = KeychainHelper.get(key: "koe_api_key"), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String,
                      !content.isEmpty else {
                    completion(text) // フォールバック: 元のテキスト
                    return
                }
                completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.resume()
    }
}

struct HistoryItem: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date
    init(text: String, date: Date) {
        self.id = UUID()
        self.text = text
        self.date = date
    }
}
