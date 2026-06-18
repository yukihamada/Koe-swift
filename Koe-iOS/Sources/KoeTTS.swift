import Foundation
import AVFoundation

/// 「話す → 本人のクローン声で再生」。
/// m5 のローカル本人声 TTS（Qwen-TTS, voice.koe.live/speak）を叩き、返ってきた mp3 を再生する。
/// ElevenLabs は使わない（完全ローカル・APIキー不要・無料）。
@MainActor
final class KoeTTS: NSObject, ObservableObject {
    static let shared = KoeTTS()

    enum State: Equatable { case idle, loading, playing, error(String) }
    @Published var state: State = .idle

    struct Balance: Equatable { let balance: Int; let freeRemaining: Int; let freeDaily: Int }
    @Published var credits: Balance? = nil
    @Published var purchaseEnabled = false
    @Published var jpyPerCredit = 20

    private let base = "https://voice.koe.live"
    private var endpoint: URL { URL(string: base + "/speak")! }
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()

    /// クレジット口座ID（端末ごとに固定・Keychain）。残高/無料枠の課金キー。
    static let acctKey = "koe_acct_id"
    var acct: String {
        if let a = KeychainHelper.get(key: Self.acctKey), !a.isEmpty { return a }
        let a = "ios-" + UUID().uuidString.lowercased()
        KeychainHelper.save(key: Self.acctKey, value: a)
        return a
    }

    /// 残高を取得して `credits` を更新（公開エンドポイント・認証不要）。
    func refreshBalance() async {
        guard let url = URL(string: base + "/credits/balance") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["acct": acct])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        credits = Balance(
            balance: (j["balance"] as? Int) ?? 0,
            freeRemaining: (j["free_remaining"] as? Int) ?? 0,
            freeDaily: (j["free_daily"] as? Int) ?? 0)
    }

    /// 購入が有効か（Stripe接続済みか）と単価を取得。
    func loadConfig() async {
        guard let url = URL(string: base + "/credits/config") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        purchaseEnabled = (j["purchase_enabled"] as? Bool) ?? false
        jpyPerCredit = (j["jpy_per_credit"] as? Int) ?? 20
    }

    /// クレジット購入のStripe Checkout URLを取得（開くのは呼び出し側）。
    func checkoutURL(credits n: Int) async -> URL? {
        guard let url = URL(string: base + "/credits/checkout") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["acct": acct, "credits": n])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (j["ok"] as? Bool) == true, let s = j["url"] as? String else { return nil }
        return URL(string: s)
    }

    /// テキストを本人声で再生する。lang指定で翻訳読み上げ（サーバ側合成言語）。
    func speakInMyVoice(_ text: String, lang: String = "ja") async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .loading

        var body: [String: Any] = [
            "text": trimmed,
            "format": "mp3",
            "user_id": "default",   // default = 本人声（Yuki）
            "acct": acct,           // クレジット課金キー（端末固定）
            "lang": lang,
        ]
        // 合成先：ネットワーク(自分のMac優先→無ければ他人のMac)を使うか、中央(共有)か。
        // Macを持たない人は既定(中央)のままで使える。持っている人はノードIDで自分のMacへ。
        if UserDefaults.standard.bool(forKey: "koe_tts_use_network") {
            body["route"] = "nodes"
            let node = (UserDefaults.standard.string(forKey: "koe_tts_prefer_node") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !node.isEmpty { body["prefer_node"] = node }
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.ttsToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120   // ローカル合成は数秒〜十数秒かかる
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200,
               (resp.mimeType?.contains("audio") ?? false) || data.count > 1000 {
                try playMP3(data)
                await refreshBalance()   // 合成で残高/無料枠が動くので更新
                return
            }
            if code == 402 {
                // クレジット不足は意図的なエラー（フォールバックしない）
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                state = .error(prettify(detail ?? "クレジットが足りません"))
                return
            }
            // 5xx等サーバ異常 → 端末内合成にフォールバック（必ず鳴らす）
            playOnDevice(trimmed, lang: lang)
        } catch {
            // ネットワーク不通（m5ダウン等）→ 端末内合成にフォールバック
            playOnDevice(trimmed, lang: lang)
        }
    }

    /// 本人声サーバに繋がらない時の保険：端末内の音声合成で必ず読み上げる。
    private func playOnDevice(_ text: String, lang: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Self.bcp47(lang))
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.delegate = self
        synth.speak(u)
        state = .playing
    }

    private static func bcp47(_ lang: String) -> String {
        switch lang {
        case "en": return "en-US"
        case "zh": return "zh-CN"
        case "es": return "es-ES"
        case "ko": return "ko-KR"
        default: return "ja-JP"
        }
    }

    private func playMP3(_ data: Data) throws {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        state = .playing
    }

    /// サーバの生エラーを、ユーザー向けに優しく言い換える。
    private func prettify(_ raw: String) -> String {
        if raw.contains("401") || raw.lowercased().contains("unauthorized")
            || raw.lowercased().contains("token") {
            return "本人声サーバに接続できませんでした（認証）。少し時間をおいて試してください。"
        }
        if raw.lowercased().contains("too long") || raw.contains("長") {
            return "文章が長すぎます。短くして試してください。"
        }
        return raw
    }
}

extension KoeTTS: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.state = .idle }
    }
}

extension KoeTTS: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.state = .idle }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.state = .idle }
    }
}
