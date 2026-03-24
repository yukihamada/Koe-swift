import Foundation
import CoreBluetooth

/// ESP32 ↔ iPhone オーディオブリッジ
/// ESP32からPCM音声を受け取り → API送信 → TTS応答をBLEで返す
class BLEAudioBridge: NSObject, ObservableObject {

    static let audioTXUUID = CBUUID(string: "FFE5")  // ESP32→iPhone (notify)
    static let audioRXUUID = CBUUID(string: "FFE6")  // iPhone→ESP32 (write)

    @Published var isActive = false
    @Published var statusText = "待機中"

    private weak var peripheral: CBPeripheral?
    private var audioRXChar: CBCharacteristic?

    private var audioBuffer = Data()
    private let eouMarker = Data([0x00])  // end-of-utterance マーカー

    func start(peripheral: CBPeripheral, chars: [CBCharacteristic], scanner: BLEDeviceScanner? = nil) {
        self.peripheral = peripheral
        for c in chars {
            if c.uuid == Self.audioTXUUID {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.uuid == Self.audioRXUUID {
                audioRXChar = c
            }
        }
        // scannerのコールバックを設定してnotify受信を転送
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

    /// ESP32からのnotifyデータを受け取る (CBPeripheralDelegateから呼ぶ)
    func didReceiveAudioChunk(_ data: Data) {
        if data == eouMarker {
            // 発話終了 → APIに送信
            let captured = audioBuffer
            audioBuffer.removeAll()
            guard !captured.isEmpty else { return }
            Task {
                await self.processAudio(captured)
            }
        } else {
            audioBuffer.append(data)
        }
    }

    // MARK: - API送信 → TTS受信 → ESP32へ返送

    private func processAudio(_ pcmData: Data) async {
        await MainActor.run { statusText = "音声認識中..." }

        guard let url = URL(string: "https://api.chatweb.ai/api/v1/device/audio") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("koe-bridge", forHTTPHeaderField: "X-Device-Id")
        req.httpBody = pcmData

        do {
            let (responseData, _) = try await URLSession.shared.data(for: req)
            guard !responseData.isEmpty else {
                await MainActor.run { statusText = "待機中" }
                return
            }
            await MainActor.run { statusText = "応答送信中..." }
            sendToPheripheral(responseData)
            await MainActor.run { statusText = "ブリッジ接続中" }
        } catch {
            await MainActor.run { statusText = "エラー: \(error.localizedDescription)" }
        }
    }

    /// TTS音声をFFE6経由でESP32へ送信 (512バイトチャンク + EOU)
    private func sendToPheripheral(_ data: Data) {
        guard let peripheral, let char = audioRXChar else { return }
        let chunkSize = 512
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            peripheral.writeValue(Data(chunk), for: char, type: .withoutResponse)
            offset = end
            // BLE over-the-air flow control: 送りすぎ防止
            Thread.sleep(forTimeInterval: 0.005)
        }
        // EOU送信
        peripheral.writeValue(eouMarker, for: char, type: .withoutResponse)
    }
}
