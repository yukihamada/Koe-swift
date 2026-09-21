import AppKit
import AVFoundation

/// m5 の synth_verified TTS(誤読ゼロ本人声)を叩いて要約を読み上げるクライアント。
/// 3段フォールバック(m5.local → IP直 → voice.koe.live 経由)+ 全滅時は OS標準音声で無音にしない。
final class M5SpeakClient: NSObject {
    static let shared = M5SpeakClient()

    private var player: AVAudioPlayer?
    private var speechSynth: NSSpeechSynthesizer?

    enum SpeakOutcome {
        case playedM5
        case playedFallbackVoice
        case failed(String)
    }

    /// 指定レコードの要約(無ければ文字起こし冒頭120字)を本人声で読み上げる。
    func speak(_ record: VoiceMemoRecord, completion: @escaping (SpeakOutcome) -> Void) {
        let text = summaryText(for: record)
        guard !text.isEmpty else {
            completion(.failed("読み上げるテキストがありません(文字起こし未完了)"))
            return
        }

        let cacheURL = VoiceMemoLibrary.ttsCacheDir.appendingPathComponent("\(record.id.uuidString).mp3")
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            playMP3(at: cacheURL)
            completion(.playedM5)
            return
        }

        guard let apiKey = resolveApiKey() else {
            completion(.failed("キーが未設定です"))
            return
        }

        Task {
            if let mp3 = await fetchFromM5(text: text, apiKey: apiKey) {
                try? mp3.write(to: cacheURL)
                await MainActor.run {
                    self.playMP3(at: cacheURL)
                    completion(.playedM5)
                }
            } else {
                await MainActor.run {
                    self.speakWithSystemVoice(text)
                    completion(.playedFallbackVoice)
                }
            }
        }
    }

    private func summaryText(for record: VoiceMemoRecord) -> String {
        if let s = record.summary, !s.isEmpty { return s }
        if let t = record.transcript, !t.isEmpty { return String(t.prefix(120)) }
        return ""
    }

    // MARK: - m5 エンドポイント(3段フォールバック)

    private func candidateURLs() -> [URL] {
        let host = UserDefaults.standard.string(forKey: "m5SpeakHost").flatMap { $0.isEmpty ? nil : $0 } ?? "m5.local"
        var urls: [URL] = []
        if let u = URL(string: "http://\(host):8790/speak") { urls.append(u) }
        if host != "192.168.0.47", let u = URL(string: "http://192.168.0.47:8790/speak") { urls.append(u) }
        if let u = URL(string: "https://voice.koe.live/speak") { urls.append(u) }
        return urls
    }

    private func fetchFromM5(text: String, apiKey: String) async -> Data? {
        for url in candidateURLs() {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = url.host == "voice.koe.live" ? 90 : 4
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let payload: [String: Any] = ["text": text, "user_id": "default"]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
                    klog("M5SpeakClient: success via \(url.host ?? "?")")
                    return data
                }
                klog("M5SpeakClient: \(url.host ?? "?") returned status \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            } catch {
                klog("M5SpeakClient: \(url.host ?? "?") failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    // MARK: - 再生

    private func playMP3(at url: URL) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            klog("M5SpeakClient: mp3 playback failed for \(url.lastPathComponent)")
            return
        }
        player = p
        p.play()
    }

    /// m5 に全く到達できない場合、無音で失敗させず OS 標準音声で読み上げる。
    private func speakWithSystemVoice(_ text: String) {
        let synth = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: "com.apple.speech.synthesis.voice.Kyoko"))
            ?? NSSpeechSynthesizer()
        speechSynth = synth
        synth.startSpeaking(text)
    }

    // MARK: - API キー(KoeAccount 共通・全機能で1回の接続を共有)

    private func resolveApiKey() -> String? {
        KoeAccount.resolveWithPasteFallback(
            promptTitle: "本人声読み上げの API キーが未設定です",
            promptBody: "「ブラウザで接続」を押すとログインリンクが届き、開くだけで自動的に接続されます。"
        )
    }
}
