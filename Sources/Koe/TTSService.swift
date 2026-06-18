import AppKit
import AVFoundation

// MARK: - バックエンド抽象化

protocol TTSBackend: AnyObject {
    func speak(_ text: String, lang: String)
    func stop()
}

/// macOS 組み込み音声（オフライン・無料）。
final class SayBackend: NSObject, TTSBackend {
    private let synth = NSSpeechSynthesizer()

    func speak(_ text: String, lang: String) {
        if let voice = Self.preferredVoice(for: lang) { synth.setVoice(voice) }
        synth.stopSpeaking()
        synth.startSpeaking(text)
    }

    func stop() { synth.stopSpeaking() }

    static func preferredVoice(for language: String) -> NSSpeechSynthesizer.VoiceName? {
        let preferred: [String: String] = [
            "ja": "com.apple.speech.synthesis.voice.kyoko",
            "en": "com.apple.speech.synthesis.voice.samantha",
            "zh": "com.apple.speech.synthesis.voice.sin-ji",
            "ko": "com.apple.speech.synthesis.voice.yuna",
        ]
        let prefix = String(language.prefix(2))
        guard let name = preferred[prefix] else { return nil }
        let voiceName = NSSpeechSynthesizer.VoiceName(rawValue: name)
        return NSSpeechSynthesizer.availableVoices.contains(voiceName) ? voiceName : nil
    }
}

/// ElevenLabs（高品質・要 API キー）。失敗 / オフライン時は say へフォールバック。
final class ElevenLabsBackend: NSObject, TTSBackend {
    private var player: AVAudioPlayer?
    private var task: URLSessionDataTask?
    private let fallback = SayBackend()

    func speak(_ text: String, lang: String) {
        let s = AppSettings.shared
        // オフラインモード or キー無しは say
        if s.offlineModeEnabled || s.elevenLabsAPIKey.isEmpty || s.elevenLabsVoiceID.isEmpty {
            fallback.speak(text, lang: lang); return
        }
        let voiceID = s.elevenLabsVoiceID
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            fallback.speak(text, lang: lang); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(s.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_multilingual_v2",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        stop()
        task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            guard let data, err == nil,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                klog("TTS(EL): failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)) → say")
                DispatchQueue.main.async { self.fallback.speak(text, lang: lang) }
                return
            }
            DispatchQueue.main.async {
                do {
                    self.player = try AVAudioPlayer(data: data)
                    self.player?.play()
                } catch {
                    klog("TTS(EL): playback error → say")
                    self.fallback.speak(text, lang: lang)
                }
            }
        }
        task?.resume()
    }

    func stop() {
        task?.cancel(); task = nil
        player?.stop(); player = nil
        fallback.stop()
    }
}

// MARK: - TTSService

/// 散在していた読み上げを集約。「完了通知＋要約」ポリシーを適用する。
final class TTSService {
    static let shared = TTSService()

    private var sayBackend = SayBackend()
    private var elBackend = ElevenLabsBackend()

    private var backend: TTSBackend {
        AppSettings.shared.ttsBackend == "elevenLabs" ? elBackend : sayBackend
    }

    private init() {}

    /// そのまま読み上げ（割り込み停止つき）。
    func speak(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lang = language ?? AppSettings.shared.language
        DispatchQueue.main.async {
            self.backend.stop()
            self.backend.speak(trimmed, lang: lang)
            klog("TTS: \(trimmed.prefix(60))")
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.sayBackend.stop()
            self.elBackend.stop()
        }
    }

    /// コマンド結果/応答を「完了通知＋要約」ポリシーで読み上げる。
    func speakResult(_ raw: String, language: String? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let lang = language ?? AppSettings.shared.language

        switch AppSettings.shared.ttsVerbosity {
        case "completionOnly":
            // 短い状況語ならそのまま、長ければ定型
            speak(text.count <= 16 ? text : "完了しました", language: lang)

        case "full":
            speak(text, language: lang)

        default: // completionPlusSummary
            let firstSentence = Self.firstSentence(text)
            if text.count <= 60 || firstSentence.count == text.count {
                speak(text, language: lang)
                return
            }
            // 先頭1文を即読み、続けて要約
            speak(firstSentence, language: lang)
            summarize(text) { [weak self] summary in
                guard let self, let summary, !summary.isEmpty else { return }
                self.speak("要するに、" + summary, language: lang)
            }
        }
    }

    // MARK: ヘルパー

    private static func firstSentence(_ text: String) -> String {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        var result = ""
        for ch in text {
            result.append(ch)
            if terminators.contains(ch) { break }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// LLM で1文要約。オフライン/失敗時は nil（先頭1文のみで打ち切り）。
    private func summarize(_ text: String, completion: @escaping (String?) -> Void) {
        if AppSettings.shared.offlineModeEnabled {
            completion(nil); return
        }
        let prompt = "次の内容を日本語で1文に要約してください。要約文のみ出力:\n\(String(text.prefix(2000)))"
        LLMProcessor.shared.processScreenContext(prompt: prompt) { result in
            let s = result.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(s.isEmpty ? nil : s)
        }
    }
}
