import AppKit

/// 🎙→📻 ボイスレコーダーの録音を「自分の声かどうか」確認したうえで、自分のラジオ(部屋)に載せる。
/// 声の照合は m5 の /voice/compare を直叩き(koe.live の公開 /api/voice-login はブラウザセッション向けの
/// ticket/email/TOFU 機構があり、信頼済みローカルアプリには不要な複雑さのため経由しない)。
/// 違う声だった場合は絶対に無断で声登録しない — その場でお題を読む生存確認(ライブネス)が
/// KOE の同意ゲートの心臓部であり、録音に写り込んだだけの声を勝手に登録すると本人の同意なく
/// 声紋が作られてしまう。代わりに /enroll をブラウザで開いて本人に委ねる。
final class RadioUploader {
    static let shared = RadioUploader()

    private static let roomKeyKeychainKey = "koeRoomKey"
    private static let koeLiveBase = "https://koe.live"
    private static let roomHandle = "yuki"
    /// koe.live 側の VOICE_LOGIN_SIM_THRESHOLD(既定0.90)と同一基準に揃える。
    private static let matchThreshold: Double = 0.90

    enum VoiceCheckResult {
        case isYuki(similarity: Double)
        case notYuki(similarity: Double?)
        case checkFailed(String)
    }

    enum UploadOutcome {
        case success(roomURL: String)
        case failure(String)
    }

    // MARK: - ① 声の照合

    func checkVoice(_ record: VoiceMemoRecord, completion: @escaping (VoiceCheckResult) -> Void) {
        guard let apiKey = resolveM5Key() else {
            completion(.checkFailed("m5のキーが未設定です"))
            return
        }
        guard let refURL = Bundle.main.url(forResource: "ref_yuki", withExtension: "wav"),
              let refData = try? Data(contentsOf: refURL) else {
            completion(.checkFailed("参照音声が同梱されていません(要ビルド再生成)"))
            return
        }
        guard let recData = try? Data(contentsOf: record.fileURL) else {
            completion(.checkFailed("録音ファイルが読めません"))
            return
        }
        Task {
            let result = await Self.compare(apiKey: apiKey, a: recData, b: refData)
            await MainActor.run { completion(result) }
        }
    }

    private static func compare(apiKey: String, a: Data, b: Data) async -> VoiceCheckResult {
        for host in candidateHosts() {
            guard let url = URL(string: "http://\(host):8790/voice/compare") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let payload: [String: Any] = [
                "audio_a_b64": a.base64EncodedString(),
                "audio_b_b64": b.base64EncodedString(),
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    klog("RadioUploader: compare via \(host) returned status \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    continue
                }
                guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (j["ok"] as? Bool) == true, let sim = j["similarity"] as? Double else {
                    continue
                }
                klog("RadioUploader: compare via \(host) similarity=\(sim)")
                return sim >= matchThreshold ? .isYuki(similarity: sim) : .notYuki(similarity: sim)
            } catch {
                klog("RadioUploader: compare via \(host) failed: \(error.localizedDescription)")
            }
        }
        return .checkFailed("m5(声の照合サーバ)に接続できませんでした")
    }

    private static func candidateHosts() -> [String] {
        let host = UserDefaults.standard.string(forKey: "m5SpeakHost").flatMap { $0.isEmpty ? nil : $0 } ?? "m5.local"
        var hosts = [host]
        if host != "192.168.0.47" { hosts.append("192.168.0.47") }
        return hosts
    }

    // MARK: - ② 自分の部屋(ラジオ)へアップロード

    func uploadToRoom(_ record: VoiceMemoRecord, completion: @escaping (UploadOutcome) -> Void) {
        guard let key = resolveRoomKey() else {
            completion(.failure("部屋の鍵が未設定です"))
            return
        }
        guard let data = try? Data(contentsOf: record.fileURL) else {
            completion(.failure("録音ファイルが読めません"))
            return
        }
        Task {
            let outcome = await Self.segrecordAndConfirm(key: key, audio: data, dur: record.duration)
            await MainActor.run { completion(outcome) }
        }
    }

    private static func segrecordAndConfirm(key: String, audio: Data, dur: Double) async -> UploadOutcome {
        guard var startComps = URLComponents(string: "\(koeLiveBase)/api/live/segrecord") else {
            return .failure("URLの構築に失敗しました")
        }
        startComps.queryItems = [URLQueryItem(name: "h", value: roomHandle), URLQueryItem(name: "k", value: key)]
        guard let startURL = startComps.url else { return .failure("URLの構築に失敗しました") }

        var startReq = URLRequest(url: startURL)
        startReq.httpMethod = "POST"
        startReq.timeoutInterval = 60
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let b64 = "data:audio/m4a;base64," + audio.base64EncodedString()
        startReq.httpBody = try? JSONSerialization.data(withJSONObject: ["audio_b64": b64, "dur": dur])

        let startData: Data
        do { (startData, _) = try await URLSession.shared.data(for: startReq) } catch {
            return .failure("アップロード失敗: \(error.localizedDescription)")
        }
        guard let sj = try? JSONSerialization.jsonObject(with: startData) as? [String: Any],
              let draftID = sj["draft_id"] as? String else {
            let detail = (try? JSONSerialization.jsonObject(with: startData) as? [String: Any])?["detail"] as? String
            return .failure(detail ?? "下書きの作成に失敗しました")
        }
        let text = (sj["transcript"] as? String) ?? ""

        guard var confirmComps = URLComponents(string: "\(koeLiveBase)/api/live/segrecord/confirm") else {
            return .failure("URLの構築に失敗しました")
        }
        confirmComps.queryItems = [URLQueryItem(name: "h", value: roomHandle), URLQueryItem(name: "k", value: key)]
        guard let confirmURL = confirmComps.url else { return .failure("URLの構築に失敗しました") }

        var confirmReq = URLRequest(url: confirmURL)
        confirmReq.httpMethod = "POST"
        confirmReq.timeoutInterval = 30
        confirmReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        confirmReq.httpBody = try? JSONSerialization.data(withJSONObject: ["draft_id": draftID, "dur": dur, "text": text])

        let confirmData: Data
        do { (confirmData, _) = try await URLSession.shared.data(for: confirmReq) } catch {
            return .failure("確定に失敗しました: \(error.localizedDescription)")
        }
        guard let cj = try? JSONSerialization.jsonObject(with: confirmData) as? [String: Any],
              (cj["ok"] as? Bool) == true else {
            let detail = (try? JSONSerialization.jsonObject(with: confirmData) as? [String: Any])?["detail"] as? String
            return .failure(detail ?? "確定に失敗しました")
        }
        return .success(roomURL: "\(koeLiveBase)/live/\(roomHandle)")
    }

    // MARK: - 未登録の声への案内(絶対に無断登録しない)

    func promptEnrollIfNeeded() {
        let alert = NSAlert()
        alert.messageText = "登録されていない声のようです"
        alert.informativeText = "この録音の声は、あなたの登録済みの声と一致しませんでした。KOEでは本人の同意なく声を登録しません。新しい声として使いたい場合は、ブラウザで /enroll を開いて、その場でお題を読んでください。"
        alert.addButton(withTitle: "koe.live/enroll を開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://koe.live/enroll")!)
        }
    }

    // MARK: - 鍵(KoeAccount 共通・全機能で1回の接続を共有。部屋の鍵だけは別途)

    private func resolveM5Key() -> String? {
        KoeAccount.resolveWithPasteFallback(
            promptTitle: "Koe API キーが未設定です",
            promptBody: "本人声読み上げ機能と同じキーを使います。「ブラウザで接続」を押すとログインリンクが届き、開くだけで自動的に接続されます。"
        )
    }

    private func resolveRoomKey() -> String? {
        if let k = KeychainHelper.get(Self.roomKeyKeychainKey), !k.isEmpty { return k }
        let alert = NSAlert()
        alert.messageText = "自分の部屋(ラジオ)の鍵が未設定です"
        alert.informativeText = "koe.live の /myroom 編集リンクにある k= の値（部屋の鍵）を貼り付けてください（Keychain に保存されます）。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "部屋の鍵"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        KeychainHelper.set(key, for: Self.roomKeyKeychainKey)
        return key
    }
}
