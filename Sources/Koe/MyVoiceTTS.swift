import AVFoundation
import CryptoKit
import Foundation

/// 自分の声で読み上げ (本人指示 2026-06-12)。
///
/// 合成は koe-mcp (Fly nrt, https://mcp.koe.live・Rust/axum) の `speak` ツール
/// (本人声クローン "Yuki HQ" / ElevenLabs multilingual_v2) を HTTP で呼び、mp3 を受け取って再生する。
/// 旧実装は `ssh m5 → koe_say.py` だったが SSH 依存を撤廃し HTTP API 化した
/// (NOU×KOE 統合・C 担当 / 2026-06-14)。
///
/// 認証: 鍵を持っていれば 1 日 200 回・500 字、無ければ匿名 1 日 5 回・120 字。
/// KOE 鍵 (koe_…) は環境変数 `KOE_API_KEY` か Keychain (`koeAPIKey`) からのみ読み、
/// コード/ログ/出力に生値を出さない。鍵が無ければ匿名で叩く。
/// エンドポイントは `defaults write com.yuki.koe myVoiceTTSEndpoint <url>` で変更可 (既定 https://mcp.koe.live/mcp)。
/// 同一テキストはローカルキャッシュ (sha256) に保存して即時再生。
///
/// 注: クラウド (ElevenLabs) 経由になるため「完全ローカル本人声」を厳密に満たすには
/// 別途 端末内/m5 内 TTS 経路の保持が要る (設計 risks 参照)。本実装は SSH 撤廃と HTTP 一本化が目的。
final class MyVoiceTTS: NSObject, AVAudioPlayerDelegate {
    static let shared = MyVoiceTTS()

    private var player: AVAudioPlayer?
    private var currentTask: URLSessionDataTask?
    private(set) var isGenerating = false

    /// 匿名時の文字数上限 (koe-mcp ANON_TEXT_CHARS 準拠)。超過分は切り詰める。
    private let anonTextLimit = 120
    /// 鍵あり時の文字数上限 (koe-mcp MAX_TEXT_CHARS 準拠)。
    private let keyedTextLimit = 500

    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe/myvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// koe-mcp の MCP エンドポイント (JSON-RPC over HTTP)。
    private var endpoint: URL {
        let s = UserDefaults.standard.string(forKey: "myVoiceTTSEndpoint") ?? ""
        return URL(string: s.isEmpty ? "https://mcp.koe.live/mcp" : s) ?? URL(string: "https://mcp.koe.live/mcp")!
    }

    /// KOE 鍵 (任意)。env > Keychain の順で読み、生値はログに出さない。
    private var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["KOE_API_KEY"], !env.isEmpty { return env }
        if let kc = KeychainHelper.get("koeAPIKey"), !kc.isEmpty { return kc }
        return nil
    }

    /// テキストを自分の声で読み上げる。完了/失敗で completion(成功か, メッセージ)。
    func speak(_ text: String, completion: @escaping (Bool, String) -> Void) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(false, "テキストが空です"); return }
        guard !isGenerating else { completion(false, "生成中です"); return }

        // 文字数上限でクライアント側でも切り詰め (サーバ拒否でエラーになるのを避ける)。
        let hasKey = apiKey != nil
        let limit = hasKey ? keyedTextLimit : anonTextLimit
        if trimmed.count > limit {
            trimmed = String(trimmed.prefix(limit))
        }

        // キャッシュ命中なら即再生 (鍵有無で内容は変わらないため共通キー)。
        let key = SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let cached = cacheDir.appendingPathComponent("\(key).mp3")
        if FileManager.default.fileExists(atPath: cached.path) {
            play(url: cached, completion: completion)
            return
        }

        isGenerating = true
        klog("MyVoiceTTS: generating (\(trimmed.count) chars) via koe-mcp speak (keyed=\(hasKey))")

        // MCP tools/call: speak{text}
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "speak",
                "arguments": ["text": trimmed],
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            isGenerating = false
            completion(false, "リクエスト生成に失敗しました")
            return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = apiKey {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = bodyData
        req.timeoutInterval = 90  // 生成は数秒〜十数秒。旧 SSH 実装と同じ 90 秒で見切る。

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            self.currentTask = nil
            self.isGenerating = false

            if let error {
                klog("MyVoiceTTS: HTTP failed — \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false, "声の生成に失敗しました（接続を確認）") }
                return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, status == 200 else {
                klog("MyVoiceTTS: bad status \(status)")
                let msg = status == 429
                    ? "本日の読み上げ上限に達しました（鍵を取ると枠が広がります）"
                    : "声の生成に失敗しました（サーバー応答 \(status)）"
                DispatchQueue.main.async { completion(false, msg) }
                return
            }

            // JSON-RPC レスポンスから audio(base64 mp3) を取り出す。
            guard let mp3 = self.extractAudioMP3(from: data) else {
                klog("MyVoiceTTS: no audio in response (\(data.count) bytes)")
                DispatchQueue.main.async { completion(false, "音声データが取得できませんでした") }
                return
            }

            // mp3 マジック (ID3 / 0xFF) のゆるい検証 — エラーテキストを再生しない。
            let looksLikeMP3 = mp3.count > 4_000 &&
                (mp3.prefix(3) == Data("ID3".utf8) || mp3.first == 0xFF)
            guard looksLikeMP3 else {
                klog("MyVoiceTTS: decoded data not mp3 (bytes=\(mp3.count))")
                DispatchQueue.main.async { completion(false, "音声データが不正です") }
                return
            }

            try? mp3.write(to: cached, options: .atomic)
            klog("MyVoiceTTS: generated \(mp3.count / 1024)KB → cache \(key)")
            DispatchQueue.main.async { self.play(url: cached, completion: completion) }
        }
        currentTask = task
        task.resume()
    }

    /// MCP tools/call の戻り値から最初の audio コンテンツ(base64 mp3)を Data に復号して返す。
    /// 形: { result: { content: [ { type:"audio", data:"<b64>", mimeType:"audio/mpeg" }, ... ] } }
    private func extractAudioMP3(from data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        for item in content {
            if (item["type"] as? String) == "audio",
               let b64 = item["data"] as? String,
               let bytes = Data(base64Encoded: b64) {
                return bytes
            }
        }
        return nil
    }

    func stop() {
        player?.stop()
        player = nil
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
    }

    private func play(url: URL, completion: @escaping (Bool, String) -> Void) {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            player = p
            p.play()
            completion(true, "")
        } catch {
            completion(false, "再生に失敗しました")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
    }
}
