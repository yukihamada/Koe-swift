import Foundation

/// 音声メモをDocuments + UserDefaultsに保存するストア
final class VoiceMemoStore {
    static let shared = VoiceMemoStore()
    private let key = "koe_voice_memos"

    struct VoiceMemo: Codable, Identifiable {
        let id: UUID
        let text: String
        let date: Date
        let audioPath: String // Documents相対パス
    }

    private init() {}

    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// PCMサンプル(Float32, 16kHz mono)をWAVとして保存し、メモをUserDefaultsに追加
    func save(text: String, samples: [Float]) {
        let id = UUID()
        let filename = "memo_\(id.uuidString).wav"
        let fileURL = documentsDir.appendingPathComponent(filename)

        // WAV書き出し (16kHz, mono, Float32 → Int16)
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // PCM
        data.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append(contentsOf: "data".utf8)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.append(withUnsafeBytes(of: int16.littleEndian) { Data($0) })
        }

        try? data.write(to: fileURL)

        let memo = VoiceMemo(id: id, text: text, date: Date(), audioPath: filename)
        var memos = loadMemos()
        memos.insert(memo, at: 0)
        if memos.count > 200 { memos = Array(memos.prefix(200)) }
        if let encoded = try? JSONEncoder().encode(memos) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    func loadMemos() -> [VoiceMemo] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let memos = try? JSONDecoder().decode([VoiceMemo].self, from: data) else {
            return []
        }
        return memos
    }
}
