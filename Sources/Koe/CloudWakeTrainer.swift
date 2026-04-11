import Foundation

/// koe-wake-train HTTPクライアント。
///
/// サーバー側仕様 (docs/wake-train-protocol.md 参照):
///   POST /v1/wake/train
///        body: {"text": "ヘイこえ", "model_name": "hey_koe", "lang": "ja"}
///        → 202 {"job_id": "<uuid>"}
///
///   GET /v1/wake/train/{job_id}
///        → 200 {"status":"pending|running|done|failed",
///               "progress":"...", "onnx_url":"https://..."}
///
///   GET {onnx_url}
///        → 200 application/octet-stream (.onnxバイナリ)
final class CloudWakeTrainer {
    enum CloudError: LocalizedError {
        case submit(String)
        case polling(String)
        case timeout
        case download(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .submit(let m):   return "リクエスト送信失敗: \(m)"
            case .polling(let m):  return "ステータス取得失敗: \(m)"
            case .timeout:         return "学習がタイムアウトしました（30分）"
            case .download(let m): return "モデルDL失敗: \(m)"
            case .server(let m):   return "サーバーエラー: \(m)"
            }
        }
    }

    private let base: URL
    private let session: URLSession
    private let pollInterval: TimeInterval = 15
    private let maxWait: TimeInterval = 1800  // 30分

    init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    /// 同期実行（呼び出し側のバックグラウンドキューで回すこと）。
    func train(
        text: String,
        modelName: String,
        savePath: String,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // 1. submit
        progress("サーバーに学習リクエスト送信中…")
        let jobIdResult = submitSync(text: text, modelName: modelName)
        let jobId: String
        switch jobIdResult {
        case .success(let id): jobId = id
        case .failure(let e):  completion(.failure(e)); return
        }

        // 2. poll
        let start = Date()
        while Date().timeIntervalSince(start) < maxWait {
            let statusResult = pollSync(jobId: jobId)
            switch statusResult {
            case .failure(let e):
                completion(.failure(e)); return
            case .success(let status):
                if let msg = status.progress, !msg.isEmpty {
                    progress(msg)
                }
                switch status.status {
                case "done":
                    guard let urlStr = status.onnxURL, let url = URL(string: urlStr) else {
                        completion(.failure(CloudError.server("done だが onnx_url が無い")))
                        return
                    }
                    progress("モデルをダウンロード中…")
                    if let e = downloadSync(from: url, to: savePath) {
                        completion(.failure(e))
                    } else {
                        completion(.success(savePath))
                    }
                    return
                case "failed":
                    completion(.failure(CloudError.server(status.progress ?? "unknown")))
                    return
                default:
                    break  // pending/running → sleep & retry
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        completion(.failure(CloudError.timeout))
    }

    // MARK: - sync helpers

    private func submitSync(text: String, modelName: String) -> Result<String, Error> {
        let url = base.appendingPathComponent("v1/wake/train")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_name": modelName,
            "lang": text.range(of: "\\p{Hiragana}|\\p{Katakana}|\\p{Han}", options: .regularExpression) != nil ? "ja" : "en",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(CloudError.submit("not started"))
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(CloudError.submit(err.localizedDescription)); return }
            guard let http = resp as? HTTPURLResponse else {
                result = .failure(CloudError.submit("no HTTP response")); return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(CloudError.submit("HTTP \(http.statusCode): \(body.prefix(200))"))
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["job_id"] as? String else {
                result = .failure(CloudError.submit("invalid response body"))
                return
            }
            result = .success(id)
        }.resume()
        sem.wait()
        return result
    }

    private struct JobStatus {
        let status: String
        let progress: String?
        let onnxURL: String?
    }

    private func pollSync(jobId: String) -> Result<JobStatus, Error> {
        let url = base.appendingPathComponent("v1/wake/train/\(jobId)")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<JobStatus, Error> = .failure(CloudError.polling("not started"))
        session.dataTask(with: url) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(CloudError.polling(err.localizedDescription)); return }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                result = .failure(CloudError.polling("bad status"))
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String else {
                result = .failure(CloudError.polling("invalid body"))
                return
            }
            result = .success(JobStatus(
                status: status,
                progress: obj["progress"] as? String,
                onnxURL: obj["onnx_url"] as? String
            ))
        }.resume()
        sem.wait()
        return result
    }

    private func downloadSync(from url: URL, to path: String) -> Error? {
        let sem = DispatchSemaphore(value: 0)
        var err: Error? = CloudError.download("not started")
        session.downloadTask(with: url) { tempURL, resp, e in
            defer { sem.signal() }
            if let e = e { err = CloudError.download(e.localizedDescription); return }
            guard let tempURL = tempURL else {
                err = CloudError.download("no temp URL"); return
            }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                err = CloudError.download("HTTP \(http.statusCode)"); return
            }
            do {
                let dest = URL(fileURLWithPath: path)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                err = nil
            } catch let moveErr {
                err = CloudError.download(moveErr.localizedDescription)
            }
        }.resume()
        sem.wait()
        return err
    }
}
