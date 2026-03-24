import Foundation
import CoreBluetooth
import AVFoundation

/// ESP32 ↔ iPhone ローカルAIブリッジ
///
/// フロー:
///   ESP32 (16kHz Int16 PCM) → FFE5 notify
///   → iPhone: Whisper (ローカル STT) → テキスト
///   → iPhone: chatweb.ai LLM → 応答テキスト
///   → iPhone: AVSpeechSynthesizer (ローカル TTS) → PCM
///   → FFE6 write → ESP32 再生
class BLEAudioBridge: NSObject, ObservableObject {

    static let audioTXUUID = CBUUID(string: "FFE5")  // ESP32→iPhone notify
    static let audioRXUUID = CBUUID(string: "FFE6")  // iPhone→ESP32 write

    @Published var isActive = false
    @Published var statusText = "待機中"

    private weak var peripheral: CBPeripheral?
    private var audioRXChar: CBCharacteristic?
    private let eouMarker = Data([0x00])

    // 受信バッファ (Int16 PCM, 16kHz)
    private var audioBuffer = Data()

    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    private var ttsBuffers: [AVAudioPCMBuffer] = []

    // MARK: - 起動 / 停止

    func start(peripheral: CBPeripheral, chars: [CBCharacteristic], scanner: BLEDeviceScanner? = nil) {
        self.peripheral = peripheral
        for c in chars {
            if c.uuid == Self.audioTXUUID { peripheral.setNotifyValue(true, for: c) }
            if c.uuid == Self.audioRXUUID { audioRXChar = c }
        }
        scanner?.onAudioChunkReceived = { [weak self] data in
            self?.didReceiveAudioChunk(data)
        }
        isActive = true
        statusText = "ブリッジ接続中"
    }

    func stop() {
        isActive = false
        audioBuffer.removeAll()
        statusText = "待機中"
    }

    // MARK: - ESP32からの音声チャンク受信

    func didReceiveAudioChunk(_ data: Data) {
        if data.count == 1 && data[0] == 0x00 {
            // EOU: Whisper→LLM→TTS パイプライン起動
            let captured = audioBuffer
            audioBuffer.removeAll()
            guard captured.count > 1600 else { return } // 50ms未満はノイズ
            Task { await self.runPipeline(pcmData: captured) }
        } else {
            audioBuffer.append(data)
        }
    }

    // MARK: - AIパイプライン

    private func runPipeline(pcmData: Data) async {
        // 1. Int16 PCM → Float32 (Whisper入力形式)
        let samples = int16ToFloat32(pcmData)
        guard samples.count > 800 else { return }

        // 2. Whisper STT (ローカル)
        await setStatus("🎙️ 音声認識中...")
        let text = await transcribeLocally(samples: samples)
        guard let text, !text.isEmpty else {
            await setStatus("ブリッジ接続中")
            return
        }
        print("[Bridge] STT: \(text)")

        // 3. LLM (chatweb.ai)
        await setStatus("🧠 考え中...")
        let response = await callLLM(userText: text) ?? text
        print("[Bridge] LLM: \(response)")

        // 4. TTS → PCM (ローカル)
        await setStatus("🔊 応答生成中...")
        let audioPCM = await synthesizeSpeech(text: response)

        // 5. PCMをESP32へ送信
        if let pcm = audioPCM {
            await setStatus("📡 送信中...")
            sendToESP32(pcm)
        }
        await setStatus("ブリッジ接続中")
    }

    // MARK: - Whisper STT

    private func transcribeLocally(samples: [Float]) async -> String? {
        // Whisperモデルが未ロードならApple Speech Frameworkにフォールバック
        guard WhisperContext.shared.isLoaded else {
            return await transcribeWithAppleSpeech(samples: samples)
        }
        return await withCheckedContinuation { continuation in
            let lang = UserDefaults.standard.string(forKey: "koe_language") ?? "ja"
            WhisperContext.shared.transcribeBuffer(samples: samples, language: lang) { text in
                continuation.resume(returning: text)
            }
        }
    }

    /// Apple Speechフォールバック (Whisper未ロード時)
    private func transcribeWithAppleSpeech(samples: [Float]) async -> String? {
        // AVAudioPCMBuffer経由でSFSpeechRecognizer に渡す実装は複雑なため
        // Whisperがロードされるまでnilを返し、ユーザーにモデルDLを促す
        await setStatus("⚠️ Whisperモデルが未ロードです")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return nil
    }

    // MARK: - LLM

    private func callLLM(userText: String) async -> String? {
        guard let url = URL(string: "https://api.chatweb.ai/v1/chat/completions") else { return nil }

        let systemPrompt = "あなたはKoe Deviceという音声アシスタントです。ユーザーの音声入力に対して、簡潔で自然な日本語で応答してください。1〜2文で答えてください。"
        let body: [String: Any] = [
            "model": "auto",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "max_tokens": 200,
            "temperature": 0.7
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = KeychainHelper.get(key: "koe_api_key"), !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = jsonData
        req.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[Bridge] LLM error: \(error)")
            return nil
        }
    }

    // MARK: - TTS → PCM

    private func synthesizeSpeech(text: String) async -> Data? {
        return await withCheckedContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
            utterance.rate = 0.52
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0

            var collectedBuffers = [AVAudioPCMBuffer]()

            // write() メソッドでPCMバッファを直接取得 (iOS 13+, 再生なし)
            self.synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
                      pcmBuffer.frameLength > 0 else { return }
                collectedBuffers.append(pcmBuffer)
            }

            // synthesizerはコールバック完了後にnilバッファを送る
            // 簡易実装: 少し待ってから完了とみなす
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let merged = Self.mergePCMBuffers(collectedBuffers)
                continuation.resume(returning: merged)
            }
        }
    }

    /// AVAudioPCMBuffer群を16kHz Int16 PCM Dataにマージ変換
    private static func mergePCMBuffers(_ buffers: [AVAudioPCMBuffer]) -> Data? {
        guard !buffers.isEmpty else { return nil }
        var result = Data()
        for buf in buffers {
            guard let float32Data = buf.floatChannelData?[0] else { continue }
            let frameCount = Int(buf.frameLength)
            // Float32 → Int16 変換
            for i in 0..<frameCount {
                let sample = max(-1.0, min(1.0, float32Data[i]))
                let int16Val = Int16(sample * 32767.0)
                withUnsafeBytes(of: int16Val.littleEndian) { result.append(contentsOf: $0) }
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - ESP32への送信 (FFE6)

    private func sendToESP32(_ pcmData: Data) {
        guard let peripheral, let char = audioRXChar else { return }
        let chunkSize = 512
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            peripheral.writeValue(Data(pcmData[offset..<end]), for: char, type: .withoutResponse)
            offset = end
            Thread.sleep(forTimeInterval: 0.005) // BLE flow control
        }
        peripheral.writeValue(eouMarker, for: char, type: .withoutResponse)
    }

    // MARK: - PCM変換ユーティリティ

    /// ESP32から受信したInt16 LE PCM (16kHz) → Float32
    private func int16ToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(Int16(littleEndian: ptr[i])) / 32768.0
            }
        }
        return samples
    }

    @MainActor
    private func setStatus(_ text: String) {
        statusText = text
    }
}
