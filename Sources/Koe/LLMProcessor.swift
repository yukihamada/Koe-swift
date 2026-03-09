import Foundation

class LLMProcessor {
    static let shared = LLMProcessor()

    func process(text: String, instruction: String, completion: @escaping (String) -> Void) {
        let s = AppSettings.shared
        guard s.llmEnabled, !instruction.isEmpty, !s.llmAPIKey.isEmpty, !text.isEmpty else {
            completion(text); return
        }
        let body: [String: Any] = [
            "model": s.llmModel,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text]
            ],
            "max_tokens": 1000,
            "stream": false
        ]
        guard let url = URL(string: "\(s.llmBaseURL)/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(text); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(s.llmAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                klog("LLM: failed, using original")
                DispatchQueue.main.async { completion(text) }
                return
            }
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            klog("LLM done: '\(result)'")
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
